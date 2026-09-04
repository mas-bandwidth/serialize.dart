// Bit cost and unsigned-domain arithmetic helpers.
//
// Dart's int is a signed 64-bit integer. Unsigned 32/64-bit wire values are
// held bit-transparently in it: arithmetic wraps two's complement, exactly
// the unsigned-domain wrap the format's offset encodings rely on. Where
// unsigned ORDERING matters, the explicit compare helpers below flip the sign
// bit so the signed comparison orders the unsigned domain.

/// The sign bit of a 64-bit integer, used to translate unsigned comparisons
/// into the signed domain.
const int signBit64 = 0x8000000000000000;

/// All 64 bits set: the unsigned 64-bit maximum, held bit-transparently.
const int allOnes64 = -1;

/// Unsigned 64-bit less-than.
bool unsignedLessThan(int a, int b) => (a ^ signBit64) < (b ^ signBit64);

/// Unsigned 64-bit greater-than.
bool unsignedGreaterThan(int a, int b) => (a ^ signBit64) > (b ^ signBit64);

/// The top of the `int_relative` domain: 2^31 - 1. Both `previous` and
/// `current` lie in 0 to this value inclusive, which is a property of the
/// operation rather than of the caller's storage type (STANDARD.md,
/// "int_relative").
const int intRelativeMax = 0x7FFFFFFF;

/// The mask of the low [bits] bits, for bits in [0,64].
int mask64(int bits) => bits >= 64 ? allOnes64 : (1 << bits) - 1;

/// The number of bits required to serialize an integer in [min,max], both in
/// the unsigned 32-bit domain: zero for a degenerate range, otherwise the bit
/// length of max - min (STANDARD.md, "int (ranged)").
int bitsRequired(int min, int max) {
  assert(min >= 0 && min <= 0xFFFFFFFF);
  assert(max >= 0 && max <= 0xFFFFFFFF);
  assert(min <= max);
  return min == max ? 0 : (max - min).bitLength;
}

/// The number of bits required to serialize a 64-bit integer in [min,max].
/// The subtraction is performed in the unsigned domain, so ranges wider than
/// 2^63 are exact rather than overflowing. min and max are unsigned 64-bit
/// values held bit-transparently in signed ints.
int bitsRequired64(int min, int max) {
  if (min == max) {
    return 0;
  }
  // subtract in the unsigned domain: wraps two's complement, and a wrapped
  // (negative-looking) difference has its top bit set, which is 64 bits
  final diff = max - min;
  return diff < 0 ? 64 : diff.bitLength;
}

/// Does [value] fit in a raw bit field of [bits] bits, for bits in [1,64]?
///
/// The write side range check for the `bits` operation, run on the caller's
/// value before the bit writer masks it to the field width: a check placed
/// after that masking is handed a value the masking already made legal, so a
/// 40-bit value written in 8 bits arrives as its low 8 bits, in range by
/// construction, and the check that exists to diagnose it cannot see it. The
/// bound holds at every width in [1,64] and not only at 32 or fewer
/// (STANDARD.md, "bits").
///
/// The value is read as unsigned, so a negative input is a very large one and
/// does not fit: a raw bit field is unsigned, and a signed value belongs in
/// serializeInt over a range that includes it.
bool valueFitsInBits(int value, int bits) => bits >= 64 || value >>> bits == 0;
