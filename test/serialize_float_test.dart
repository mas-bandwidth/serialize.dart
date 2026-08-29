// float and double bit transparency — every pattern legal, NaN payloads
// byte-exact, compared as bit patterns, never values — and the compressed
// float: the discriminating quantization rows of STANDARD.md, refusals for
// smuggled integers and truncation.

import 'dart:typed_data';

import 'package:serialize/serialize.dart';

import 'harness.dart';

void run() {
  test('serializeFloat: values round trip bit-exactly', () {
    for (final value in [
      0.0,
      -0.0,
      1.0,
      fround(3.1415926),
      fround(-1e30),
      double.infinity,
      double.negativeInfinity,
      fround(1.401298464324817e-45), // the smallest denormal
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

  test(
    'serializeFloat: NaN payloads ride byte-for-byte, quiet or signaling',
    () {
      // quiet NaN, quiet NaN with payload, signaling NaN (quiet bit clear,
      // nonzero payload), negative signaling NaN
      for (final bits in const [
        0x7FC00000,
        0x7FC12345,
        0x7F812345,
        0xFF800001,
      ]) {
        final writer = WriteStream(Uint8List(8));
        writer.serializeFloat(Ref<double>(doubleFromFloat32Bits(bits)));
        writer.flush();
        final wire = writer.data();
        expectEquals(
          wire[0] | (wire[1] << 8) | (wire[2] << 16) | (wire[3] << 24),
          bits,
          'wire bits for NaN ${bits.toRadixString(16)}',
        );
        final reader = ReadStream(wire);
        final read = Ref<double>(0);
        expect(reader.serializeFloat(read), 'reader must not reject NaN');
        expectEquals(
          float32BitsFromDouble(read.value),
          bits,
          'reproduced pattern ${bits.toRadixString(16)}',
        );
      }
    },
  );

  test('serializeDouble: values and NaN payloads round trip bit-exactly', () {
    for (final value in [
      0.0,
      -0.0,
      1.0 / 3.0,
      double.infinity,
      double.negativeInfinity,
      doubleFromFloat64Bits(0x7FF0000000000001), // signaling NaN
      doubleFromFloat64Bits(0xFFF8123456789ABC), // quiet NaN with payload
      doubleFromFloat64Bits(0x0000000000000001), // smallest denormal
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
