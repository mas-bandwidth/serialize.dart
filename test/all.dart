// Runs every test suite and exits nonzero on any failure:
//   dart run test/all.dart

import 'dart:io';

import 'bitpacker_test.dart' as bitpacker;
import 'bits_required_test.dart' as bits_required;
import 'conformance_test.dart' as conformance;
import 'golden_wire_test.dart' as golden_wire;
import 'harness.dart';
import 'int128_test.dart' as int128;
import 'measure_test.dart' as measure;
import 'serialize_bits_test.dart' as serialize_bits;
import 'serialize_bytes_string_test.dart' as serialize_bytes_string;
import 'serialize_fixed_test.dart' as serialize_fixed;
import 'serialize_float_test.dart' as serialize_float;
import 'serialize_int_relative_test.dart' as serialize_int_relative;
import 'serialize_int_test.dart' as serialize_int;
import 'terminality_test.dart' as terminality;

void main() {
  bits_required.run();
  bitpacker.run();
  serialize_bits.run();
  serialize_int.run();
  serialize_int_relative.run();
  serialize_float.run();
  serialize_bytes_string.run();
  serialize_fixed.run();
  measure.run();
  golden_wire.run();
  int128.run();
  conformance.run();
  terminality.run();
  exit(summarize() > 0 ? 1 : 0);
}
