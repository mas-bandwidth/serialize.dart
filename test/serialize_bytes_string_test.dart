// serialize_bytes (aligns first, zero count still aligns) and the UTF-8
// string: accept paths, real text in every script round tripped byte for
// byte, buffer-size dependence, and every refusal rule with its reason —
// embedded NUL, invalid UTF-8, nonzero align padding, truncation — and the
// order where two of them meet. Hostile bytes never throw.

import 'dart:typed_data';

import 'package:serialize/serialize.dart';

import 'harness.dart';

void run() {
  test('serializeBytes: aligns first, then raw bytes', () {
    final payload = Uint8List.fromList(const [0xDE, 0xAD, 0xBE, 0xEF]);
    final writer = WriteStream(Uint8List(16));
    writer.serializeBits(Ref<int>(5), 3);
    writer.serializeBytes(payload);
    writer.flush();
    expectEquals(writer.bitsProcessed, 8 + 32, 'align padded to the byte');
    final reader = ReadStream(writer.data());
    final head = Ref<int>(0);
    reader.serializeBits(head, 3);
    final readBack = Uint8List(4);
    expect(reader.serializeBytes(readBack), 'read');
    expectBytes(readBack, payload, 'payload');
  });

  test(
    'serializeBytes: a zero count still aligns, and verifies the padding',
    () {
      final writer = WriteStream(Uint8List(8));
      writer.serializeBits(Ref<int>(1), 1);
      writer.serializeBytes(Uint8List(0));
      expectEquals(writer.bitsProcessed, 8, 'aligned, nothing else');
      writer.flush();

      // the reader performs and verifies the same alignment
      final clean = ReadStream(writer.data());
      clean.serializeBits(Ref<int>(0), 1);
      expect(clean.serializeBytes(Uint8List(0)), 'zero-length read aligns');
      expectEquals(clean.bitsProcessed, 8, 'reader aligned too');

      // nonzero padding under the zero-length align is refused
      final doctored = Uint8List.fromList(writer.data());
      doctored[0] |= 0x80;
      final dirty = ReadStream(doctored);
      dirty.serializeBits(Ref<int>(0), 1);
      expect(!dirty.serializeBytes(Uint8List(0)), 'nonzero padding refused');
    },
  );

  test('serializeBytes: refusals — padding, truncation', () {
    // nonzero align padding
    final doctored = Uint8List.fromList(const [0x0D, 0xAA]);
    final reader = ReadStream(doctored);
    reader.serializeBits(Ref<int>(0), 3);
    expect(!reader.serializeBytes(Uint8List(1)), 'nonzero padding refused');
    // more bytes than remain
    final short = ReadStream(Uint8List(2));
    expect(!short.serializeBytes(Uint8List(3)), 'truncation refused');
    // the destination is untouched on refusal
    final dest = Uint8List(3)..fillRange(0, 3, 0x77);
    final short2 = ReadStream(Uint8List(2));
    expect(!short2.serializeBytes(dest), 'refused');
    expectBytes(dest, const [0x77, 0x77, 0x77], 'destination untouched');
  });

  test('serializeString: round trips, including the empty string', () {
    for (final value in ['golden', '', 'a', 'мир truth', 'emoji \u{1F680}']) {
      final writer = WriteStream(Uint8List(64));
      expect(writer.serializeString(Ref<String>(value), 32), 'write "$value"');
      writer.flush();
      final reader = ReadStream(writer.data());
      final read = Ref<String>('unset');
      expect(reader.serializeString(read, 32), 'read "$value"');
      expectEquals(read.value, value, 'round trip "$value"');
    }
  });

  test('serializeString: the bit cost depends on the buffer size', () {
    final small = WriteStream(Uint8List(32));
    small.serializeString(Ref<String>('ab'), 8); // length in 3 bits
    final large = WriteStream(Uint8List(32));
    large.serializeString(Ref<String>('ab'), 256); // length in 8 bits
    expectEquals(small.bitsProcessed, 3 + 5 + 16, 'length 3 bits + align');
    expectEquals(large.bitsProcessed, 8 + 16, 'length 8 bits, aligned');
  });

  test('serializeString: an interior NUL fails the read', () {
    // write a valid 3-byte string, then doctor a payload byte to zero
    final writer = WriteStream(Uint8List(16));
    writer.serializeString(Ref<String>('abc'), 16);
    writer.flush();
    final doctored = Uint8List.fromList(writer.data());
    doctored[1] = 0; // the first payload byte (length nibble aligns to byte 1)
    final reader = ReadStream(doctored);
    final read = Ref<String>('unset');
    expect(!reader.serializeString(read, 16), 'interior NUL refused');
    expectEquals(reader.refusal, Refusal.embeddedNul, 'refusal reason');
    expectEquals(read.value, 'unset', 'holder untouched on refusal');
  });

  test('serializeString: invalid UTF-8 fails the read', () {
    // overlong encoding, stray continuation, truncated sequence, surrogate
    // code point, above U+10FFFF
    const payloads = [
      [0xC0, 0xAF, 0x61], // overlong 2-byte
      [0x80, 0x61, 0x61], // stray continuation
      [0x61, 0x61, 0xE2], // truncated 3-byte sequence at the end
      [0xED, 0xA0, 0x80], // surrogate U+D800
      [0xF4, 0x90, 0x80], // above U+10FFFF (truncated is also invalid)
    ];
    for (final payload in payloads) {
      final writer = WriteStream(Uint8List(16));
      // write a length-3 CLEAN string, then replace the payload bytes
      writer.serializeString(Ref<String>('abc'), 16);
      writer.flush();
      final doctored = Uint8List.fromList(writer.data());
      for (var i = 0; i < 3; i++) {
        doctored[1 + i] = payload[i];
      }
      final reader = ReadStream(doctored);
      final read = Ref<String>('unset');
      expect(!reader.serializeString(read, 16), 'invalid UTF-8 refused');
      expectEquals(reader.refusal, Refusal.invalidUtf8, 'refusal reason');
    }
  });

  test('serializeString: a length overrunning the data fails the read', () {
    // a 1-byte stream whose length field claims 15 bytes follow
    final writer = WriteStream(Uint8List(8));
    writer.serializeBits(Ref<int>(15), 4); // length field for bufferSize 16
    writer.serializeAlign();
    writer.flush();
    final reader = ReadStream(writer.data());
    final read = Ref<String>('unset');
    expect(!reader.serializeString(read, 16), 'overrun length refused');
  });

  test('serializeString: the refusal reasons, and their order', () {
    Refusal? refusalOf(List<int> bytes, int bufferSize) {
      final reader = ReadStream(Uint8List.fromList(bytes));
      final read = Ref<String>('unset');
      expect(!reader.serializeString(read, bufferSize), 'refused');
      expectEquals(read.value, 'unset', 'holder untouched on refusal');
      return reader.refusal;
    }

    // buffer size 4: a 2-bit length, then the aligned payload
    expectEquals(refusalOf(const [0x01, 0x00], 4), Refusal.embeddedNul, 'NUL');
    expectEquals(
      refusalOf(const [0x01, 0xFF], 4),
      Refusal.invalidUtf8,
      'a byte that never appears in UTF-8',
    );
    // both rules at once: the NUL scan runs over the whole payload BEFORE
    // the encoding is checked, so 02 FF 00 is embedded_nul
    expectEquals(
      refusalOf(const [0x02, 0xFF, 0x00], 4),
      Refusal.embeddedNul,
      'NUL wins over invalid UTF-8',
    );
    // set padding before a truncated payload: the align comes first
    expectEquals(
      refusalOf(const [0x0B], 8), // length 3, padding bit 3 set
      Refusal.nonzeroPadding,
      'padding wins over the truncated payload',
    );
    expectEquals(refusalOf(const [0x03], 8), Refusal.pastEnd, 'truncated');
    // buffer size 4 allows lengths 0..3, so a length field of 3 at buffer
    // size 3 (2 bits, 0..2 allowed) is out of range
    expectEquals(
      refusalOf(const [0x03, 0x61, 0x62, 0x63], 3),
      Refusal.valueOutOfRange,
      'length past the buffer',
    );
  });

  test('serializeString: real text round trips byte for byte', () {
    for (final value in [
      '\u56F4\u68CB', // weiqi
      '\uBC14\uB451', // baduk
      '\u0634\u0637\u0631\u0646\u062C', // right to left
      'e\u0301', // combining acute: never normalized to U+00E9
      '\u00E9',
      '\uFEFFgo', // a leading byte order mark is kept
      'go\uFEFF',
      '\uFEFF\uFEFF',
      '\uFFFF', // a noncharacter travels
      '\u{1F680}', // four bytes
      '\u{20000}', // CJK Extension B
      '\u{10FFFF}',
    ]) {
      final writer = WriteStream(Uint8List(64));
      expect(writer.serializeString(Ref<String>(value), 32), 'write');
      writer.flush();
      final reader = ReadStream(writer.data());
      final read = Ref<String>('unset');
      expect(reader.serializeString(read, 32), 'read');
      expect(reader.serializeEnd(), 'exactly consumed');
      expectEquals(
        read.value.codeUnits.join(' '),
        value.codeUnits.join(' '),
        'code units of ${value.codeUnits}',
      );
    }
  });

  test('serializeString: a lone surrogate or a NUL is caller error', () {
    if (!assertsEnabled) {
      return; // a release build performs no write-side validation
    }
    // utf8.encode would silently replace a lone surrogate with U+FFFD, so
    // the writer must assert rather than emit text the caller never had
    for (final value in ['\uD800', 'a\uDC00', 'a\uD83Db', 'a\u0000b']) {
      expectThrows(
        () =>
            WriteStream(Uint8List(32)).serializeString(Ref<String>(value), 16),
        'write ${value.codeUnits}',
      );
      expectThrows(
        () => MeasureStream().serializeString(Ref<String>(value), 16),
        'measure ${value.codeUnits}',
      );
    }
  });

  test('serializeAlign: a nonzero pad fails the read', () {
    final writer = WriteStream(Uint8List(8));
    writer.serializeBits(Ref<int>(3), 3);
    writer.serializeAlign();
    writer.serializeBits(Ref<int>(0xAB), 8);
    writer.flush();
    final doctored = Uint8List.fromList(writer.data());
    doctored[0] |= 0x40; // set a padding bit
    final reader = ReadStream(doctored);
    reader.serializeBits(Ref<int>(0), 3);
    expect(!reader.serializeAlign(), 'nonzero padding refused');
    expectEquals(reader.refusal, Refusal.nonzeroPadding, 'refusal reason');
    // and the clean stream is accepted
    final clean = ReadStream(writer.data());
    clean.serializeBits(Ref<int>(0), 3);
    expect(clean.serializeAlign(), 'clean padding accepted');
  });
}
