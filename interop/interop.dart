// dart format off
//
// The Dart half of the cross language interop harness.
//
// Its twin is interop/interop.cpp, built in CI against the real C++ serialize
// library at the release .github/workflows/ci.yml pins. The two halves run head
// to head on every push and pull request: each writes the boundary message, the
// two files must be byte identical, and each must decode the other's file to the
// exact values and re-encode it to the exact bytes.
//
//     dart run interop/interop.dart write  <file>
//     dart run interop/interop.dart read   <file>
//     dart run interop/interop.dart refuse <file>
//
// THE MESSAGE is the boundary set: every operation STANDARD.md defines, at the
// values where implementations disagree. Zero bit ranges on all three ranged
// widths and on fixed point; the domain edges of int, int64, int128 and
// int_relative; the maximum widths of bits, uint128 and the four group fixed
// point path; both sides of the alignment rule, including the align inside a
// zero length bytes; empty and full strings; and the wide string cases the
// surrogate rule governs, up to the largest code unit.
//
// WHAT IT DELIBERATELY DOES NOT CARRY: a NaN payload. STANDARD.md's bit
// transparency claim covers it, but a NaN's payload bits do not survive every
// language's float type on the way to the wire, so a difference here would say
// nothing about the wire format. This port pins its own NaN patterns in its own
// suite, where the claim can be tested honestly.
//
// The formatter is off for this file: it is a table of wire vectors, and the
// aligned columns are the readable form of a table. Analysis stays on.
//
// Any change to the sequence below must be mirrored in interop/interop.cpp, and
// never changes the wire format.

import 'dart:io';
import 'dart:typed_data';

import 'package:serialize/serialize.dart';

const int int32Min = -2147483648;
const int int32Max = 2147483647;
// hex spellings: the decimal literals for the 64-bit extremes are not
// expressible in Dart
const int int64Min = 0x8000000000000000;
const int int64Max = 0x7FFFFFFFFFFFFFFF;
const int allOnes64 = 0xFFFFFFFFFFFFFFFF;

// ---------------------------------------------------------------------------
// the sequence, mirrored field for field from interop/interop.cpp

class BitsVector {
  final int bits;
  final int value;
  const BitsVector(this.bits, this.value);
}

const List<BitsVector> bitsVectors = [
  BitsVector(1, 1),               // the minimum width, at its maximum value
  BitsVector(1, 0),               // and at its minimum
  BitsVector(7, 0x7F),            // a sub-byte width, all ones
  BitsVector(31, 0x7FFFFFFF),     // one below the single group maximum
  BitsVector(32, 0xFFFFFFFF),     // the widest single group, all ones
  BitsVector(32, 0),              // and all zeros
  BitsVector(33, 0x1FFFFFFFF),    // the first width past the 32 bit split
  BitsVector(64, allOnes64),      // the maximum width, all ones
  BitsVector(64, 0),              // and all zeros
];

const List<int> uint8Values = [0x00, 0xFF];
const List<int> uint16Values = [0x0000, 0xFFFF];
const List<int> uint32Values = [0x00000000, 0xFFFFFFFF];
const List<int> uint64Values = [0, allOnes64];

final List<UInt128> uint128Values = [
  UInt128.zero,
  UInt128.maxValue,
  const UInt128(0x0123456789ABCDEF, 0x0FEDCBA987654321),
];

class IntVector {
  final int min;
  final int max;
  final int value;
  const IntVector(this.min, this.max, this.value);
}

const List<IntVector> intVectors = [
  IntVector(42, 42, 42),                        // degenerate: zero bits, mid sequence
  IntVector(-100, 100, -100),                   // the bottom of the range
  IntVector(-100, 100, 100),                    // the top of the range
  IntVector(int32Min, int32Max, int32Min),      // the full domain, 32 bits on the wire
  IntVector(int32Min, int32Max, int32Max),
  IntVector(-100, 100, -37),                    // a live field after the degenerate one
];

