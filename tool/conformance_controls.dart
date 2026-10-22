// The negative controls: proof that the conformance corpus notices when this
// reader is wrong.
//
//   dart run tool/conformance_controls.dart
//
// STANDARD.md, "The conformance corpus": a gate nobody has seen go red is a
// claim, not a measurement. Two kinds of control prove the instrument
// responds, and this tool runs both:
//
//  - unknown-operation: the runner is pointed at a corpus file whose
//    operation has no runner, and must go RED rather than skip it;
//
//  - one control per refusal rule: a scratch copy of the library with that
//    ONE rule deleted, run against the real corpus, which must fail EXACTLY
//    the vectors conformance-controls/<rule>.expected names. A sabotage that
//    breaks more than its rule, or less, measures something other than what
//    it claims, and fails here.
//
// The sabotage is a string replacement on the scratch copy, the way the C++
// reference's CMakeLists.txt builds its controls, so the library itself
// carries no hook for disabling a rule. Every needle must match exactly
// once: a needle that stops matching means the line it deletes has moved, and
// the control stops proving anything, so that is a failure rather than a
// silent no-op. Update the needle; never delete the control. Each patch keeps
// the line compiling and reading the variables the rule read: the added
// conjunct is false exactly when the rule would have fired.
//
// Where Dart implements one rule at two sites, the control deletes it at both,
// because deleting a rule means deleting all of it:
//
//  - the int_relative bounded tiers carry their payload's ranged int inline,
//    so ranged-range and ranged-reconstruction delete the rule there too;
//  - a fixed point field's degenerate read exists for 64-bit and 128-bit
//    storage, as the reference's two specializations do;
//  - the string reader's strict UTF-8 decoder is a second guard behind the
//    validator, which would turn a deleted refusal into a throw. The UTF-8
//    controls relax it with the validator, so what they measure is the
//    refusal, and the throw (a trap on hostile input, which STANDARD.md calls
//    non-conforming) never stands in for it.
//
// The scratch copies live under .dart_tool/conformance-controls/ and touch
// nothing outside the repository.

import 'dart:io';

/// One string replacement in one library file.
final class _Patch {
  const _Patch(this.file, this.needle, this.replacement);

  final String file;
  final String needle;
  final String replacement;
}

/// One rule, deleted.
final class _Control {
  const _Control(this.name, this.rule, this.patches);

  final String name;
  final String rule;
  final List<_Patch> patches;
}

const String _streams = 'lib/src/streams.dart';
const String _bitpacker = 'lib/src/bitpacker.dart';

const String _deleted = ' // NEGATIVE CONTROL: this rule is deleted on purpose';

