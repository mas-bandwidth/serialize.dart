// The ranged integers at all three widths: accept paths, degenerate ranges,
// and every refusal rule — out-of-range offsets smuggled into the bit
// headroom and truncated data both refuse cleanly, never throw.

import 'dart:typed_data';

import 'package:serialize/serialize.dart';

import 'harness.dart';

const int int64Min = 0x8000000000000000;
const int int64Max = 0x7FFFFFFFFFFFFFFF;

void run() {
  test('serializeInt: round trips across the range', () {
    for (final value in const [-100, -37, -1, 0, 1, 42, 99, 100]) {
      final writer = WriteStream(Uint8List(8));
      expect(writer.serializeInt(Ref<int>(value), -100, 100), 'write $value');
      writer.flush();
      expectEquals(writer.bitsProcessed, 8, 'bits for [-100,100]');
      final reader = ReadStream(writer.data());
      final read = Ref<int>(0);
      expect(reader.serializeInt(read, -100, 100), 'read $value');
      expectEquals(read.value, value, 'round trip $value');
    }
  });

  test('serializeInt: the full int32 range costs 32 bits and wraps safely', () {
    const min = -2147483648;
    const max = 2147483647;
    for (final value in const [-2147483648, -123456789, 0, 2147483647]) {
      final writer = WriteStream(Uint8List(8));
      writer.serializeInt(Ref<int>(value), min, max);
      writer.flush();
      expectEquals(writer.bitsProcessed, 32, 'bits for full range');
      final reader = ReadStream(writer.data());
      final read = Ref<int>(0);
      expect(reader.serializeInt(read, min, max), 'read $value');
      expectEquals(read.value, value, 'round trip $value');
    }
  });

  test('serializeInt: a degenerate range costs zero bits', () {
    final writer = WriteStream(Uint8List(8));
    writer.serializeInt(Ref<int>(77), 77, 77);
    expectEquals(writer.bitsProcessed, 0, 'zero bits written');
    final reader = ReadStream(Uint8List(0));
    final read = Ref<int>(0);
    expect(reader.serializeInt(read, 77, 77), 'degenerate read');
    expectEquals(read.value, 77, 'the value IS the range');
  });

  test('serializeInt: an out-of-range offset is refused, never clamped', () {
    // write 100 in [0,100]: 7 bits, offset 100. Read against [0,80]: the
    // same 7 bits, so the range check is what convicts it.
    final writer = WriteStream(Uint8List(8));
    writer.serializeInt(Ref<int>(100), 0, 100);
    writer.flush();
    final reader = ReadStream(writer.data());
    final read = Ref<int>(123);
    expect(!reader.serializeInt(read, 0, 80), 'out of range refused');
    expectEquals(read.value, 123, 'holder untouched on refusal');
  });

  test('serializeInt: truncated data is refused', () {
    final reader = ReadStream(Uint8List(1));
    final read = Ref<int>(0);
    expect(reader.serializeInt(read, 0, 100), 'first 7 bits fit one byte');
    expect(!reader.serializeInt(read, 0, 100), 'the next 7 do not');
  });

  test('serializeInt64: round trips including ranges wider than 2^63', () {
    final cases = [
      (
        const [-5000000000, -1, 0, 1, 4123456789, 5000000000],
        -5000000000,
        5000000000,
        34,
      ),
      ([int64Min, -1, 0, 1, int64Max], int64Min, int64Max, 64),
      (const [0, 1, 255], 0, 255, 8),
    ];
    for (final (values, min, max, bits) in cases) {
      for (final value in values) {
        final writer = WriteStream(Uint8List(16)); // 16: a whole word slack
        expect(
          writer.serializeInt64(Ref<int>(value), min, max),
          'write $value',
        );
        writer.flush();
        expectEquals(writer.bitsProcessed, bits, 'bits for [$min,$max]');
        final reader = ReadStream(writer.data());
        final read = Ref<int>(0);
        expect(reader.serializeInt64(read, min, max), 'read $value');
        expectEquals(read.value, value, 'round trip $value');
      }
    }
  });

  test('serializeInt64: an out-of-range offset is refused', () {
    // 255 in [0,255] is 8 bits; [0,200] is also 8 bits: the reader consumes
    // the same bits and the range check convicts it
    final writer = WriteStream(Uint8List(8));
    writer.serializeInt64(Ref<int>(255), 0, 255);
    writer.flush();
    final reader = ReadStream(writer.data());
    final read = Ref<int>(0);
    expect(!reader.serializeInt64(read, 0, 200), 'out of range refused');
  });

  test('serializeInt64: truncated data is refused', () {
    final reader = ReadStream(Uint8List(4)); // 32 bits available, 64 required
    final read = Ref<int>(0);
    expect(!reader.serializeInt64(read, int64Min, int64Max), 'truncation');
  });

  test(
    'serializeInt128: wire identity with serializeInt64 in 64-bit ranges',
    () {
      const min = -5000000000;
      const max = 5000000000;
      for (final value in const [-5000000000, -1, 0, 4123456789, 5000000000]) {
        final buffer64 = Uint8List(16);
        final buffer128 = Uint8List(16);
        final w64 = WriteStream(buffer64);
        final w128 = WriteStream(buffer128);
        w64.serializeInt64(Ref<int>(value), min, max);
        w128.serializeInt128(
          Ref<Int128>(Int128.fromInt(value)),
          Int128.fromInt(min),
          Int128.fromInt(max),
        );
        w64.flush();
        w128.flush();
        expectEquals(w128.bitsProcessed, w64.bitsProcessed, 'bit identity');
        expectBytes(buffer128, buffer64, 'byte identity for $value');
      }
    },
  );

  test('serializeInt128: the wide bands, including wider than 2^127', () {
    final wideMin = -(Int128.fromInt(1) << 100);
    final wideMax = Int128.fromInt(1) << 100;
    final wideValues = [
      wideMin,
      wideMin + Int128.fromInt(1),
      Int128.fromInt(-1),
      Int128.zero,
      Int128.fromInt(1) << 99,
      wideMax,
    ];
    for (final value in wideValues) {
      final writer = WriteStream(Uint8List(16));
      expect(
        writer.serializeInt128(Ref<Int128>(value), wideMin, wideMax),
        'write $value',
      );
      writer.flush();
      expectEquals(writer.bitsProcessed, 102, '102 bits for +/-2^100');
      final reader = ReadStream(writer.data());
      final read = Ref<Int128>(Int128.zero);
      expect(reader.serializeInt128(read, wideMin, wideMax), 'read $value');
      expectEquals(read.value, value, 'round trip $value');
    }
    // the full 128-bit range: every group full, range wider than 2^127
    for (final value in [
      Int128.minValue,
      Int128.fromInt(-1),
      Int128.zero,
      Int128.fromInt(1),
      Int128.maxValue,
    ]) {
      final writer = WriteStream(Uint8List(16));
      expect(
        writer.serializeInt128(
          Ref<Int128>(value),
          Int128.minValue,
          Int128.maxValue,
        ),
        'write full $value',
      );
      writer.flush();
      expectEquals(writer.bitsProcessed, 128, '128 bits for the full range');
      final reader = ReadStream(writer.data());
      final read = Ref<Int128>(Int128.zero);
      expect(
        reader.serializeInt128(read, Int128.minValue, Int128.maxValue),
        'read full $value',
      );
      expectEquals(read.value, value, 'round trip full $value');
    }
  });

  test('serializeInt128: out-of-range offset and truncation are refused', () {
    final writer = WriteStream(Uint8List(8));
    writer.serializeInt128(
      Ref<Int128>(Int128.fromInt(255)),
      Int128.zero,
      Int128.fromInt(255),
    );
    writer.flush();
    final reader = ReadStream(writer.data());
    final read = Ref<Int128>(Int128.zero);
    expect(
      !reader.serializeInt128(read, Int128.zero, Int128.fromInt(200)),
      'out of range refused',
    );

    final truncated = ReadStream(Uint8List(4)); // 32 bits for a 128-bit read
    expect(
      !truncated.serializeInt128(read, Int128.minValue, Int128.maxValue),
      'truncation refused',
    );
  });

  test('measure agrees with the write stream on ranged integer widths', () {
    final cases = [
      (Int128.zero, Int128.zero, Int128.fromInt(255)),
      (
        Int128.fromInt(7),
        Int128.fromInt(-5000000000),
        Int128.fromInt(5000000000),
      ),
      (
        Int128.fromInt(1),
        -(Int128.fromInt(1) << 100),
        Int128.fromInt(1) << 100,
      ),
      (Int128.zero, Int128.minValue, Int128.maxValue),
    ];
    for (final (value, min, max) in cases) {
      final writer = WriteStream(Uint8List(24));
      writer.serializeInt128(Ref<Int128>(value), min, max);
      writer.flush();
      final measure = MeasureStream();
      measure.serializeInt128(Ref<Int128>(value), min, max);
      expectEquals(
        measure.bitsProcessed,
        writer.bitsProcessed,
        'measure identity for [$min,$max]',
      );
    }
  });

  test('serializeInt128: a degenerate range costs zero bits', () {
    // min == max is legal on the 128-bit width exactly as on the narrower
    // ones (STANDARD.md, "int128 (ranged)"): the writer emits nothing, the
    // measure adds nothing, and the reader consumes nothing and takes the
    // value from min. The corpus pins the read; this pins all three streams,
    // and it holds in checked builds, where min <= max is the assertion.
    final bound = (Int128.fromInt(1) << 100) + Int128.fromInt(7);
    for (final value in [
      Int128.zero,
      bound,
      Int128.minValue,
      Int128.maxValue,
    ]) {
      final writer = WriteStream(Uint8List(24));
      expect(
        writer.serializeInt128(Ref<Int128>(value), value, value),
        'write [$value,$value]',
      );
      writer.flush();
      expectEquals(writer.bitsProcessed, 0, 'the writer emits nothing');

      final measure = MeasureStream();
      measure.serializeInt128(Ref<Int128>(value), value, value);
      expectEquals(measure.bitsProcessed, 0, 'the measure adds nothing');

      final reader = ReadStream(Uint8List(0));
      final read = Ref<Int128>(Int128.fromInt(-424242));
      expect(
        reader.serializeInt128(read, value, value),
        'read [$value,$value]',
      );
      expectEquals(read.value, value, 'the value comes from min');
      expectEquals(reader.bitsProcessed, 0, 'the reader consumes nothing');
    }
  });
}
