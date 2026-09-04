// The shared conformance corpus, run through this port's reader, writer and
// measure.
//
// conformance/ is a VERBATIM VENDORED COPY of the corpus in
// mas-bandwidth/serialize, synced by the spec-sync CI job the way STANDARD.md
// is. The vector format is specified in STANDARD.md, "The vector format".
//
// It is the conformance instrument the whole family runs, and it is
// deliberately not generated from this code: a suite that regenerates its own
// expectations proves only that a port agrees with itself, which is how one
// wrong reading of the standard travels to nine implementations under green
// results.
//
// A RUNNER DISCOVERS THE DIRECTORY. It does not name the files, so a newly
// vendored vector file runs here without anyone editing a list. An empty
// directory fails the run, a file with no vectors fails, and a vector whose
// operation, parameter or fixed point declaration this runner cannot drive
// FAILS rather than being skipped: an operation nobody implemented must be red.
//
// ONE STEP MACHINE drives both the single operation files and the sequence,
// object and message files. A single operation vector is a one or two step
// sequence built from the record's own parameters, so the sequence files cannot
// drift away from the operation files.
//
// NUMERIC COMPARISON IS BY 128-BIT TWO'S COMPLEMENT PATTERN, never through a
// double. Every integer width, and the float, double and compressed_float bit
// patterns, compare as patterns, so a hexadecimal expectation and its decimal
// twin are one expectation. STANDARD.md requires it: NaN compares unequal to
// itself, -0.0 == 0.0, and no tolerance comparison can see a quieted signaling
// bit. The remaining kinds have textual spellings the corpus states directly.
//
// THE BUFFER CONTRACT. This reader requires no slack past the data, so the
// stream it is handed is a view of exactly the vector's bytes. The view sits
// over a longer array filled with a non-zero pattern, so a decode that strayed
// past the end would read 0xA5 rather than zeros.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:serialize/serialize.dart';

import 'harness.dart';

// Non-zero, so a read that strayed past the end of a stream is visible.
const int _slackFill = 0xA5;

// Destination sentinels. They must survive the narrowing this runner performs
// on the way to each operation's own width — 32 bits for float and for the
// ranged int — or a destination the library correctly left alone still reads
// as written.
final BigInt _sentinelPattern = BigInt.from(0xCAFEF00D);
final BigInt _sentinelNumber = BigInt.from(-1234567).toUnsigned(128);

// ---------------------------------------------------------------------------
// numbers
// ---------------------------------------------------------------------------

final RegExp _decimalDigits = RegExp(r'^[0-9]+$');
final RegExp _hexDigits = RegExp(r'^[0-9a-fA-F]+$');

/// Parses a corpus number — signed decimal or `0x` hexadecimal, up to 128 bits
/// wide — into its 128-bit two's complement pattern. Null when the text is not
/// a number: the sign is applied in the unsigned domain, so both extremes of
/// the 128-bit range land where they should.
BigInt? _parseNumber(String text) {
  var body = text;
  var negative = false;
  if (body.startsWith('-')) {
    negative = true;
    body = body.substring(1);
  } else if (body.startsWith('+')) {
    body = body.substring(1);
  }
  BigInt magnitude;
  if (body.startsWith('0x') || body.startsWith('0X')) {
    final digits = body.substring(2);
    if (!_hexDigits.hasMatch(digits)) {
      return null;
    }
    magnitude = BigInt.parse(digits, radix: 16);
  } else {
    if (!_decimalDigits.hasMatch(body)) {
      return null;
    }
    magnitude = BigInt.parse(body);
  }
  return (negative ? -magnitude : magnitude).toUnsigned(128);
}

/// The signed 64-bit value of a BigInt, exactly: [BigInt.toInt] clamps rather
/// than truncating, so the value is reduced to 64 bits first.
int _int64(BigInt value) => value.toSigned(64).toInt();

/// A Dart int as a 128-bit pattern, sign extended.
BigInt _pattern64(int value) => BigInt.from(value).toUnsigned(128);

/// A Dart int as a 128-bit pattern, zero extended: the spelling for a raw bit
/// field, whose value is unsigned however the 64-bit int holds it.
BigInt _patternUnsigned64(int value) => BigInt.from(value).toUnsigned(64);

final BigInt _low64 = (BigInt.one << 64) - BigInt.one;

