// The end of the object (STANDARD.md, "end", format 2.0): a reader's end
// refuses a whole byte or more after the object as trailing_data, checked
// first, and a set bit in the final byte's padding as nonzero_padding, and
// never looks at the last field's own bits. A writer's end emits nothing and
// a measure's costs nothing. Format 1.1 had no end, so every refusal here is
// a stream 1.1 accepted.

import 'dart:typed_data';

import 'package:serialize/serialize.dart';

import 'harness.dart';

/// Reads [bits] bits of [bytes], then the end. Returns the refusal, or null
/// when the end accepted.
Refusal? _endAfter(int bits, List<int> bytes) {
  final stream = ReadStream(Uint8List.fromList(bytes));
  if (bits > 0) {
    expect(stream.serializeBits(Ref<int>(0), bits), 'the field reads');
  }
  final accepted = stream.serializeEnd();
  expectEquals(accepted, stream.refusal == null, 'the result names no rule');
  if (accepted) {
    expectEquals(stream.bitsProcessed, bytes.length * 8, 'exactly consumed');
  }
  return stream.refusal;
}

void run() {
  test('serializeEnd: an exactly consumed stream is accepted', () {
    expectEquals(_endAfter(0, const []), null, 'the empty object');
    expectEquals(_endAfter(3, const [0x05]), null, 'three bits, clean pad');
    expectEquals(_endAfter(3, const [0x07]), null, 'field bits all set');
    expectEquals(_endAfter(8, const [0xAB]), null, 'aligned, no padding');
    expectEquals(_endAfter(1, const [0x01]), null, 'seven bits of padding');
  });

  test('serializeEnd: a whole byte after the object is trailing data', () {
    expectEquals(_endAfter(0, const [0x00]), Refusal.trailingData, 'zero');
    expectEquals(_endAfter(0, const [0xFF]), Refusal.trailingData, 'set');
    expectEquals(
      _endAfter(3, const [0x05, 0x00]),
      Refusal.trailingData,
      'a zero byte after an unaligned object',
    );
    expectEquals(
      _endAfter(8, const [0xAB, 0x00]),
      Refusal.trailingData,
      'a zero byte after an aligned object',
    );
    // both rules at once: trailing data is checked first
    expectEquals(
      _endAfter(3, const [0x0D, 0x00]),
      Refusal.trailingData,
      'trailing data before padding',
    );
  });

  test('serializeEnd: every padding bit is checked, and no field bit', () {
    for (var bits = 1; bits < 8; bits++) {
      for (var pad = bits; pad < 8; pad++) {
        expectEquals(
          _endAfter(bits, [(1 << pad) | ((1 << bits) - 1)]),
          Refusal.nonzeroPadding,
          'a $bits bit field, padding bit $pad set',
        );
      }
      expectEquals(
        _endAfter(bits, [(1 << bits) - 1]),
        null,
        'a $bits bit field, every field bit set, clean padding',
      );
    }
  });

  test('serializeEnd: nothing is left after it', () {
    final stream = ReadStream(Uint8List.fromList(const [0x05]));
    expect(stream.serializeBits(Ref<int>(0), 3), 'field');
    expect(stream.serializeEnd(), 'end');
    expect(!stream.serializeBool(Ref<bool>(false)), 'a one-bit read after');
    expectEquals(stream.refusal, Refusal.pastEnd, 'past the end');
  });

  test('serializeEnd: a zero-bit read still succeeds after it', () {
    final stream = ReadStream(Uint8List.fromList(const [0x05]));
    expect(
      stream.serializeBits(Ref<int>(0), 3) && stream.serializeEnd(),
      'end',
    );
    final value = Ref<int>(0);
    expect(stream.serializeInt(value, 9, 9), 'a degenerate range');
    expectEquals(value.value, 9, 'takes its value from min');
  });

  test('serializeEnd: a writer emits nothing, a measure costs nothing', () {
    final buffer = Uint8List(8)..fillRange(0, 8, 0xFF);
    final writer = WriteStream(buffer);
    expect(writer.serializeBits(Ref<int>(5), 3), 'field');
    expect(writer.serializeEnd(), 'end');
    writer.flush();
    expectEquals(writer.bitsProcessed, 3, 'no bits');
    expectBytes(writer.data(), const [0x05], 'zero padding, no more bytes');

    final measure = MeasureStream();
    expect(measure.serializeEnd(), 'a measure refuses nothing');
    expectEquals(measure.bitsProcessed, 0, 'zero bits');
  });
}