const List<_Control> _controls = [
  _Control(
    'align-padding',
    'readers must verify that the alignment padding bits are zero',
    [
      _Patch(
        _bitpacker,
        '      if (value != 0) {',
        '      if (value == 0xFFFFFFFF) {$_deleted',
      ),
    ],
  ),
  _Control(
    'ranged-reconstruction',
    'a ranged int decodes to its offset plus min',
    [
      _Patch(
        _streams,
        '    value.value = ((unsignedValue + min) & 0xFFFFFFFF).toSigned(32);',
        '    value.value = unsignedValue.toSigned(32);$_deleted',
      ),
      _Patch(
        _streams,
        '        final reconstructed = previous + tierMin + offset;',
        '        final reconstructed = previous + offset;$_deleted',
      ),
    ],
  ),
  _Control(
    'ranged-range',
    'a ranged int whose offset is past the span is refused',
    [
      _Patch(
        _streams,
        '    if (unsignedValue > max - min) {',
        '    if (unsignedValue > max - min + 0xFFFFFFFF) {$_deleted',
      ),
      _Patch(
        _streams,
        '        if (offset > tierMax - tierMin) {',
        '        if (offset > tierMax - tierMin + 0xFFFFFFFF) {$_deleted',
      ),
    ],
  ),
  _Control(
    'fixed-degenerate-terminal',
    'every read consults the failure state, zero bit reads included',
    [
      _Patch(
        _streams,
        '      if (failed) {\n'
            '        return false;\n'
            '      }\n'
            '      value.value = _storageValue(',
        '      if (failed && min > max) {$_deleted\n'
            '        return false;\n'
            '      }\n'
            '      value.value = _storageValue(',
      ),
      _Patch(
        _streams,
        '      if (failed) {\n'
            '        return false;\n'
            '      }\n'
            '      value.value = params.rawMin.toSigned();',
        '      if (failed && min > max) {$_deleted\n'
            '        return false;\n'
            '      }\n'
            '      value.value = params.rawMin.toSigned();',
      ),
    ],
  ),
  _Control('float-finite', 'a float read refuses NaN and the infinities', [
    _Patch(
      _streams,
      '    if (!float32BitsAreFinite(bits)) {',
      '    if (!float32BitsAreFinite(bits) && bits == 0) {$_deleted',
    ),
  ]),
  _Control('double-finite', 'a double read refuses NaN and the infinities', [
    _Patch(
      _streams,
      '    if (!float64BitsAreFinite(bits)) {',
      '    if (!float64BitsAreFinite(bits) && bits == 0) {$_deleted',
    ),
  ]),
  _Control(
    'compressed-float-finite',
    'a compressed float decode that is not finite is refused',
    [
      _Patch(
        _streams,
        '    if (!decoded.isFinite) {',
        '    if (!decoded.isFinite && decoded == 0) {$_deleted',
      ),
    ],
  ),
  _Control(
    'end-trailing-data',
    'an end refuses a whole byte after the object',
    [
      _Patch(
        _streams,
        '    if (remaining >= 8) {',
        '    if (remaining >= 8 && remaining < 0) {$_deleted',
      ),
    ],
  ),
  _Control('end-padding', 'an end refuses non-zero padding in the final byte', [
    _Patch(
      _streams,
      '      if (padding != 0) {',
      '      if (padding == 0xFFFFFFFF) {$_deleted',
    ),
  ]),
  _Control(
    'int-relative-canonical',
    'the absolute tier refuses a difference a bounded tier carries',
    [
      _Patch(
        _streams,
        '    if (reconstructed - previous <= _relativeTierMax.last) {',
        '    if (reconstructed - previous <= _relativeTierMax.last &&\n'
            '        reconstructed < 0) {$_deleted',
      ),
    ],
  ),
  _Control(
    'string-embedded-nul',
    'a string read refuses a zero byte among its payload',
    [
      _Patch(
        _streams,
        '      if (bytes[i] == 0) {',
        '      if (bytes[i] == 0 && i < 0) {$_deleted',
      ),
    ],
  ),
  _Control(
    'string-utf8',
    'a string read refuses a payload that is not well formed UTF-8',
    [
      _Patch(
        _streams,
        '    if (!_isValidUtf8(bytes, bytes.length)) {',
        '    if (!_isValidUtf8(bytes, bytes.length) && bytes.length < 0) {'
            '$_deleted',
      ),
      _Patch(
        _streams,
        'utf8.decode(bytes, allowMalformed: false)',
        'utf8.decode(bytes, allowMalformed: true)',
      ),
    ],
  ),
  _Control(
    'string-utf8-surrogate',
    'a string read refuses an encoded surrogate code point',
    [
      _Patch(
        _streams,
        '      if (lead == 0xED && byte1 >= 0xA0) {',
        '      if (lead == 0xED && byte1 >= 0xA0 && byte1 > 0xFF) {$_deleted',
      ),
      _Patch(
        _streams,
        'utf8.decode(bytes, allowMalformed: false)',
        'utf8.decode(bytes, allowMalformed: true)',
      ),
    ],
  ),
  _Control(
    'int64-through-double',
    'a 64 bit value is carried exactly, never through a double',
    [
      _Patch(
        _streams,
        '    value.value = unsignedValue + min;',
        '    final throughDouble = (unsignedValue + min).toDouble();$_deleted\n'
            '    value.value = throughDouble >= 9223372036854775807.0\n'
            '        ? 0x7FFFFFFFFFFFFFFF\n'
            '        : throughDouble.toInt();',
      ),
    ],
  ),
  _Control('wrong-reason', 'a refusal names the rule that refused it', [
    _Patch(
      _streams,
      '        return _refuse(Refusal.embeddedNul);',
      '        return _refuse(Refusal.invalidUtf8);$_deleted',
    ),
  ]),
];

int _occurrences(String text, String needle) {
  var count = 0;
  for (
    var at = text.indexOf(needle);
    at >= 0;
    at = text.indexOf(needle, at + 1)
  ) {
    count++;
  }
  return count;
}

/// Copies [from] into [to], recursively.
void _copyTree(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final entity in from.listSync()) {
    final name = entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    if (entity is Directory) {
      _copyTree(entity, Directory('${to.path}/$name'));
    } else if (entity is File) {
      entity.copySync('${to.path}/$name');
    }
  }
}

