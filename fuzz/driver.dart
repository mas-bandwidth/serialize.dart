// fuzz/driver.dart: the Dart side of TestDifferentialAgainstSerializeGo
// (fuzz/differential_test.go).
//
//     fuzz/driver <batch file>
//
// The Go host compiles this file once per test run (dart compile exe, asserts
// on, so a writer contract the generator breaks, or an assert a hostile read
// trips, fails loudly) and runs the binary once per batch of programs. The
// batch file holds one request per line; the driver answers each with one
// line on stdout, every value in lowercase hex, then `done <count>`. Hostile
// bytes never throw (STANDARD.md, Reader Obligations): anything this driver
// throws is a failure of the batch, which the Go side reports by its stderr.
//
// THE REQUESTS.
//
//     w <id> <capacity> <program>   write the program into a buffer of
//                                   <capacity> bytes (a multiple of 8)
//     r <id> x<hex> <program>       read the program's steps from those bytes
//
// THE ANSWERS.
//
//     <id> w ok <bits> <measured> x<hex>        bitsProcessed, the
//                                               MeasureStream bound, data()
//     <id> r ok <bits> <v0> ... <vn-1>          bitsProcessed and every value
//     <id> r refused <i> <kind> <v0> ... <vi-1> the refusing step, refusal,
//                                               and the values decoded before
//
// <kind> is the stream's first refusal reason, spelled as STANDARD.md spells
// it (format 2.0, Refusal reasons). A refused read whose destination was
// written answers kind `touched:<kind>`, so the differential goes red on it
// (a refusal leaves the caller's destination untouched).
//
// THE PROGRAM TEXT: steps one after another, each `<kind> <params> <value>`;
// a number is 32 hex digits, the 128-bit two's complement (signed kinds sign
// extended, unsigned kinds zero extended; a float by its bit pattern); a byte
// string is `x` and its hex; widths, Q formats and buffer sizes are decimal.
//
//     bits <w> N  bits64 <w> N  bool 0|1  uint8 N  uint16 N  uint32 N
//     uint64 N  uint128 N  int MIN MAX N  int64 MIN MAX N  int128 MIN MAX N
//     fixed64 <ib> <fb> MIN MAX N  fixed128 <ib> <fb> MIN MAX N
//     int_relative PREV N  float N  double N  cfloat MIN MAX RES N
//     bytes xHEX  string <buffer> xHEX  align  end  object <span>
//
// `object <span>` serializes the next <span> steps inside serializeObject
// (STANDARD.md object). A value token is ignored on a read.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:serialize/serialize.dart';

// ---------------------------------------------------------------------------
// the program

final class Step {
  final String kind;
  int width = 0; // bits width; object span; string buffer size
  int ib = 0;
  int fb = 0;
  UInt128 min = UInt128.zero;
  UInt128 max = UInt128.zero;
  int prev = 0;
  double fmin = 0;
  double fmax = 0;
  double fres = 0;
  UInt128 v = UInt128.zero;
  bool b = false;
  Uint8List data = Uint8List(0);

  Step(this.kind);
}

final class Tokens {
  final List<String> _t;
  int _p = 0;

  Tokens(this._t);

  bool get done => _p >= _t.length;

  String word() {
    if (done) {
      throw const FormatException('driver: a token is missing');
    }
    return _t[_p++];
  }

  int dec() => int.parse(word());

  // a 128-bit number, 32 hex digits
  UInt128 num() {
    final w = word();
    if (w.length != 32) {
      throw FormatException('driver: a number is 32 hex digits: $w');
    }
    return UInt128(
      int.parse(w.substring(0, 8), radix: 16) << 32 |
          int.parse(w.substring(8, 16), radix: 16),
      int.parse(w.substring(16, 24), radix: 16) << 32 |
          int.parse(w.substring(24, 32), radix: 16),
    );
  }

  Uint8List bytes() {
    final w = word();
    if (!w.startsWith('x') || w.length.isEven) {
      throw FormatException('driver: a byte string is x and its hex: $w');
    }
    final out = Uint8List((w.length - 1) ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(w.substring(1 + 2 * i, 3 + 2 * i), radix: 16);
    }
    return out;
  }
}

int signed32(int x) => (x & 0xFFFFFFFF).toSigned(32);

// The program's string, as the text a writer is handed. utf8.decode drops a
// leading U+FEFF, which is a character like any other on the wire
// (STANDARD.md string: no stripped byte order mark), so it is put back.
String textOf(Uint8List data) {
  final text = utf8.decode(data);
  final bom =
      data.length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF;
  return bom && !text.startsWith('﻿') ? '﻿$text' : text;
}

