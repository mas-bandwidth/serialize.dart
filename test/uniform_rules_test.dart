// The uniform behaviour rules of reference IMPLEMENTING.md, U1 to U16, where
// this port had to change to keep them. Rules the port already kept are
// covered by the suites that test those operations.
//
// Read side (U5, U7, U16): a bad caller declaration on a read stream is
// refused as value_out_of_range before any bits move, in every build mode,
// and never throws; a stream that already failed keeps its first reason.
// Write and measure side: the same declarations are caller error, asserted
// in the checked build, which is this port's one write-misuse mechanism (U9).

import 'dart:typed_data';

import 'package:serialize/serialize.dart';

import 'harness.dart';

ReadStream _reader(List<int> bytes) => ReadStream(Uint8List.fromList(bytes));

/// Runs [read] on a fresh stream over sixteen 0xFF bytes and requires a
/// value_out_of_range refusal and no throw. Sixteen bytes of ones are enough
/// for every read here, so a read that moved bits would accept or refuse for
/// a wire reason instead.
void _expectDeclarationRefused(
  String what,
  bool Function(ReadStream stream) read,
) {
  final reader = _reader(List<int>.filled(16, 0xFF));
  var ok = true;
  try {
    ok = read(reader);
  } catch (error) {
    expect(false, '$what: threw $error');
    return;
  }
  expect(!ok, '$what: refused');
  expectEquals(reader.refusal, Refusal.valueOutOfRange, '$what: reason');
  expect(reader.failed, '$what: terminal');
}

/// Requires [body] to fail the checked build's write-misuse check before it
/// moves a bit of [stream].
void _expectMisuse(String what, BitStream stream, void Function() body) {
  if (!assertsEnabled) {
    return;
  }
  final before = stream.bitsProcessed;
  expectThrows(body, '$what: caught');
  expectEquals(stream.bitsProcessed, before, '$what: no bits moved');
}

