// Runs every test suite and exits nonzero on any failure:
//   dart run test/all.dart

import 'dart:io';

import 'golden_wire_test.dart' as golden_wire;
import 'harness.dart';

void main() {
  golden_wire.run();
  exit(summarize() > 0 ? 1 : 0);
}
