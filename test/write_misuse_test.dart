// The 2.1.1 rulings on write and measure misuse (reference IMPLEMENTING.md
// U6 and U9): one mechanism, the trap. In this port the trap is Dart's
// `assert`, an AssertionError at the call in the checked build
// (`--enable-asserts`); the release build compiles every check out. Write
// misuse never latches: no reason is recorded, nothing returns false (but
// reject in release), and the stream keeps writing.

import 'dart:typed_data';

import 'package:serialize/serialize.dart';

import 'harness.dart';

/// Requires [body] to trap in the checked build, moving no bit of [stream].
void _expectTrap(String what, BitStream stream, void Function() body) {
  if (!assertsEnabled) {
    return;
  }
  final before = stream.bitsProcessed;
  try {
    body();
  } on AssertionError {
    expectEquals(stream.bitsProcessed, before, '$what: no bits moved');
    return;
  } catch (error) {
    expect(false, '$what: trapped with $error, not an AssertionError');
    return;
  }
  expect(false, '$what: did not trap');
}

const List<double> _nonFinite = [double.nan, double.infinity, -double.infinity];

void run() {
  test('U9: reject on write or measure traps in the checked build', () {
    final writer = WriteStream(Uint8List(8));
    writer.serializeBits(Ref<int>(5), 3);
    final measure = MeasureStream();
    measure.serializeBits(Ref<int>(5), 3);
    for (final BitStream stream in [writer, measure]) {
      if (assertsEnabled) {
        _expectTrap('$stream: reject', stream, stream.reject);
      } else {
        // the one unchecked result U9 promises: false, nothing recorded
        expect(!stream.reject(), '$stream: reject is false in release');
      }
      expectEquals(stream.bitsProcessed, 3, '$stream: nothing recorded');
      expect(stream.serializeBits(Ref<int>(1), 1), '$stream: still writes');
    }
  });

  test('U6: a measure traps a non-finite float or double value', () {
    for (final v in _nonFinite) {
      final measure = MeasureStream();
      _expectTrap(
        'float $v',
        measure,
        () => measure.serializeFloat(Ref<double>(v)),
      );
      _expectTrap(
        'double $v',
        measure,
        () => measure.serializeDouble(Ref<double>(v)),
      );
    }
    // a finite double above the float32 range narrows to an infinity, and
    // that is what a write would send
    final measure = MeasureStream();
    _expectTrap(
      'float 1e39',
      measure,
      () => measure.serializeFloat(Ref<double>(1e39)),
    );
  });

  test('U9 kept: a write traps a non-finite float or double value', () {
    for (final v in [..._nonFinite, 1e39]) {
      final writer = WriteStream(Uint8List(16));
      _expectTrap(
        'float $v',
        writer,
        () => writer.serializeFloat(Ref<double>(v)),
      );
    }
    for (final v in _nonFinite) {
      final writer = WriteStream(Uint8List(16));
      _expectTrap(
        'double $v',
        writer,
        () => writer.serializeDouble(Ref<double>(v)),
      );
    }
  });

  test('U6: a measure traps a non-finite compressed_float value', () {
    final p = compressedFloatParams(0, 10, 0.01);
    for (final v in _nonFinite) {
      final measure = MeasureStream();
      _expectTrap(
        'compressed_float $v',
        measure,
        () => measure.serializeCompressedFloat(Ref<double>(v), 0, 10, 0.01),
      );
      _expectTrap(
        'compressed_float precomputed $v',
        measure,
        () => measure.serializeCompressedFloatPrecomputed(
          Ref<double>(v),
          p.maxIntegerValue,
          p.bits,
          p.delta,
          0,
        ),
      );
    }
  });

  test('U9 kept: a write traps a non-finite compressed_float, no clamp', () {
    for (final v in _nonFinite) {
      final writer = WriteStream(Uint8List(16));
      _expectTrap(
        'compressed_float $v',
        writer,
        () => writer.serializeCompressedFloat(Ref<double>(v), 0, 10, 0.01),
      );
    }
  });

  test('U6: a measure traps precomputed constants whose top decodes '
      'non-finite', () {
    // valid constants on their own (one step, one bit, delta finite), but
    // min + delta overflows float32: the write asserts it, so a measure must
    final measure = MeasureStream();
    _expectTrap(
      'measure top decode',
      measure,
      () => measure.serializeCompressedFloatPrecomputed(
        Ref<double>(3e38),
        1,
        1,
        3e38,
        3e38,
      ),
    );
    final writer = WriteStream(Uint8List(16));
    _expectTrap(
      'write top decode',
      writer,
      () => writer.serializeCompressedFloatPrecomputed(
        Ref<double>(3e38),
        1,
        1,
        3e38,
        3e38,
      ),
    );
  });

  test('U3 kept: a lone surrogate traps on write and measure', () {
    for (final text in ['a\uD800b', 'a\uDC00']) {
      final writer = WriteStream(Uint8List(16));
      _expectTrap(
        'write $text',
        writer,
        () => writer.serializeString(Ref<String>(text), 16),
      );
      final measure = MeasureStream();
      _expectTrap(
        'measure $text',
        measure,
        () => measure.serializeString(Ref<String>(text), 16),
      );
    }
  });

  test('U9: write misuse never latches', () {
    if (!assertsEnabled) {
      return;
    }
    final writer = WriteStream(Uint8List(16));
    try {
      writer.serializeInt(Ref<int>(99), 0, 10);
    } on AssertionError {
      // the trap
    }
    expect(writer.serializeInt(Ref<int>(7), 0, 10), 'the next write is true');
    expectEquals(writer.bitsProcessed, 4, 'only the good write moved bits');
  });
}