const List<IntVector> int64Vectors = [
  IntVector(10000000000, 10000000000, 10000000000),   // degenerate, bounds past 2^32
  IntVector(-5000000000, 5000000000, -5000000000),    // wider than 32 bits, bottom
  IntVector(-5000000000, 5000000000, 5000000000),     // and top
  IntVector(int64Min, int64Max, int64Min),            // the full domain, 64 bits
  IntVector(int64Min, int64Max, int64Max),
];

class Int128Vector {
  final Int128 min;
  final Int128 max;
  final Int128 value;
  const Int128Vector(this.min, this.max, this.value);
}

// 2^100 + 7: a degenerate bound no 64 bit path can carry
final Int128 int128Degenerate = (Int128.fromInt(1) << 100) + Int128.fromInt(7);

final List<Int128Vector> int128Vectors = [
  Int128Vector(int128Degenerate, int128Degenerate, int128Degenerate),
  // bounds inside the 64 bit domain: the bytes are identical to serializeInt64 here
  Int128Vector(Int128.fromInt(-5000000000), Int128.fromInt(5000000000), Int128.fromInt(5000000000)),
  Int128Vector(Int128.minValue, Int128.maxValue, Int128.minValue),
  Int128Vector(Int128.minValue, Int128.maxValue, Int128.maxValue),
];

class RelativeVector {
  final int previous;
  final int current;
  const RelativeVector(this.previous, this.current);
}

const List<RelativeVector> relativeVectors = [
  RelativeVector(0, 1),                       // one-bit
  RelativeVector(0, 2),                       // bounded-3, both ends
  RelativeVector(0, 6),
  RelativeVector(0, 7),                       // bounded-5
  RelativeVector(0, 23),
  RelativeVector(0, 24),                      // bounded-9
  RelativeVector(0, 280),
  RelativeVector(0, 281),                     // bounded-13
  RelativeVector(0, 4377),
  RelativeVector(0, 4378),                    // bounded-17
  RelativeVector(0, 69914),
  RelativeVector(0, 69915),                   // absolute, at its smallest difference
  RelativeVector(2147483646, 2147483647),     // one-bit, at the top of the domain
  RelativeVector(0, 2147483647),              // absolute, at the top of the domain
];

// floats are given as bit patterns, so no decimal literal is parsed twice
const List<int> floatBits = [
  0x00000000,   // +0
  0x80000000,   // -0
  0x7F800000,   // +infinity
  0xFF800000,   // -infinity
  0x7F7FFFFF,   // the largest finite float32
  0x00800000,   // the smallest normal
  0x00000001,   // the smallest subnormal
  0x3F800000,   // 1.0
  0xBF800000,   // -1.0
];

const List<int> doubleBits = [
  0x0000000000000000,   // +0
  0x8000000000000000,   // -0
  0x7FF0000000000000,   // +infinity
  0xFFF0000000000000,   // -infinity
  0x7FEFFFFFFFFFFFFF,   // the largest finite float64
  0x0010000000000000,   // the smallest normal
  0x0000000000000001,   // the smallest subnormal
  0x3FF0000000000000,   // 1.0
  0xBFF0000000000000,   // -1.0
];

class CompressedFloatVector {
  final double value;
  final double min;
  final double max;
  final double res;
  const CompressedFloatVector(this.value, this.min, this.max, this.res);
}

const List<CompressedFloatVector> compressedFloatVectors = [
  CompressedFloatVector(0.0, 0.0, 10.0, 0.01),              // the bottom of the range: integer 0
  CompressedFloatVector(10.0, 0.0, 10.0, 0.01),             // the top: the maximum integer
  CompressedFloatVector(0.005, 0.0, 10.0, 0.01),            // between quanta: 1 under float32, 0 widened
  CompressedFloatVector(0.025, 0.0, 10.0, 0.01),            // between quanta: 3 vs 2
  CompressedFloatVector(0.105, 0.0, 10.0, 0.01),            // between quanta: 11 vs 10
  CompressedFloatVector(9.995, 0.0, 10.0, 0.01),            // between quanta: 1000 vs 999
  CompressedFloatVector(-100.0, -100.0, 100.0, 0.01),       // the bottom of a non-zero min range
  CompressedFloatVector(-42.573, -100.0, 100.0, 0.01),      // off quantum over a non-zero min
  CompressedFloatVector(8388609.0, 0.0, 8388609.0, 1.0),    // clamp witness A (schema#109)
  CompressedFloatVector(16777215.0, 0.0, 16777215.0, 1.0),  // clamp witness B
  CompressedFloatVector(0.0, 0.0, 1.0, 1.0),                // a one bit field, both codes
  CompressedFloatVector(1.0, 0.0, 1.0, 1.0),
];

