// serialize.dart benchmark.
//
// A deliberate operation-for-operation mirror of serialize.c's bench.c --
// itself a mirror of the C++ library's bench.cpp -- so the outputs of all the
// family's benchmarks can be read side by side. Same operations in the same
// order, same iteration counts, same buffer sizes, same LCG-driven input
// data, same best-of-five-trials discipline, same reporting format and units.
//
//   dart run bench/bench.dart           the rows, human readable
//   dart run bench/bench.dart --csv     the same numbers as CSV: row,op,units,value
//
// Both of the runtime's modes matter: JIT (dart run) is the iteration number,
// AOT (dart compile exe, then run the binary) is the number that ships --
// Flutter release builds are AOT. Asserts are off in both unless
// --enable-asserts is passed, so a plain run measures the release shape.
//
// Iteration counts are overridable so the harness can be run at a different
// scale and the timings checked for linearity -- a benchmark whose loop has
// been optimized away does not scale with its iteration count:
//
//   BENCH_BITPACKER_PASSES=256 BENCH_STREAM_PACKETS=100000 dart run bench/bench.dart
//
// GOLDEN GATED: before any row is timed, the exact buffers its loops write
// are verified byte for byte against pins produced by serialize.c's own bench
// data paths (the same pins the JavaScript bench carries). The LCG is the C
// bench's uint64 LCG, direct in Dart's 64-bit int: variant 0 diverges on any
// error in a single step, and variant 63 diverges on any error anywhere in 64
// chained steps, in any field, in any serialize operation. The read leg then
// decodes every variant buffer and verifies every field. A bench that fails
// its goldens reports nothing.
//
// WHAT IS DELIBERATELY NOT MIRRORED
//
// bench.cpp's compile time rows (its template parameter surface) have no
// counterpart in Dart, the same omission serialize.c makes. And where bench.c
// writes separate write/read/measure functions per shape -- C has no other
// way -- this bench writes ONE serialize function per shape and runs it
// against all three streams: the family's defining pattern, and exactly what
// generated Dart looks like.
//
// Only numbers from a quiet machine are meaningful, and only as ratios
// between family legs measured back to back on the same machine.

import 'dart:io';
import 'dart:typed_data';

import 'package:serialize/serialize.dart';

/* --------------------------------------------------------------------------
   harness
   -------------------------------------------------------------------------- */

const int numTrials = 5;
const int numVariants = 64;

int envInt(String name, int fallback) {
  final raw = Platform.environment[name];
  if (raw == null) {
    return fallback;
  }
  final value = int.tryParse(raw);
  if (value == null || value < 1) {
    stderr.write('$name must be a positive integer\n');
    exit(1);
  }
  return value;
}

const int bitpackerBufferSize = 64 * 1024;
final int bitpackerNumPasses = envInt('BENCH_BITPACKER_PASSES', 4096);
final int streamNumPackets = envInt('BENCH_STREAM_PACKETS', 1000000);

bool csv = false;

final Stopwatch _clock = Stopwatch()..start();

double now() => _clock.elapsedMicroseconds * 1e-6;

// the g_sink of the C bench: computed values flow here, and the bench
// publishes it at exit under an env var the compiler cannot rule out, so no
// loop's work can be proven unobservable
int sink = 0;

final class _Result {
  final String row;
  final String op;
  final String units;
  final double value;
  _Result(this.row, this.op, this.units, this.value);
}

final List<_Result> results = [];

void report(String row, String op, String units, double value) {
  results.add(_Result(row, op, units, value));
}

void printRow(String line) {
  if (!csv) {
    stdout.write(line);
  }
}