UInt128 _toUInt128(BigInt pattern) => UInt128(
  (pattern >> 64).toSigned(64).toInt(),
  (pattern & _low64).toSigned(64).toInt(),
);

BigInt _fromUInt128(UInt128 value) =>
    (BigInt.from(value.hi).toUnsigned(64) << 64) |
    BigInt.from(value.lo).toUnsigned(64);

String _hex128(BigInt pattern) =>
    '0x${pattern.toUnsigned(128).toRadixString(16).toUpperCase().padLeft(32, '0')}';

String _hexBytes(List<int> bytes) => [
  for (final byte in bytes)
    byte.toRadixString(16).toUpperCase().padLeft(2, '0'),
].join(' ');

String _hexUnits(String text) => [
  for (final unit in text.codeUnits)
    unit.toRadixString(16).toUpperCase().padLeft(4, '0'),
].join(' ');

// ---------------------------------------------------------------------------
// the vector record
// ---------------------------------------------------------------------------

/// One record of a vector file, exactly the keys STANDARD.md defines.
final class _Vector {
  _Vector(this.file);

  final String file;
  String operation = '';
  String name = '';
  final List<MapEntry<String, String>> params = [];
  final List<String> steps = [];
  Uint8List bytes = Uint8List(0);
  bool refused = false;
  String expect = '';
  int? consumed;
  int? measureAtLeast;
  bool writerCanonical = false;

  bool get isEmpty => operation.isEmpty;

  String? param(String name) {
    for (final entry in params) {
      if (entry.key == name) {
        return entry.value;
      }
    }
    return null;
  }
}

/// Which operation takes which parameter. A parameter this runner does not
/// understand is a failure rather than a silent default: a vector whose
/// declaration is not the one being exercised proves nothing.
bool _operationTakesParam(String operation, String name) => switch (name) {
  'step' => operation == 'sequence',
  'preceding_bits' => operation == 'align' || operation == 'bytes',
  'bits' => operation == 'bits',
  'count' => operation == 'bytes',
  'buffer_size' => operation == 'string' || operation == 'wstring',
  'previous' => operation == 'int_relative',
  'res' => operation == 'compressed_float',
  'integer_bits' || 'fraction_bits' => operation == 'fixed',
  'min' || 'max' =>
    operation == 'int' ||
        operation == 'int64' ||
        operation == 'int128' ||
        operation == 'fixed' ||
        operation == 'compressed_float',
  _ => false,
};

// ---------------------------------------------------------------------------
// the step machine
// ---------------------------------------------------------------------------

enum _Kind {
  bits,
  boolean,
  uint128,
  align,
  ranged32,
  ranged64,
  ranged128,
  intRelative,
  float32,
  float64,
  compressedFloat,
  bytes,
  string,
  wstring,
  fixed,
  object,
}

bool _isBitPattern(_Kind kind) =>
    kind == _Kind.bits ||
    kind == _Kind.uint128 ||
    kind == _Kind.float32 ||
    kind == _Kind.float64 ||
    kind == _Kind.compressedFloat;

bool _isNumber(_Kind kind) =>
    kind == _Kind.ranged32 ||
    kind == _Kind.ranged64 ||
    kind == _Kind.ranged128 ||
    kind == _Kind.intRelative ||
    kind == _Kind.fixed;

final class _Step {
  _Step(this.kind);

  final _Kind kind;

  /// Bits, count, buffer_size, or the number of steps an object wraps.
  int width = 0;
  BigInt min = BigInt.zero;
  BigInt max = BigInt.zero;
  double fmin = 0;
  double fmax = 0;
  double fres = 0;
  int integerBits = 0;
  int fractionBits = 0;
  int previous = 0;

  // The destinations. The caller seeds them and inspects them afterwards for
  // the scalar kinds, which is exactly how far "a refused primitive read must
  // leave its destination unwritten" reaches: STANDARD.md leaves a caller
  // owned buffer unspecified after a refusal, so bytes, string and wstring
  // are not checked.
  BigInt pattern = BigInt.zero;
  BigInt number = BigInt.zero;
  bool boolean = true;
  Uint8List buffer = Uint8List(0);
  String text = '';
}

