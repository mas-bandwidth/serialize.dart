// The golden wire format battery: the family's cross-language conformance
// message, ported from serialize.h (GoldenWireData / GoldenWireSerialize /
// golden_wire_bytes, test_golden_wire_format). The exact bytes produced by
// the serializer are pinned down here and must never change: if a pin in
// this file fails, the wire format has changed and previously written data
// no longer decodes — a breaking change, and NEVER something to fix by
// adjusting this file.
//
// The battery also carries the format's edge doctrines and its own
// self-test:
//   - trailing bits (STANDARD.md, adopted 2026-08-15): writers emit zero in
//     the unused bits of the final byte; readers must not reject a stream
//     for their contents, and must decode a doctored tail identically.
//   - past-end memory (STANDARD.md, ruled 2026-08-15): bytes past the
//     stream end are never interpreted. The Dart reader prices its windows
//     inside the buffer, so the proof here is the contract's observable
//     half: poison past the end of the data view changes nothing, on the
//     accept path or the refusal path.
//   - the sabotage sweep: every consumed bit of the golden stream is load
//     bearing. Flipping any single one of the 891 consumed bits must make
//     the decode refuse or produce different values — proving this battery
//     CAN fail — while flipping any of the 5 trailing bits must change
//     nothing. Hostile data never throws anywhere in the sweep.
//   - the golden uint128 and int128 pins and the two compressed float
//     conformance vectors (nonzero-min and writer-fusion) from serialize.h.

import 'dart:typed_data';

import 'package:serialize/serialize.dart';

import 'harness.dart';

const int int32Min = -2147483648;
const int int32Max = 2147483647;
// hex spellings: the decimal literal for -2^63 is not expressible in Dart
const int int64Min = 0x8000000000000000;
const int int64Max = 0x7FFFFFFFFFFFFFFF;

// serialize.h's golden_wire_bytes, extracted mechanically from the reference
// source: 112 bytes, pinned forever.
final Uint8List goldenWireBytes = Uint8List.fromList([
  0x5D, 0xDA, 0xF7, 0xE6, 0xD5, 0x77, 0xDF, 0x56, 0xEF, 0x9F, 0x75, 0x19, //
  0x52, 0xBC, 0xDA, 0x0F, 0x49, 0x40, 0xF4, 0x55, 0x55, 0x55, 0x55, 0x55, //
  0x55, 0x55, 0xFF, 0xFC, 0xD1, 0x48, 0xE0, 0x59, 0xD1, 0x48, 0xC0, 0x7B, //
  0xF3, 0x6A, 0xE2, 0x59, 0xD1, 0x48, 0x84, 0xB7, 0x06, 0xDE, 0xAD, 0xBE, //
  0xEF, 0xCA, 0xFE, 0x01, 0x06, 0x67, 0x6F, 0x6C, 0x64, 0x65, 0x6E, 0xE3, //
  0x21, 0x00, 0x00, 0xC0, 0x21, 0x00, 0x00, 0x00, 0x22, 0x00, 0x00, 0x00, //
  0xC0, 0x60, 0x00, 0x80, 0xA2, 0x7C, 0xFC, 0xEC, 0x26, 0xCB, 0xFF, 0xFF, //
  0x4B, 0x1D, 0x1F, 0xEF, 0xD2, 0x1A, 0x1F, 0x01, 0xE9, 0xFF, 0xFF, 0x09, //
  0x19, 0x2A, 0x3B, 0x4C, 0x5D, 0x6E, 0x7F, 0x78, 0x6F, 0x5E, 0x4D, 0x3C, //
  0x2B, 0x1A, 0x09, 0x04,
]);

// The golden stream ends 3 bits into its final byte: 891 consumed bits, 5
// trailing bits the writer must zero and the reader must ignore.
const int goldenBits = 891;

