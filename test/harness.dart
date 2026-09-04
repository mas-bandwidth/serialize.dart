// A minimal hand-rolled test harness: zero package dependencies keeps the
// build hermetic. Suites register named tests; run() executes them all and
// returns the number of failures, which test/all.dart turns into the exit
// code. Switching to package:test later is a one-evening decision.

import 'dart:typed_data';

int _passed = 0;
int _failed = 0;
String _current = '';

/// Runs [body] as a named test: an unexpected throw is a failure, and every
/// [expect] failure inside it is reported with the test name.
void test(String name, void Function() body) {
  _current = name;
  final failedBefore = _failed;
  try {
    body();
  } catch (error, stack) {
    _failed++;
    print('FAIL $_current: threw $error');
    print(stack);
  }
  if (_failed == failedBefore) {
    _passed++;
  }
}

/// Fails the current test with [message] unless [condition] holds.
void expect(bool condition, String message) {
  if (!condition) {
    _failed++;
    print('FAIL $_current: $message');
  }
}

/// True when this run has assertions on — `dart --enable-asserts`, the
/// checked build the standard's check model speaks of. CI runs the suite both
/// ways, so a test of a checked-build contract asks this first.
bool get assertsEnabled {
  var enabled = false;
  assert(enabled = true);
  return enabled;
}

/// Fails unless [body] throws. For checked-build contract violations: guard
/// the call with [assertsEnabled], because a release build performs no
/// write-side validation and nothing throws.
void expectThrows(void Function() body, String message) {
  try {
    body();
  } catch (_) {
    return;
  }
  _failed++;
  print('FAIL $_current: $message: nothing was thrown');
}

/// Fails unless [actual] equals [expected].
void expectEquals(Object? actual, Object? expected, String message) {
  if (actual != expected) {
    _failed++;
    print('FAIL $_current: $message: got $actual, expected $expected');
  }
}

/// Fails unless [actual] and [expected] hold identical doubles — compared as
/// bit patterns, so NaN matches NaN with the same payload and -0.0 does not
/// match 0.0 (the bit-transparency doctrine: value-space comparison here
/// proves nothing).
void expectSameDouble(double actual, double expected, String message) {
  final scratch = ByteData(16);
  scratch.setFloat64(0, actual);
  scratch.setFloat64(8, expected);
  if (scratch.getUint64(0) != scratch.getUint64(8)) {
    _failed++;
    print('FAIL $_current: $message: got $actual, expected $expected');
  }
}

/// Fails unless the byte lists match exactly.
void expectBytes(List<int> actual, List<int> expected, String message) {
  var equal = actual.length == expected.length;
  if (equal) {
    for (var i = 0; i < actual.length; i++) {
      if (actual[i] != expected[i]) {
        equal = false;
        break;
      }
    }
  }
  if (!equal) {
    _failed++;
    print('FAIL $_current: $message: got $actual, expected $expected');
  }
}

/// Prints the summary for [suite] and returns the failure count so far.
int summarize() {
  print('$_passed passed, $_failed failed');
  return _failed;
}