/// Runs one step against any stream. The step's destination fields carry the
/// value in and the value out, so the reader leg leaves behind exactly what
/// the writer and the measure legs are handed.
bool _runStep(BitStream stream, _Step step) {
  switch (step.kind) {
    case _Kind.bits:
      final value = Ref<int>(_int64(step.pattern));
      final ok = step.width <= 32
          ? stream.serializeBits(value, step.width)
          : stream.serializeBits64(value, step.width);
      step.pattern = _patternUnsigned64(value.value);
      return ok;

    case _Kind.boolean:
      final value = Ref<bool>(step.boolean);
      final ok = stream.serializeBool(value);
      step.boolean = value.value;
      return ok;

    case _Kind.uint128:
      final value = Ref<UInt128>(_toUInt128(step.pattern));
      final ok = stream.serializeUint128(value);
      step.pattern = _fromUInt128(value.value);
      return ok;

    case _Kind.align:
      return stream.serializeAlign();

    case _Kind.ranged32:
      final value = Ref<int>(_int64(step.number));
      final ok = stream.serializeInt(value, _int64(step.min), _int64(step.max));
      step.number = _pattern64(value.value);
      return ok;

    case _Kind.ranged64:
      final value = Ref<int>(_int64(step.number));
      final ok = stream.serializeInt64(
        value,
        _int64(step.min),
        _int64(step.max),
      );
      step.number = _pattern64(value.value);
      return ok;

    case _Kind.ranged128:
      final value = Ref<Int128>(_toUInt128(step.number).toSigned());
      final ok = stream.serializeInt128(
        value,
        _toUInt128(step.min).toSigned(),
        _toUInt128(step.max).toSigned(),
      );
      step.number = _fromUInt128(value.value.toUnsigned());
      return ok;

    case _Kind.intRelative:
      final value = Ref<int>(_int64(step.number));
      final ok = stream.serializeIntRelative(step.previous, value);
      step.number = _pattern64(value.value);
      return ok;

    case _Kind.float32:
      final value = Ref<double>(doubleFromFloat32Bits(_int64(step.pattern)));
      final ok = stream.serializeFloat(value);
      step.pattern = _patternUnsigned64(float32BitsFromDouble(value.value));
      return ok;

    case _Kind.float64:
      final value = Ref<double>(doubleFromFloat64Bits(_int64(step.pattern)));
      final ok = stream.serializeDouble(value);
      step.pattern = _patternUnsigned64(float64BitsFromDouble(value.value));
      return ok;

    case _Kind.compressedFloat:
      final value = Ref<double>(doubleFromFloat32Bits(_int64(step.pattern)));
      final ok = stream.serializeCompressedFloat(
        value,
        step.fmin,
        step.fmax,
        step.fres,
      );
      step.pattern = _patternUnsigned64(float32BitsFromDouble(value.value));
      return ok;

    case _Kind.bytes:
      if (step.buffer.length != step.width) {
        step.buffer = Uint8List(step.width);
      }
      return stream.serializeBytes(step.buffer);

    case _Kind.string:
      final value = Ref<String>(step.text);
      final ok = stream.serializeString(value, step.width);
      step.text = value.value;
      return ok;

    case _Kind.wstring:
      final value = Ref<String>(step.text);
      final ok = stream.serializeWideString(value, step.width);
      step.text = value.value;
      return ok;

    case _Kind.fixed:
      if (step.integerBits + step.fractionBits == 128) {
        final value = Ref<Int128>(_toUInt128(step.number).toSigned());
        final ok = stream.serializeFixed128(
          value,
          step.integerBits,
          step.fractionBits,
          _int64(step.min),
          _int64(step.max),
        );
        step.number = _fromUInt128(value.value.toUnsigned());
        return ok;
      }
      final value = Ref<int>(_int64(step.number));
      final ok = stream.serializeFixed(
        value,
        step.integerBits,
        step.fractionBits,
        _int64(step.min),
        _int64(step.max),
      );
      step.number = _pattern64(value.value);
      return ok;

    case _Kind.object:
      // nesting is driven by _runSteps, which owns the step range an object
      // wraps; a bare object step reaching here is a runner bug
      return false;
  }
}

/// Where a run stopped: the top level index of the step or object that
/// refused, and the innermost step whose destination the refusal must not
/// have written.
final class _Run {
  int stoppedAt = -1;
  _Step? failedStep;
}

