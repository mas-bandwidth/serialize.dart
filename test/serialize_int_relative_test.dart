// The relative-integer ladder: every tier boundary, the final absolute
// tier, the ordering refusal — the absolute form carries no ordering
// guarantee of its own — and the domain, 0 to 2^31 - 1 inclusive, which the
// reader checks after reconstructing in every tier.
//
// The shared corpus (conformance/int_relative.txt, run by conformance_test)
// is the authority on the domain refusals; these are the port's own reads of
// the same rules, plus the checked-build contract on previous.

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

  test('serializeIntRelative: the domain top round trips', () {
    // previous one step below the top of the domain: the one-bit tier lands
    // exactly on 2^31 - 1, which is inside the domain and must be accepted
    final writer = WriteStream(Uint8List(8));
    expect(
      writer.serializeIntRelative(intRelativeMax - 1, Ref<int>(intRelativeMax)),
      'write the domain top',
    );
    writer.flush();
    final reader = ReadStream(writer.data());
    final read = Ref<int>(0);
    expect(
      reader.serializeIntRelative(intRelativeMax - 1, read),
      'read the domain top',
    );
    expectEquals(read.value, intRelativeMax, 'the domain top comes back');
    expectEquals(reader.bitsProcessed, 1, 'one bit');
  });

  test('serializeIntRelative: reconstruction past the domain refuses', () {
    // every tier, driven from a previous that puts the tier's smallest
    // difference past the top of the domain. The reconstruction is checked
    // in each one, so each must refuse with the holder untouched.
    final tiers = <String, List<int>>{
      'one-bit': [0x01],
      'bounded-3': [0x02],
      'bounded-5': [0x04],
      'bounded-9': [0x08, 0x00],
      'bounded-13': [0x10, 0x00, 0x00],
      'bounded-17': [0x20, 0x00, 0x00],
    };
    for (final entry in tiers.entries) {
      final reader = ReadStream(Uint8List.fromList(entry.value));
      final read = Ref<int>(-1);
      expect(
        !reader.serializeIntRelative(intRelativeMax, read),
        '${entry.key}: past the domain refused',
      );
      expectEquals(read.value, -1, '${entry.key}: holder untouched');
    }
  });

  test('serializeIntRelative: the absolute tier reads 32 unsigned bits', () {
    // six zero flags then 32 raw bits. A group with its top bit set is
    // outside the domain — a reader that took it as a signed sequence value
    // would see a negative and a different answer about the same bytes.
    for (final absolute in const [0x80000000, 0xFFFFFFFF]) {
      final writer = WriteStream(Uint8List(8));
      writer.serializeBits(Ref<int>(0), 6);
      writer.serializeBits(Ref<int>(absolute), 32);
      writer.flush();
      final reader = ReadStream(writer.data());
      final read = Ref<int>(-1);
      expect(
        !reader.serializeIntRelative(100, read),
        'top bit set is outside the domain',
      );
      expectEquals(read.value, -1, 'holder untouched');
    }

    // and the domain maximum itself is accepted through the same tier
    final writer = WriteStream(Uint8List(8));
    writer.serializeBits(Ref<int>(0), 6);
    writer.serializeBits(Ref<int>(intRelativeMax), 32);
    writer.flush();
    final reader = ReadStream(writer.data());
    final read = Ref<int>(0);
    expect(reader.serializeIntRelative(100, read), 'the domain maximum');
    expectEquals(read.value, intRelativeMax, 'the domain maximum comes back');
    expectEquals(reader.bitsProcessed, 38, 'six flags and 32 raw bits');
  });

  test('serializeIntRelative: previous outside the domain is caller error', () {
    if (!assertsEnabled) {
      return; // release builds perform no write-side validation
    }
    final read = Ref<int>(0);
    expectThrows(
      () => ReadStream(Uint8List(8)).serializeIntRelative(1 << 31, read),
      'a previous of 2^31 is outside the domain',
    );
    expectThrows(
      () => ReadStream(Uint8List(8)).serializeIntRelative(-1, read),
      'a negative previous is outside the domain',
    );
    expectThrows(
      () => WriteStream(
        Uint8List(8),
      ).serializeIntRelative(1 << 31, Ref<int>((1 << 31) + 1)),
      'the writer holds the same domain',
    );
  });
}
