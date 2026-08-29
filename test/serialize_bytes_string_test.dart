// serialize_bytes (aligns first, zero count still aligns), the UTF-8 string
// and the wide string: accept paths, buffer-size dependence, and every
// refusal rule — interior NUL, invalid UTF-8, unpaired surrogates, groups
// above 0xFFFF, nonzero align padding, truncation. Hostile bytes never
// throw.

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

  test('serializeWideString: round trips, BMP and astral', () {
    for (final value in ['мир', '', 'wide', 'astral \u{1F680}\u{10348}']) {
      final writer = WriteStream(Uint8List(128));
      expect(
        writer.serializeWideString(Ref<String>(value), 16),
        'write "$value"',
      );
      writer.flush();
      final reader = ReadStream(writer.data());
      final read = Ref<String>('unset');
      expect(reader.serializeWideString(read, 16), 'read "$value"');
      expectEquals(read.value, value, 'round trip "$value"');
    }
  });

  test('serializeWideString: no alignment anywhere in the operation', () {
    // 3 code units against bufferSize 8: 3 length bits + 3 x 32, never
    // padded — the worked example structure of STANDARD.md
    final writer = WriteStream(Uint8List(32));
    writer.serializeWideString(Ref<String>('мир'), 8);
    expectEquals(writer.bitsProcessed, 3 + 3 * 32, 'unaligned bit cost');
  });

  test('serializeWideString: refusals — group above 0xFFFF, interior NUL, '
      'unpaired surrogates, truncation', () {
    Uint8List writeGroups(int length, List<int> groups) {
      final writer = WriteStream(Uint8List(64));
      writer.serializeBits(Ref<int>(length), 3); // length for bufferSize 8
      for (final group in groups) {
        writer.serializeBits(Ref<int>(group), 32);
      }
      writer.flush();
      return writer.data();
    }

    final read = Ref<String>('unset');
    // a group above 0xFFFF is not a UTF-16 code unit
    expect(
      !ReadStream(writeGroups(1, const [0x10000])).serializeWideString(read, 8),
      'group above 0xFFFF refused',
    );
    // an interior NUL group
    expect(
      !ReadStream(
        writeGroups(2, const [0x61, 0x00]),
      ).serializeWideString(read, 8),
      'interior NUL refused',
    );
    // a high surrogate without its low
    expect(
      !ReadStream(
        writeGroups(2, const [0xD800, 0x61]),
      ).serializeWideString(read, 8),
      'high surrogate without low refused',
    );
    // a low surrogate with no high before it
    expect(
      !ReadStream(writeGroups(1, const [0xDC00])).serializeWideString(read, 8),
      'stray low surrogate refused',
    );
    // a dangling high surrogate as the final group
    expect(
      !ReadStream(writeGroups(1, const [0xD800])).serializeWideString(read, 8),
      'dangling high surrogate refused',
    );
    // a well-formed pair passes
    expect(
      ReadStream(
        writeGroups(2, const [0xD83D, 0xDE80]),
      ).serializeWideString(read, 8),
      'well-formed pair accepted',
    );
    expectEquals(read.value, '\u{1F680}', 'pair recombines to the character');
    // truncation: length claims more groups than the data holds
    expect(
      !ReadStream(
        writeGroups(7, const [0x61]),
      ).serializeWideString(Ref<String>('unset'), 8),
      'truncation refused',
    );
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
    // and the clean stream is accepted
    final clean = ReadStream(writer.data());
    clean.serializeBits(Ref<int>(0), 3);
    expect(clean.serializeAlign(), 'clean padding accepted');
  });
}
