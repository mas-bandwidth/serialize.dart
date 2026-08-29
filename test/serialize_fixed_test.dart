// Fixed point at every storage shape the family pins: narrow, two-group,
// unsigned, and the wide three- and four-group structures. Round trips are
// EXACT — fixed point values are integers underneath — degenerate ranges
// cost zero bits on every storage width, wire identity with serialize_int64
// holds for storage of 64 bits or fewer, and out-of-range offsets refuse.

import 'dart:typed_data';

import 'package:serialize/serialize.dart';

import 'harness.dart';

const int int64Min = 0x8000000000000000;
const int int64Max = 0x7FFFFFFFFFFFFFFF;

void run() {
  test('serializeFixed: the golden shapes round trip exactly', () {
    // (raw value, integerBits, fractionBits, min, max, wire bits)
    final cases = [
      (-(3 * 256 + 64), 8, 8, -100, 100, 16), // -3.25 in Q8.8
      (1234 * 65536 + 32768, 16, 16, -2000, 2000, 28), // 1234.5 in Q16.16
      (-(54321 * 65536 + 12345), 48, 16, -100000, 100000, 34), // Q48.16
      (29999 * 65536 + 65535, 16, 16, 0, 30000, 31), // unsigned Q16.16
    ];
    for (final (value, integerBits, fractionBits, min, max, bits) in cases) {
      final writer = WriteStream(Uint8List(16));
      expect(
        writer.serializeFixed(
          Ref<int>(value),
          integerBits,
          fractionBits,
          min,
          max,
        ),
        'write Q$integerBits.$fractionBits',
      );
      writer.flush();
      expectEquals(
        writer.bitsProcessed,
        bits,
        'wire bits for Q$integerBits.$fractionBits over [$min,$max]',
      );
      final reader = ReadStream(writer.data());
      final read = Ref<int>(0);
      expect(
        reader.serializeFixed(read, integerBits, fractionBits, min, max),
        'read Q$integerBits.$fractionBits',
      );
      expectEquals(read.value, value, 'exact round trip');
    }
  });

  test('serializeFixed: wire identity with serializeInt64 over raw bounds', () {
    // for storage of 64 bits or fewer the bytes are identical to
    // serialize_int64( raw_value, raw_min, raw_max ) — fixed point adds no
    // new wire structure (STANDARD.md, "fixed")
    const value = -(3 * 256 + 64);
    final fixedBuffer = Uint8List(8);
    final intBuffer = Uint8List(8);
    final fixedWriter = WriteStream(fixedBuffer);
    fixedWriter.serializeFixed(Ref<int>(value), 8, 8, -100, 100);
    fixedWriter.flush();
    final intWriter = WriteStream(intBuffer);
    intWriter.serializeInt64(Ref<int>(value), -100 << 8, 100 << 8);
    intWriter.flush();
    expectEquals(
      fixedWriter.bitsProcessed,
      intWriter.bitsProcessed,
      'bit identity',
    );
    expectBytes(fixedBuffer, intBuffer, 'byte identity');
  });

  test('serializeFixed: with fractionBits 0 the operation IS a ranged int', () {
    final fixedBuffer = Uint8List(8);
    final fixedWriter = WriteStream(fixedBuffer);
    fixedWriter.serializeFixed(Ref<int>(42), 16, 0, -100, 100);
    fixedWriter.flush();
    final intBuffer = Uint8List(8);
    final intWriter = WriteStream(intBuffer);
    intWriter.serializeInt64(Ref<int>(42), -100, 100);
    intWriter.flush();
    expectBytes(fixedBuffer, intBuffer, 'byte identity at zero fraction');
  });

  test('serializeFixed: degenerate ranges cost zero bits on every width', () {
    // narrow storage
    final writer = WriteStream(Uint8List(8));
    writer.serializeFixed(Ref<int>(-3 << 8), 8, 8, -3, -3);
    expectEquals(writer.bitsProcessed, 0, 'zero bits, Q8.8');
    final reader = ReadStream(Uint8List(0));
    final read = Ref<int>(0);
    expect(reader.serializeFixed(read, 8, 8, -3, -3), 'degenerate read');
    expectEquals(read.value, -3 << 8, 'the raw value is min << fractionBits');

    // wide storage: a Q112.16 field over a degenerate range costs zero
    // bits, NOT fractionBits of zeros (STANDARD.md, adopted 2026-08-15)
    final wideWriter = WriteStream(Uint8List(8));
    wideWriter.serializeFixed128(
      Ref<Int128>(Int128.fromInt(7 << 16)),
      112,
      16,
      7,
      7,
    );
    expectEquals(wideWriter.bitsProcessed, 0, 'zero bits, Q112.16');
    final wideReader = ReadStream(Uint8List(0));
    final wideRead = Ref<Int128>(Int128.zero);
    expect(
      wideReader.serializeFixed128(wideRead, 112, 16, 7, 7),
      'degenerate wide read',
    );
    expectEquals(
      wideRead.value,
      Int128.fromInt(7 << 16),
      'the raw value is min << fractionBits',
    );
  });

  test('serializeFixed128: the golden wide shapes round trip exactly', () {
    // Q112.16 over +/-2^57 whole units: 75 bits, the three-group structure
    final q112 = Int128.fromInt(-(98765432109 * 65536 + 4321));
    final writer112 = WriteStream(Uint8List(16));
    expect(
      writer112.serializeFixed128(
        Ref<Int128>(q112),
        112,
        16,
        -144115188075855872,
        144115188075855872,
      ),
      'write Q112.16',
    );
    writer112.flush();
    expectEquals(writer112.bitsProcessed, 75, '75 bits: three groups');
    final reader112 = ReadStream(writer112.data());
    final read112 = Ref<Int128>(Int128.zero);
    expect(
      reader112.serializeFixed128(
        read112,
        112,
        16,
        -144115188075855872,
        144115188075855872,
      ),
      'read Q112.16',
    );
    expectEquals(read112.value, q112, 'exact wide round trip');

    // Q64.64 over the full int64 unit range: 128 bits, four groups
    const q64 = Int128(0x0123456789ABCDEF, 0x0FEDCBA987654321);
    final writer64 = WriteStream(Uint8List(16));
    expect(
      writer64.serializeFixed128(Ref<Int128>(q64), 64, 64, int64Min, int64Max),
      'write Q64.64',
    );
    writer64.flush();
    expectEquals(writer64.bitsProcessed, 128, '128 bits: four groups');
    final reader64 = ReadStream(writer64.data());
    final read64 = Ref<Int128>(Int128.zero);
    expect(
      reader64.serializeFixed128(read64, 64, 64, int64Min, int64Max),
      'read Q64.64',
    );
    expectEquals(read64.value, q64, 'exact full-range round trip');
  });

  test(
    'serializeFixed: an out-of-range offset refuses — reject, never clamp',
    () {
      // write the top of [-100,100] in Q8.8, read against [-100,99]: the same
      // 16 bits, so the range check is what convicts it
      final writer = WriteStream(Uint8List(8));
      writer.serializeFixed(Ref<int>(100 << 8), 8, 8, -100, 100);
      writer.flush();
      final reader = ReadStream(writer.data());
      final read = Ref<int>(-1);
      expect(
        !reader.serializeFixed(read, 8, 8, -100, 99),
        'out-of-range raw refused',
      );
      expectEquals(read.value, -1, 'holder untouched on refusal');
    },
  );

  test('serializeFixed128: an out-of-range offset refuses', () {
    final writer = WriteStream(Uint8List(16));
    writer.serializeFixed128(
      Ref<Int128>(Int128.fromInt(100 << 16)),
      112,
      16,
      -100,
      100,
    );
    writer.flush();
    final reader = ReadStream(writer.data());
    final read = Ref<Int128>(Int128.zero);
    expect(
      !reader.serializeFixed128(read, 112, 16, -100, 99),
      'out-of-range wide raw refused',
    );
  });

  test('serializeFixed: truncation refuses at both group widths', () {
    final read = Ref<int>(0);
    expect(
      !ReadStream(Uint8List(1)).serializeFixed(read, 8, 8, -100, 100),
      '16 bits from 8',
    );
    expect(
      !ReadStream(Uint8List(4)).serializeFixed(read, 48, 16, -100000, 100000),
      '34 bits from 32',
    );
    final wideRead = Ref<Int128>(Int128.zero);
    expect(
      !ReadStream(Uint8List(8)).serializeFixed128(
        wideRead,
        112,
        16,
        -144115188075855872,
        144115188075855872,
      ),
      '75 bits from 64',
    );
  });

  test('measure agrees with the write stream on fixed point widths', () {
    final writer = WriteStream(Uint8List(16));
    writer.serializeFixed(Ref<int>(1234 * 65536), 16, 16, -2000, 2000);
    writer.flush();
    final measure = MeasureStream();
    measure.serializeFixed(Ref<int>(1234 * 65536), 16, 16, -2000, 2000);
    expectEquals(
      measure.bitsProcessed,
      writer.bitsProcessed,
      'measure identity',
    );
  });
}