class BytesVector {
  final int length;
  final int fill;
  const BytesVector(this.length, this.fill);
}

const List<BytesVector> bytesVectors = [
  BytesVector(0, 0x00),   // zero length: the align happens anyway
  BytesVector(8, 0x00),
  BytesVector(8, 0xFF),
  BytesVector(1, 0x5A),
];

const int stringBufferSize = 16;
const List<String> strings = [
  '',                             // empty
  '0123456789abcde',              // fifteen bytes: the most buffer size 16 carries
  '\u043C\u0438\u0440',           // six UTF-8 bytes, as explicit code points so no
                                  // source file encoding can reach the wire
];

const int wstringBufferSize = 8;
const List<String> wideStrings = [
  '',                             // empty
  '\u043C\u0438\u0440',           // basic plane
  '\uE000',                       // the first code unit above the surrogate block
  '\uFFFF',                       // the largest code unit there is
  'A\uD83D\uDE00B',                // U+1F600 as its surrogate pair: four code units
  'abcdefg',                      // seven code units, the most buffer size 8 carries
];

// ---------------------------------------------------------------------------
// the message

class InteropData {
  final List<Ref<int>> bits;
  final List<Ref<bool>> bools;
  final List<Ref<int>> uint8;
  final List<Ref<int>> uint16;
  final List<Ref<int>> uint32;
  final List<Ref<int>> uint64;
  final List<Ref<UInt128>> uint128;
  final List<Ref<int>> ints;
  final List<Ref<int>> int64s;
  final List<Ref<Int128>> int128s;
  final Ref<int> fixedQ8x8Min;
  final Ref<int> fixedQ8x8Max;
  final Ref<int> fixedQ16x16Degenerate;
  final Ref<int> fixedQ48x16Min;
  final Ref<int> fixedQ48x16Max;
  final Ref<Int128> fixedQ112x16Max;
  final Ref<Int128> fixedQ64x64Degenerate;
  final Ref<Int128> fixedQ64x64Max;
  final List<Ref<int>> relative;
  final List<Ref<double>> floats;
  final List<Ref<double>> doubles;
  final List<Ref<double>> compressedFloats;
  final Ref<int> filler;
  final List<Uint8List> bytes;
  final List<Ref<String>> narrowStrings;
  final List<Ref<String>> wide;

  InteropData._({
    required this.bits,
    required this.bools,
    required this.uint8,
    required this.uint16,
    required this.uint32,
    required this.uint64,
    required this.uint128,
    required this.ints,
    required this.int64s,
    required this.int128s,
    required this.fixedQ8x8Min,
    required this.fixedQ8x8Max,
    required this.fixedQ16x16Degenerate,
    required this.fixedQ48x16Min,
    required this.fixedQ48x16Max,
    required this.fixedQ112x16Max,
    required this.fixedQ64x64Degenerate,
    required this.fixedQ64x64Max,
    required this.relative,
    required this.floats,
    required this.doubles,
    required this.compressedFloats,
    required this.filler,
    required this.bytes,
    required this.narrowStrings,
    required this.wide,
  });

