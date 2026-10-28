// The public surface (reference IMPLEMENTING.md U15, "Exports beyond the
// reference operations", ruling 2026-10-27): the library exports the
// reference operations' streams, the refusal list and its name function,
// copyString, the reference's public helpers, and the language necessities
// documented as such. Nothing else. This reads lib/serialize.dart's `show`
// lists, so a new export has to be argued for here first.

import 'dart:io';

import 'harness.dart';

const Set<String> _allowed = {
  // the streams and the unified surface (the reference operations)
  'BitStream', 'MeasureStream', 'ReadStream', 'WriteStream', 'Serializable',
  // the refusal list and its name function (U14)
  'Refusal', 'refusalName',
  // serialize_copy_string (U15)
  'copyString',
  // the reference's own public helpers
  'BitReader', 'BitWriter', 'bitsRequired', 'bitsRequired64',
  'bitsRequired128', 'valueFitsInBits', 'compressedFloatParams',
  'float32BitsAreFinite', 'float64BitsAreFinite', 'Int128', 'UInt128',
  // language necessities: Dart has no float32 type and no float bit casts,
  // and a scalar cannot be passed by reference
  'fround', 'float32BitsFromDouble', 'float64BitsFromDouble',
  'doubleFromFloat32Bits', 'doubleFromFloat64Bits', 'Ref',
};

void run() {
  test('U15: lib/serialize.dart exports nothing beyond the ruling', () {
    final source = File('lib/serialize.dart').readAsStringSync();
    final shown = <String>{};
    for (final match in RegExp(r'show([^;]*);').allMatches(source)) {
      for (final name in match.group(1)!.split(',')) {
        shown.add(name.trim());
      }
    }
    expect(shown.isNotEmpty, 'found the show lists');
    final extra = shown.difference(_allowed);
    expect(extra.isEmpty, 'exports beyond U15: $extra');
    expect(
      !RegExp(r"export '[^']*';").hasMatch(source),
      'every export names what it shows',
    );
    expect(shown.contains('copyString'), 'copyString is exported');
  });
}
