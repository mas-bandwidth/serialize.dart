// The conformance directory override: the vendored copies by default, the
// environment's directories when it names them. Resolution only; no file is
// read.

import 'conformance_dirs.dart';
import 'harness.dart';

void run() {
  test('conformance dirs: the vendored copies when nothing is set', () {
    expectEquals(conformanceDir('/r', const {}), '/r/conformance', 'corpus');
    expectEquals(
      conformanceControlsDir('/r', const {}),
      '/r/conformance-controls',
      'controls',
    );
  });

  test('conformance dirs: an empty variable is unset', () {
    const environment = {
      'SERIALIZE_CONFORMANCE_DIR': '',
      'SERIALIZE_CONFORMANCE_CONTROLS_DIR': '',
    };
    expectEquals(conformanceDir('/r', environment), '/r/conformance', 'corpus');
    expectEquals(
      conformanceControlsDir('/r', environment),
      '/r/conformance-controls',
      'controls',
    );
  });

  test('conformance dirs: an absolute override is kept as it is', () {
    const environment = {
      'SERIALIZE_CONFORMANCE_DIR': '/up/conformance',
      'SERIALIZE_CONFORMANCE_CONTROLS_DIR': '/up/conformance-controls',
    };
    expectEquals(
      conformanceDir('/r', environment),
      '/up/conformance',
      'corpus',
    );
    expectEquals(
      conformanceControlsDir('/r', environment),
      '/up/conformance-controls',
      'controls',
    );
  });

  test('conformance dirs: a relative override is taken from the root', () {
    const environment = {
      'SERIALIZE_CONFORMANCE_DIR': 'upstream/conformance',
      'SERIALIZE_CONFORMANCE_CONTROLS_DIR': 'upstream/conformance-controls',
    };
    expectEquals(
      conformanceDir('/r', environment),
      '/r/upstream/conformance',
      'corpus',
    );
    expectEquals(
      conformanceControlsDir('/r', environment),
      '/r/upstream/conformance-controls',
      'controls',
    );
  });

  test('conformance dirs: each variable moves only its own directory', () {
    const environment = {'SERIALIZE_CONFORMANCE_DIR': '/up/conformance'};
    expectEquals(
      conformanceDir('/r', environment),
      '/up/conformance',
      'corpus',
    );
    expectEquals(
      conformanceControlsDir('/r', environment),
      '/r/conformance-controls',
      'controls',
    );
  });
}
