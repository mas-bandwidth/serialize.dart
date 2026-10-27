// Write-then-read fuzz of float and double, built for the web target by
// tool/web_float_fuzz.dart (and runnable on the VM: dart run
// fuzz/float_roundtrip.dart).
//
// The oracle is integer arithmetic only, never a float conversion of this
// library or of the platform: each round draws a finite bit pattern, lays its
// little-endian bytes out by shifts, reads them with serializeFloat or
// serializeDouble, writes the value it got back with a fresh WriteStream, and
// requires those bytes to be the bytes it started from. A conversion that
// changes any bit, on either side, breaks the round trip; a read that refuses
// a finite pattern fails it too.
//
// The patterns are weighted towards the ones dart2wasm once corrupted: a
// 32-bit half (or the whole float) shaped like a signaling NaN, exponent all
// ones and quiet bit clear.
//
// SEED and ROUNDS come from the environment declarations, so the compiled
// program needs no arguments: -DSEED=7 -DROUNDS=1000000.

import 'dart:math';
import 'dart:typed_data';

import 'package:serialize/serialize.dart';

const int _seed = int.fromEnvironment('SEED', defaultValue: 1);
const int _rounds = int.fromEnvironment('ROUNDS', defaultValue: 1000000);

/// A uniformly random 32-bit pattern.
int _u32(Random rng) => rng.nextInt(1 << 16) << 16 | rng.nextInt(1 << 16);

/// A 32-bit pattern shaped like a float32 signaling NaN, any sign.
int _snan32(Random rng) {
  var payload = _u32(rng) & 0x003FFFFF;
  if (payload == 0) {
    payload = 1;
  }
  return (rng.nextBool() ? 0x80000000 : 0) | 0x7F800000 | payload;
}

/// A 32-bit half: half the time sNaN-shaped, otherwise uniform.
int _half(Random rng) => rng.nextBool() ? _snan32(rng) : _u32(rng);

Uint8List _bytes(int pattern, int count) => Uint8List.fromList([
  for (var i = 0; i < count; i++) (pattern >>> (8 * i)) & 0xFF,
]);

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

/// Reads [wire] as one float (count 4) or double (count 8), writes the value
/// back, and returns null when the bytes match, else the failure.
String? _roundTrip(Uint8List wire) {
  final isDouble = wire.length == 8;
  final value = Ref<double>(0);
  final reader = ReadStream(wire);
  final ok = isDouble
      ? reader.serializeDouble(value)
      : reader.serializeFloat(value);
  if (!ok) {
    return 'read ${_hex(wire)} refused ${reader.refusal}';
  }
  final writer = WriteStream(Uint8List(8));
  if (isDouble) {
    writer.serializeDouble(value);
  } else {
    writer.serializeFloat(value);
  }
  writer.flush();
  final out = writer.data();
  for (var i = 0; i < wire.length; i++) {
    if (out[i] != wire[i]) {
      return 'read ${_hex(wire)} wrote ${_hex(out)} (${value.value})';
    }
  }
  return null;
}

void main() {
  final rng = Random(_seed);
  var failures = 0;
  var checked = 0;

  void check(Uint8List wire) {
    checked++;
    final failure = _roundTrip(wire);
    if (failure != null && failures++ < 10) {
      print('FAIL ${wire.length == 8 ? 'double' : 'float'}: $failure');
    }
  }

  // the audit's own finds first: doubles with an sNaN-shaped 32-bit half
  check(Uint8List.fromList([0x00, 0x02, 0x10, 0xf2, 0x76, 0x22, 0xb7, 0x7f]));
  check(Uint8List.fromList([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xb0, 0x7f]));
  check(Uint8List.fromList([0x50, 0xe1, 0x91, 0x7f, 0xcf, 0x1a, 0x16, 0x00]));

  for (var round = 0; round < _rounds; round++) {
    // float: finite only (the exponent field all ones is refused by design)
    final f = rng.nextInt(4) == 0 ? (_snan32(rng) & 0xFF7FFFFF) : _u32(rng);
    if ((f & 0x7F800000) != 0x7F800000) {
      check(_bytes(f, 4));
    }
    // double: two 32-bit halves, either one may be sNaN-shaped
    final d = _half(rng) << 32 | _half(rng);
    if ((d & 0x7FF0000000000000) != 0x7FF0000000000000) {
      check(_bytes(d, 8));
    }
  }

  print(
    'float/double write-then-read: $checked patterns, seed $_seed, '
    '$failures failed',
  );
  if (failures > 0) {
    throw StateError('float/double round trip failed');
  }
}