List<Step> parseSteps(Tokens t) {
  final steps = <Step>[];
  while (!t.done) {
    final s = Step(t.word());
    switch (s.kind) {
      case 'bits' || 'bits64':
        s.width = t.dec();
        s.v = t.num();
      case 'bool':
        s.b = t.dec() == 1;
      case 'uint8' ||
          'uint16' ||
          'uint32' ||
          'uint64' ||
          'uint128' ||
          'float' ||
          'double':
        s.v = t.num();
      case 'int' || 'int64' || 'int128':
        s.min = t.num();
        s.max = t.num();
        s.v = t.num();
      case 'fixed64' || 'fixed128':
        s.ib = t.dec();
        s.fb = t.dec();
        s.min = t.num();
        s.max = t.num();
        s.v = t.num();
      case 'int_relative':
        s.prev = signed32(t.num().lo);
        s.v = t.num();
      case 'cfloat':
        s.fmin = doubleFromFloat32Bits(t.num().lo);
        s.fmax = doubleFromFloat32Bits(t.num().lo);
        s.fres = doubleFromFloat32Bits(t.num().lo);
        s.v = t.num();
      case 'bytes':
        s.data = t.bytes();
      case 'string':
        s.width = t.dec();
        s.data = t.bytes();
      case 'align' || 'end':
        break;
      case 'object':
        s.width = t.dec();
      default:
        throw FormatException('driver: no step kind ${s.kind}');
    }
    steps.add(s);
  }
  return steps;
}

// ---------------------------------------------------------------------------
// rendering (lowercase hex)

