// The shared conformance corpus, run through this port's reader.
//
// conformance/ is a VERBATIM VENDORED COPY of the corpus in
// mas-bandwidth/serialize, synced by the spec-sync CI job the way STANDARD.md
// is. The vector format is specified in STANDARD.md, "The vector format":
// records separated by blank lines, `#` comments, and the keys operation,
// name, param, bytes, expect and consumed.
//
// This suite reads those files and drives the reader with them. It never
// regenerates an expectation: a suite that writes its own vectors and reads
// them back proves only that the port agrees with itself, which is how one
// wrong reading of the standard travels to nine implementations under green
// results. Accepted vectors must yield the stated value and consume the
// stated number of bits; refused vectors must refuse.

import 'dart:io';
import 'dart:typed_data';

import 'package:serialize/serialize.dart';

import 'harness.dart';

/// One record of a vector file.
final class _Vector {
  final String operation;
  final String name;
  final Map<String, String> params;
  final Uint8List bytes;

  /// Null when the vector expects a refusal.
  final String? expectedValue;

  /// Bits a conforming reader consumes; stated on accepted reads only.
  final int? consumed;

  _Vector({
    required this.operation,
    required this.name,
    required this.params,
    required this.bytes,
    required this.expectedValue,
    required this.consumed,
  });

  bool get refused => expectedValue == null;
}

/// Parses one vector file. Anything the format does not define is a hard
/// error: a vector silently skipped is a rule silently unenforced.
List<_Vector> _parse(String text, String path) {
  final vectors = <_Vector>[];
  String? operation;
  String? name;
  var params = <String, String>{};
  var bytes = Uint8List(0);
  String? expectedValue;
  int? consumed;
  var open = false;

  void flush() {
    if (!open) {
      return;
    }
    if (operation == null || name == null) {
      throw FormatException('$path: a record without an operation or a name');
    }
    vectors.add(
      _Vector(
        operation: operation!,
        name: name!,
        params: params,
        bytes: bytes,
        expectedValue: expectedValue,
        consumed: consumed,
      ),
    );
    operation = null;
    name = null;
    params = <String, String>{};
    bytes = Uint8List(0);
    expectedValue = null;
    consumed = null;
    open = false;
  }

  for (final rawLine in text.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) {
      flush();
      continue;
    }
    if (line.startsWith('#')) {
      continue;
    }
    final space = line.indexOf(' ');
    final key = space < 0 ? line : line.substring(0, space);
    final rest = space < 0 ? '' : line.substring(space + 1).trim();
    open = true;
    switch (key) {
      case 'operation':
        operation = rest;
      case 'name':
        name = rest;
      case 'param':
        final equals = rest.indexOf('=');
        if (equals < 0) {
          throw FormatException('$path: param without "=": $rest');
        }
        params[rest.substring(0, equals).trim()] = rest
            .substring(equals + 1)
            .trim();
      case 'bytes':
        final pairs = rest.split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
        bytes = Uint8List.fromList([
          for (final pair in pairs) int.parse(pair, radix: 16),
        ]);
      case 'expect':
        if (rest == 'refused') {
          expectedValue = null;
        } else if (rest.startsWith('value =')) {
          expectedValue = rest.substring('value ='.length).trim();
        } else {
          throw FormatException('$path: unrecognized expect: $rest');
        }
      case 'consumed':
        consumed = int.parse(rest);
      default:
        throw FormatException('$path: unrecognized key: $key');
    }
  }
  flush();
  return vectors;
}

/// The outcome of driving one vector through the reader: whether the read was
/// accepted, the decoded value rendered as the corpus renders it, and the
/// bits consumed.
final class _Outcome {
  final bool accepted;
  final String value;
  final int consumed;

  _Outcome(this.accepted, this.value, this.consumed);
}

/// Decimal rendering of a 128-bit two's complement pattern, matching the
/// corpus, which states int128 values in decimal.
String _decimal(Int128 value) {
  final unsigned = value.toUnsigned();
  var magnitude =
      (BigInt.from(unsigned.hi).toUnsigned(64) << 64) |
      BigInt.from(unsigned.lo).toUnsigned(64);
  if (magnitude >= BigInt.one << 127) {
    magnitude -= BigInt.one << 128;
  }
  return magnitude.toString();
}

/// Parses a decimal 128-bit value from the corpus into the pair type.
Int128 _int128(String text) {
  var magnitude = BigInt.parse(text);
  if (magnitude.isNegative) {
    magnitude += BigInt.one << 128;
  }
  final mask = (BigInt.one << 64) - BigInt.one;
  return UInt128(
    (magnitude >> 64).toSigned(64).toInt(),
    (magnitude & mask).toSigned(64).toInt(),
  ).toSigned();
}

String _param(_Vector vector, String key) {
  final value = vector.params[key];
  if (value == null) {
    throw FormatException('${vector.name}: missing param $key');
  }
  return value;
}

_Outcome _run(_Vector vector) {
  final stream = ReadStream(vector.bytes);
  switch (vector.operation) {
    case 'int_relative':
      final previous = int.parse(_param(vector, 'previous'));
      final current = Ref<int>(_sentinel);
      final accepted = stream.serializeIntRelative(previous, current);
      if (!accepted && current.value != _sentinel) {
        throw StateError('${vector.name}: refused read wrote its destination');
      }
      return _Outcome(accepted, '${current.value}', stream.bitsProcessed);
    case 'int128':
      final min = _int128(_param(vector, 'min'));
      final max = _int128(_param(vector, 'max'));
      final value = Ref<Int128>(_sentinel128);
      final accepted = stream.serializeInt128(value, min, max);
      if (!accepted && value.value != _sentinel128) {
        throw StateError('${vector.name}: refused read wrote its destination');
      }
      return _Outcome(accepted, _decimal(value.value), stream.bitsProcessed);
    default:
      throw FormatException('no driver for operation ${vector.operation}');
  }
}

// Destination values no vector decodes to, so "untouched" is observable.
const int _sentinel = -424242;
final Int128 _sentinel128 = Int128.fromInt(-424242);

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

  final files =
      directory
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.txt'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  test('conformance: the corpus holds vectors', () {
    expect(files.isNotEmpty, 'conformance/ holds no vector files');
  });

  for (final file in files) {
    test('conformance: ${file.uri.pathSegments.last}', () {
      final vectors = _parse(file.readAsStringSync(), file.path);
      expect(vectors.isNotEmpty, '${file.path} holds no vectors');
      for (final vector in vectors) {
        final outcome = _run(vector);
        if (vector.refused) {
          expect(!outcome.accepted, '${vector.name}: must be refused');
          // after a refusal the stream position is not part of the contract,
          // so nothing here is judged on it
          continue;
        }
        expect(outcome.accepted, '${vector.name}: must be accepted');
        if (!outcome.accepted) {
          continue;
        }
        expectEquals(outcome.value, vector.expectedValue, '${vector.name}');
        expectEquals(
          outcome.consumed,
          vector.consumed,
          '${vector.name}: bits consumed',
        );
      }
    });
  }
}

/// Runs this suite on its own — `dart run test/conformance_test.dart` — so the
/// interop job can hold this reader and the pinned C++ reader to the same
/// corpus in one place. test/all.dart calls [run] directly.
void main() {
  run();
  exit(summarize() > 0 ? 1 : 0);
}
