// Failure is terminal (STANDARD.md, "Reader Obligations"): the first failed
// read latches the stream, and every later read fails, consuming no bits and
// writing no destination. Only reset — re-initialization — clears it.
//
// Each case here fails a stream a different way, then proves that a read
// which would otherwise succeed fails instead and leaves its holder alone.

import 'dart:typed_data';

import 'package:serialize/serialize.dart';

import 'harness.dart';

/// Data whose first byte reads back as 0xAB, with plenty of room after it, so
/// the follow-up read below would succeed on a stream that had not failed.
Uint8List _room() => Uint8List.fromList(const [0xAB, 0, 0, 0, 0, 0, 0, 0]);

/// Proves the stream is latched: a read that the data plainly supports must
/// fail, and its holder must be untouched. A zero-bit read is included
/// because a degenerate range consumes nothing and so has no past-end check
/// of its own to lean on.
void _expectLatched(ReadStream stream, String what) {
  expect(stream.failed, '$what: the stream reports the failure');
  final byte = Ref<int>(0x77);
  expect(!stream.serializeBits(byte, 8), '$what: a later read fails');
  expectEquals(byte.value, 0x77, '$what: a later read writes nothing');
  final degenerate = Ref<int>(0x77);
  expect(
    !stream.serializeInt(degenerate, 5, 5),
    '$what: a later zero-bit read fails',
  );
  expectEquals(
    degenerate.value,
    0x77,
    '$what: a later zero-bit read writes nothing',
  );
  final wide = Ref<Int128>(Int128.zero);
  expect(
    !stream.serializeInt128(wide, Int128.fromInt(5), Int128.fromInt(5)),
    '$what: a later zero-bit 128-bit read fails',
  );
  expectEquals(wide.value, Int128.zero, '$what: and writes nothing');
  final reason = stream.refusal;
  expect(!stream.serializeEnd(), '$what: a later end fails');
  expectEquals(stream.refusal, reason, '$what: the echoes keep the reason');
}

