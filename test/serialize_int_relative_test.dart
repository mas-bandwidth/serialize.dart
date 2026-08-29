// The relative-integer ladder: every tier boundary, the final absolute
// tier, and the ordering refusal — the absolute form carries no ordering
// guarantee of its own, so the reader must verify current > previous.

import 'dart:typed_data';

import 'package:serialize/serialize.dart';

import 'harness.dart';

void run() {
  test('serializeIntRelative: every tier boundary round trips at its cost', () {
    // (difference, expected bits): flags + payload per STANDARD.md's table
    const cases = [
      (1, 1), // '1'
      (2, 2 + 3), (6, 2 + 3), // '01' + 3
      (7, 3 + 5), (23, 3 + 5), // '001' + 5
      (24, 4 + 9), (280, 4 + 9), // '0001' + 9
      (281, 5 + 13), (2000, 5 + 13), (4377, 5 + 13), // '00001' + 13
      (4378, 6 + 17), (69914, 6 + 17), // '000001' + 17
      (69915, 6 + 32), (1000000, 6 + 32), // '000000' + 32 raw
    ];
    const previous = 100;
    for (final (difference, bits) in cases) {
      final current = previous + difference;
      final writer = WriteStream(Uint8List(16));
      expect(
        writer.serializeIntRelative(previous, Ref<int>(current)),
        'write difference $difference',
      );
      writer.flush();
      expectEquals(
        writer.bitsProcessed,
        bits,
        'bits for difference $difference',
      );
      final reader = ReadStream(writer.data());
      final read = Ref<int>(0);
      expect(
        reader.serializeIntRelative(previous, read),
        'read difference $difference',
      );
      expectEquals(read.value, current, 'round trip difference $difference');

      // and the measure stream prices the ladder exactly
      final measure = MeasureStream();
      measure.serializeIntRelative(previous, Ref<int>(current));
      expectEquals(measure.bitsProcessed, bits, 'measured ladder cost');
    }
  });

  test('serializeIntRelative: the final tier refuses current <= previous', () {
    // hand-build a final-tier stream: six zero flags, then 32 raw bits that
    // do not exceed previous
    final writer = WriteStream(Uint8List(8));
    writer.serializeBits(Ref<int>(0), 6); // six zero flags
    writer.serializeBits(Ref<int>(50), 32); // current = 50
    writer.flush();
    final reader = ReadStream(writer.data());
    final read = Ref<int>(0);
    expect(
      !reader.serializeIntRelative(100, read),
      'current <= previous refused',
    );
  });

  test('serializeIntRelative: truncation refuses at every stage', () {
    final read = Ref<int>(0);
    expect(
      !ReadStream(Uint8List(0)).serializeIntRelative(100, read),
      'no flag bit',
    );
    // a single zero byte: all six flags read as zero, then the 32 raw bits
    // of the final tier do not fit the 2 remaining bits
    expect(
      !ReadStream(Uint8List(1)).serializeIntRelative(100, read),
      'final tier truncation refused',
    );
  });
}