/// GoldenWireData, field for field: the scalar fields as Ref holders, the
/// byte array filled in place. The fixed point fields hold the RAW scaled
/// integers.
final class GoldenData {
  final bits4 = Ref<int>(0);
  final bits11 = Ref<int>(0);
  final bits24 = Ref<int>(0);
  final bits32 = Ref<int>(0);
  final intSmall = Ref<int>(0);
  final intFull = Ref<int>(0);
  final flag = Ref<bool>(false);
  final floatValue = Ref<double>(0);
  final compressedFloatValue = Ref<double>(0);
  final doubleValue = Ref<double>(0);
  final uint8Value = Ref<int>(0);
  final uint16Value = Ref<int>(0);
  final uint32Value = Ref<int>(0);
  final uint64Value = Ref<int>(0);
  final relativeNear = Ref<int>(0);
  final relativeFar = Ref<int>(0);
  final bytes = Uint8List(7);
  final string = Ref<String>('');
  final wstring = Ref<String>('');
  final fixedQ8x8 = Ref<int>(0);
  final fixedQ16x16 = Ref<int>(0);
  final fixedQ48x16 = Ref<int>(0);
  final fixedQ16x16Unsigned = Ref<int>(0);
  final fixedQ112x16Wide = Ref<Int128>(Int128.zero);
  final fixedQ64x64Wide = Ref<Int128>(Int128.zero);

  /// Zeroed holders, for the read side.
  GoldenData();

  /// GoldenWireInit, value for value.
  GoldenData.golden() {
    bits4.value = 13;
    bits11.value = 1445;
    bits24.value = 11259375;
    bits32.value = 0xDEADBEEF;
    intSmall.value = -37;
    intFull.value = -123456789;
    flag.value = true;
    floatValue.value = fround(3.1415926);
    compressedFloatValue.value = 5.0;
    doubleValue.value = 1.0 / 3.0;
    uint8Value.value = 0x7F;
    uint16Value.value = 0x1234;
    uint32Value.value = 0x12345678;
    uint64Value.value = 0x123456789ABCDEF0;
    relativeNear.value = 101; // difference of 1: the one-bit branch
    relativeFar.value = 2100; // difference of 2000: the mid-ladder bucket
    bytes.setAll(0, const [0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0x01]);
    string.value = 'golden';
    // built from explicit code points so source encoding can never change
    // the golden bytes: cyrillic, BMP only
    wstring.value = String.fromCharCodes(const [0x043C, 0x0438, 0x0440]);
    fixedQ8x8.value = -(3 * 256 + 64); // -3.25 in Q8.8
    fixedQ16x16.value = 1234 * 65536 + 32768; // 1234.5 in Q16.16
    fixedQ48x16.value = -(54321 * 65536 + 12345); // -54321.188... in Q48.16
    fixedQ16x16Unsigned.value = 29999 * 65536 + 65535; // every fraction bit
    // -98765432109.066 in Q112.16: 75 bits on the wire, three groups
    fixedQ112x16Wide.value = Int128.fromInt(-(98765432109 * 65536 + 4321));
    // Q64.64 over the full unit range: 128 bits, four groups, all distinct
    fixedQ64x64Wide.value =
        const Int128(0x0123456789ABCDEF, 0x0FEDCBA987654321);
  }
}

/// GoldenWireSerialize, operation for operation. The && chain mirrors the
/// reference macros' early return: the first refusal stops the message.
bool serializeGoldenWire(BitStream stream, GoldenData data) {
  const relativeBase = 100;
  return stream.serializeBits(data.bits4, 4) &&
      stream.serializeBits(data.bits11, 11) &&
      stream.serializeBits(data.bits24, 24) &&
      stream.serializeBits(data.bits32, 32) &&
      stream.serializeInt(data.intSmall, -100, 100) &&
      stream.serializeInt(data.intFull, int32Min, int32Max) &&
      stream.serializeBool(data.flag) &&
      stream.serializeFloat(data.floatValue) &&
      stream.serializeCompressedFloat(
          data.compressedFloatValue, 0.0, 10.0, 0.01) &&
      stream.serializeDouble(data.doubleValue) &&
      stream.serializeUint8(data.uint8Value) &&
      stream.serializeUint16(data.uint16Value) &&
      stream.serializeUint32(data.uint32Value) &&
      stream.serializeUint64(data.uint64Value) &&
      stream.serializeIntRelative(relativeBase, data.relativeNear) &&
      stream.serializeIntRelative(relativeBase, data.relativeFar) &&
      stream.serializeAlign() &&
      stream.serializeBytes(data.bytes) &&
      stream.serializeString(data.string, 16) &&
      stream.serializeWideString(data.wstring, 8) &&
      // the fixed point section starts byte aligned, so every byte pinned
      // above it stays put
      stream.serializeAlign() &&
      stream.serializeFixed(data.fixedQ8x8, 8, 8, -100, 100) &&
      stream.serializeFixed(data.fixedQ16x16, 16, 16, -2000, 2000) &&
      stream.serializeFixed(data.fixedQ48x16, 48, 16, -100000, 100000) &&
      stream.serializeFixed(data.fixedQ16x16Unsigned, 16, 16, 0, 30000) &&
      // the wide fixed section starts byte aligned as well
      stream.serializeAlign() &&
      // +-2^57 units: 75 bits, the three-group structure
      stream.serializeFixed128(data.fixedQ112x16Wide, 112, 16,
          -144115188075855872, 144115188075855872) &&
      // full unit range: 128 bits, the four-group structure
      stream.serializeFixed128(
          data.fixedQ64x64Wide, 64, 64, int64Min, int64Max);
}

