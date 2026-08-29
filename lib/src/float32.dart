// Float32 arithmetic and bit-transparency helpers.
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
// serialize_float is bit transparent in both directions: every pattern is
// legal on the wire — NaNs with any payload, signaling NaNs, infinities,
// negative zero, denormals — and the reader reproduces the transmitted
// pattern exactly. The hardware float64 <-> float32 conversion quiets a
// signaling NaN, so NaN patterns are narrowed and widened in software, the
// same technique as the JavaScript port.

import 'dart:typed_data';

final ByteData _scratch = ByteData(8);

/// [value] rounded to the nearest float32, as a double: the float32 rounding
/// boundary the compressed float arithmetic is pinned to.
double fround(double value) {
  _scratch.setFloat32(0, value, Endian.little);
  return _scratch.getFloat32(0, Endian.little);
}

/// The 32 bits of the IEEE-754 single-precision representation of [value].
///
/// Non-NaN values go through the hardware conversion. A NaN is narrowed in
/// software — sign kept, the top 23 mantissa bits kept, the quiet bit NOT
/// forced — so every NaN pattern the read half can produce round trips
/// byte-exactly. A NaN whose payload lives entirely in the low 29 mantissa
/// bits would narrow to an all-zero mantissa — the bit pattern of infinity —
/// so the quiet bit is forced for exactly that case, matching what the
/// hardware conversion produces there.
int float32BitsFromDouble(double value) {
  if (!value.isNaN) {
    _scratch.setFloat32(0, value, Endian.little);
    return _scratch.getUint32(0, Endian.little);
  }
  _scratch.setFloat64(0, value, Endian.little);
  final bits64 = _scratch.getUint64(0, Endian.little);
  final sign = (bits64 >>> 63) << 31;
  var mantissa = (bits64 >>> 29) & 0x7FFFFF;
  if (mantissa == 0) {
    mantissa = 0x400000; // payload entirely in the low 29 bits: never infinity
  }
  return sign | 0x7F800000 | mantissa;
}

/// The double whose IEEE-754 single-precision representation is [bits]: the
/// read half of serialize_float's bit transparency.
///
/// Non-NaN patterns go through the hardware conversion (exact: float32 is a
/// subset of float64). NaN patterns are widened in software — sign kept, the
/// 23 mantissa bits shifted into the top of the float64 mantissa, the quiet
/// bit NOT forced — because the hardware conversion quiets a signaling NaN,
/// and the reader must reproduce the transmitted pattern exactly.
double doubleFromFloat32Bits(int bits) {
  if ((bits & 0x7F800000) == 0x7F800000 && (bits & 0x007FFFFF) != 0) {
    final sign = (bits >>> 31) << 63;
    final mantissa = (bits & 0x007FFFFF) << 29;
    _scratch.setUint64(0, sign | 0x7FF0000000000000 | mantissa, Endian.little);
    return _scratch.getFloat64(0, Endian.little);
  }
  _scratch.setUint32(0, bits, Endian.little);
  return _scratch.getFloat32(0, Endian.little);
}

/// The 64 bits of the IEEE-754 double-precision representation of [value]:
/// exactly the bits of the Dart double, no conversion at all.
int float64BitsFromDouble(double value) {
  _scratch.setFloat64(0, value, Endian.little);
  return _scratch.getUint64(0, Endian.little);
}

/// The double whose IEEE-754 double-precision representation is [bits].
double doubleFromFloat64Bits(int bits) {
  _scratch.setUint64(0, bits, Endian.little);
  return _scratch.getFloat64(0, Endian.little);
}