/// Advances past the steps a nested object owns, so a top level walk sees one
/// step per object.
int _stepSpan(List<_Step> steps, int index) =>
    steps[index].kind == _Kind.object ? 1 + steps[index].width : 1;

/// The [Serializable] a `object <n>` step wraps its successors in. The nested
/// steps go through the stream's own serializeObject, so what the vectors
/// exercise is the composition the library performs.
final class _NestedObject implements Serializable {
  _NestedObject(this.steps, this.start, this.end, this.run);

  final List<_Step> steps;
  final int start;
  final int end;
  final _Run run;

  @override
  bool serialize(BitStream stream) => _runSteps(stream, steps, start, end, run);
}

bool _runSteps(
  BitStream stream,
  List<_Step> steps,
  int start,
  int end,
  _Run run,
) {
  for (var i = start; i < end; i += _stepSpan(steps, i)) {
    if (steps[i].kind == _Kind.object) {
      final object = _NestedObject(steps, i + 1, i + 1 + steps[i].width, run);
      if (!stream.serializeObject(object)) {
        run.stoppedAt = i; // the object is one step of the enclosing walk
        return false;
      }
      continue;
    }
    if (!_runStep(stream, steps[i])) {
      run.failedStep = steps[i];
      run.stoppedAt = i;
      return false;
    }
  }
  return true;
}

// ---------------------------------------------------------------------------
// building steps
// ---------------------------------------------------------------------------

/// The legal fixed point storage widths (STANDARD.md, "fixed"). Dart takes the
/// four parameters at runtime, so this runner carries no table of compile time
/// declarations: what it must still refuse is a declaration the format does not
/// define.
bool _fixedDeclarationIsLegal(int integerBits, int fractionBits) {
  const widths = [8, 16, 32, 64, 128];
  return integerBits >= 1 &&
      fractionBits >= 0 &&
      widths.contains(integerBits + fractionBits);
}

/// Parses one `param step = ` spelling, from the head of conformance/
/// sequence.txt and conformance/object.txt. Null when the runner has no step
/// for it.
_Step? _stepFromWords(String text) {
  final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) {
    return null;
  }
  BigInt? number(int index) => _parseNumber(words[index]);

  switch (words[0]) {
    case 'bits' when words.length == 2 && number(1) != null:
      return _Step(_Kind.bits)..width = _int64(number(1)!);
    case 'bool' when words.length == 1:
      return _Step(_Kind.boolean);
    case 'object' when words.length == 2 && number(1) != null:
      return _Step(_Kind.object)..width = _int64(number(1)!);
    case 'align' when words.length == 1:
      return _Step(_Kind.align);
    case 'float' when words.length == 1:
      return _Step(_Kind.float32);
    case 'double' when words.length == 1:
      return _Step(_Kind.float64);
    case 'uint128' when words.length == 1:
      return _Step(_Kind.uint128);
    case 'int_relative' when words.length == 2 && number(1) != null:
      return _Step(_Kind.intRelative)..previous = _int64(number(1)!);
    case 'compressed_float' when words.length == 4:
      final fmin = double.tryParse(words[1]);
      final fmax = double.tryParse(words[2]);
      final fres = double.tryParse(words[3]);
      if (fmin == null || fmax == null || fres == null) {
        return null;
      }
      return _Step(_Kind.compressedFloat)
        ..fmin = fmin
        ..fmax = fmax
        ..fres = fres;
    case 'bytes' when words.length == 2 && number(1) != null:
      return _Step(_Kind.bytes)..width = _int64(number(1)!);
    case 'string' when words.length == 2 && number(1) != null:
      return _Step(_Kind.string)..width = _int64(number(1)!);
    case 'wstring' when words.length == 2 && number(1) != null:
      return _Step(_Kind.wstring)..width = _int64(number(1)!);
    case 'int' || 'int64' || 'int128'
        when words.length == 3 && number(1) != null && number(2) != null:
      return _Step(switch (words[0]) {
          'int' => _Kind.ranged32,
          'int64' => _Kind.ranged64,
          _ => _Kind.ranged128,
        })
        ..min = number(1)!
        ..max = number(2)!;
    case 'fixed' when words.length == 5:
      final integerBits = number(1);
      final fractionBits = number(2);
      final min = number(3);
      final max = number(4);
      if (integerBits == null ||
          fractionBits == null ||
          min == null ||
          max == null) {
        return null;
      }
      if (!_fixedDeclarationIsLegal(
        _int64(integerBits),
        _int64(fractionBits),
      )) {
        return null;
      }
      return _Step(_Kind.fixed)
        ..integerBits = _int64(integerBits)
        ..fractionBits = _int64(fractionBits)
        ..min = min
        ..max = max;
    default:
      return null;
  }
}