void run() {
  test('U5 and audit H2: int bounds outside int32 refuse on read', () {
    _expectDeclarationRefused(
      'int [0, 0xFFFFFFFF]',
      (r) => r.serializeInt(Ref<int>(7), 0, 0xFFFFFFFF),
    );
    _expectDeclarationRefused(
      'int [-2^31 - 1, 0]',
      (r) => r.serializeInt(Ref<int>(7), -(1 << 31) - 1, 0),
    );
    _expectDeclarationRefused(
      'int [0, 2^40]',
      (r) => r.serializeInt(Ref<int>(7), 0, 1 << 40),
    );
    final value = Ref<int>(7);
    _reader(const [0xFF, 0xFF, 0xFF, 0xFF]).serializeInt(value, 0, 0xFFFFFFFF);
    expectEquals(value.value, 7, 'the holder is untouched');
  });

  test('U5 and audit H2: int bounds outside int32 are write misuse', () {
    final writer = WriteStream(Uint8List(8));
    _expectMisuse(
      'write int [0, 0xFFFFFFFF]',
      writer,
      () => writer.serializeInt(Ref<int>(0xFFFFFFFF), 0, 0xFFFFFFFF),
    );
    final measure = MeasureStream();
    _expectMisuse(
      'measure int [0, 0xFFFFFFFF]',
      measure,
      () => measure.serializeInt(Ref<int>(0xFFFFFFFF), 0, 0xFFFFFFFF),
    );
  });

  test('U7 and audit H2: a string buffer size the wire cannot use refuses', () {
    for (final bufferSize in [0, -5, 1 << 32, (1 << 31) + 1, 1 << 40]) {
      _expectDeclarationRefused(
        'string bufferSize $bufferSize',
        (r) => r.serializeString(Ref<String>('untouched'), bufferSize),
      );
    }
  });

  test('U7: a ranged read with min > max refuses', () {
    _expectDeclarationRefused(
      'int [5, 4]',
      (r) => r.serializeInt(Ref<int>(0), 5, 4),
    );
    _expectDeclarationRefused(
      'int64 [5, 4]',
      (r) => r.serializeInt64(Ref<int>(0), 5, 4),
    );
    _expectDeclarationRefused(
      'int128 [5, 4]',
      (r) => r.serializeInt128(
        Ref<Int128>(Int128.zero),
        Int128.fromInt(5),
        Int128.fromInt(4),
      ),
    );
  });

  test('U7: a bad declaration keeps the first reason', () {
    final reader = _reader(const [0xFF]);
    expect(!reader.serializeBits(Ref<int>(0), 16), 'past the end');
    expect(!reader.serializeInt(Ref<int>(0), 0, 0xFFFFFFFF), 'refuses');
    expect(!reader.serializeBits(Ref<int>(0), 0), 'refuses');
    expect(!reader.serializeString(Ref<String>(''), 0), 'refuses');
    expectEquals(reader.refusal, Refusal.pastEnd, 'the first reason stays');
  });

  test('U16: a bits count outside its range refuses on read', () {
    for (final bits in [0, -1, 33]) {
      _expectDeclarationRefused(
        'bits $bits',
        (r) => r.serializeBits(Ref<int>(0), bits),
      );
    }
    for (final bits in [0, -1, 65]) {
      _expectDeclarationRefused(
        'bits64 $bits',
        (r) => r.serializeBits64(Ref<int>(0), bits),
      );
    }
  });

  test('U16: an int_relative previous outside the domain refuses', () {
    for (final previous in [-1, intRelativeMax + 1]) {
      _expectDeclarationRefused(
        'int_relative previous $previous',
        (r) => r.serializeIntRelative(previous, Ref<int>(0)),
      );
    }
  });

  test('U16: a compressed_float declaration it cannot derive refuses', () {
    final declarations = <List<double>>[
      [1, 1, 0.1], // min == max
      [2, 1, 0.1], // min > max
      [0, 1, 0], // resolution zero
      [0, 1, -0.1], // resolution negative
      [double.nan, 1, 0.1],
      [0, double.nan, 0.1],
      [0, 1, double.nan],
      [0, double.infinity, 0.1],
      [-3.4e38, 3.4e38, 1], // delta overflows float32
    ];
    for (final d in declarations) {
      _expectDeclarationRefused(
        'compressed_float $d',
        (r) => r.serializeCompressedFloat(Ref<double>(0), d[0], d[1], d[2]),
      );
    }
  });

  test('U16: a fixed point declaration that does not fit refuses', () {
    final declarations = <List<int>>[
      [0, 8, 0, 1], // no integer bits
      [4, -1, 0, 1], // negative fraction bits
      [3, 3, 0, 1], // storage width 6
      [4, 4, 1, 0], // min > max
      [4, 4, 0, 16], // max past the unsigned Q4 range
      [4, 4, -9, 0], // min past the signed Q4 range
    ];
    for (final d in declarations) {
      _expectDeclarationRefused(
        'fixed $d',
        (r) => r.serializeFixed(Ref<int>(0), d[0], d[1], d[2], d[3]),
      );
    }
    final wide = <List<int>>[
      [64, 32, 0, 1], // storage width 96
      [0, 128, 0, 1], // no integer bits
      [64, 64, 1, 0], // min > max
    ];
    for (final d in wide) {
      _expectDeclarationRefused(
        'fixed128 $d',
        (r) => r.serializeFixed128(
          Ref<Int128>(Int128.zero),
          d[0],
          d[1],
          d[2],
          d[3],
        ),
      );
    }
  });

  test('U10: bytes checks room for the align and payload first', () {
    final writer = WriteStream(Uint8List(8));
    writer.serializeBits(Ref<int>(0), 30);
    writer.serializeBits(Ref<int>(0), 30);
    _expectMisuse(
      'bytes past the buffer',
      writer,
      () => writer.serializeBytes(Uint8List(1)),
    );
  });

  test('U10: string checks room for length, align and payload first', () {
    final writer = WriteStream(Uint8List(8));
    writer.serializeBits(Ref<int>(0), 30);
    _expectMisuse(
      'string past the buffer',
      writer,
      () => writer.serializeString(Ref<String>('hello'), 256),
    );
  });

  test('U14: the refusal-name function spells the family names', () {
    expectEquals(refusalName(null), 'none', 'no refusal');
    for (final reason in Refusal.values) {
      expectEquals(refusalName(reason), reason.name, 'name of $reason');
    }
    expectEquals(refusalName(Refusal.pastEnd), 'past_end', 'past_end');
    expectEquals(refusalName(Refusal.rejected), 'rejected', 'rejected');
  });

  test('U14: fail latches its reason, or rejected with none given', () {
    final reader = _reader(const [0xFF]);
    expect(!reader.fail(Refusal.nonCanonical), 'fail returns false');
    expectEquals(reader.refusal, Refusal.nonCanonical, 'the given reason');
    expect(reader.failed, 'terminal');
    expect(!reader.fail(Refusal.pastEnd), 'a second fail');
    expectEquals(reader.refusal, Refusal.nonCanonical, 'the first one wins');
    expect(!reader.serializeBits(Ref<int>(0), 1), 'a later read refuses');

    final silent = _reader(const [0xFF]);
    expect(!silent.fail(), 'fail with no reason');
    expectEquals(silent.refusal, Refusal.rejected, 'records rejected');
    expectEquals(refusalName(silent.refusal), 'rejected', 'never none');
  });

  test('U6 and U9: fail and reject on write or measure return false', () {
    final writer = WriteStream(Uint8List(8));
    writer.serializeBits(Ref<int>(5), 3);
    final measure = MeasureStream();
    measure.serializeBits(Ref<int>(5), 3);
    for (final BitStream stream in [writer, measure]) {
      expect(!stream.fail(Refusal.pastEnd), '$stream: fail is false');
      expect(!stream.fail(), '$stream: fail with no reason is false');
      expect(!stream.reject(), '$stream: reject is false');
      expectEquals(stream.bitsProcessed, 3, '$stream: nothing recorded');
      expect(stream.serializeBits(Ref<int>(1), 1), '$stream: still writes');
    }
  });

  test('U15: compressedFloatParams derives the per-call constants', () {
    final p = compressedFloatParams(0, 10, 0.01);
    expectEquals(p.maxIntegerValue, 1000, 'step count');
    expectEquals(p.bits, 10, 'bits');
    expectSameDouble(p.delta, 10.0, 'delta');
    final wide = compressedFloatParams(-100, 100, 0.001);
    expectEquals(wide.bits, bitsRequired(0, wide.maxIntegerValue), 'bits');
  });

  test('U15: precomputed is wire identical to the unified form', () {
    final declarations = <List<double>>[
      [0, 10, 0.01],
      [-100, 100, 0.001],
      [-1, 16777218, 1],
      [0.5, 0.75, 0.1],
    ];
    for (final d in declarations) {
      final p = compressedFloatParams(d[0], d[1], d[2]);
      final values = [d[0], d[1], (d[0] + d[1]) / 2, d[0] - 1, d[1] + 1];
      for (var prefix = 0; prefix < 64; prefix++) {
        for (final v in values) {
          final unified = WriteStream(Uint8List(16));
          final precomputed = WriteStream(Uint8List(16));
          if (prefix > 0) {
            unified.serializeBits64(Ref<int>(0), prefix);
            precomputed.serializeBits64(Ref<int>(0), prefix);
          }
          unified.serializeCompressedFloat(Ref<double>(v), d[0], d[1], d[2]);
          precomputed.serializeCompressedFloatPrecomputed(
            Ref<double>(v),
            p.maxIntegerValue,
            p.bits,
            p.delta,
            d[0],
          );
          unified.flush();
          precomputed.flush();
          expectEquals(
            precomputed.bitsProcessed,
            unified.bitsProcessed,
            '$d $v at $prefix: bits',
          );
          expectBytes(precomputed.data(), unified.data(), '$d $v at $prefix');

          final measure = MeasureStream();
          measure.serializeCompressedFloatPrecomputed(
            Ref<double>(v),
            p.maxIntegerValue,
            p.bits,
            p.delta,
            d[0],
          );
          expectEquals(measure.bitsProcessed, p.bits, '$d: measured');

          if (prefix == 0) {
            final a = Ref<double>(0);
            final b = Ref<double>(0);
            final ra = ReadStream(unified.data());
            final rb = ReadStream(unified.data());
            expect(
              ra.serializeCompressedFloat(a, d[0], d[1], d[2]),
              '$d $v: unified read',
            );
            expect(
              rb.serializeCompressedFloatPrecomputed(
                b,
                p.maxIntegerValue,
                p.bits,
                p.delta,
                d[0],
              ),
              '$d $v: precomputed read',
            );
            expectSameDouble(b.value, a.value, '$d $v: same decode');
            expectEquals(rb.bitsProcessed, ra.bitsProcessed, '$d: bits read');
          }
        }
      }
    }
  });

  test('U16: precomputed constants it cannot derive refuse on read', () {
    final constants = <(int, int, double)>[
      (0, 0, 1), // step count zero
      (4294967041, 32, 1), // step count past 4294967040
      (1000, 9, 0.01), // bits not bitsRequired(0, 1000)
      (1000, 11, 0.01),
      (1000, 10, 0), // delta zero
      (1000, 10, -1), // delta negative
      (1000, 10, double.nan),
      (1000, 10, double.infinity),
      (1000, 10, 1e39), // finite as a double, infinite in float32
    ];
    for (final (maxIntegerValue, bits, delta) in constants) {
      _expectDeclarationRefused(
        'precomputed ($maxIntegerValue, $bits, $delta)',
        (r) => r.serializeCompressedFloatPrecomputed(
          Ref<double>(0),
          maxIntegerValue,
          bits,
          delta,
          0,
        ),
      );
      final writer = WriteStream(Uint8List(16));
      _expectMisuse(
        'write precomputed ($maxIntegerValue, $bits, $delta)',
        writer,
        () => writer.serializeCompressedFloatPrecomputed(
          Ref<double>(0),
          maxIntegerValue,
          bits,
          delta,
          0,
        ),
      );
      final measure = MeasureStream();
      _expectMisuse(
        'measure precomputed ($maxIntegerValue, $bits, $delta)',
        measure,
        () => measure.serializeCompressedFloatPrecomputed(
          Ref<double>(0),
          maxIntegerValue,
          bits,
          delta,
          0,
        ),
      );
    }
  });
}