  /// The write side: every holder carries the value the sequence pins.
  factory InteropData.boundary() => InteropData._(
        bits: [for (final v in bitsVectors) Ref<int>(v.value)],
        bools: [Ref<bool>(true), Ref<bool>(false)],
        uint8: [for (final v in uint8Values) Ref<int>(v)],
        uint16: [for (final v in uint16Values) Ref<int>(v)],
        uint32: [for (final v in uint32Values) Ref<int>(v)],
        uint64: [for (final v in uint64Values) Ref<int>(v)],
        uint128: [for (final v in uint128Values) Ref<UInt128>(v)],
        ints: [for (final v in intVectors) Ref<int>(v.value)],
        int64s: [for (final v in int64Vectors) Ref<int>(v.value)],
        int128s: [for (final v in int128Vectors) Ref<Int128>(v.value)],
        fixedQ8x8Min: Ref<int>(-100 * 256),                                 // the bottom of the range
        fixedQ8x8Max: Ref<int>(100 * 256),                                  // the top
        fixedQ16x16Degenerate: Ref<int>(7 * 65536),                         // min == max: zero bits
        fixedQ48x16Min: Ref<int>(-100000 * 65536),                          // 34 bits on the wire
        fixedQ48x16Max: Ref<int>(100000 * 65536),
        fixedQ112x16Max: Ref<Int128>(Int128.fromInt(144115188075855872) << 16),  // 75 bits, three groups
        fixedQ64x64Degenerate: Ref<Int128>(Int128.fromInt(5) << 64),        // zero bits at 128 bit storage
        fixedQ64x64Max: Ref<Int128>(Int128.fromInt(int64Max) << 64),        // 128 bits, four groups
        relative: [for (final v in relativeVectors) Ref<int>(v.current)],
        floats: [for (final b in floatBits) Ref<double>(doubleFromFloat32Bits(b))],
        doubles: [for (final b in doubleBits) Ref<double>(doubleFromFloat64Bits(b))],
        compressedFloats: [for (final v in compressedFloatVectors) Ref<double>(v.value)],
        filler: Ref<int>(5),
        bytes: [for (final v in bytesVectors) Uint8List(v.length)..fillRange(0, v.length, v.fill)],
        narrowStrings: [for (final s in strings) Ref<String>(s)],
        wide: [for (final s in wideStrings) Ref<String>(s)],
      );

  /// The read side: zeroed holders the stream fills.
  factory InteropData.empty() => InteropData._(
        bits: [for (var i = 0; i < bitsVectors.length; i++) Ref<int>(0)],
        bools: [Ref<bool>(false), Ref<bool>(false)],
        uint8: [for (var i = 0; i < uint8Values.length; i++) Ref<int>(0)],
        uint16: [for (var i = 0; i < uint16Values.length; i++) Ref<int>(0)],
        uint32: [for (var i = 0; i < uint32Values.length; i++) Ref<int>(0)],
        uint64: [for (var i = 0; i < uint64Values.length; i++) Ref<int>(0)],
        uint128: [for (var i = 0; i < uint128Values.length; i++) Ref<UInt128>(UInt128.zero)],
        ints: [for (var i = 0; i < intVectors.length; i++) Ref<int>(0)],
        int64s: [for (var i = 0; i < int64Vectors.length; i++) Ref<int>(0)],
        int128s: [for (var i = 0; i < int128Vectors.length; i++) Ref<Int128>(Int128.zero)],
        fixedQ8x8Min: Ref<int>(0),
        fixedQ8x8Max: Ref<int>(0),
        fixedQ16x16Degenerate: Ref<int>(0),
        fixedQ48x16Min: Ref<int>(0),
        fixedQ48x16Max: Ref<int>(0),
        fixedQ112x16Max: Ref<Int128>(Int128.zero),
        fixedQ64x64Degenerate: Ref<Int128>(Int128.zero),
        fixedQ64x64Max: Ref<Int128>(Int128.zero),
        relative: [for (var i = 0; i < relativeVectors.length; i++) Ref<int>(0)],
        floats: [for (var i = 0; i < floatBits.length; i++) Ref<double>(0)],
        doubles: [for (var i = 0; i < doubleBits.length; i++) Ref<double>(0)],
        compressedFloats: [for (var i = 0; i < compressedFloatVectors.length; i++) Ref<double>(0)],
        filler: Ref<int>(0),
        bytes: [for (final v in bytesVectors) Uint8List(v.length)],
        narrowStrings: [for (var i = 0; i < strings.length; i++) Ref<String>('')],
        wide: [for (var i = 0; i < wideStrings.length; i++) Ref<String>('')],
      );
}