/// Builds the step list for a vector. A single operation vector becomes a one
/// or two step sequence: the operations whose interesting behavior only exists
/// at a non-zero bit index take a `preceding_bits` parameter, which becomes a
/// leading bits step. Null when this runner cannot drive the record.
List<_Step>? _buildSteps(_Vector vector) {
  if (vector.operation == 'sequence') {
    final steps = <_Step>[];
    for (final text in vector.steps) {
      final step = _stepFromWords(text);
      if (step == null) {
        return null;
      }
      steps.add(step);
    }
    return steps.isEmpty ? null : steps;
  }

  final steps = <_Step>[];
  final precedingBits = vector.param('preceding_bits');
  if (precedingBits != null) {
    final width = _parseNumber(precedingBits);
    if (width == null) {
      return null;
    }
    if (_int64(width) > 0) {
      steps.add(_Step(_Kind.bits)..width = _int64(width));
    }
  }

  BigInt? number(String name) {
    final text = vector.param(name);
    return text == null ? null : _parseNumber(text);
  }

  double? real(String name) {
    final text = vector.param(name);
    return text == null ? null : double.tryParse(text);
  }

  _Step? step;
  switch (vector.operation) {
    case 'bits':
      final width = number('bits');
      if (width == null) {
        return null;
      }
      step = _Step(_Kind.bits)..width = _int64(width);
    case 'bool':
      step = _Step(_Kind.boolean);
    case 'uint128':
      step = _Step(_Kind.uint128);
    case 'align':
      step = _Step(_Kind.align);
    case 'int' || 'int64' || 'int128':
      final min = number('min');
      final max = number('max');
      if (min == null || max == null) {
        return null;
      }
      step =
          _Step(switch (vector.operation) {
              'int' => _Kind.ranged32,
              'int64' => _Kind.ranged64,
              _ => _Kind.ranged128,
            })
            ..min = min
            ..max = max;
    case 'int_relative':
      final previous = number('previous');
      if (previous == null) {
        return null;
      }
      step = _Step(_Kind.intRelative)..previous = _int64(previous);
    case 'float':
      step = _Step(_Kind.float32);
    case 'double':
      step = _Step(_Kind.float64);
    case 'compressed_float':
      final min = real('min');
      final max = real('max');
      final res = real('res');
      if (min == null || max == null || res == null) {
        return null;
      }
      step = _Step(_Kind.compressedFloat)
        ..fmin = min
        ..fmax = max
        ..fres = res;
    case 'bytes':
      final count = number('count');
      if (count == null) {
        return null;
      }
      step = _Step(_Kind.bytes)..width = _int64(count);
    case 'string' || 'wstring':
      final bufferSize = number('buffer_size');
      if (bufferSize == null) {
        return null;
      }
      step = _Step(vector.operation == 'string' ? _Kind.string : _Kind.wstring)
        ..width = _int64(bufferSize);
    case 'fixed':
      final integerBits = number('integer_bits');
      final fractionBits = number('fraction_bits');
      final min = number('min');
      final max = number('max');
      if (integerBits == null ||
          fractionBits == null ||
          min == null ||
          max == null) {
        return null;
      }
      if (!_fixedDeclarationIsLegal(
        _int64(integerBits),
        _int64(fractionBits),
      )) {
        return null;
      }
      step = _Step(_Kind.fixed)
        ..integerBits = _int64(integerBits)
        ..fractionBits = _int64(fractionBits)
        ..min = min
        ..max = max;
    default:
      return null;
  }

  steps.add(step);
  return steps;
}

// ---------------------------------------------------------------------------
// expectations
// ---------------------------------------------------------------------------

/// The step's decoded value as a 128-bit pattern, for the kinds the corpus
/// states numerically. Null for the kinds it states textually.
BigInt? _stepPattern(_Step step) {
  if (_isBitPattern(step.kind)) {
    return step.pattern;
  }
  if (_isNumber(step.kind)) {
    return step.number;
  }
  return null;
}

