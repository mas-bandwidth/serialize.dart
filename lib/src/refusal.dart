// The refusal reasons: the closed list of STANDARD.md, "Refusal reasons".
//
// A refusal names the rule that refused it. Every implementation in the
// family spells these names identically wherever it exposes them, and every
// refused vector in the corpus states the one it expects. A ReadStream
// latches the FIRST refusal's reason: the later refusals of a failed stream
// are its echoes and keep it.

/// Why a [ReadStream] refused, from the closed list STANDARD.md defines.
/// [name] is the family wide spelling, exactly as the standard and the
/// conformance corpus write it.
enum Refusal {
  /// A read needs more bits than the stream holds.
  pastEnd('past_end'),

  /// A decoded value outside its declared range or domain: a ranged offset
  /// past its span, a string length past its buffer, a compressed integer
  /// past its step count, an int_relative outside its domain or not
  /// increasing.
  valueOutOfRange('value_out_of_range'),

  /// A set bit in an align's padding, or in the unused bits of the final
  /// byte at the end.
  nonzeroPadding('nonzero_padding'),

  /// A whole byte or more after the end of the object.
  trailingData('trailing_data'),

  /// A float or double that is NaN or an infinity, or a compressed float
  /// decode that is not finite.
  nonFiniteFloat('non_finite_float'),

  /// A string payload that is not well formed UTF-8.
  invalidUtf8('invalid_utf8'),

  /// A zero byte among a string's transmitted bytes.
  embeddedNul('embedded_nul'),

  /// An encoding a conforming writer never produces for the value it
  /// carries: the int_relative absolute tier carrying a bounded difference.
  nonCanonical('non_canonical'),

  /// The bytes were well formed, and the reader's caller refused the value
  /// they carry: [ReadStream.reject] at the top level, or a nested object
  /// whose [Serializable.serialize] returned false with nothing refused
  /// inside it. No wire rule refused, so no wire reason is reported.
  rejected('rejected');

  const Refusal(this.name);

  /// The family wide spelling, for example `past_end`.
  final String name;

  /// The reason spelled [name], or null when no reason is spelled that way.
  static Refusal? byName(String name) {
    for (final reason in values) {
      if (reason.name == name) {
        return reason;
      }
    }
    return null;
  }

  @override
  String toString() => name;
}