bool _sameDouble(double a, double b) =>
    float64BitsFromDouble(a) == float64BitsFromDouble(b);

/// True when every decoded field equals the expected values exactly —
/// including the compressed float, which the golden values pin exactly by
/// construction. Doubles compare as bit patterns, matching the
/// bit-transparent float doctrine.
bool matchesGolden(GoldenData a, GoldenData b) {
  if (a.bits4.value != b.bits4.value) return false;
  if (a.bits11.value != b.bits11.value) return false;
  if (a.bits24.value != b.bits24.value) return false;
  if (a.bits32.value != b.bits32.value) return false;
  if (a.intSmall.value != b.intSmall.value) return false;
  if (a.intFull.value != b.intFull.value) return false;
  if (a.flag.value != b.flag.value) return false;
  if (!_sameDouble(a.floatValue.value, b.floatValue.value)) return false;
  if (!_sameDouble(
      a.compressedFloatValue.value, b.compressedFloatValue.value)) {
    return false;
  }
  if (!_sameDouble(a.doubleValue.value, b.doubleValue.value)) return false;
  if (a.uint8Value.value != b.uint8Value.value) return false;
  if (a.uint16Value.value != b.uint16Value.value) return false;
  if (a.uint32Value.value != b.uint32Value.value) return false;
  if (a.uint64Value.value != b.uint64Value.value) return false;
  if (a.relativeNear.value != b.relativeNear.value) return false;
  if (a.relativeFar.value != b.relativeFar.value) return false;
  for (var i = 0; i < a.bytes.length; i++) {
    if (a.bytes[i] != b.bytes[i]) return false;
  }
  if (a.string.value != b.string.value) return false;
  if (a.wstring.value != b.wstring.value) return false;
  if (a.fixedQ8x8.value != b.fixedQ8x8.value) return false;
  if (a.fixedQ16x16.value != b.fixedQ16x16.value) return false;
  if (a.fixedQ48x16.value != b.fixedQ48x16.value) return false;
  if (a.fixedQ16x16Unsigned.value != b.fixedQ16x16Unsigned.value) {
    return false;
  }
  if (a.fixedQ112x16Wide.value != b.fixedQ112x16Wide.value) return false;
  if (a.fixedQ64x64Wide.value != b.fixedQ64x64Wide.value) return false;
  return true;
}