void run() {
  test('terminal failure: before any bits are consumed', () {
    final stream = ReadStream(Uint8List(0));
    final value = Ref<int>(0x77);
    expect(!stream.serializeBits(value, 8), 'the empty stream refuses');
    expectEquals(value.value, 0x77, 'holder untouched');
    _expectLatched(stream, 'past the end at once');
  });

  test('terminal failure: after a partial consumption', () {
    // one byte of data: the first 4-bit read succeeds, the 8-bit read that
    // follows does not fit and fails with 4 bits already consumed
    final stream = ReadStream(Uint8List.fromList(const [0xAB]));
    final nibble = Ref<int>(0);
    expect(stream.serializeBits(nibble, 4), 'the first four bits fit');
    expect(!stream.serializeBits(Ref<int>(0), 8), 'the next eight do not');
    _expectLatched(stream, 'past the end mid-stream');
  });

  test('terminal failure: on range headroom', () {
    // [0,100] is seven bits wide; the low seven bits here are 127, above the
    // max: the offset rides the bit headroom and the range check convicts it
    final stream = ReadStream(
      Uint8List.fromList(const [0x7F, 0, 0, 0, 0, 0, 0, 0]),
    );
    final value = Ref<int>(0x77);
    expect(!stream.serializeInt(value, 0, 100), 'the smuggled offset refuses');
    expectEquals(value.value, 0x77, 'holder untouched');
    _expectLatched(stream, 'range headroom');
  });

  test('terminal failure: on alignment', () {
    // three bits consumed, then an align whose padding bits are not zero
    final stream = ReadStream(_room());
    expect(stream.serializeBits(Ref<int>(0), 3), 'three bits');
    expect(!stream.serializeAlign(), 'nonzero padding refuses');
    _expectLatched(stream, 'nonzero align padding');
  });

  test('terminal failure: on a malformed string', () {
    // a length-3 string whose payload is an overlong UTF-8 encoding
    final writer = WriteStream(Uint8List(16));
    writer.serializeString(Ref<String>('abc'), 16);
    writer.flush();
    final doctored = Uint8List.fromList(writer.data());
    doctored.setRange(1, 4, const [0xC0, 0xAF, 0x61]);
    final stream = ReadStream(doctored);
    final text = Ref<String>('unset');
    expect(!stream.serializeString(text, 16), 'invalid UTF-8 refuses');
    expectEquals(text.value, 'unset', 'holder untouched');
    _expectLatched(stream, 'malformed string');
  });

  test('terminal failure: on int_relative', () {
    // six zero flags, then 32 raw bits carrying a value at or below previous
    final writer = WriteStream(Uint8List(16));
    writer.serializeBits(Ref<int>(0), 6);
    writer.serializeBits(Ref<int>(50), 32);
    writer.flush();
    final stream = ReadStream(writer.data());
    final current = Ref<int>(0x77);
    expect(!stream.serializeIntRelative(100, current), 'not increasing');
    expectEquals(current.value, 0x77, 'holder untouched');
    _expectLatched(stream, 'int_relative');
  });

  test('a failure is cleared only by re-initialization', () {
    final stream = ReadStream(Uint8List(0));
    expect(!stream.serializeBits(Ref<int>(0), 8), 'the empty stream refuses');
    expect(stream.failed, 'latched');

    expectEquals(stream.refusal, Refusal.pastEnd, 'the reason');

    stream.reset(_room());
    expect(!stream.failed, 'reset clears the failure');
    expectEquals(stream.refusal, null, 'and its reason');
    final value = Ref<int>(0);
    expect(stream.serializeBits(value, 8), 'and reads work again');
    expectEquals(value.value, 0xAB, 'the byte comes back');
  });

  test('the reason is the FIRST refusal\'s', () {
    // a range refusal, then a read past the end, then an end: every later
    // refusal is an echo, and the stream reports the first
    final stream = ReadStream(Uint8List.fromList(const [0x0F]));
    expect(!stream.serializeInt(Ref<int>(0), 0, 8), 'offset 15 refused');
    expectEquals(stream.refusal, Refusal.valueOutOfRange, 'first reason');
    expect(!stream.serializeBits(Ref<int>(0), 32), 'past the end');
    expect(!stream.serializeEnd(), 'end');
    expectEquals(stream.refusal, Refusal.valueOutOfRange, 'still the first');
  });

  test('an object keeps the reason of the read that refused inside it', () {
    final stream = ReadStream(Uint8List.fromList(const [0x80]));
    expect(!stream.serializeObject(_Field(7)), 'refused');
    expectEquals(stream.refusal, Refusal.nonzeroPadding, 'the inner reason');
    _expectLatched(stream, 'object');
  });

  test('an object that refuses on its own is terminal and rejected', () {
    // the caller's serialize returned false with no refused read: the stream
    // latches as rejected (2.1), and no wire rule is blamed for it
    final stream = ReadStream(_room());
    expect(!stream.serializeObject(_Refuser()), 'refused');
    expectEquals(stream.refusal, Refusal.rejected, 'the caller refused');
    _expectLatched(stream, 'caller refusal');
    // and the echoes after it keep that reason
    expectEquals(stream.refusal, Refusal.rejected, 'still rejected');
  });

  test(
    'an object whose serialize ignores an inner refusal still refuses the composition',
    () {
      // [0,100] is seven bits wide; 0x7F has low seven bits 127, which fails
      // the range check with Refusal.valueOutOfRange after consuming 0 bits
      // (poisoning the stream). Even if the object's serialize callback
      // ignores that boolean and returns true, serializeObject must return
      // false while keeping the first refusal reason and terminal latch.
      final stream = ReadStream(
        Uint8List.fromList(const [0x7F, 0xAB, 0, 0, 0, 0, 0, 0]),
      );
      expect(
        !stream.serializeObject(_SwallowedFailure()),
        'the composite read refuses even when the callback returns true',
      );
      expectEquals(
        stream.refusal,
        Refusal.valueOutOfRange,
        'the inner refusal reason is preserved',
      );
      _expectLatched(stream, 'swallowed inner failure');
    },
  );
}

/// An object of [bits] bits and an align.
final class _Field implements Serializable {
  _Field(this.bits);

  final int bits;

  @override
  bool serialize(BitStream stream) =>
      stream.serializeBits(Ref<int>(0), bits) && stream.serializeAlign();
}

/// An object whose own serialize refuses without a refused read.
final class _Refuser implements Serializable {
  @override
  bool serialize(BitStream stream) => false;
}

/// An object whose serialize performs a failing primitive read, ignores the
/// returned false, and returns true anyway.
final class _SwallowedFailure implements Serializable {
  @override
  bool serialize(BitStream stream) {
    stream.serializeInt(Ref<int>(0), 0, 100);
    return true;
  }
}
