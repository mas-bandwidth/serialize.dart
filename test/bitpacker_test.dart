// Unit tests for the bitpacker: LSB-first packing, little-endian words on
// the wire, word-boundary splits, flush semantics, aligns, and the byte
// fast path — the foundations under every golden byte.

import 'dart:typed_data';

import 'package:serialize/serialize.dart';

import 'harness.dart';

void run() {
  test('LSB-first packing: the first value occupies the lowest bits', () {
    final buffer = Uint8List(8);
    final writer = BitWriter(buffer);
    writer.writeBits(1, 1);
    writer.writeBits(0, 1);
    writer.writeBits(1, 1);
    writer.writeBits(3, 2);
    writer.flushBits();
    // bits from the bottom: 1, 0, 1, then 11 -> 0b11101 = 0x1D
    expectEquals(buffer[0], 0x1D, 'first byte');
    expectEquals(writer.bitsWritten, 5, 'bits written');
    expectEquals(writer.bytesWritten, 1, 'bytes written');
  });

  test('little-endian words: a 64-bit fill lands low byte first', () {
    final buffer = Uint8List(8);
    final writer = BitWriter(buffer);
    writer.writeBits(0x44332211, 32);
    writer.writeBits(0x88776655, 32);
    // the word filled to exactly 64 bits: stored without an explicit flush
    expectBytes(buffer, const [
      0x11,
      0x22,
      0x33,
      0x44,
      0x55,
      0x66,
      0x77,
      0x88,
    ], 'wire bytes');
    expectEquals(writer.bitsWritten, 64, 'bits written');
  });

  test('word-boundary split: a value crossing 64 bits splits low/high', () {
    final buffer = Uint8List(16);
    final writer = BitWriter(buffer);
    writer.writeBits(0, 32);
    writer.writeBits(0, 28);
    // 60 bits in: this 24-bit value splits 4 bits into word 0, 20 into word 1
    writer.writeBits(0xABCDEF, 24);
    writer.flushBits();
    final reader = BitReader(buffer);
    reader.readBits(32);
    reader.readBits(28);
    expectEquals(reader.readBits(24), 0xABCDEF, 'value across the boundary');

    // and bit-exactly: the low 4 bits complete word 0's top nibble
    expectEquals(buffer[7] >> 4, 0xF, 'low 4 bits in word 0');
  });

  test('flush semantics: a partial word reaches memory only on flush', () {
    final buffer = Uint8List(8);
    final writer = BitWriter(buffer);
    writer.writeBits(0xFF, 8);
    expectEquals(buffer[0], 0, 'nothing stored before flush');
    writer.flushBits();
    expectEquals(buffer[0], 0xFF, 'stored after flush');
    // flush is idempotent once the scratch is empty
    writer.flushBits();
    expectEquals(writer.bytesWritten, 1, 'bytes written');
  });

  test('trailing bits are zero by construction', () {
    final buffer = Uint8List(8)..fillRange(0, 8, 0xFF);
    final writer = BitWriter(buffer);
    writer.writeBits(0x3, 3);
    writer.flushBits();
    expectEquals(buffer[0], 0x03, 'unused bits of the final byte are zero');
    expectEquals(buffer[7], 0x00, 'the flushed word zeroes the rest');
  });

  test('writeAlign pads with zeros to the byte boundary, or nothing', () {
    final buffer = Uint8List(8);
    final writer = BitWriter(buffer);
    writer.writeBits(1, 3);
    expectEquals(writer.alignBits, 5, 'align bits at bit 3');
    writer.writeAlign();
    expectEquals(writer.bitsWritten, 8, 'aligned to 8');
    writer.writeAlign();
    expectEquals(writer.bitsWritten, 8, 'already aligned: nothing written');
    expectEquals(writer.alignBits, 0, 'align bits at a byte boundary');
  });

  test('writeBytes: the fused head/body/tail matches per-byte writeBits', () {
    final payload = Uint8List.fromList(
      List<int>.generate(19, (i) => (i * 37) & 0xFF),
    );
    // via writeBytes, at a byte-aligned but non-word-aligned cursor
    final fused = Uint8List(40);
    final writer = BitWriter(fused);
    writer.writeBits(0xAB, 8);
    writer.writeBytes(payload);
    writer.writeBits(0xCD, 8); // the tail scratch must resume correctly
    writer.flushBits();
    // via writeBits a byte at a time
    final packed = Uint8List(40);
    final byteWriter = BitWriter(packed);
    byteWriter.writeBits(0xAB, 8);
    for (final byte in payload) {
      byteWriter.writeBits(byte, 8);
    }
    byteWriter.writeBits(0xCD, 8);
    byteWriter.flushBits();
    expectBytes(fused, packed, 'wire identical');

    final reader = BitReader(fused);
    expectEquals(reader.readBits(8), 0xAB, 'head byte');
    final readBack = Uint8List(19);
    reader.readBytes(readBack);
    expectBytes(readBack, payload, 'payload');
    expectEquals(reader.readBits(8), 0xCD, 'tail byte');
  });

  test('reader: wouldReadPastEnd and bit accounting', () {
    final reader = BitReader(Uint8List.fromList(const [0xFF, 0x01]));
    expect(!reader.wouldReadPastEnd(16), '16 bits available');
    expect(reader.wouldReadPastEnd(17), 'not 17');
    expectEquals(reader.readBits(12), 0x1FF, 'value');
    expectEquals(reader.bitsRead, 12, 'bits read');
    expectEquals(reader.bitsRemaining, 4, 'bits remaining');
    expect(reader.wouldReadPastEnd(5), 'only 4 left');
  });

  test('reader: buffers shorter than 8 bytes window inside the data', () {
    final reader = BitReader(Uint8List.fromList(const [0xB1, 0xC2, 0xD3]));
    expectEquals(reader.readBits(8), 0xB1, 'byte 0');
    expectEquals(reader.readBits(8), 0xC2, 'byte 1');
    expectEquals(reader.readBits(8), 0xD3, 'byte 2');
    final empty = BitReader(Uint8List(0));
    expect(empty.wouldReadPastEnd(1), 'empty data has no bits');
  });

  test('reader: readAlign verifies zero padding and refuses nonzero', () {
    // clean padding: 3 bits then zeros to the byte
    final clean = BitReader(Uint8List.fromList(const [0x05, 0xAA]));
    clean.readBits(3);
    expect(clean.readAlign(), 'zero padding accepted');
    expectEquals(clean.readBits(8), 0xAA, 'next byte');
    // doctored padding: a nonzero bit in the pad
    final dirty = BitReader(Uint8List.fromList(const [0x0D, 0xAA]));
    dirty.readBits(3);
    expect(!dirty.readAlign(), 'nonzero padding refused');
    // already aligned: nothing read, nothing refused
    final aligned = BitReader(Uint8List.fromList(const [0xFF]));
    expect(aligned.readAlign(), 'aligned is a no-op');
    expectEquals(aligned.bitsRead, 0, 'no bits consumed');
  });

  test('round trip: mixed widths across several words', () {
    final buffer = Uint8List(64);
    final writer = BitWriter(buffer);
    final widths = [1, 3, 7, 8, 13, 17, 24, 31, 32, 5, 32, 32, 11, 2, 29];
    final values = <int>[];
    var seed = 0x12345678;
    for (final width in widths) {
      seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
      final value = seed & (width == 32 ? 0xFFFFFFFF : (1 << width) - 1);
      values.add(value);
      writer.writeBits(value, width);
    }
    writer.flushBits();
    final reader = BitReader(
      Uint8List.sublistView(buffer, 0, writer.bytesWritten),
    );
    for (var i = 0; i < widths.length; i++) {
      expectEquals(reader.readBits(widths[i]), values[i], 'value $i');
    }
    expectEquals(reader.bitsRead, writer.bitsWritten, 'bit accounting');
  });
}
