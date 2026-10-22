// The relative-integer ladder: every tier boundary, the final absolute
// tier, the ordering refusal — the absolute form carries no ordering
// guarantee of its own — the domain, 0 to 2^31 - 1 inclusive, which the
// reader checks after reconstructing in every tier, and the canonical tier:
// the absolute form carrying a difference a bounded tier takes is refused.
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

  /// Six zero flags, then [absolute] as 32 raw bits: the absolute tier,
  /// built by hand whatever the difference.
  Uint8List absoluteTier(int absolute) {
    final writer = WriteStream(Uint8List(8));
    writer.serializeBits(Ref<int>(0), 6);
    writer.serializeBits(Ref<int>(absolute), 32);
    writer.flush();
    return writer.data();
  }

  test('serializeIntRelative: the absolute tier is canonical', () {
    // a difference the last bounded tier takes, carried in the absolute
    // tier, is a second encoding of the value: refused as non_canonical.
    // Format 1.1 accepted all of these
    for (final difference in const [1, 2, 6, 7, 4378, 69913, 69914]) {
      final reader = ReadStream(absoluteTier(100 + difference));
      final read = Ref<int>(-1);
      expect(
        !reader.serializeIntRelative(100, read),
        'difference $difference refused',
      );
      expectEquals(reader.refusal, Refusal.nonCanonical, 'refusal reason');
      expectEquals(read.value, -1, 'holder untouched');
    }
    // the first difference past the last tier is the absolute tier's own
    final reader = ReadStream(absoluteTier(100 + 69915));
    final read = Ref<int>(0);
    expect(reader.serializeIntRelative(100, read), 'difference 69915');
    expectEquals(read.value, 100 + 69915, 'comes back');
  });

  test('serializeIntRelative: the domain comes before the canonical tier', () {
    // a current past the domain is value_out_of_range whatever its
    // difference: previous at the top of the domain, current one above it,
    // a difference of one, which a reader testing the difference first, or
    // subtracting in 32 bits, would call non_canonical
    final reader = ReadStream(absoluteTier(0x80000000));
    expect(
      !reader.serializeIntRelative(intRelativeMax, Ref<int>(0)),
      'refused',
    );
    expectEquals(reader.refusal, Refusal.valueOutOfRange, 'refusal reason');
    // and a current not above previous is value_out_of_range too
    final equal = ReadStream(absoluteTier(100));
    expect(!equal.serializeIntRelative(100, Ref<int>(0)), 'equal refused');
    expectEquals(equal.refusal, Refusal.valueOutOfRange, 'refusal reason');
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