/// The message, operation for operation. The && chain stops at the first refusal.
bool interopSerialize(BitStream stream, InteropData d) {
  // ----- raw bit groups
  for (var i = 0; i < bitsVectors.length; i++) {
    final bits = bitsVectors[i].bits;
    final ok = bits <= 32
        ? stream.serializeBits(d.bits[i], bits)
        : stream.serializeBits64(d.bits[i], bits);
    if (!ok) return false;
  }

  // ----- bool, both codes
  for (final ref in d.bools) {
    if (!stream.serializeBool(ref)) return false;
  }

  // both sides of the alignment rule: the stream is unaligned here, so the first
  // align pads and the second must write nothing at all
  if (!stream.serializeAlign()) return false;
  if (!stream.serializeAlign()) return false;

  // ----- the fixed width unsigned helpers, at their domain edges
  for (final ref in d.uint8) { if (!stream.serializeUint8(ref)) return false; }
  for (final ref in d.uint16) { if (!stream.serializeUint16(ref)) return false; }
  for (final ref in d.uint32) { if (!stream.serializeUint32(ref)) return false; }
  for (final ref in d.uint64) { if (!stream.serializeUint64(ref)) return false; }
  for (final ref in d.uint128) { if (!stream.serializeUint128(ref)) return false; }

  // ----- ranged integers
  for (var i = 0; i < intVectors.length; i++) {
    if (!stream.serializeInt(d.ints[i], intVectors[i].min, intVectors[i].max)) return false;
  }
  for (var i = 0; i < int64Vectors.length; i++) {
    if (!stream.serializeInt64(d.int64s[i], int64Vectors[i].min, int64Vectors[i].max)) return false;
  }
  for (var i = 0; i < int128Vectors.length; i++) {
    if (!stream.serializeInt128(d.int128s[i], int128Vectors[i].min, int128Vectors[i].max)) return false;
  }

  // ----- fixed point, at the ends of its ranges and degenerate on two storage widths
  if (!stream.serializeAlign()) return false;
  if (!stream.serializeFixed(d.fixedQ8x8Min, 8, 8, -100, 100)) return false;
  if (!stream.serializeFixed(d.fixedQ8x8Max, 8, 8, -100, 100)) return false;
  if (!stream.serializeFixed(d.fixedQ16x16Degenerate, 16, 16, 7, 7)) return false;
  if (!stream.serializeFixed(d.fixedQ48x16Min, 48, 16, -100000, 100000)) return false;
  if (!stream.serializeFixed(d.fixedQ48x16Max, 48, 16, -100000, 100000)) return false;
  if (!stream.serializeFixed128(d.fixedQ112x16Max, 112, 16, -144115188075855872, 144115188075855872)) return false;
  if (!stream.serializeFixed128(d.fixedQ64x64Degenerate, 64, 64, 5, 5)) return false;
  if (!stream.serializeFixed128(d.fixedQ64x64Max, 64, 64, int64Min, int64Max)) return false;

  // ----- int_relative: every tier at both ends, and the domain edges
  for (var i = 0; i < relativeVectors.length; i++) {
    if (!stream.serializeIntRelative(relativeVectors[i].previous, d.relative[i])) return false;
  }

  // ----- float and double, bit transparent at the domain edges
  for (final ref in d.floats) { if (!stream.serializeFloat(ref)) return false; }
  for (final ref in d.doubles) { if (!stream.serializeDouble(ref)) return false; }

  // ----- compressed_float
  for (var i = 0; i < compressedFloatVectors.length; i++) {
    final v = compressedFloatVectors[i];
    if (!stream.serializeCompressedFloat(d.compressedFloats[i], v.min, v.max, v.res)) return false;
  }

  // ----- bytes. The three bit filler leaves the stream unaligned, so the align
  // that begins the first block -- a ZERO LENGTH one -- is load bearing.
  if (!stream.serializeBits(d.filler, 3)) return false;
  for (final block in d.bytes) {
    if (!stream.serializeBytes(block)) return false;
  }

  // ----- string: empty, full, and multi-byte UTF-8
  for (final ref in d.narrowStrings) {
    if (!stream.serializeString(ref, stringBufferSize)) return false;
  }

  // ----- wstring: empty, basic plane, the code unit boundaries, a pair, full
  for (final ref in d.wide) {
    if (!stream.serializeWideString(ref, wstringBufferSize)) return false;
  }

  return true;
}

