// float and double carry finite values only, every one bit exact (format
// 2.0): finite patterns round trip compared as bit patterns, never values;
// NaN with any payload and both infinities are refused on read as
// non_finite_float, tested on the raw bits, and are caller error on write.
// And the compressed float: the discriminating quantization rows of
// STANDARD.md, refusals for smuggled integers, truncation and a decode that
// rounds to infinity.

import 'dart:typed_data';

import 'package:serialize/serialize.dart';

import 'harness.dart';

/// The little-endian bytes of a [bits] wide pattern.
Uint8List _wire(int pattern, int bits) => Uint8List.fromList([
  for (var i = 0; i < bits ~/ 8; i++) (pattern >>> (8 * i)) & 0xFF,
]);

void run() {
  test('serializeFloat: finite values round trip bit-exactly', () {
    for (final value in [
      0.0,
      -0.0,
      1.0,
      fround(3.1415926),
      fround(-1e30),
      doubleFromFloat32Bits(0x7F7FFFFF), // the largest finite
      doubleFromFloat32Bits(0xFF7FFFFF), // the most negative finite
      doubleFromFloat32Bits(0x00000001), // the smallest denormal
      doubleFromFloat32Bits(0x807FFFFF), // the largest negative denormal
    ]) {
      final writer = WriteStream(Uint8List(8));
      writer.serializeFloat(Ref<double>(value));
      writer.flush();
      expectEquals(writer.bitsProcessed, 32, '32 bits');
      final reader = ReadStream(writer.data());
      final read = Ref<double>(0);
      expect(reader.serializeFloat(read), 'read');
      expectSameDouble(read.value, value, 'bit-exact round trip of $value');
    }
  });

  test('serializeFloat: non-finite patterns are refused, holder untouched', () {
    // both infinities, quiet NaN, quiet NaN with payload, signaling NaN
    // (quiet bit clear), negative signaling NaN, every payload bit: the
    // patterns format 1.1 carried, which 2.0 refuses on the raw bits
    for (final bits in const [
      0x7F800000,
      0xFF800000,
      0x7FC00000,
      0x7FC12345,
      0x7F812345,
      0xFF800001,
      0xFFFFFFFF,
    ]) {
      final reader = ReadStream(_wire(bits, 32));
      final read = Ref<double>(-2.5);
      expect(!reader.serializeFloat(read), '${bits.toRadixString(16)} refused');
      expectEquals(reader.refusal, Refusal.nonFiniteFloat, 'refusal reason');
      expectSameDouble(read.value, -2.5, 'holder untouched on refusal');
      expect(reader.failed, 'the refusal is terminal');
    }
    // the edge: the exponent one below all ones is the largest finite
    final edge = ReadStream(_wire(0x7F7FFFFF, 32));
    expect(edge.serializeFloat(Ref<double>(0)), 'largest finite accepted');
  });

  test('serializeDouble: finite values round trip bit-exactly', () {
    for (final value in [
      0.0,
      -0.0,
      1.0 / 3.0,
      doubleFromFloat64Bits(0x7FEFFFFFFFFFFFFF), // the largest finite
      doubleFromFloat64Bits(0x0000000000000001), // the smallest denormal
      doubleFromFloat64Bits(0x800FFFFFFFFFFFFF), // a negative denormal
    ]) {
      final writer = WriteStream(Uint8List(8));
      writer.serializeDouble(Ref<double>(value));
      writer.flush();
      expectEquals(writer.bitsProcessed, 64, '64 bits');
      final reader = ReadStream(writer.data());
      final read = Ref<double>(0);
      expect(reader.serializeDouble(read), 'read');
      expectSameDouble(read.value, value, 'bit-exact round trip');
    }
  });

  test(
    'serializeDouble: non-finite patterns are refused, holder untouched',
    () {
      for (final bits in const [
        0x7FF0000000000000, // +inf
        0xFFF0000000000000, // -inf
        0x7FF0000000000001, // signaling NaN, payload in the low group only
        0xFFF8123456789ABC, // quiet NaN with payload
        0xFFFFFFFFFFFFFFFF, // every bit
      ]) {
        final reader = ReadStream(_wire(bits, 64));
        final read = Ref<double>(-2.5);
        expect(!reader.serializeDouble(read), 'refused');
        expectEquals(reader.refusal, Refusal.nonFiniteFloat, 'refusal reason');
        expectSameDouble(read.value, -2.5, 'holder untouched on refusal');
      }
    },
  );

  test('float and double: a non-finite write is caller error', () {
    if (!assertsEnabled) {
      return; // a release build performs no write-side validation
    }
    for (final value in [
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ]) {
      expectThrows(
        () => WriteStream(Uint8List(8)).serializeFloat(Ref<double>(value)),
        'float write of $value',
      );
      expectThrows(
        () => WriteStream(Uint8List(8)).serializeDouble(Ref<double>(value)),
        'double write of $value',
      );
    }
    // the check runs AFTER the narrowing: a finite double above the float32
    // range narrows to an infinity, which the wire does not carry
    expectThrows(
      () => WriteStream(Uint8List(8)).serializeFloat(Ref<double>(1e39)),
      'float write of a double that narrows to infinity',
    );
    // and the largest finite float32 does not fire it
    WriteStream(
      Uint8List(8),
    ).serializeFloat(Ref<double>(doubleFromFloat32Bits(0x7F7FFFFF)));
  });

  // A finite pattern whose 32-bit half is shaped like a signaling NaN: the
  // conversions once overlaid typed-list views that dart2wasm does not keep
  // bit transparent, and these came back with the quiet bit set. The web
  // target runs the same round trip at scale (tool/web_float_fuzz.dart).
  test('float and double: sNaN-shaped 32-bit halves round trip as bytes', () {
    for (final wire in const [
      [0x00, 0x02, 0x10, 0xf2, 0x76, 0x22, 0xb7, 0x7f],
      [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xb0, 0x7f],
      [0x50, 0xe1, 0x91, 0x7f, 0xcf, 0x1a, 0x16, 0x00],
      [0x01, 0x00, 0x80, 0x7f, 0x01, 0x00, 0x80, 0xff],
    ]) {
      final read = Ref<double>(0);
      expect(
        ReadStream(Uint8List.fromList(wire)).serializeDouble(read),
        '$wire',
      );
      final writer = WriteStream(Uint8List(8));
      writer.serializeDouble(read);
      writer.flush();
      expectBytes(writer.data(), wire, 'double $wire written back');
    }
    for (final bits in const [0x00000001, 0x3FBFFFFF, 0x7F3FFFFF, 0x80400001]) {
      final read = Ref<double>(0);
      expect(ReadStream(_wire(bits, 32)).serializeFloat(read), '$bits read');
      final writer = WriteStream(Uint8List(8));
      writer.serializeFloat(read);
      writer.flush();
      expectBytes(writer.data(), _wire(bits, 32), 'float $bits written back');
    }
  });

  test('the finite bit tests look at the exponent field only', () {
    expect(float32BitsAreFinite(0x7F7FFFFF), 'largest finite float');
    expect(float32BitsAreFinite(0x80000000), 'negative zero');
    expect(!float32BitsAreFinite(0x7F800000), '+inf');
    expect(!float32BitsAreFinite(0xFFC00001), 'negative NaN');
    expect(float64BitsAreFinite(0x7FEFFFFFFFFFFFFF), 'largest finite double');
    expect(!float64BitsAreFinite(0x7FF0000000000000), '+inf');
    expect(!float64BitsAreFinite(0xFFF0000000000001), 'negative NaN');
  });

  test('compressed float: the discriminating rows of STANDARD.md', () {
    // over [0,10] at resolution 0.01 the required float32 arithmetic
    // quantizes 0.005 -> 1, 0.025 -> 3, 0.105 -> 11 and 9.995 -> 1000;
    // widening to double yields 0, 2, 10 and 999. These land BETWEEN quanta,
    // which is what makes them evidence.
    const rows = [(0.005, 1), (0.025, 3), (0.105, 11), (9.995, 1000)];
    for (final (value, quantized) in rows) {
      final writer = WriteStream(Uint8List(8));
      writer.serializeCompressedFloat(Ref<double>(value), 0.0, 10.0, 0.01);
      writer.flush();
      expectEquals(writer.bitsProcessed, 10, '10 bits for [0,10] at 0.01');
      final reader = ReadStream(writer.data());
      final read = Ref<int>(0);
      reader.serializeBits(read, 10);
      expectEquals(read.value, quantized, '$value quantizes to $quantized');
    }
  });

  test('compressed float: values clamp into the declared range', () {
    for (final (value, quantized) in const [(-5.0, 0), (15.0, 1000)]) {
      final writer = WriteStream(Uint8List(8));
      writer.serializeCompressedFloat(Ref<double>(value), 0.0, 10.0, 0.01);
      writer.flush();
      final reader = ReadStream(writer.data());
      final read = Ref<int>(0);
      reader.serializeBits(read, 10);
      expectEquals(read.value, quantized, '$value clamps to $quantized');
    }
  });

  test('compressed float: a smuggled integer above the step count refuses', () {
    // [0,10] at 0.01 has maxIntegerValue 1000 in 10 bits: 1001..1023 fit the
    // field but exceed the step count and must refuse — reject, never clamp
    final writer = WriteStream(Uint8List(8));
    writer.serializeBits(Ref<int>(1001), 10);
    writer.flush();
    final reader = ReadStream(writer.data());
    final read = Ref<double>(-1.0);
    expect(
      !reader.serializeCompressedFloat(read, 0.0, 10.0, 0.01),
      'smuggled integer refused',
    );
    expectEquals(reader.refusal, Refusal.valueOutOfRange, 'refusal reason');
    expectSameDouble(read.value, -1.0, 'holder untouched on refusal');
  });

  test('compressed float: truncated data refuses', () {
    final reader = ReadStream(Uint8List(1)); // 8 bits, 10 required
    expect(
      !reader.serializeCompressedFloat(Ref<double>(0), 0.0, 10.0, 0.01),
      'truncation refused',
    );
  });

  test('compressed float: round trip returns the nearest quantum exactly', () {
    // 5.0 lands exactly on a quantum of [0,10] at 0.01 (maxIntegerValue is
    // exactly 1000 after float32 rounding), so the decode is exact
    final writer = WriteStream(Uint8List(8));
    writer.serializeCompressedFloat(Ref<double>(5.0), 0.0, 10.0, 0.01);
    writer.flush();
    final reader = ReadStream(writer.data());
    final read = Ref<double>(0);
    expect(reader.serializeCompressedFloat(read, 0.0, 10.0, 0.01), 'read');
    expectSameDouble(read.value, 5.0, 'exact quantum decode');
  });

  // over [3 * 2^103, FLT_MAX] at resolution 2^104 every operand is finite,
  // delta rounds up to 2^128 - 2^105, and the top integer decodes to 2^128:
  // +inf. STANDARD.md's witness for "the decode must be finite"
  const witnessMin = 30423614405477505635920876929024.0;
  const witnessMax = 340282346638528859811704183484516925440.0;
  const witnessRes = 20282409603651670423947251286016.0;

  test('compressed float: a decode that rounds to infinity is refused', () {
    // the top integer, 2^24 - 2, in 24 bits
    final reader = ReadStream(Uint8List.fromList(const [0xFE, 0xFF, 0xFF]));
    final read = Ref<double>(-1.0);
    expect(
      !reader.serializeCompressedFloat(
        read,
        witnessMin,
        witnessMax,
        witnessRes,
      ),
      'the infinite decode refused',
    );
    expectEquals(reader.refusal, Refusal.nonFiniteFloat, 'refusal reason');
    expectSameDouble(read.value, -1.0, 'holder untouched on refusal');

    // one integer below the top decodes finite and is accepted: the refusal
    // is the decode's, never the declaration's
    final below = ReadStream(Uint8List.fromList(const [0xFD, 0xFF, 0xFF]));
    expect(
      below.serializeCompressedFloat(read, witnessMin, witnessMax, witnessRes),
      'the finite decode below the top accepted',
    );
    expectEquals(float32BitsFromDouble(read.value), 0x7F7FFFFE, 'its bits');
  });

  test('compressed float: a declaration whose top decodes to infinity is '
      'caller error on write, even for a finite value', () {
    if (!assertsEnabled) {
      return;
    }
    expectThrows(
      () => WriteStream(Uint8List(8)).serializeCompressedFloat(
        Ref<double>(witnessMin),
        witnessMin,
        witnessMax,
        witnessRes,
      ),
      'write over the non-conforming declaration',
    );
    // a measure makes every check a write makes (IMPLEMENTING.md U6; C++
    // asserts it under IsWriting, which a measure sets); a reader refuses
    // the decode itself, and the read above ran with asserts on too
    expectThrows(
      () => MeasureStream().serializeCompressedFloat(
        Ref<double>(witnessMin),
        witnessMin,
        witnessMax,
        witnessRes,
      ),
      'measure over the non-conforming declaration',
    );
  });

  test('float truncation refusals', () {
    expect(
      !ReadStream(Uint8List(3)).serializeFloat(Ref<double>(0)),
      'float from 24 bits',
    );
    expect(
      !ReadStream(Uint8List(7)).serializeDouble(Ref<double>(0)),
      'double from 56 bits',
    );
  });
}
