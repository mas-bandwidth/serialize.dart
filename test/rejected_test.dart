// rejected: the caller's own refusal (STANDARD.md, "Refusal reasons").
//
// The bytes were well formed and the caller refused the value they carry:
// ReadStream.reject at the top level, or a nested object whose serialize
// returns false with nothing refused inside it. Either way the stream latches
// rejected, terminal like every refusal, and the first reason wins.

import 'dart:typed_data';

import 'package:serialize/serialize.dart';

import 'harness.dart';

/// Reads four bits, then refuses on its own.
final class _RefusesAfterFourBits implements Serializable {
  @override
  bool serialize(BitStream stream) {
    if (!stream.serializeBits(Ref<int>(0), 4)) {
      return false;
    }
    return false;
  }
}

/// Reads [bits] bits and accepts.
final class _Reads implements Serializable {
  _Reads(this.bits);

  final int bits;
  bool called = false;

  @override
  bool serialize(BitStream stream) {
    called = true;
    return stream.serializeBits(Ref<int>(0), bits);
  }
}

/// Reads past the end, ignores the refusal, and returns true.
final class _SwallowsRefusal implements Serializable {
  @override
  bool serialize(BitStream stream) {
    stream.serializeBits(Ref<int>(0), 32);
    return true;
  }
}

/// Reads past the end, then refuses on its own.
final class _RefusesAfterPastEnd implements Serializable {
  @override
  bool serialize(BitStream stream) {
    stream.serializeBits(Ref<int>(0), 32);
    return false;
  }
}

ReadStream _reader(List<int> bytes) => ReadStream(Uint8List.fromList(bytes));

void _expectPoisoned(ReadStream reader, Refusal reason, String what) {
  final bits = reader.bitsProcessed;
  final probe = Ref<int>(0x55);
  expect(!reader.serializeBits(probe, 8), '$what: a later read refuses');
  expectEquals(probe.value, 0x55, '$what: the later read wrote nothing');
  final empty = _Reads(0);
  expect(!reader.serializeObject(empty), '$what: a later object refuses');
  expect(!empty.called, '$what: the later object never ran');
  expectEquals(reader.bitsProcessed, bits, '$what: nothing consumed');
  expectEquals(reader.refusal, reason, '$what: the first reason stays');
}

void run() {
  test('rejected: the family spelling', () {
    expectEquals(Refusal.rejected.name, 'rejected', 'name');
    expectEquals(Refusal.byName('rejected'), Refusal.rejected, 'byName');
  });

  test('reject: refuses as rejected, terminal', () {
    final reader = _reader(const [0x05, 0xAB]);
    expect(reader.serializeBits(Ref<int>(0), 4), 'the bits are accepted');
    expectEquals(reader.refusal, null, 'nothing refused yet');
    expect(!reader.reject(), 'reject returns false');
    expect(reader.failed, 'the stream failed');
    expectEquals(reader.refusal, Refusal.rejected, 'reason');
    _expectPoisoned(reader, Refusal.rejected, 'after reject');
    expect(!reader.reject(), 'a second reject still refuses');
    expectEquals(reader.refusal, Refusal.rejected, 'reason after the echo');
  });

  test('reject: a wire refusal first keeps its reason', () {
    final reader = _reader(const [0xFD, 0xAB]);
    expect(reader.serializeBits(Ref<int>(0), 3), 'three bits');
    expect(!reader.serializeAlign(), 'the align refuses its padding');
    expect(!reader.reject(), 'reject on the failed stream');
    expectEquals(reader.refusal, Refusal.nonzeroPadding, 'first reason wins');
  });

  test('reset clears a rejection', () {
    final reader = _reader(const [0x05]);
    reader.reject();
    reader.reset(Uint8List.fromList(const [0x05]));
    expectEquals(reader.refusal, null, 'no reason after reset');
    expect(reader.serializeBits(Ref<int>(0), 4), 'reads again');
  });

  test('serializeObject: a serialize returning false latches rejected', () {
    final reader = _reader(const [0x05, 0xAB]);
    expect(
      !reader.serializeObject(_RefusesAfterFourBits()),
      'the object refuses',
    );
    expectEquals(reader.refusal, Refusal.rejected, 'reason');
    _expectPoisoned(reader, Refusal.rejected, 'after the object');
  });

  test('serializeObject: an inner refusal keeps its reason', () {
    final refused = _reader(const [0xFF]);
    expect(!refused.serializeObject(_RefusesAfterPastEnd()), 'refuses');
    expectEquals(refused.refusal, Refusal.pastEnd, 'past_end kept');

    final swallowed = _reader(const [0xFF]);
    expect(!swallowed.serializeObject(_SwallowsRefusal()), 'refuses');
    expectEquals(swallowed.refusal, Refusal.pastEnd, 'swallowed: past_end');
  });

  test('serializeObject: an object that does not refuse is accepted', () {
    final reader = _reader(const [0x1A]);
    expect(reader.serializeObject(_Reads(5)), 'accepted');
    expectEquals(reader.refusal, null, 'no reason');
    expectEquals(reader.bitsProcessed, 5, 'five bits');
  });
}
