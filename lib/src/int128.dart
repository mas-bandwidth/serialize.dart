// The emulated 128-bit pair: Int128 / UInt128.
//
// Dart has no native 128-bit integer, so the 128-bit serialize surface speaks
// these types, mirroring the C# port's Int128Value / UInt128Value (decision:
// one API everywhere, so wire behavior cannot diverge by platform). The
// operation set is exactly what the serialize paths need — add, subtract,
// shifts, or, and, compares, word casts — implemented as two's-complement
// math on (hi, lo) 64-bit halves held bit-transparently in Dart ints.
// Nothing speculative: no mul/div/parse. toString is hex, for diagnostics.

import 'bits.dart';

/// Unsigned 128-bit value as (hi, lo) 64-bit halves, each held
/// bit-transparently in a signed Dart int.
final class UInt128 {
  /// The high 64 bits.
  final int hi;

  /// The low 64 bits.
  final int lo;

  /// Constructs from explicit high and low halves.
  const UInt128(this.hi, this.lo);

  /// The zero value.
  static const UInt128 zero = UInt128(0, 0);

  /// The unsigned 128-bit maximum.
  static const UInt128 maxValue = UInt128(allOnes64, allOnes64);

  /// Constructs from a 64-bit value, sign-extending: the conversion from a
  /// signed 64-bit integer, matching the C# port's implicit conversion from
  /// long. For a non-negative value this zero-extends.
  factory UInt128.fromInt(int value) =>
      UInt128(value < 0 ? allOnes64 : 0, value);

  /// The value reinterpreted as signed: bit-transparent.
  Int128 toSigned() => Int128(hi, lo);

  /// The low 64 bits, truncating.
  int toInt() => lo;

  UInt128 operator +(UInt128 other) {
    final low = lo + other.lo;
    final carry = unsignedLessThan(low, lo) ? 1 : 0;
    return UInt128(hi + other.hi + carry, low);
  }

  UInt128 operator -(UInt128 other) {
    final low = lo - other.lo;
    final borrow = unsignedLessThan(lo, other.lo) ? 1 : 0;
    return UInt128(hi - other.hi - borrow, low);
  }

  UInt128 operator -() => zero - this;

  /// Logical left shift. The count is masked to 0..127, matching the C#
  /// pair's shift semantics.
  UInt128 operator <<(int count) {
    count &= 127;
    if (count == 0) {
      return this;
    }
    if (count < 64) {
      return UInt128((hi << count) | (lo >>> (64 - count)), lo << count);
    }
    return UInt128(lo << (count - 64), 0);
  }

  /// Logical right shift. The count is masked to 0..127.
  UInt128 operator >>(int count) {
    count &= 127;
    if (count == 0) {
      return this;
    }
    if (count < 64) {
      return UInt128(hi >>> count, (lo >>> count) | (hi << (64 - count)));
    }
    return UInt128(0, hi >>> (count - 64));
  }

  UInt128 operator |(UInt128 other) => UInt128(hi | other.hi, lo | other.lo);

  UInt128 operator &(UInt128 other) => UInt128(hi & other.hi, lo & other.lo);

  bool operator <(UInt128 other) => hi == other.hi
      ? unsignedLessThan(lo, other.lo)
      : unsignedLessThan(hi, other.hi);

  bool operator >(UInt128 other) => other < this;

  bool operator <=(UInt128 other) => !(other < this);

  bool operator >=(UInt128 other) => !(this < other);

  @override
  bool operator ==(Object other) =>
      other is UInt128 && hi == other.hi && lo == other.lo;

  @override
  int get hashCode => Object.hash(hi, lo);

  @override
  String toString() =>
      '0x${(hi & allOnes64).toRadixString(16).padLeft(16, '0')}'
      '${(lo & allOnes64).toRadixString(16).padLeft(16, '0')}';
}

/// Signed 128-bit value as (hi, lo) 64-bit halves, two's complement.
final class Int128 {
  /// The high 64 bits. The sign lives in its top bit.
  final int hi;

  /// The low 64 bits, held bit-transparently.
  final int lo;

  /// Constructs from explicit high and low halves.
  const Int128(this.hi, this.lo);

  /// The zero value.
  static const Int128 zero = Int128(0, 0);

  /// The signed 128-bit minimum, -2^127.
  static const Int128 minValue = Int128(signBit64, 0);

  /// The signed 128-bit maximum, 2^127 - 1.
  static const Int128 maxValue = Int128(0x7FFFFFFFFFFFFFFF, allOnes64);

  /// Constructs from a 64-bit value, sign-extending.
  factory Int128.fromInt(int value) => Int128(value < 0 ? allOnes64 : 0, value);

  /// The value reinterpreted as unsigned: bit-transparent.
  UInt128 toUnsigned() => UInt128(hi, lo);

  /// The low 64 bits, truncating.
  int toInt() => lo;

  Int128 operator +(Int128 other) =>
      (toUnsigned() + other.toUnsigned()).toSigned();

  Int128 operator -(Int128 other) =>
      (toUnsigned() - other.toUnsigned()).toSigned();

  Int128 operator -() => zero - this;

  /// Left shift. The count is masked to 0..127.
  Int128 operator <<(int count) => (toUnsigned() << count).toSigned();

  /// Arithmetic right shift. The count is masked to 0..127.
  Int128 operator >>(int count) {
    count &= 127;
    if (count == 0) {
      return this;
    }
    if (count < 64) {
      return Int128(hi >> count, (lo >>> count) | (hi << (64 - count)));
    }
    return Int128(hi >> 63, hi >> (count - 64));
  }

  bool operator <(Int128 other) =>
      hi == other.hi ? unsignedLessThan(lo, other.lo) : hi < other.hi;

  bool operator >(Int128 other) => other < this;

  bool operator <=(Int128 other) => !(other < this);

  bool operator >=(Int128 other) => !(this < other);

  @override
  bool operator ==(Object other) =>
      other is Int128 && hi == other.hi && lo == other.lo;

  @override
  int get hashCode => Object.hash(hi, lo);

  @override
  String toString() =>
      '0x${(hi & allOnes64).toRadixString(16).padLeft(16, '0')}'
      '${(lo & allOnes64).toRadixString(16).padLeft(16, '0')}';
}

/// The number of bits required to serialize a 128-bit integer in [min,max].
/// The subtraction is performed in the unsigned domain, so ranges wider than
/// 2^127 are exact rather than overflowing (STANDARD.md, "int128 (ranged)").
int bitsRequired128(UInt128 min, UInt128 max) {
  if (min == max) {
    return 0;
  }
  final diff = max - min;
  return diff.hi != 0
      ? 64 + bitsRequired64(0, diff.hi)
      : bitsRequired64(0, diff.lo);
}
