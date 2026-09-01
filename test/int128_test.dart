// toString renders the 128-bit PATTERN — 32 zero-padded hex digits, never a
// sign — including limbs whose sign bit is set (a masked negative through
// toRadixString keeps its sign, which is the defect this suite pins).

import 'package:serialize/serialize.dart';

import 'harness.dart';

void run() {
  test('Int128/UInt128 toString: sign-bit limbs render as patterns', () {
    expectEquals(
      UInt128(0, 0).toString(),
      '0x00000000000000000000000000000000',
      'zero',
    );
    expectEquals(
      UInt128(0, 0x7FFFFFFFFFFFFFFF).toString(),
      '0x00000000000000007fffffffffffffff',
      'positive lo',
    );
    expectEquals(
      UInt128(-0x8000000000000000, 0).toString(),
      '0x80000000000000000000000000000000',
      'sign-bit hi',
    );
    expectEquals(
      UInt128(-1, -1).toString(),
      '0xffffffffffffffffffffffffffffffff',
      'all ones',
    );
    expectEquals(
      Int128(-0x8000000000000000, 0).toString(),
      '0x80000000000000000000000000000000',
      'Int128 min',
    );
    expectEquals(
      Int128(-1, -1).toString(),
      '0xffffffffffffffffffffffffffffffff',
      'Int128 minus one',
    );
    expectEquals(
      Int128(0x0123456789ABCDEF, -0x0FEDCBA987654322).toString(),
      '0x0123456789abcdeff0123456789abcde',
      'mixed limbs',
    );
    final rendered = Int128(-1, 0).toString();
    expectEquals(rendered.contains('-'), false, 'no sign character ever');
    expectEquals(rendered.length, 34, '0x plus 32 digits');
  });
}