String hex16(int x) =>
    (x >>> 32).toRadixString(16).padLeft(8, '0') +
    (x & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');

String n128(int hi, int lo) => hex16(hi) + hex16(lo);

String unsignedN(int v) => n128(0, v);

String signedN(int v) => n128(v < 0 ? -1 : 0, v);

String xOf(List<int> b) {
  final out = StringBuffer('x');
  for (final c in b) {
    out.write(c.toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}

// ---------------------------------------------------------------------------
// one step on any stream: the holder carries the program's value on a write;
// on a read it starts at a sentinel that a refusal must leave in place

const int sentinel = 0x5a5a5a5a;
const double sentinelF = 1234.5;
const String sentinelS = 'sentinel';
final Int128 sentinel128 = Int128(sentinel, sentinel);
final UInt128 sentinelU128 = UInt128(sentinel, sentinel);

final class Run {
  final List<Step> steps;
  final List<String> vals;
  int? failed;
  bool touched = false;

  Run(this.steps) : vals = List<String>.filled(steps.length, '-');
}

bool runOne(BitStream stream, Step s, int i, Run st) {
  final w = stream.isWriting;
  bool ok;
  String out = '-';
  bool untouched = true;
  switch (s.kind) {
    case 'bits' ||
        'bits64' ||
        'uint8' ||
        'uint16' ||
        'uint32' ||
        'uint64' ||
        'int' ||
        'int64' ||
        'fixed64' ||
        'int_relative':
      final signed = s.kind == 'int' || s.kind == 'int_relative';
      final h = Ref<int>(w ? (signed ? signed32(s.v.lo) : s.v.lo) : sentinel);
      ok = switch (s.kind) {
        'bits' => stream.serializeBits(h, s.width),
        'bits64' => stream.serializeBits64(h, s.width),
        'uint8' => stream.serializeUint8(h),
        'uint16' => stream.serializeUint16(h),
        'uint32' => stream.serializeUint32(h),
        'uint64' => stream.serializeUint64(h),
        'int' => stream.serializeInt(h, signed32(s.min.lo), signed32(s.max.lo)),
        'int64' => stream.serializeInt64(h, s.min.lo, s.max.lo),
        'fixed64' => stream.serializeFixed(h, s.ib, s.fb, s.min.lo, s.max.lo),
        _ => stream.serializeIntRelative(s.prev, h),
      };
      final isSigned = signed || s.kind == 'int64' || s.kind == 'fixed64';
      out = isSigned ? signedN(h.value) : unsignedN(h.value);
      untouched = h.value == sentinel;
    case 'bool':
      // a bool holder has no value to spare for a sentinel
      final h = Ref<bool>(w && s.b);
      ok = stream.serializeBool(h);
      out = h.value ? '1' : '0';
    case 'uint128':
      final h = Ref<UInt128>(w ? s.v : sentinelU128);
      ok = stream.serializeUint128(h);
      out = n128(h.value.hi, h.value.lo);
      untouched = h.value == sentinelU128;
    case 'int128' || 'fixed128':
      final h = Ref<Int128>(w ? s.v.toSigned() : sentinel128);
      ok = s.kind == 'int128'
          ? stream.serializeInt128(h, s.min.toSigned(), s.max.toSigned())
          : stream.serializeFixed128(h, s.ib, s.fb, s.min.lo, s.max.lo);
      out = n128(h.value.hi, h.value.lo);
      untouched = h.value == sentinel128;
    case 'float' || 'cfloat':
      final h = Ref<double>(w ? doubleFromFloat32Bits(s.v.lo) : sentinelF);
      ok = s.kind == 'float'
          ? stream.serializeFloat(h)
          : stream.serializeCompressedFloat(h, s.fmin, s.fmax, s.fres);
      out = unsignedN(float32BitsFromDouble(h.value));
      untouched = h.value == sentinelF;
    case 'double':
      final h = Ref<double>(w ? doubleFromFloat64Bits(s.v.lo) : sentinelF);
      ok = stream.serializeDouble(h);
      out = unsignedN(float64BitsFromDouble(h.value));
      untouched = h.value == sentinelF;
    case 'bytes':
      final data = w
          ? Uint8List.fromList(s.data)
          : (Uint8List(s.data.length)..fillRange(0, s.data.length, 0xa5));
      ok = stream.serializeBytes(data);
      out = xOf(data);
      untouched = data.every((c) => c == 0xa5);
    case 'string':
      final h = Ref<String>(w ? textOf(s.data) : sentinelS);
      ok = stream.serializeString(h, s.width);
      out = xOf(utf8.encode(h.value));
      untouched = h.value == sentinelS;
    case 'align':
      ok = stream.serializeAlign();
    case 'end':
      ok = stream.serializeEnd();
    default:
      throw FormatException('driver: no runner for ${s.kind}');
  }
  if (ok) {
    st.vals[i] = out;
  } else if (!w && !untouched) {
    st.touched = true;
  }
  return ok;
}

final class Nested implements Serializable {
  final Run st;
  final int from;
  final int to;

  Nested(this.st, this.from, this.to);

  @override
  bool serialize(BitStream stream) => runSteps(stream, st, from, to) == to;
}

// the steps [from, to) in order on one stream; returns the index of the
// first refusing step (st.failed), or `to` (STANDARD.md object: a nested
// object's steps run inline, no bytes of its own)
int runSteps(BitStream stream, Run st, int from, int to) {
  var i = from;
  while (i < to) {
    final s = st.steps[i];
    if (s.kind == 'object') {
      st.vals[i] = '-';
      if (!stream.serializeObject(Nested(st, i + 1, i + 1 + s.width))) {
        st.failed ??= i;
        return i;
      }
      i += 1 + s.width;
      continue;
    }
    if (!runOne(stream, s, i, st)) {
      st.failed ??= i;
      return i;
    }
    i++;
  }
  return to;
}

// ---------------------------------------------------------------------------
// the requests

void answer(StringBuffer out, String line) {
  final t = Tokens(line.split(' ').where((w) => w.isNotEmpty).toList());
  final op = t.word();
  final id = t.word();
  if (op == 'w') {
    final capacity = t.dec();
    final steps = parseSteps(t);
    final st = Run(steps);
    final ws = WriteStream(Uint8List(capacity));
    if (runSteps(ws, st, 0, steps.length) != steps.length) {
      // a WriteStream refuses nothing (writes are trusted): a false return
      // here is a defect of its own, reported as such
      out.writeln('$id w refused ${st.failed} write_returned_false');
      return;
    }
    ws.flush();
    final ms = MeasureStream();
    final mt = Run(steps);
    runSteps(ms, mt, 0, steps.length);
    out.writeln(
      '$id w ok ${ws.bitsProcessed} ${ms.bitsProcessed} ${xOf(ws.data())}',
    );
  } else if (op == 'r') {
    final data = t.bytes();
    final steps = parseSteps(t);
    final st = Run(steps);
    final rs = ReadStream(data);
    final stop = runSteps(rs, st, 0, steps.length);
    var n = steps.length;
    if (stop == steps.length) {
      out.write('$id r ok ${rs.bitsProcessed}');
    } else {
      n = st.failed!;
      final kind = rs.refusal?.name ?? 'none';
      out.write('$id r refused $n ${st.touched ? 'touched:$kind' : kind}');
    }
    for (var j = 0; j < n; j++) {
      out.write(' ${st.vals[j]}');
    }
    out.writeln();
  } else {
    throw FormatException('driver: no request $op');
  }
}

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: driver <batch file>');
    exitCode = 2;
    return;
  }
  final out = StringBuffer();
  var count = 0;
  for (final line in File(args[0]).readAsLinesSync()) {
    if (line.isEmpty) {
      continue;
    }
    answer(out, line);
    count++;
  }
  out.writeln('done $count');
  stdout.write(out.toString());
}
