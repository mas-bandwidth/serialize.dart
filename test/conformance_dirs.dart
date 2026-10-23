// Where the conformance corpus and its controls are read from. By default the
// vendored copies in this repository; the nightly functional test points both
// at a fresh checkout of mas-bandwidth/serialize instead, so this port is held
// to the CURRENT C/C++ data and not only to the copy it vendored:
//
//     SERIALIZE_CONFORMANCE_DIR=<dir>           the corpus, default conformance
//     SERIALIZE_CONFORMANCE_CONTROLS_DIR=<dir>  its controls, default
//                                               conformance-controls
//
// Pure resolution logic, so the unit test hands it a map and touches no file.

import 'dart:io';

/// The corpus directory: `SERIALIZE_CONFORMANCE_DIR` from [environment] when
/// set, the vendored `conformance` otherwise, relative to [root].
String conformanceDir(String root, Map<String, String> environment) =>
    _resolve(root, environment['SERIALIZE_CONFORMANCE_DIR'], 'conformance');

/// The controls directory: `SERIALIZE_CONFORMANCE_CONTROLS_DIR` from
/// [environment] when set, the vendored `conformance-controls` otherwise,
/// relative to [root].
String conformanceControlsDir(String root, Map<String, String> environment) =>
    _resolve(
      root,
      environment['SERIALIZE_CONFORMANCE_CONTROLS_DIR'],
      'conformance-controls',
    );

/// [override] when it names something, [vendored] otherwise; a relative
/// result is taken from [root], an absolute one is kept as it is. An empty
/// override is unset, so a workflow that blanks the variable gets the
/// vendored copy rather than the root itself.
String _resolve(String root, String? override, String vendored) {
  final path = override == null || override.isEmpty ? vendored : override;
  return File(path).isAbsolute ? path : '$root/$path';
}