/// Builds the sabotaged scratch package for [control]. Returns the reason it
/// could not, or null.
String? _build(_Control control, Directory root, Directory scratch) {
  if (scratch.existsSync()) {
    scratch.deleteSync(recursive: true);
  }
  _copyTree(Directory('${root.path}/lib'), Directory('${scratch.path}/lib'));
  Directory('${scratch.path}/test').createSync(recursive: true);
  for (final file in [
    'test/conformance_test.dart',
    'test/conformance_runner.dart',
    'test/harness.dart',
  ]) {
    File('${root.path}/$file').copySync('${scratch.path}/$file');
  }
  File('${root.path}/pubspec.yaml').copySync('${scratch.path}/pubspec.yaml');
  Directory('${scratch.path}/.dart_tool').createSync();
  File('${scratch.path}/.dart_tool/package_config.json').writeAsStringSync(
    '{"configVersion":2,"packages":[{"name":"serialize","rootUri":"../",'
    '"packageUri":"lib/","languageVersion":"3.9"}]}\n',
  );

  for (final patch in control.patches) {
    final file = File('${scratch.path}/${patch.file}');
    final text = file.readAsStringSync();
    final count = _occurrences(text, patch.needle);
    if (count != 1) {
      return 'its needle matches $count times in ${patch.file}, not once, so '
          "it no longer proves that deleting '${control.rule}' turns the "
          'corpus red. Update the needle; do not delete the control:\n'
          '${patch.needle}';
    }
    file.writeAsStringSync(text.replaceFirst(patch.needle, patch.replacement));
  }
  return null;
}

Future<bool> _runControl(_Control control, Directory root) async {
  final expected = File(
    '${root.path}/conformance-controls/${control.name}.expected',
  );
  if (!expected.existsSync()) {
    print('FAIL ${control.name}: no ${expected.path} naming its vectors');
    return false;
  }
  final scratch = Directory(
    '${root.path}/.dart_tool/conformance-controls/${control.name}',
  );
  final problem = _build(control, root, scratch);
  if (problem != null) {
    print('FAIL ${control.name}: $problem');
    return false;
  }
  final result = await Process.run(Platform.resolvedExecutable, [
    'run',
    'test/conformance_test.dart',
    '--expect-failures',
    expected.absolute.path,
    Directory('${root.path}/conformance').absolute.path,
  ], workingDirectory: scratch.path);
  final verdict = (result.stdout as String)
      .split('\n')
      .where((line) => line.startsWith('CONTROL:'))
      .join('\n  ');
  if (result.exitCode != 0) {
    print('FAIL ${control.name} (${control.rule}):\n  $verdict');
    if (verdict.isEmpty) {
      print(result.stdout);
      print(result.stderr);
    }
    return false;
  }
  print('ok   ${control.name}: $verdict');
  return true;
}

/// The unknown-operation control: the real runner, pointed at a file whose
/// operation has no runner, must go red.
Future<bool> _runUnknownOperation(Directory root) async {
  final result = await Process.run(Platform.resolvedExecutable, [
    'run',
    'test/conformance_test.dart',
    'conformance-controls/unknown-operation.txt',
  ], workingDirectory: root.path);
  if (result.exitCode == 0) {
    print(
      'FAIL unknown-operation: the runner passed a vector whose operation it '
      'cannot drive; it must fail rather than skip',
    );
    return false;
  }
  // red for the right reason: a compile error or a missing file is red too,
  // and proves nothing about skipping
  if (!(result.stdout as String).contains(
    'control-a-runner-must-fail-on-an-operation-it-cannot-drive: no runner '
    "for parameter 'whatever' on operation 'no_such_operation'",
  )) {
    print(
      'FAIL unknown-operation: the runner went red, but not by refusing the '
      'operation it has no runner for:\n${result.stdout}${result.stderr}',
    );
    return false;
  }
  print('ok   unknown-operation: the runner went red');
  return true;
}

Future<void> main() async {
  final root = Directory(
    File.fromUri(Platform.script).parent.parent.absolute.path,
  );
  final results = await Future.wait([
    _runUnknownOperation(root),
    for (final control in _controls) _runControl(control, root),
  ]);

  // every vendored .expected list must have its control here: a rule the
  // reference can delete and this port cannot is a gap, not a pass
  final known = {for (final control in _controls) control.name};
  var unclaimed = 0;
  for (final entity in Directory(
    '${root.path}/conformance-controls',
  ).listSync()) {
    final name = entity.uri.pathSegments.last;
    if (name.endsWith('.expected') &&
        !known.contains(name.substring(0, name.length - 9))) {
      print('FAIL $name: no control in this tool deletes its rule');
      unclaimed++;
    }
  }

  final failed = results.where((ok) => !ok).length + unclaimed;
  print(
    '${results.length} controls, ${failed == 0 ? 'all' : '$failed not'} '
    'exact',
  );
  exit(failed == 0 ? 0 : 1);
}