/// What a conforming reader recovers. Everything is exact except the compressed
/// floats, which are lossy by construction: the reader returns the nearest
/// quantum, so they are compared within one resolution step. Floats compare by
/// BIT PATTERN -- a value comparison cannot see -0.0.
List<String> interopCheck(InteropData d) {
  final problems = <String>[];
  void equal(String label, Object? actual, Object? expected) {
    if (actual != expected) {
      problems.add('$label: got $actual, expected $expected');
    }
  }

  final expected = InteropData.boundary();

  for (var i = 0; i < bitsVectors.length; i++) {
    equal('bits[$i]', d.bits[i].value, bitsVectors[i].value);
  }
  equal('bool[0]', d.bools[0].value, true);
  equal('bool[1]', d.bools[1].value, false);
  for (var i = 0; i < uint8Values.length; i++) {
    equal('uint8[$i]', d.uint8[i].value, uint8Values[i]);
  }
  for (var i = 0; i < uint16Values.length; i++) {
    equal('uint16[$i]', d.uint16[i].value, uint16Values[i]);
  }
  for (var i = 0; i < uint32Values.length; i++) {
    equal('uint32[$i]', d.uint32[i].value, uint32Values[i]);
  }
  for (var i = 0; i < uint64Values.length; i++) {
    equal('uint64[$i]', d.uint64[i].value, uint64Values[i]);
  }
  for (var i = 0; i < uint128Values.length; i++) {
    equal('uint128[$i]', d.uint128[i].value, uint128Values[i]);
  }
  for (var i = 0; i < intVectors.length; i++) {
    equal('int[$i]', d.ints[i].value, intVectors[i].value);
  }
  for (var i = 0; i < int64Vectors.length; i++) {
    equal('int64[$i]', d.int64s[i].value, int64Vectors[i].value);
  }
  for (var i = 0; i < int128Vectors.length; i++) {
    equal('int128[$i]', d.int128s[i].value, int128Vectors[i].value);
  }

  equal('fixed q8.8 min', d.fixedQ8x8Min.value, expected.fixedQ8x8Min.value);
  equal('fixed q8.8 max', d.fixedQ8x8Max.value, expected.fixedQ8x8Max.value);
  equal('fixed q16.16 degenerate', d.fixedQ16x16Degenerate.value, expected.fixedQ16x16Degenerate.value);
  equal('fixed q48.16 min', d.fixedQ48x16Min.value, expected.fixedQ48x16Min.value);
  equal('fixed q48.16 max', d.fixedQ48x16Max.value, expected.fixedQ48x16Max.value);
  equal('fixed q112.16 max', d.fixedQ112x16Max.value, expected.fixedQ112x16Max.value);
  equal('fixed q64.64 degenerate', d.fixedQ64x64Degenerate.value, expected.fixedQ64x64Degenerate.value);
  equal('fixed q64.64 max', d.fixedQ64x64Max.value, expected.fixedQ64x64Max.value);
  equal('filler', d.filler.value, expected.filler.value);

  for (var i = 0; i < relativeVectors.length; i++) {
    equal('int_relative[$i]', d.relative[i].value, relativeVectors[i].current);
  }
  for (var i = 0; i < floatBits.length; i++) {
    equal('float[$i]', float32BitsFromDouble(d.floats[i].value), floatBits[i]);
  }
  for (var i = 0; i < doubleBits.length; i++) {
    equal('double[$i]', float64BitsFromDouble(d.doubles[i].value), doubleBits[i]);
  }
  for (var i = 0; i < compressedFloatVectors.length; i++) {
    final v = compressedFloatVectors[i];
    final decoded = d.compressedFloats[i].value;
    if (!((decoded - v.value).abs() <= v.res)) {
      problems.add('compressed_float[$i]: got $decoded, expected ${v.value} within ${v.res}');
    }
  }
  for (var i = 0; i < bytesVectors.length; i++) {
    final block = d.bytes[i];
    final want = expected.bytes[i];
    var same = block.length == want.length;
    for (var j = 0; same && j < block.length; j++) {
      if (block[j] != want[j]) same = false;
    }
    if (!same) problems.add('bytes[$i]: got $block, expected $want');
  }
  for (var i = 0; i < strings.length; i++) {
    equal('string[$i]', d.narrowStrings[i].value, strings[i]);
  }
  for (var i = 0; i < wideStrings.length; i++) {
    equal('wstring[$i]', d.wide[i].value, wideStrings[i]);
  }

  return problems;
}

