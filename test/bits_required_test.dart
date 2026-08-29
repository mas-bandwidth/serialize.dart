// Known-answer tests for the bit cost functions, at all three widths.

import 'package:serialize/serialize.dart';

import 'harness.dart';

void run() {
  test('bitsRequired: known answers', () {
    expectEquals(bitsRequired(0, 0), 0, 'degenerate range');
    expectEquals(bitsRequired(5, 5), 0, 'degenerate range at 5');
    expectEquals(bitsRequired(0, 1), 1, '[0,1]');
    expectEquals(bitsRequired(0, 7), 3, '[0,7]');
    expectEquals(bitsRequired(0, 8), 4, '[0,8]');
    expectEquals(bitsRequired(0, 255), 8, '[0,255]');
    expectEquals(bitsRequired(0, 256), 9, '[0,256]');
    expectEquals(bitsRequired(0, 1000), 10, '[0,1000]');
    expectEquals(bitsRequired(0, 0xFFFFFFFF), 32, 'full 32-bit range');
    expectEquals(bitsRequired(100, 300), 8, '[100,300]');
  });

  test('bitsRequired64: known answers, including wrap-wide ranges', () {
    expectEquals(bitsRequired64(0, 0), 0, 'degenerate');
    expectEquals(bitsRequired64(0, 1), 1, '[0,1]');
    expectEquals(bitsRequired64(0, 0xFFFFFFFF), 32, '32-bit range');
    expectEquals(bitsRequired64(0, 0x100000000), 33, '33-bit range');
    expectEquals(bitsRequired64(-5000000000, 5000000000), 34, '+/-5e9');
    // the full int64 range is wider than 2^63: the subtraction must wrap in
    // the unsigned domain rather than overflow
    expectEquals(
      bitsRequired64(-0x8000000000000000, 0x7FFFFFFFFFFFFFFF),
      64,
      'full',
    );
    expectEquals(bitsRequired64(0, -1), 64, 'full unsigned range');
  });

  test('bitsRequired128: known answers, including ranges wider than 2^127', () {
    expectEquals(bitsRequired128(UInt128.zero, UInt128.zero), 0, 'degenerate');
    expectEquals(
      bitsRequired128(UInt128.zero, UInt128.fromInt(255)),
      8,
      '[0,255]',
    );
    // bits_required128( -2^100, 2^100 ) == 102, from the reference's test
    final min = (-(Int128.fromInt(1) << 100)).toUnsigned();
    final max = (Int128.fromInt(1) << 100).toUnsigned();
    expectEquals(bitsRequired128(min, max), 102, '+/-2^100');
    // the full int128 range is wider than 2^127
    expectEquals(
      bitsRequired128(
        Int128.minValue.toUnsigned(),
        Int128.maxValue.toUnsigned(),
      ),
      128,
      'full int128 range',
    );
    // +/-2^70 needs 72 bits: the three-group structure of the golden pin
    final min70 = (-(Int128.fromInt(1) << 70)).toUnsigned();
    final max70 = (Int128.fromInt(1) << 70).toUnsigned();
    expectEquals(bitsRequired128(min70, max70), 72, '+/-2^70');
  });

  test('Int128 / UInt128 arithmetic: the operations the codec relies on', () {
    // carry propagation
    final carry = UInt128(0, -1) + UInt128(0, 1);
    expectEquals(carry, const UInt128(1, 0), 'add carry');
    // borrow propagation
    final borrow = const UInt128(1, 0) - const UInt128(0, 1);
    expectEquals(borrow, UInt128(0, -1), 'subtract borrow');
    // shifts across the lane boundary
    expectEquals(UInt128.fromInt(1) << 64, const UInt128(1, 0), 'shl 64');
    expectEquals(const UInt128(1, 0) >> 64, const UInt128(0, 1), 'shr 64');
    expectEquals(
      UInt128.fromInt(1) << 100 >> 100,
      UInt128.fromInt(1),
      'shl/shr 100',
    );
    // unsigned ordering: a value with the high bit set is large, not negative
    expect(UInt128.maxValue > UInt128.zero, 'unsigned max > 0');
    expect(
      const UInt128(0x8000000000000000, 0) > const UInt128(1, 0),
      'unsigned compare uses the unsigned domain',
    );
    // signed ordering
    expect(Int128.minValue < Int128.zero, 'signed min < 0');
    expect(Int128.maxValue > Int128.zero, 'signed max > 0');
    expect(Int128.fromInt(-1) < Int128.fromInt(1), '-1 < 1');
    // sign extension
    expectEquals(Int128.fromInt(-1), Int128(-1, -1), 'sign extend');
    expectEquals(
      -Int128.fromInt(5) + Int128.fromInt(5),
      Int128.zero,
      'negation',
    );
  });
}
