// Raw bits at every width, the fixed-width unsigned helpers through uint64,
// uint128, and bool: accept paths and truncation refusals.

import 'dart:typed_data';

import 'package:serialize/serialize.dart';

import 'harness.dart';

void run() {
  test('serializeBits: round trips at the four golden widths', () {
    final cases = [(13, 4), (1445, 11), (11259375, 24), (0xDEADBEEF, 32)];
    final writer = WriteStream(Uint8List(16));
    for (final (value, bits) in cases) {
      expect(writer.serializeBits(Ref<int>(value), bits), 'write $bits bits');
    }
    writer.flush();
    expectEquals(writer.bitsProcessed, 4 + 11 + 24 + 32, 'total bits');
    final reader = ReadStream(writer.data());
    for (final (value, bits) in cases) {
      final read = Ref<int>(0);
      expect(reader.serializeBits(read, bits), 'read $bits bits');
      expectEquals(read.value, value, 'round trip at $bits bits');
    }
  });

  test('serializeBits64: single group up to 32, split lo/hi above', () {
    for (final (value, bits) in [
      (0x1FFFFFFFF, 33),
      (0x123456789A, 40),
      (0x123456789ABCDEF0, 61),
      (-1, 64), // all 64 bits set
    ]) {
      final writer = WriteStream(Uint8List(16));
      expect(writer.serializeBits64(Ref<int>(value), bits), 'write $bits');
      writer.flush();
      expectEquals(writer.bitsProcessed, bits, 'bits processed');
      final reader = ReadStream(writer.data());
      final read = Ref<int>(0);
      expect(reader.serializeBits64(read, bits), 'read $bits');
      expectEquals(
        read.value,
        value & ((bits == 64) ? -1 : (1 << bits) - 1),
        'round trip at $bits bits',
      );
    }
  });

  test('unsigned helpers: uint8/16/32/64 are raw bits at their widths', () {
    final writer = WriteStream(Uint8List(16));
    writer.serializeUint8(Ref<int>(0x7F));
    writer.serializeUint16(Ref<int>(0x1234));
    writer.serializeUint32(Ref<int>(0x12345678));
    writer.serializeUint64(Ref<int>(0x123456789ABCDEF0));
    writer.flush();
    expectEquals(writer.bitsProcessed, 8 + 16 + 32 + 64, 'total bits');
    final reader = ReadStream(writer.data());
    final read = Ref<int>(0);
    reader.serializeUint8(read);
    expectEquals(read.value, 0x7F, 'uint8');
    reader.serializeUint16(read);
    expectEquals(read.value, 0x1234, 'uint16');
    reader.serializeUint32(read);
    expectEquals(read.value, 0x12345678, 'uint32');
    reader.serializeUint64(read);
    expectEquals(read.value, 0x123456789ABCDEF0, 'uint64');
  });

  test('serializeUint64: aligned, the wire is the value little-endian', () {
    final buffer = Uint8List(8);
    final writer = WriteStream(buffer);
    writer.serializeUint64(Ref<int>(0x123456789ABCDEF0));
    writer.flush();
    expectBytes(buffer, const [
      0xF0,
      0xDE,
      0xBC,
      0x9A,
      0x78,
      0x56,
      0x34,
      0x12,
    ], 'little-endian bytes');
  });

  test('serializeUint128: round trip and the two-halves convention', () {
    const value = UInt128(0x0123456789ABCDEF, 0xFEDCBA9876543210);
    final writer = WriteStream(Uint8List(16));
    expect(writer.serializeUint128(Ref<UInt128>(value)), 'write');
    writer.flush();
    expectEquals(writer.bitsProcessed, 128, 'always 128 bits');
    final reader = ReadStream(writer.data());
    final read = Ref<UInt128>(UInt128.zero);
    expect(reader.serializeUint128(read), 'read');
    expectEquals(read.value, value, 'round trip');
  });

  test('serializeBool: one bit each way', () {
    final writer = WriteStream(Uint8List(8));
    writer.serializeBool(Ref<bool>(true));
    writer.serializeBool(Ref<bool>(false));
    writer.serializeBool(Ref<bool>(true));
    writer.flush();
    expectEquals(writer.bitsProcessed, 3, 'three bits');
    final reader = ReadStream(writer.data());
    final read = Ref<bool>(false);
    reader.serializeBool(read);
    expectEquals(read.value, true, 'first');
    reader.serializeBool(read);
    expectEquals(read.value, false, 'second');
    reader.serializeBool(read);
    expectEquals(read.value, true, 'third');
  });

  test('truncation refusals: bits, bits64, uint128, bool', () {
    final read = Ref<int>(0);
    expect(!ReadStream(Uint8List(0)).serializeBits(read, 1), 'bits on empty');
    expect(!ReadStream(Uint8List(1)).serializeBits(read, 9), '9 bits from 8');
    expect(
      !ReadStream(Uint8List(4)).serializeBits64(read, 33),
      '33 bits from 32',
    );
    // the second half of a 64-bit read past the end: partial consumption is
    // terminal for the stream, per the reference's group-by-group checks
    final reader = ReadStream(Uint8List(5));
    expect(!reader.serializeBits64(read, 64), '64 bits from 40');
    expect(
      !ReadStream(Uint8List(8)).serializeUint128(Ref<UInt128>(UInt128.zero)),
      '128 bits from 64',
    );
    expect(
      !ReadStream(Uint8List(0)).serializeBool(Ref<bool>(false)),
      'bool on empty',
    );
  });

  // STANDARD.md, "bits": the bound value < 2^bits holds at every width in
  // [1,64] and not only at 32 or fewer. The predicate is what the write side
  // asserts, and it runs on the caller's own value: the bit writer masks a
  // value to the field width, so a check placed after that masking is handed a
  // value the masking already made legal and can never report the truncation
  // it exists to diagnose.
  test('valueFitsInBits: the caller value, before any masking', () {
    expect(valueFitsInBits(0xFF, 8), '0xFF fits 8 bits');
    expect(!valueFitsInBits(0x100, 8), '0x100 does not fit 8 bits');
    expect(!valueFitsInBits(0x1FF, 8), '0x1FF does not fit 8 bits');
    expect(valueFitsInBits(0xFFFFFFFF, 32), 'the 32-bit maximum fits 32 bits');
    expect(!valueFitsInBits(0x100000000, 32), '2^32 does not fit 32 bits');
    // the bound binds above 32 too, which is where a mask-then-check form
    // stops being visible at all
    expect(valueFitsInBits(0x1FFFFFFFF, 33), 'the 33-bit maximum fits 33 bits');
    expect(!valueFitsInBits(0x200000000, 33), '2^33 does not fit 33 bits');
    expect(!valueFitsInBits(-1, 63), 'a raw bit field is unsigned');
    expect(valueFitsInBits(-1, 64), 'all 64 bits set fits 64 bits');
  });

  test('serializeBits: a value wider than the field is caller error', () {
    if (!assertsEnabled) {
      return; // a release build performs no write-side validation
    }
    for (final (value, bits) in [
      (0x1FF, 8),
      (0x100000000, 32),
      (0x200000000, 33),
      (-1, 63),
    ]) {
      expectThrows(
        () => bits <= 32
            ? WriteStream(Uint8List(16)).serializeBits(Ref<int>(value), bits)
            : WriteStream(Uint8List(16)).serializeBits64(Ref<int>(value), bits),
        'writing $value in $bits bits',
      );
      // the negative control: the widest value that does fit must not fire
      final inside = (1 << bits) - 1;
      expect(
        bits <= 32
            ? WriteStream(Uint8List(16)).serializeBits(Ref<int>(inside), bits)
            : WriteStream(
                Uint8List(16),
              ).serializeBits64(Ref<int>(inside), bits),
        'writing $inside in $bits bits',
      );
    }
  });
}