String toHexBytes(Uint8List data, int bytes) {
  final buffer = StringBuffer();
  for (var i = 0; i < bytes; i++) {
    buffer.write(data[i].toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

Never gateFail(String row, String what, String expected, String got) {
  stderr.write(
    'GOLDEN GATE FAILED: $row $what\n  expected $expected\n  got      $got\n',
  );
  stderr.write('reporting nothing.\n');
  exit(1);
}

/* --------------------------------------------------------------------------
   the C bench's uint64 LCG, direct: Dart's int is 64 bits and wraps two's
   complement, which IS arithmetic mod 2^64
   -------------------------------------------------------------------------- */

const int lcgMul = 0x5851F42D4C957F2D;
const int lcgAdd = 0x14057B7EF767814F;

int rng = 1;

void lcgSeed() {
  rng = 1;
}

void lcgStep() {
  rng = rng * lcgMul + lcgAdd;
}

// the low 32 bits of (rng >> s), for s in [0,63]
int shr(int s) => (rng >>> s) & 0xFFFFFFFF;

/* --------------------------------------------------------------------------
   pins

   Produced by serialize.c's own bench data paths (its static vary and write
   functions, run to the letter): the bitpacker's pass buffer, and for each
   packet shape the first and last of the 64 variant buffers the read leg
   decodes. Byte identical across the family, so these gate this bench's wire
   against the C reference, not against itself.
   -------------------------------------------------------------------------- */

const int pinBitpackerBytesPerPass = 65518;
const String pinBitpackerFirst64 =
    'e5e6dd7856e4a656da4c1f909b173ac12a3e2f56da3c5011ce0b72f32e37efc6'
    'b32237b5d266fa80dcbcd00956f179b1d2e6818a705e909b77b979379e15b9a9';
const String pinBitpackerLast8 = 'cd0315e1bc20376f';

final class _Pin {
  final int bytesPerPacket;
  final String variant0;
  final String variant63;
  const _Pin(this.bytesPerPacket, this.variant0, this.variant63);
}

const _Pin pinStream = _Pin(
  49,
  '44fd43634d97ff0006d03f0000f0850000a08001809085f800fa8758dfaed800ac1f3e5d7c9bbad9f81736557493b2d1f0',
  '7e6bc3e30c348874a5bb360182748e0000a080018090858274d786d778b6ae016b1f3e5d7c9bbad9f81736557493b2d1f0',
);

const _Pin pinInt = _Pin(
  14,
  '44fd43634df7f390f5be45153d1b',
  '7e6bc3e30c14d7508df23ce1b915',
);

const _Pin pinBits = _Pin(
  20,
  'fc073080fe51ff10eb5bdfec8acd07d03fc4fa06',
  '41a42bddb5f1daf01acf7866eb1aa4bb36bcc603',
);

const _Pin pinGen = _Pin(
  21,
  '00fdfd43ac6f7cf0430cb1c6fa1ec007d03fc4fa66',
  'ba6b6bc36b3c416ac30bafbdc69116a4bb36bcc6d3',
);

/* --------------------------------------------------------------------------
   bitpacker

   The raw bit packer with mixed widths: 227 bits per group of 16 writes,
   repeated until fewer than 256 bits remain in a 64KB buffer.
   -------------------------------------------------------------------------- */

const int numWidths = 16;
const List<int> bitpackerWidths = [
  1, 32, 7, 13, 3, 25, 8, 19, 4, 28, 11, 16, 2, 30, 6, 22, //
];
final Uint32List bitpackerValues = Uint32List(numWidths);

void initBitpackerValues() {
  for (var i = 0; i < numWidths; i++) {
    final width = bitpackerWidths[i];
    final mask = (1 << width) - 1;
    bitpackerValues[i] = (0x9e3779b9 * (i + 1)) & mask;
  }
}

final class _GatedBitpacker {
  final Uint8List buffer;
  final int bytesPerPass;
  _GatedBitpacker(this.buffer, this.bytesPerPass);
}

// One pass, held byte for byte against the C reference, then read back in
// full. Returns the written pass buffer and its size for the timing loops.
_GatedBitpacker gateBitpacker() {
  final buffer = Uint8List(bitpackerBufferSize);
  final writer = BitWriter(buffer);
  final reader = BitReader(buffer);

  while (writer.bitsAvailable >= 256) {
    for (var i = 0; i < numWidths; i++) {
      writer.writeBits(bitpackerValues[i], bitpackerWidths[i]);
    }
  }
  writer.flushBits();
  final bytesPerPass = writer.bytesWritten;
  if (bytesPerPass != pinBitpackerBytesPerPass) {
    gateFail(
      'bitpacker',
      'bytes per pass',
      '$pinBitpackerBytesPerPass',
      '$bytesPerPass',
    );
  }
  final first64 = toHexBytes(buffer, 64);
  if (first64 != pinBitpackerFirst64) {
    gateFail('bitpacker', 'first 64 bytes', pinBitpackerFirst64, first64);
  }
  final last8 = toHexBytes(
    Uint8List.sublistView(buffer, bytesPerPass - 8),
    8,
  );
  if (last8 != pinBitpackerLast8) {
    gateFail('bitpacker', 'last 8 bytes', pinBitpackerLast8, last8);
  }
  reader.reset(buffer);
  while (reader.bitsRemaining >= 256) {
    for (var i = 0; i < numWidths; i++) {
      final value = reader.readBits(bitpackerWidths[i]);
      if (value != bitpackerValues[i]) {
        gateFail('bitpacker', 'read back', '${bitpackerValues[i]}', '$value');
      }
    }
  }

  return _GatedBitpacker(buffer, bytesPerPass);
}

void benchBitpacker(_GatedBitpacker gated) {
  final buffer = gated.buffer;
  final writer = BitWriter(buffer);
  final reader = BitReader(buffer);

  var bestWrite = double.infinity;
  var bestRead = double.infinity;

  for (var trial = 0; trial < numTrials; trial++) {
    var start = now();
    for (var pass = 0; pass < bitpackerNumPasses; pass++) {
      writer.reset(buffer);
      while (writer.bitsAvailable >= 256) {
        for (var i = 0; i < numWidths; i++) {
          writer.writeBits(bitpackerValues[i], bitpackerWidths[i]);
        }
      }
      writer.flushBits();
      sink = (sink + writer.bytesWritten) & 0xFFFFFFFF;
    }
    var elapsed = now() - start;
    if (elapsed < bestWrite) {
      bestWrite = elapsed;
    }

    start = now();
    for (var pass = 0; pass < bitpackerNumPasses; pass++) {
      reader.reset(buffer);
      var sum = 0;
      while (reader.bitsRemaining >= 256) {
        for (var i = 0; i < numWidths; i++) {
          sum += reader.readBits(bitpackerWidths[i]);
        }
      }
      sink = (sink + sum) & 0xFFFFFFFF;
    }
    elapsed = now() - start;
    if (elapsed < bestRead) {
      bestRead = elapsed;
    }
  }

  final totalMB = (gated.bytesPerPass * bitpackerNumPasses) / (1024 * 1024);
  report('bitpacker', 'write', 'MB/s', totalMB / bestWrite);
  report('bitpacker', 'read', 'MB/s', totalMB / bestRead);
  printRow(
    'bitpacker write:  ${(totalMB / bestWrite).toStringAsFixed(1).padLeft(8)} MB/s\n',
  );
  printRow(
    'bitpacker read:   ${(totalMB / bestRead).toStringAsFixed(1).padLeft(8)} MB/s\n',
  );
}

/* --------------------------------------------------------------------------
   packet shapes

   Each shape is one serialize function run against all three streams, a
   vary function that drives most fields from the serially dependent LCG the
   optimizer cannot fold, and a field-equality check for the read gate.
   Packets are Ref-holder objects created once and mutated in place: the
   loops allocate nothing of their own, so what the timings show is the
   library. The stream's uint64 field is a plain 64-bit int here -- Dart has
   real 64-bit integers, so there is no wide edge to pay, unlike JavaScript.
   -------------------------------------------------------------------------- */

// shape: the representative stream packet (ints, bits, bool, floats, uint64, bytes)

final class BenchPacket {
  final a = Ref<int>(0);
  final b = Ref<int>(0);
  final c = Ref<int>(0);
  final bits7 = Ref<int>(0);
  final bits13 = Ref<int>(0);
  final bits23 = Ref<int>(0);
  final flag = Ref<bool>(false);
  final x = Ref<double>(0);
  final y = Ref<double>(0);
  final z = Ref<double>(0);
  final big = Ref<int>(0);
  final blob = Uint8List(17);
}

void initBenchPacket(BenchPacket p) {
  p.a.value = -37;
  p.b.value = 12345;
  p.c.value = 987654;
  p.bits7.value = 97;
  p.bits13.value = 5000;
  p.bits23.value = 1234567;
  p.flag.value = true;
  p.x.value = 1.5;
  p.y.value = -3.25;
  p.z.value = 100.125;
  p.big.value = 0x123456789abcdef0;
  for (var i = 0; i < 17; i++) {
    p.blob[i] = (i * 31) & 0xff;
  }
}

void varyBenchPacket(BenchPacket p) {
  lcgStep();
  p.a.value = (shr(8) & 63) - 32;
  p.b.value = shr(16) & 65535;
  p.c.value = (shr(24) & 0xfffff) - 500000;
  p.bits7.value = rng & 127;
  p.bits13.value = shr(3) & 8191;
  p.bits23.value = shr(5) & 8388607;
  p.flag.value = (rng & 1) != 0;
  p.x.value = (rng & 0xffff).toDouble(); // exact in float32
  p.big.value = rng; // the full 64 bits, direct
  p.blob[0] = shr(32) & 0xff;
}

bool serializeBenchPacket(BitStream stream, BenchPacket p) {
  return stream.serializeInt(p.a, -100, 100) &&
      stream.serializeInt(p.b, 0, 65535) &&
      stream.serializeInt(p.c, -1000000, 1000000) &&
      stream.serializeBits(p.bits7, 7) &&
      stream.serializeBits(p.bits13, 13) &&
      stream.serializeBits(p.bits23, 23) &&
      stream.serializeBool(p.flag) &&
      stream.serializeFloat(p.x) &&
      stream.serializeFloat(p.y) &&
      stream.serializeFloat(p.z) &&
      stream.serializeUint64(p.big) &&
      stream.serializeBytes(p.blob);
}

bool checkBenchPacket(BenchPacket expected, BenchPacket decoded) {
  if (expected.a.value != decoded.a.value ||
      expected.b.value != decoded.b.value ||
      expected.c.value != decoded.c.value ||
      expected.bits7.value != decoded.bits7.value ||
      expected.bits13.value != decoded.bits13.value ||
      expected.bits23.value != decoded.bits23.value ||
      expected.flag.value != decoded.flag.value ||
      expected.x.value != decoded.x.value ||
      expected.y.value != decoded.y.value ||
      expected.z.value != decoded.z.value ||
      expected.big.value != decoded.big.value) {
    return false;
  }
  for (var i = 0; i < 17; i++) {
    if (expected.blob[i] != decoded.blob[i]) {
      return false;
    }
  }
  return true;
}

// shape 1: a realistic packet of ten bounded ints

final class IntFields {
  final f0 = Ref<int>(0);
  final f1 = Ref<int>(0);
  final f2 = Ref<int>(0);
  final f3 = Ref<int>(0);
  final f4 = Ref<int>(0);
  final f5 = Ref<int>(0);
  final f6 = Ref<int>(0);
  final f7 = Ref<int>(0);
  final f8 = Ref<int>(0);
  final f9 = Ref<int>(0);
}

void varyIntFields(IntFields f) {
  lcgStep();
  f.f0.value = (shr(8) & 63) - 32;
  f.f1.value = shr(16) & 65535;
  f.f2.value = (shr(24) & 0xfffff) - 500000;
  f.f3.value = shr(2) & 3;
  f.f4.value = (shr(11) & 15) - 8;
  f.f5.value = shr(22) & 511;
  f.f6.value = (shr(33) & 2047) - 1024;
  f.f7.value = shr(40) & 255;
  f.f8.value = (shr(30) & 0xfffff) - 500000;
  f.f9.value = shr(57) & 63;
}

bool serializeIntFields(BitStream stream, IntFields f) {
  return stream.serializeInt(f.f0, -100, 100) &&
      stream.serializeInt(f.f1, 0, 65535) &&
      stream.serializeInt(f.f2, -1000000, 1000000) &&
      stream.serializeInt(f.f3, 0, 3) &&
      stream.serializeInt(f.f4, -15, 15) &&
      stream.serializeInt(f.f5, 0, 1000) &&
      stream.serializeInt(f.f6, -2048, 2047) &&
      stream.serializeInt(f.f7, 0, 255) &&
      stream.serializeInt(f.f8, -600000, 600000) &&
      stream.serializeInt(f.f9, 0, 100);
}

bool checkIntFields(IntFields expected, IntFields decoded) {
  return expected.f0.value == decoded.f0.value &&
      expected.f1.value == decoded.f1.value &&
      expected.f2.value == decoded.f2.value &&
      expected.f3.value == decoded.f3.value &&
      expected.f4.value == decoded.f4.value &&
      expected.f5.value == decoded.f5.value &&
      expected.f6.value == decoded.f6.value &&
      expected.f7.value == decoded.f7.value &&
      expected.f8.value == decoded.f8.value &&
      expected.f9.value == decoded.f9.value;
}

// shape 2: mixed bit widths including one wider than 32 bits. The 48-bit
// field travels as its low dword then the 16-bit remainder in two lanes --
// STANDARD.md's splitting rule, mirrored from the family benches.

final class BitsFields {
  final b7 = Ref<int>(0);
  final b13 = Ref<int>(0);
  final b23 = Ref<int>(0);
  final b3 = Ref<int>(0);
  final b32 = Ref<int>(0);
  final b11 = Ref<int>(0);
  final b19 = Ref<int>(0);
  final b48lo = Ref<int>(0);
  final b48hi = Ref<int>(0);
}

void varyBitsFields(BitsFields f) {
  lcgStep();
  f.b7.value = rng & 127;
  f.b13.value = shr(3) & 8191;
  f.b23.value = shr(5) & 8388607;
  f.b3.value = shr(29) & 7;
  f.b32.value = shr(16);
  f.b11.value = shr(37) & 2047;
  f.b19.value = shr(44) & 524287;
  f.b48lo.value = rng & 0xFFFFFFFF;
  f.b48hi.value = shr(32) & 0xffff;
}

bool serializeBitsFields(BitStream stream, BitsFields f) {
  return stream.serializeBits(f.b7, 7) &&
      stream.serializeBits(f.b13, 13) &&
      stream.serializeBits(f.b23, 23) &&
      stream.serializeBits(f.b3, 3) &&
      stream.serializeBits(f.b32, 32) &&
      stream.serializeBits(f.b11, 11) &&
      stream.serializeBits(f.b19, 19) &&
      stream.serializeBits(f.b48lo, 32) &&
      stream.serializeBits(f.b48hi, 16);
}

bool checkBitsFields(BitsFields expected, BitsFields decoded) {
  return expected.b7.value == decoded.b7.value &&
      expected.b13.value == decoded.b13.value &&
      expected.b23.value == decoded.b23.value &&
      expected.b3.value == decoded.b3.value &&
      expected.b32.value == decoded.b32.value &&
      expected.b11.value == decoded.b11.value &&
      expected.b19.value == decoded.b19.value &&
      expected.b48lo.value == decoded.b48lo.value &&
      expected.b48hi.value == decoded.b48hi.value;
}

// shape 3: a "generated packet" mixing bounded ints, bits and bools, the way
// schema generated code looks. The 48-bit timestamp travels in two lanes.

final class GenFields {
  final sequence = Ref<int>(0);
  final ackBits = Ref<int>(0);
  final entityId = Ref<int>(0);
  final posX = Ref<int>(0);
  final posY = Ref<int>(0);
  final posZ = Ref<int>(0);
  final yaw = Ref<int>(0);
  final moving = Ref<bool>(false);
  final firing = Ref<bool>(false);
  final timestampLo = Ref<int>(0);
  final timestampHi = Ref<int>(0);
  final weapon = Ref<int>(0);
}

void varyGenFields(GenFields f) {
  lcgStep();
  f.sequence.value = shr(8) & 65535;
  f.ackBits.value = shr(16);
  f.entityId.value = rng & 4095;
  f.posX.value = (shr(20) & 32767) - 16384;
  f.posY.value = (shr(25) & 32767) - 16384;
  f.posZ.value = (shr(30) & 32767) - 16384;
  f.yaw.value = shr(3) & 511;
  f.moving.value = (rng & 1) != 0;
  f.firing.value = (rng & 2) != 0;
  f.timestampLo.value = rng & 0xFFFFFFFF;
  f.timestampHi.value = shr(32) & 0xffff;
  f.weapon.value = shr(60) & 15;
}

bool serializeGenFields(BitStream stream, GenFields f) {
  return stream.serializeInt(f.sequence, 0, 65535) &&
      stream.serializeBits(f.ackBits, 32) &&
      stream.serializeBits(f.entityId, 12) &&
      stream.serializeInt(f.posX, -16384, 16383) &&
      stream.serializeInt(f.posY, -16384, 16383) &&
      stream.serializeInt(f.posZ, -16384, 16383) &&
      stream.serializeBits(f.yaw, 9) &&
      stream.serializeBool(f.moving) &&
      stream.serializeBool(f.firing) &&
      stream.serializeBits(f.timestampLo, 32) &&
      stream.serializeBits(f.timestampHi, 16) &&
      stream.serializeInt(f.weapon, 0, 15);
}

bool checkGenFields(GenFields expected, GenFields decoded) {
  return expected.sequence.value == decoded.sequence.value &&
      expected.ackBits.value == decoded.ackBits.value &&
      expected.entityId.value == decoded.entityId.value &&
      expected.posX.value == decoded.posX.value &&
      expected.posY.value == decoded.posY.value &&
      expected.posZ.value == decoded.posZ.value &&
      expected.yaw.value == decoded.yaw.value &&
      expected.moving.value == decoded.moving.value &&
      expected.firing.value == decoded.firing.value &&
      expected.timestampLo.value == decoded.timestampLo.value &&
      expected.timestampHi.value == decoded.timestampHi.value &&
      expected.weapon.value == decoded.weapon.value;
}

/* --------------------------------------------------------------------------
   variant generation and the golden gate, shared by every packet shape
   -------------------------------------------------------------------------- */

final class _GatedShape<P> {
  final P packet;
  final P decoded;
  final List<Uint8List> variants;
  final int bytesPerPacket;
  _GatedShape(this.packet, this.decoded, this.variants, this.bytesPerPacket);
}

// Pre-writes the 64 variant buffers the read leg decodes, using the same LCG
// sequence as the write loop, then holds the wire against the C pins and
// decodes every variant back, verifying every field. Returns the variant
// views and the constant per-packet byte size.
_GatedShape<P> gateShape<P>(
  String row,
  P packet,
  P decoded,
  void Function(P) init,
  void Function(P) vary,
  bool Function(BitStream, P) serialize,
  bool Function(P, P) check,
  _Pin pin,
) {
  init(packet);
  lcgSeed();
  final variants = <Uint8List>[];
  var bytesPerPacket = 0;
  final writer = WriteStream(Uint8List(256));
  for (var k = 0; k < numVariants; k++) {
    final buffer = Uint8List(256);
    vary(packet);
    writer.reset(buffer);
    if (!serialize(writer, packet)) {
      gateFail(row, 'variant write', 'ok', 'refused');
    }
    writer.flush();
    bytesPerPacket = writer.bytesProcessed;
    variants.add(Uint8List.sublistView(buffer, 0, bytesPerPacket));
  }

  if (bytesPerPacket != pin.bytesPerPacket) {
    gateFail(row, 'bytes per packet', '${pin.bytesPerPacket}', '$bytesPerPacket');
  }
  final hex0 = toHexBytes(variants[0], bytesPerPacket);
  if (hex0 != pin.variant0) {
    gateFail(row, 'variant 0 wire', pin.variant0, hex0);
  }
  final hex63 = toHexBytes(variants[63], bytesPerPacket);
  if (hex63 != pin.variant63) {
    gateFail(row, 'variant 63 wire', pin.variant63, hex63);
  }

  // decode every variant and verify every field against a replay of the LCG
  init(packet);
  lcgSeed();
  final reader = ReadStream(variants[0]);
  for (var k = 0; k < numVariants; k++) {
    vary(packet);
    reader.reset(variants[k]);
    if (!serialize(reader, decoded)) {
      gateFail(row, 'variant $k decode', 'ok', 'refused');
    }
    if (!check(packet, decoded)) {
      gateFail(row, 'variant $k fields', 'writer values', 'different values');
    }
  }

  return _GatedShape(packet, decoded, variants, bytesPerPacket);
}

/* --------------------------------------------------------------------------
   stream

   The representative packet through all three streams: MB/s and M packets/s
   for write and read, M packets/s for measure.
   -------------------------------------------------------------------------- */

_GatedShape<BenchPacket> gateStream() {
  final gated = gateShape(
    'stream',
    BenchPacket(),
    BenchPacket(),
    initBenchPacket,
    varyBenchPacket,
    serializeBenchPacket,
    checkBenchPacket,
    pinStream,
  );

  // measure gate: the measured bits equal the written bits for this packet
  final measure = MeasureStream();
  final ok = serializeBenchPacket(measure, gated.packet);
  if (!ok || measure.bytesProcessed != gated.bytesPerPacket) {
    gateFail(
      'stream',
      'measure bytes',
      '${gated.bytesPerPacket}',
      '${measure.bytesProcessed}',
    );
  }

  return gated;
}

void benchStream(_GatedShape<BenchPacket> gated) {
  final packet = gated.packet;
  final decoded = gated.decoded;
  final variants = gated.variants;
  final buffer = Uint8List(256);
  final writer = WriteStream(buffer);
  final reader = ReadStream(variants[0]);
  final measure = MeasureStream();

  var bestWrite = double.infinity;
  var bestRead = double.infinity;
  var bestMeasure = double.infinity;

  for (var trial = 0; trial < numTrials; trial++) {
    initBenchPacket(packet);
    lcgSeed();

    var start = now();
    for (var i = 0; i < streamNumPackets; i++) {
      varyBenchPacket(packet);
      writer.reset(buffer);
      if (!serializeBenchPacket(writer, packet)) {
        exit(1);
      }
      writer.flush();
      sink = (sink + writer.bytesProcessed) & 0xFFFFFFFF;
    }
    var elapsed = now() - start;
    if (elapsed < bestWrite) {
      bestWrite = elapsed;
    }

    start = now();
    for (var i = 0; i < streamNumPackets; i++) {
      reader.reset(variants[i & (numVariants - 1)]);
      if (!serializeBenchPacket(reader, decoded)) {
        exit(1);
      }
      sink = (sink + decoded.b.value) & 0xFFFFFFFF;
    }
    elapsed = now() - start;
    if (elapsed < bestRead) {
      bestRead = elapsed;
    }

    // measure prices the packet without touching memory; that it is nearly
    // free is the property worth tracking. The vary call stays so the loop
    // is the loop the other family benches time.
    start = now();
    for (var i = 0; i < streamNumPackets; i++) {
      varyBenchPacket(packet);
      measure.reset();
      if (!serializeBenchPacket(measure, packet)) {
        exit(1);
      }
      sink = (sink + measure.bitsProcessed) & 0xFFFFFFFF;
    }
    elapsed = now() - start;
    if (elapsed < bestMeasure) {
      bestMeasure = elapsed;
    }
  }

  final totalMB = (gated.bytesPerPacket * streamNumPackets) / (1024 * 1024);
  final packets = streamNumPackets / 1000000;

  report('stream', 'write', 'MB/s', totalMB / bestWrite);
  report('stream', 'write', 'Mpackets/s', packets / bestWrite);
  report('stream', 'read', 'MB/s', totalMB / bestRead);
  report('stream', 'read', 'Mpackets/s', packets / bestRead);
  report('stream', 'measure', 'Mpackets/s', packets / bestMeasure);
  printRow(
    'stream write:     ${(totalMB / bestWrite).toStringAsFixed(1).padLeft(8)} MB/s  (${(packets / bestWrite).toStringAsFixed(1)} M packets/s)\n',
  );
  printRow(
    'stream read:      ${(totalMB / bestRead).toStringAsFixed(1).padLeft(8)} MB/s  (${(packets / bestRead).toStringAsFixed(1)} M packets/s)\n',
  );
  printRow(
    'stream measure:   ${(packets / bestMeasure).toStringAsFixed(1).padLeft(19)} M packets/s\n',
  );
}

/* --------------------------------------------------------------------------
   packet shapes: write and read, M packets/s
   -------------------------------------------------------------------------- */

void zeroInitInt(IntFields f) {}
void zeroInitBits(BitsFields f) {}
void zeroInitGen(GenFields f) {}

void benchShape<P>(
  String row,
  String label,
  _GatedShape<P> gated,
  void Function(P) init,
  void Function(P) vary,
  bool Function(BitStream, P) serialize,
  int Function(P) sinkOf,
) {
  final packet = gated.packet;
  final decoded = gated.decoded;
  final variants = gated.variants;
  final buffer = Uint8List(256);
  final writer = WriteStream(buffer);
  final reader = ReadStream(variants[0]);

  var bestWrite = double.infinity;
  var bestRead = double.infinity;

  for (var trial = 0; trial < numTrials; trial++) {
    init(packet);
    lcgSeed();

    var start = now();
    for (var i = 0; i < streamNumPackets; i++) {
      vary(packet);
      writer.reset(buffer);
      if (!serialize(writer, packet)) {
        exit(1);
      }
      writer.flush();
      sink = (sink + writer.bytesProcessed) & 0xFFFFFFFF;
    }
    var elapsed = now() - start;
    if (elapsed < bestWrite) {
      bestWrite = elapsed;
    }

    start = now();
    for (var i = 0; i < streamNumPackets; i++) {
      reader.reset(variants[i & (numVariants - 1)]);
      if (!serialize(reader, decoded)) {
        exit(1);
      }
      sink = (sink + sinkOf(decoded)) & 0xFFFFFFFF;
    }
    elapsed = now() - start;
    if (elapsed < bestRead) {
      bestRead = elapsed;
    }
  }

  final packets = streamNumPackets / 1000000;
  report(row, 'write', 'Mpackets/s', packets / bestWrite);
  report(row, 'read', 'Mpackets/s', packets / bestRead);
  printRow(
    '$label  write: ${(packets / bestWrite).toStringAsFixed(1).padLeft(6)} M packets/s   read: ${(packets / bestRead).toStringAsFixed(1).padLeft(6)} M packets/s\n',
  );
}

/* ------------------------------------------------------------------------- */

void main(List<String> arguments) {
  csv = arguments.contains('--csv');
  initBitpackerValues();

  // every row's golden gate runs before any row is timed: a bench that fails
  // its goldens reports nothing at all
  final gatedBitpacker = gateBitpacker();
  final gatedStream = gateStream();
  final gatedInt = gateShape(
    'int_packet',
    IntFields(),
    IntFields(),
    zeroInitInt,
    varyIntFields,
    serializeIntFields,
    checkIntFields,
    pinInt,
  );
  final gatedBits = gateShape(
    'bits_packet',
    BitsFields(),
    BitsFields(),
    zeroInitBits,
    varyBitsFields,
    serializeBitsFields,
    checkBitsFields,
    pinBits,
  );
  final gatedGen = gateShape(
    'mixed_packet',
    GenFields(),
    GenFields(),
    zeroInitGen,
    varyGenFields,
    serializeGenFields,
    checkGenFields,
    pinGen,
  );

  printRow('\n[serialize.dart benchmark]\n\n');

  benchBitpacker(gatedBitpacker);

  benchStream(gatedStream);

  printRow('\n');

  benchShape(
    'int_packet',
    'int packet   (runtime):     ',
    gatedInt,
    zeroInitInt,
    varyIntFields,
    serializeIntFields,
    (IntFields d) => d.f0.value,
  );
  benchShape(
    'bits_packet',
    'bits packet  (runtime):     ',
    gatedBits,
    zeroInitBits,
    varyBitsFields,
    serializeBitsFields,
    (BitsFields d) => d.b7.value,
  );
  benchShape(
    'mixed_packet',
    'mixed packet (runtime):     ',
    gatedGen,
    zeroInitGen,
    varyGenFields,
    serializeGenFields,
    (GenFields d) => d.sequence.value,
  );

  printRow(
    '\n(the C++ bench also prints a compile time row per shape. that surface is\n',
  );
  printRow(
    ' C++ template machinery with no counterpart here, the same omission the\n',
  );
  printRow(' C bench makes.)\n');
  printRow('\n');

  if (csv) {
    final buffer = StringBuffer('row,op,units,value\n');
    for (final r in results) {
      buffer.write('${r.row},${r.op},${r.units},${r.value.toStringAsFixed(4)}\n');
    }
    stdout.write(buffer.toString());
  }

  // the g_sink escape: the compiler cannot prove the env var absent, so the
  // accumulated sink is observable and no loop's work can be deleted
  if (Platform.environment['SERIALIZE_BENCH_SINK'] != null) {
    stderr.write('sink: $sink\n');
  }
}
