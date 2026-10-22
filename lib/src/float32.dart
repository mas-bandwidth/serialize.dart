// Float32 arithmetic and bit-exact conversion helpers.
//
// Dart's double is IEEE-754 binary64. The compressed float's quantization
// arithmetic is pinned to float32 with every step rounding (STANDARD.md), so
// each step here is rounded through [fround]. Emulating float32 +, -, *, /
// as a binary64 operation followed by a rounding to binary32 is EXACT: the
// binary64 result of adding, subtracting or multiplying two binary32 values
// is itself exact (2 x 24 significand bits fit in 53), and for division the
// double rounding is innocuous because 2p + 2 = 50 <= 53. Dart performs no
// floating point contraction, and every intermediate is rounded explicitly,
// so no step can fuse or widen.
//
// serialize_float and serialize_double carry FINITE values only (STANDARD.md,
// "Finite values only, every one bit exact", format 2.0): a pattern whose
// exponent field is all ones is refused on read, tested on the raw bits
// before any conversion, and never handed to a writer. Every finite pattern
// round trips bit exactly through these conversions, negative zero and the
// subnormals included, so they are plain hardware conversions: the software
// NaN narrowing and widening format 1.1 needed is gone with the patterns it
// carried.

import 'dart:typed_data';

// One 8-byte scratch buffer under four overlaid typed-list views: indexed
// typed-list access compiles to a plain load/store, cheaper than the ByteData
// methods on hot paths. The views are host-endian, which is correct here:
// every conversion is a same-width store-then-load on the same bytes, so the
// byte order cancels — no value in this file ever meets the wire directly.
final Float32List _f32 = Float32List(2);
final Uint32List _u32 = _f32.buffer.asUint32List();
final Float64List _f64 = _f32.buffer.asFloat64List();
final Uint64List _u64 = _f32.buffer.asUint64List();

/// [value] rounded to the nearest float32, as a double: the float32 rounding
/// boundary the compressed float arithmetic is pinned to.
@pragma('vm:prefer-inline')
double fround(double value) {
  _f32[0] = value;
  return _f32[0];
}

/// The 32 bits of the IEEE-754 single-precision representation of [value],
/// rounded to the nearest float32: exact for every finite float32 value. A
/// NaN comes back quieted, as the hardware conversion produces it; the wire
/// carries no NaN, so no caller of the format sees one.
@pragma('vm:prefer-inline')
int float32BitsFromDouble(double value) {
  _f32[0] = value;
  return _u32[0];
}

/// The double whose IEEE-754 single-precision representation is [bits]:
/// exact for every finite pattern, negative zero and the subnormals
/// included. A signaling NaN pattern comes back quieted.
@pragma('vm:prefer-inline')
double doubleFromFloat32Bits(int bits) {
  _u32[0] = bits;
  return _f32[0];
}

/// Is the float32 pattern [bits] finite? False exactly when its exponent
/// field is all ones: NaN with any payload or sign, and both infinities.
/// Tested on the raw bits, never through a conversion.
@pragma('vm:prefer-inline')
bool float32BitsAreFinite(int bits) => (bits & 0x7F800000) != 0x7F800000;

/// Is the float64 pattern [bits] finite? False exactly when its exponent
/// field is all ones.
@pragma('vm:prefer-inline')
bool float64BitsAreFinite(int bits) =>
    (bits & 0x7FF0000000000000) != 0x7FF0000000000000;

/// The 64 bits of the IEEE-754 double-precision representation of [value]:
/// exactly the bits of the Dart double, no conversion at all.
@pragma('vm:prefer-inline')
int float64BitsFromDouble(double value) {
  _f64[0] = value;
  return _u64[0];
}

/// The double whose IEEE-754 double-precision representation is [bits].
@pragma('vm:prefer-inline')
double doubleFromFloat64Bits(int bits) {
  _u64[0] = bits;
  return _f64[0];
}