// ---------------------------------------------------------------------------
// the three modes

// a multiple of 8, as the write stream requires
const int bufferBytes = 1024;

Uint8List encode(InteropData data) {
  final stream = WriteStream(Uint8List(bufferBytes));
  if (!interopSerialize(stream, data)) {
    throw StateError('interop dart: serialize failed');
  }
  stream.flush();
  return Uint8List.fromList(stream.data());
}

void write(String path) {
  final bytes = encode(InteropData.boundary());
  File(path).writeAsBytesSync(bytes);
  stdout.writeln('interop dart: wrote ${bytes.length} bytes to $path');
}

void read(String path) {
  final input = File(path).readAsBytesSync();
  final data = InteropData.empty();
  if (!interopSerialize(ReadStream(input), data)) {
    throw StateError('interop dart: could not decode $path');
  }
  final problems = interopCheck(data);
  if (problems.isNotEmpty) {
    throw StateError('interop dart: $path decoded to unexpected values:\n  ${problems.join('\n  ')}');
  }
  // re-encode what was decoded: the bytes must be identical to the input
  final reencoded = encode(data);
  var same = reencoded.length == input.length;
  for (var i = 0; same && i < input.length; i++) {
    if (reencoded[i] != input[i]) same = false;
  }
  if (!same) {
    throw StateError('interop dart: re-encoded bytes differ from $path');
  }
  stdout.writeln('interop dart: decoded and re-encoded ${input.length} bytes from $path, byte identical');
}

/// The hostile half: every proper prefix of a valid stream is a truncated
/// stream, and a conforming reader refuses every one of them without throwing.
void refuse(String path) {
  final input = File(path).readAsBytesSync();
  for (var length = 0; length < input.length; length++) {
    final truncated = Uint8List.sublistView(input, 0, length);
    final data = InteropData.empty();
    final bool accepted;
    try {
      accepted = interopSerialize(ReadStream(truncated), data);
    } catch (error) {
      throw StateError('interop dart refuse: the $length byte prefix of $path THREW: $error');
    }
    if (accepted) {
      throw StateError('interop dart refuse: the $length byte prefix of $path was ACCEPTED');
    }
  }
  stdout.writeln('interop dart: refused all ${input.length} truncated prefixes of $path');
}

void main(List<String> args) {
  if (args.length != 2 || !['write', 'read', 'refuse'].contains(args[0])) {
    stderr.writeln('usage: dart run interop/interop.dart write|read|refuse <file>');
    exit(2);
  }
  try {
    if (args[0] == 'write') {
      write(args[1]);
    } else if (args[0] == 'read') {
      read(args[1]);
    } else {
      refuse(args[1]);
    }
  } catch (error) {
    stderr.writeln(error);
    exit(1);
  }
}