String _renderStep(_Step step) {
  final pattern = _stepPattern(step);
  if (pattern != null) {
    return _hex128(pattern);
  }
  return switch (step.kind) {
    // neither an object nor an align has a value of its own; for align the
    // corpus states the padding it consumed, which a conforming read always
    // finds zero
    _Kind.object || _Kind.align => '0',
    _Kind.boolean => step.boolean ? 'true' : 'false',
    _Kind.bytes => _hexBytes(step.buffer),
    _Kind.string => _hexBytes(utf8.encode(step.text)),
    _Kind.wstring => _hexUnits(step.text),
    _ => '?',
  };
}

bool _expectationMatches(_Step step, String expected) {
  final pattern = _stepPattern(step);
  if (pattern != null) {
    final wanted = _parseNumber(expected);
    return wanted != null && pattern.toUnsigned(128) == wanted;
  }
  return _renderStep(step) == expected;
}

// ---------------------------------------------------------------------------
// running one vector
// ---------------------------------------------------------------------------

int _failures = 0;
int _checked = 0;
int _writerChecked = 0;
int _measureChecked = 0;

void _fail(_Vector vector, String detail) {
  _failures++;
  expect(false, '${vector.name}: $detail [${vector.file}]');
}

/// The vector's bytes as a stream: a view of exactly that many bytes over an
/// array whose following bytes are a non-zero pattern, so a decode that
/// depended on memory past the end could not pass by reading zeros.
Uint8List _streamBytes(_Vector vector) {
  final backing = Uint8List(vector.bytes.length + 8)
    ..fillRange(0, vector.bytes.length + 8, _slackFill)
    ..setRange(0, vector.bytes.length, vector.bytes);
  return Uint8List.sublistView(backing, 0, vector.bytes.length);
}

/// Failure is terminal (STANDARD.md, "Reader Obligations"), checked by
/// behavior rather than by an accessor so the check ports everywhere: a
/// further read the vector does not name must fail, consume no bits and leave
/// its own destination alone.
void _failUnlessTerminal(_Vector vector, ReadStream stream) {
  final after = Ref<int>(0x77777777);
  final bitsBefore = stream.bitsProcessed;
  if (stream.serializeBits(after, 8)) {
    _fail(vector, 'the stream accepted a read after the refusal');
    return;
  }
  if (after.value != 0x77777777) {
    _fail(vector, 'the read after the refusal wrote to its destination');
    return;
  }
  if (stream.bitsProcessed != bitsBefore) {
    _fail(vector, 'the read after the refusal consumed bits');
  }
}

void _runReader(_Vector vector, List<_Step> steps) {
  final stream = ReadStream(_streamBytes(vector));

  for (final step in steps) {
    step.pattern = _sentinelPattern;
    step.number = _sentinelNumber;
    step.boolean = true; // a refused bool read must leave this alone
  }

  final run = _Run();
  final accepted = _runSteps(stream, steps, 0, steps.length, run);

  if (vector.refused) {
    if (accepted) {
      _fail(vector, 'the read succeeded, the corpus requires refusal');
      return;
    }

    final failed = run.failedStep;
    if (failed != null) {
      final wrote =
          (_isBitPattern(failed.kind) && failed.pattern != _sentinelPattern) ||
          (_isNumber(failed.kind) && failed.number != _sentinelNumber) ||
          (failed.kind == _Kind.boolean && !failed.boolean);
      if (wrote) {
        _fail(vector, 'the refused read wrote to the destination');
        return;
      }
    }

    // failure is terminal, and a sequence states its own successors: every
    // step after the failing one must fail too, however many readable bits
    // the stream still holds
    for (
      var i = run.stoppedAt + _stepSpan(steps, run.stoppedAt);
      i < steps.length;
      i += _stepSpan(steps, i)
    ) {
      if (_runSteps(stream, steps, i, i + _stepSpan(steps, i), _Run())) {
        _fail(
          vector,
          'step ${i + 1} succeeded after step ${run.stoppedAt + 1} was '
          'refused; failure must be terminal',
        );
        return;
      }
    }

    _failUnlessTerminal(vector, stream);
    return;
  }

  if (!accepted) {
    _fail(
      vector,
      'the read was refused, the corpus requires it to be accepted',
    );
    return;
  }

  final entries = vector.expect.split('|').map((e) => e.trim()).toList();

  // one expect entry per step, objects and aligns included, which state `-`. A
  // leading preceding_bits step carries no expectation of its own: it exists to
  // place the stream, and the record states only the operation under test.
  final offset = steps.length - entries.length;
  if (offset < 0) {
    _fail(
      vector,
      'the expect list states more values than the vector has steps',
    );
    return;
  }
  for (var i = 0; i < entries.length; i++) {
    if (entries[i] == '-') {
      continue;
    }
    if (!_expectationMatches(steps[offset + i], entries[i])) {
      _fail(
        vector,
        'step ${offset + i + 1} decoded ${_renderStep(steps[offset + i])}, '
        'the corpus states ${entries[i]}',
      );
      return;
    }
  }

  final consumed = vector.consumed;
  if (consumed != null && stream.bitsProcessed != consumed) {
    _fail(
      vector,
      'consumed ${stream.bitsProcessed} bits, the corpus states $consumed',
    );
  }
}

