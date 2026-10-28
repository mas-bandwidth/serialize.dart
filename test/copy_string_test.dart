// copyString: the reference's serialize_copy_string (IMPLEMENTING.md U15,
// ruling 2026-10-27). Dart strings are UTF-16, so destSize counts the bytes
// of the strict UTF-8 encoding, and a source the strict codec refuses (a
// lone surrogate) is write misuse, trapped by assert in the checked build.
// The two ill-formed byte vectors of the reference's test_copy_string cannot
// be held by a Dart String and are skipped, as the ruling allows.

import 'dart:convert';
import 'dart:typed_data';

import 'package:serialize/serialize.dart';

import 'harness.dart';

String _bytes(List<int> utf8Bytes) => utf8.decode(utf8Bytes);

void run() {
  test('U15 copyString: the reference vectors', () {
    final e = _bytes(const [0xC3, 0xA9]); // é
    final ee = '$e$e';
    final grin = _bytes(const [0x61, 0xF0, 0x9F, 0x98, 0x80]); // a😀
    final cases = <(String, int, String)>[
      ('abc', 8, 'abc'),
      ('a\u0000bc', 8, 'a'),
      ('abcdefghij', 4, 'abc'),
      (ee, 4, e),
      (ee, 3, e),
      (grin, 3, 'a'),
      (grin, 4, 'a'),
      (grin, 5, 'a'),
      (grin, 6, grin),
      ('abc', 1, ''),
    ];
    for (final (source, destSize, expected) in cases) {
      expectEquals(
        copyString(source, destSize),
        expected,
        'copyString(${utf8.encode(source)}, $destSize)',
      );
    }
  });

  test('U15 copyString: serializeString accepts every result', () {
    final sources = [
      'abc',
      'a\u0000bc',
      _bytes(const [0xC3, 0xA9, 0xC3, 0xA9]),
      _bytes(const [0x61, 0xF0, 0x9F, 0x98, 0x80]),
      'x' * 40,
    ];
    for (final source in sources) {
      for (var destSize = 1; destSize < 48; destSize++) {
        final copied = copyString(source, destSize);
        final writer = WriteStream(Uint8List(64));
        expect(
          writer.serializeString(Ref<String>(copied), destSize),
          'write "$copied" at $destSize',
        );
        writer.flush();
        final read = Ref<String>('');
        expect(
          ReadStream(writer.data()).serializeString(read, destSize),
          'read back at $destSize',
        );
        expectEquals(read.value, copied, 'round trip at $destSize');
      }
    }
  });

  test('U15 copyString: destSize below 1 and a lone surrogate trap', () {
    if (!assertsEnabled) {
      return;
    }
    expectThrows(() => copyString('abc', 0), 'destSize 0');
    expectThrows(() => copyString('abc', -1), 'destSize -1');
    expectThrows(() => copyString('a\uD800b', 8), 'a lone high surrogate');
    expectThrows(() => copyString('a\uDC00', 8), 'a lone low surrogate');
  });
}