void run() {
  test('write side: the golden values produce exactly the golden bytes', () {
    final writer = WriteStream(Uint8List(256));
    expect(serializeGoldenWire(writer, GoldenData.golden()),
        'the golden write refused');
    writer.flush();
    expectEquals(writer.bytesProcessed, goldenWireBytes.length,
        'bytes processed');
    expectEquals(writer.bitsProcessed, goldenBits, 'bits processed');
    expectBytes(writer.data(), goldenWireBytes, 'golden wire bytes');
  });

  test('read side: the golden bytes decode to the expected values', () {
    final reader = ReadStream(goldenWireBytes);
    final data = GoldenData();
    expect(serializeGoldenWire(reader, data), 'the golden read refused');
    expectEquals(reader.bitsProcessed, goldenBits, 'bits processed');
    expect(matchesGolden(data, GoldenData.golden()),
        'decoded values do not match the golden values');
  });

  test('trailing bits: writer zeroes them, reader is indifferent', () {
    // writer obligation, small stream: a message ending 3 bits into its
    // final byte, written into a buffer pre-filled with 0xFF so the zeros
    // must come from the writer, not from the caller
    final buffer = Uint8List(64)..fillRange(0, 64, 0xFF);
    final writer = WriteStream(buffer);
    expect(writer.serializeBits(Ref<int>(0xDEADBEEF), 32), 'head write');
    expect(writer.serializeBits(Ref<int>(5), 3), 'tail write');
    writer.flush();

    final bytesWritten = writer.bytesProcessed;
    final bitsInFinalByte = writer.bitsProcessed % 8;
    expectEquals(bitsInFinalByte, 3, 'the stream really does end unaligned');
    final trailingMask = (0xFF << bitsInFinalByte) & 0xFF;
    final data = writer.data();
    expectEquals(data[bytesWritten - 1] & trailingMask, 0,
        'writers must write zero');

    // reader indifference, small stream: set every trailing bit and read
    // back. the doctored stream must be accepted and decode the same values.
    data[bytesWritten - 1] |= trailingMask;
    final reader = ReadStream(data);
    final head = Ref<int>(0);
    expect(reader.serializeBits(head, 32), 'head read');
    expectEquals(head.value, 0xDEADBEEF, 'head value');
    final tail = Ref<int>(0);
    expect(reader.serializeBits(tail, 3), 'tail read');
    expectEquals(tail.value, 5, 'tail value');
  });

  test('trailing bits: a doctored golden stream decodes identically', () {
    final bitsInFinalByte = goldenBits % 8;
    expect(bitsInFinalByte != 0, 'golden ends unaligned: can discriminate');
    final trailingMask = (0xFF << bitsInFinalByte) & 0xFF;
    expectEquals(goldenWireBytes[goldenWireBytes.length - 1] & trailingMask, 0,
        'the pinned emission met the writer obligation');

    final doctored = Uint8List.fromList(goldenWireBytes);
    doctored[doctored.length - 1] |= trailingMask; // set every trailing bit

    final reader = ReadStream(doctored);
    final data = GoldenData();
    expect(serializeGoldenWire(reader, data), 'readers must not reject');
    expect(matchesGolden(data, GoldenData.golden()),
        'and must decode identically');
    expectEquals(reader.bitsProcessed, goldenBits, 'bits processed');
  });

  test('past-end poison: bytes past the stream end are never interpreted',
      () {
    // accept path: the golden stream decodes identically whether the bytes
    // past the end of its data view are zero or poison. the reader prices
    // its windows inside the buffer, so the poison sits in the same
    // allocation, immediately past the view it must never interpret.
    final cleanBuffer = Uint8List(256);
    final poisonBuffer = Uint8List(256)..fillRange(0, 256, 0xFF);
    cleanBuffer.setAll(0, goldenWireBytes);
    poisonBuffer.setAll(0, goldenWireBytes);

    final cleanReader = ReadStream(
        Uint8List.sublistView(cleanBuffer, 0, goldenWireBytes.length));
    final cleanData = GoldenData();
    expect(serializeGoldenWire(cleanReader, cleanData), 'clean decode');
    expect(matchesGolden(cleanData, GoldenData.golden()), 'clean values');

    final poisonReader = ReadStream(
        Uint8List.sublistView(poisonBuffer, 0, goldenWireBytes.length));
    final poisonData = GoldenData();
    expect(serializeGoldenWire(poisonReader, poisonData), 'poison decode');
    expect(matchesGolden(poisonData, GoldenData.golden()), 'poison values');
    expectEquals(poisonReader.bitsProcessed, cleanReader.bitsProcessed,
        'bits processed');
  });

  test('past-end poison: a truncated stream refuses identically', () {
    // refusal path: truncate the stream one byte short so the decode must
    // fail. the refusal must be identical — same refusal point, same
    // partial state — whether the bytes at and past the truncated end are
    // zero or poison.
    final truncatedBytes = goldenWireBytes.length - 1;

    final cleanBuffer = Uint8List(256);
    final poisonBuffer = Uint8List(256)..fillRange(0, 256, 0xFF);
    cleanBuffer.setAll(0, goldenWireBytes.sublist(0, truncatedBytes));
    poisonBuffer.setAll(0, goldenWireBytes.sublist(0, truncatedBytes));

    final cleanReader =
        ReadStream(Uint8List.sublistView(cleanBuffer, 0, truncatedBytes));
    final cleanData = GoldenData();
    expect(!serializeGoldenWire(cleanReader, cleanData),
        'the truncated clean stream must refuse');

    final poisonReader =
        ReadStream(Uint8List.sublistView(poisonBuffer, 0, truncatedBytes));
    final poisonData = GoldenData();
    expect(!serializeGoldenWire(poisonReader, poisonData),
        'the truncated poison stream must refuse');

    // refused at the same point, with identical partial state
    expectEquals(poisonReader.bitsProcessed, cleanReader.bitsProcessed,
        'refusal point');
    expect(matchesGolden(poisonData, cleanData), 'identical partial state');
  });

  test('measure bounds the write at every one of the 8 starting offsets', () {
    // the measure stream prices aligning operations conservatively, so its
    // bound must hold wherever the message lands relative to a byte
    // boundary: a prefix of 1..7 bits walks the message through all of them
    for (var offset = 0; offset < 8; offset++) {
      final writer = WriteStream(Uint8List(256));
      if (offset > 0) {
        expect(writer.serializeBits(Ref<int>(0), offset), 'prefix write');
      }
      expect(serializeGoldenWire(writer, GoldenData.golden()),
          'offset $offset write');

      final measure = MeasureStream();
      if (offset > 0) {
        expect(measure.serializeBits(Ref<int>(0), offset), 'prefix measure');
      }
      expect(serializeGoldenWire(measure, GoldenData.golden()),
          'offset $offset measure');

      expect(measure.bitsProcessed >= writer.bitsProcessed,
          'offset $offset: measured ${measure.bitsProcessed} bits, '
          'wrote ${writer.bitsProcessed}');
    }
  });

  test('the sabotage sweep: every consumed bit is load bearing', () {
    // the battery must be able to fail: a conformance harness that accepts
    // doctored streams proves nothing. flipping any single one of the 891
    // consumed bits must make the read refuse or produce different values;
    // the 5 trailing bits are the exact complement: flipping any of them
    // must change nothing at all. and across all 896 doctored streams,
    // hostile data never throws.
    final golden = GoldenData.golden();
    for (var bit = 0; bit < goldenWireBytes.length * 8; bit++) {
      final doctored = Uint8List.fromList(goldenWireBytes);
      doctored[bit >> 3] ^= 1 << (bit & 7);

      final reader = ReadStream(doctored);
      final data = GoldenData();
      final ok = serializeGoldenWire(reader, data);
      final matches = ok && matchesGolden(data, golden);

      if (bit < goldenBits) {
        expect(!matches,
            'consumed bit $bit flipped: still decoded the golden values');
      } else {
        expect(matches && reader.bitsProcessed == goldenBits,
            'trailing bit $bit flipped: not accepted identically');
      }
    }
  });

  test('golden pin: uint128 is 16 little-endian bytes, low half first', () {
    // serialize.h's golden_uint128_bytes, pinned forever
    final goldenUint128Bytes = Uint8List.fromList(const [
      0x10, 0x32, 0x54, 0x76, 0x98, 0xBA, 0xDC, 0xFE, //
      0xEF, 0xCD, 0xAB, 0x89, 0x67, 0x45, 0x23, 0x01,
    ]);
    const goldenValue = UInt128(0x0123456789ABCDEF, 0xFEDCBA9876543210);

    final writer = WriteStream(Uint8List(16));
    expect(writer.serializeUint128(Ref<UInt128>(goldenValue)),
        'uint128 write');
    writer.flush();
    expectEquals(writer.bytesProcessed, 16, 'uint128 bytes processed');
    expectBytes(writer.data(), goldenUint128Bytes, 'golden uint128 bytes');

    final reader = ReadStream(goldenUint128Bytes);
    final readBack = Ref<UInt128>(UInt128.zero);
    expect(reader.serializeUint128(readBack), 'uint128 read');
    expectEquals(readBack.value, goldenValue, 'uint128 round trip');
  });

  test('golden pin: int128 over +/-2^70, the three-group structure', () {
    // serialize.h's golden_int128_bytes: bounds of +/-2^70 need 72 bits,
    // which is the THREE GROUP structure: 32, 32, then 8.
    final goldenInt128Bytes = Uint8List.fromList(const [
      0x11, 0x32, 0x54, 0x76, 0x98, 0xBA, 0xDC, 0xFE, //
      0x3F, 0x00, 0x00, 0x00,
    ]);
    final goldenMin = -(Int128.fromInt(1) << 70);
    final goldenMax = Int128.fromInt(1) << 70;
    final goldenValue = -Int128.fromInt(0x0123456789ABCDEF);

    final buffer = Uint8List(16);
    final writer = WriteStream(buffer);
    expect(
        writer.serializeInt128(Ref<Int128>(goldenValue), goldenMin, goldenMax),
        'int128 write');
    writer.flush();
    expectEquals(writer.bitsProcessed, 72, 'int128 bits processed');
    // the flush stores whole words, so the bytes past the 9 written are
    // zeros — compare the first 12 bytes of the buffer, as the reference does
    expectBytes(Uint8List.sublistView(buffer, 0, 12), goldenInt128Bytes,
        'golden int128 bytes');

    final reader = ReadStream(goldenInt128Bytes);
    final readBack = Ref<Int128>(Int128.zero);
    expect(reader.serializeInt128(readBack, goldenMin, goldenMax),
        'int128 read');
    expectEquals(readBack.value, goldenValue, 'int128 round trip');
  });

  test('compressed float conformance: the nonzero-min vector', () {
    // serialize.h test_compressed_float_conformance_nonzero_min: pinned
    // wire bytes for the strict two-rounding writer, and pinned decoded BIT
    // PATTERNS — the divergence this detects is a single ulp, and tolerance
    // would hide it.
    final pinnedBytes =
        Uint8List.fromList(const [0x10, 0xA7, 0x06, 0x80, 0x82, 0x06]);

    bool serializeVector(BitStream stream, List<Ref<double>> values) {
      for (final value in values) {
        if (!stream.serializeCompressedFloat(value, -100.0, 100.0, 0.01)) {
          return false;
        }
      }
      return stream.serializeAlign();
    }

    final writer = WriteStream(Uint8List(64));
    final written = [Ref<double>(0.0), Ref<double>(-99.875), Ref<double>(-33.34)];
    expect(serializeVector(writer, written), 'vector write');
    writer.flush();
    expectEquals(writer.bytesProcessed, pinnedBytes.length, 'vector size');
    expectBytes(writer.data(), pinnedBytes, 'pinned nonzero-min bytes');

    final reader = ReadStream(pinnedBytes);
    final read = [Ref<double>(-1.0), Ref<double>(-1.0), Ref<double>(-1.0)];
    expect(serializeVector(reader, read), 'vector read');
    expectEquals(float32BitsFromDouble(read[0].value), 0x00000000,
        'decoded bits a');
    expectEquals(float32BitsFromDouble(read[1].value), 0xC2C7BD71,
        'decoded bits b');
    expectEquals(float32BitsFromDouble(read[2].value), 0xC2055C2A,
        'decoded bits c');
  });

  test('compressed float conformance: the writer-fusion vector', () {
    // serialize.h test_compressed_float_conformance_writer_fusion: the
    // discriminating band is [2^23, 2^24) step counts — where the float32
    // ulp of the scaled product reaches 1 — and 8388608.0 is the row a
    // fused writer moves. 16777215.0 is the normative integer clamp's
    // witness row.
    final pinnedBytes = Uint8List.fromList(
        const [0x00, 0x00, 0x80, 0xAC, 0xAA, 0xAA, 0xFF, 0xFF, 0xFF]);

    bool serializeVector(BitStream stream, List<Ref<double>> values) {
      for (final value in values) {
        if (!stream.serializeCompressedFloat(value, 0.0, 16777215.0, 1.0)) {
          return false;
        }
      }
      return stream.serializeAlign();
    }

    final writer = WriteStream(Uint8List(64));
    final written = [
      Ref<double>(8388608.0),
      Ref<double>(11184811.0),
      Ref<double>(16777215.0),
    ];
    expect(serializeVector(writer, written), 'vector write');
    writer.flush();
    expectEquals(writer.bytesProcessed, pinnedBytes.length, 'vector size');
    expectBytes(writer.data(), pinnedBytes, 'pinned writer-fusion bytes');

    final reader = ReadStream(pinnedBytes);
    final read = [Ref<double>(-1.0), Ref<double>(-1.0), Ref<double>(-1.0)];
    expect(serializeVector(reader, read), 'vector read');
    expectEquals(float32BitsFromDouble(read[0].value), 0x4B000000,
        'decoded bits a'); // 8388608.0
    expectEquals(float32BitsFromDouble(read[1].value), 0x4B2AAAAC,
        'decoded bits b'); // 11184812.0
    expectEquals(float32BitsFromDouble(read[2].value), 0x4B7FFFFF,
        'decoded bits c'); // 16777215.0
  });
}