/// The writer leg. A vector marked `writer = canonical` states the bytes a
/// conforming writer emits for its value, so the runner writes the decoded
/// steps back and compares the WHOLE emitted stream, flush included. That is
/// where the trailing bits obligation bites: the unused bits of the final byte
/// must be zero, and a writer leaking anything into them produces a byte the
/// vector does not carry.
void _runWriter(_Vector vector, List<_Step> steps) {
  _writerChecked++;

  // the bit writer stores 8-byte words, so the buffer length is a multiple
  // of 8; the fill is non-zero so a byte the writer never touched shows up
  final capacity = (vector.bytes.length + 64) & ~7;
  final scratch = Uint8List(capacity)..fillRange(0, capacity, _slackFill);
  final stream = WriteStream(scratch);

  if (!_runSteps(stream, steps, 0, steps.length, _Run())) {
    _fail(vector, 'the writer refused a canonical vector');
    return;
  }
  stream.flush();

  final written = stream.data();
  if (written.length != vector.bytes.length) {
    _fail(
      vector,
      'the writer emitted ${written.length} bytes, the corpus states '
      '${vector.bytes.length}',
    );
    return;
  }
  for (var i = 0; i < written.length; i++) {
    if (written[i] != vector.bytes[i]) {
      _fail(
        vector,
        'the writer emitted ${_hexBytes(written)}, the corpus states '
        '${_hexBytes(vector.bytes)}',
      );
      return;
    }
  }
}

/// The measure leg. STANDARD.md makes a measure a BOUND and not the packet
/// size, so the corpus states a floor and the check is an inequality. A
/// measure that computes alignment from a running bit index starting at zero
/// under-counts every unaligned start and falls below the floor.
void _runMeasure(_Vector vector, List<_Step> steps) {
  _measureChecked++;

  final stream = MeasureStream();
  if (!_runSteps(stream, steps, 0, steps.length, _Run())) {
    _fail(vector, 'the measure refused a step; a measure refuses nothing');
    return;
  }

  final floor = vector.measureAtLeast!;
  if (stream.bitsProcessed < floor) {
    _fail(
      vector,
      'measured ${stream.bitsProcessed} bits, the corpus requires at least '
      '$floor',
    );
  }
}

void _runVector(_Vector vector) {
  _checked++;

  for (final entry in vector.params) {
    if (!_operationTakesParam(vector.operation, entry.key)) {
      _fail(
        vector,
        "no runner for parameter '${entry.key}' on operation "
        "'${vector.operation}'",
      );
      return;
    }
  }
  if (vector.steps.isNotEmpty && vector.operation != 'sequence') {
    _fail(vector, 'steps are only meaningful on a sequence');
    return;
  }

  final steps = _buildSteps(vector);
  if (steps == null) {
    // a corpus file this runner cannot drive is a gap in the runner, not a pass
    _fail(vector, 'no runner for this operation, or for one of its parameters');
    return;
  }

  final failuresBefore = _failures;
  _runReader(vector, steps);

  // the writer and the measure are handed the values the reader decoded, so
  // running them after a reader failure reports a second failure about a value
  // that was never decoded. One vector, one diagnosis.
  if (!vector.refused && _failures == failuresBefore) {
    if (vector.writerCanonical) {
      _runWriter(vector, steps);
    }
    if (vector.measureAtLeast != null) {
      _runMeasure(vector, steps);
    }
  }
}

// ---------------------------------------------------------------------------
// parsing a vector file
// ---------------------------------------------------------------------------

void _failFile(String path, String detail) {
  _failures++;
  expect(false, '$path: $detail');
}

int _runFile(File file) {
  final path = file.path;
  var vectors = 0;
  var vector = _Vector(path);

  void flush() {
    if (vector.isEmpty) {
      return;
    }
    vectors++;
    _runVector(vector);
    vector = _Vector(path);
  }

  for (final rawLine in file.readAsStringSync().split('\n')) {
    // a comment begins at the start of a line and nowhere else
    if (rawLine.startsWith('#')) {
      continue;
    }
    final line = rawLine.trim();
    if (line.isEmpty) {
      flush();
      continue;
    }
    final space = line.indexOf(' ');
    final key = space < 0 ? line : line.substring(0, space);
    final value = space < 0 ? '' : line.substring(space + 1).trim();

    switch (key) {
      case 'operation':
        vector.operation = value;
      case 'name':
        vector.name = value;
      case 'param':
        final equals = value.indexOf('=');
        if (equals < 0) {
          _failFile(path, 'malformed param line');
          continue;
        }
        final name = value.substring(0, equals).trim();
        final text = value.substring(equals + 1).trim();
        if (name == 'step') {
          vector.steps.add(text);
        } else {
          vector.params.add(MapEntry(name, text));
        }
      case 'bytes':
        final pairs = value.split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
        final bytes = <int>[];
        for (final pair in pairs) {
          final byte = pair.length == 2 ? int.tryParse(pair, radix: 16) : null;
          if (byte == null) {
            _failFile(path, 'malformed bytes line');
            break;
          }
          bytes.add(byte);
        }
        vector.bytes = Uint8List.fromList(bytes);
      case 'expect':
        if (value == 'refused') {
          vector.refused = true;
          continue;
        }
        final equals = value.indexOf('=');
        if (equals < 0) {
          _failFile(path, 'malformed expect line');
          continue;
        }
        final kind = value.substring(0, equals).trim();
        if (kind != 'value' && kind != 'bits') {
          _failFile(path, "unknown expect kind '$kind'");
          continue;
        }
        vector.expect = value.substring(equals + 1).trim();
      case 'consumed':
        vector.consumed = int.tryParse(value);
        if (vector.consumed == null) {
          _failFile(path, 'malformed consumed line');
        }
      case 'measure_at_least':
        vector.measureAtLeast = int.tryParse(value);
        if (vector.measureAtLeast == null) {
          _failFile(path, 'malformed measure_at_least line');
        }
      case 'writer':
        if (value != 'canonical') {
          _failFile(path, "unknown writer mode '$value'");
          continue;
        }
        vector.writerCanonical = true;
      default:
        _failFile(path, "unknown key '$key'");
    }
  }
  flush();
  return vectors;
}

// ---------------------------------------------------------------------------

void run() {
  final directory = Directory('conformance');
  test('conformance: the vendored corpus is present', () {
    expect(
      directory.existsSync(),
      'conformance/ is missing: it is vendored from mas-bandwidth/serialize',
    );
  });
  if (!directory.existsSync()) {
    return;
  }

  // the runner discovers the directory, it does not name the files: a newly
  // vendored vector file runs without anyone editing a list here
  final files =
      directory
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.txt'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  test('conformance: the corpus holds vector files', () {
    // an empty corpus is a broken checkout and not a pass
    expect(files.isNotEmpty, 'conformance/ holds no vector files');
  });

  for (final file in files) {
    test('conformance: ${file.uri.pathSegments.last}', () {
      final vectors = _runFile(file);
      expect(vectors > 0, '${file.path} holds no vectors');
    });
  }

  test('conformance: the corpus ran', () {
    expect(_checked > 0, 'no vectors ran: an empty run is a failure');
    print(
      '  $_checked vectors from ${files.length} files: '
      '$_writerChecked writer checks, $_measureChecked measure checks, '
      '$_failures failure(s)',
    );
  });
}

/// Runs this suite on its own — `dart run test/conformance_test.dart` — so the
/// interop job can hold this reader and the pinned C++ reader to the same
/// corpus in one place. test/all.dart calls [run] directly.
void main() {
  run();
  exit(summarize() > 0 ? 1 : 0);
}
