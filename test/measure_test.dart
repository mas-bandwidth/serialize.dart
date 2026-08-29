// The measure stream: a conservative bound, not the packet size. Aligning
// operations charge the worst case of 7 bits; everything else is exact.
// The worked example of STANDARD.md discriminates a conservative measure
// (23 bits) from a non-conforming exact-from-zero measure (16).

import 'dart:typed_data';

import 'package:serialize/serialize.dart';

import 'harness.dart';

void run() {
  test('the worked example: { bits(8); align; bits(8) } measures 23 bits', () {
    final measure = MeasureStream();
    measure.serializeBits(Ref<int>(0xAA), 8);
    measure.serializeAlign();
    measure.serializeBits(Ref<int>(0xBB), 8);
    expectEquals(
      measure.bitsProcessed,
      23,
      'conservative: 8 + 7 + 8, sufficient at every starting position',
    );

    // and the bound really is needed: written from bit offset 1, the same
    // message spans 23 bits
    final writer = WriteStream(Uint8List(8));
    writer.serializeBits(Ref<int>(0), 1);
    writer.serializeBits(Ref<int>(0xAA), 8);
    writer.serializeAlign();
    writer.serializeBits(Ref<int>(0xBB), 8);
    expectEquals(writer.bitsProcessed - 1, 23, 'the offset-1 write needs 23');
  });

  test('an align is always charged 7, even at a byte boundary', () {
    final measure = MeasureStream();
    measure.serializeBits(Ref<int>(0), 8);
    measure.serializeAlign();
    expectEquals(measure.bitsProcessed, 15, '8 + 7, never 8 + 0');
    expectEquals(measure.alignBits, 7, 'alignBits reports worst case');
  });

  test('non-aligning operations measure exact widths', () {
    final measure = MeasureStream();
    measure.serializeBits(Ref<int>(5), 3);
    measure.serializeInt(Ref<int>(0), -100, 100);
    measure.serializeInt64(Ref<int>(0), -5000000000, 5000000000);
    measure.serializeBool(Ref<bool>(true));
    measure.serializeFloat(Ref<double>(1.0));
    measure.serializeDouble(Ref<double>(1.0));
    measure.serializeUint8(Ref<int>(0));
    measure.serializeUint16(Ref<int>(0));
    measure.serializeUint32(Ref<int>(0));
    measure.serializeUint64(Ref<int>(0));
    measure.serializeUint128(Ref<UInt128>(UInt128.zero));
    measure.serializeCompressedFloat(Ref<double>(5.0), 0.0, 10.0, 0.01);
    expectEquals(
      measure.bitsProcessed,
      3 + 8 + 34 + 1 + 32 + 64 + 8 + 16 + 32 + 64 + 128 + 10,
      'exact widths, summed',
    );
  });

  test('bytes and string charge 7 align bits; wstring charges none', () {
    final bytesMeasure = MeasureStream();
    bytesMeasure.serializeBytes(Uint8List(5));
    expectEquals(bytesMeasure.bitsProcessed, 7 + 40, 'bytes: 7 + 8n');

    final stringMeasure = MeasureStream();
    stringMeasure.serializeString(Ref<String>('golden'), 16);
    expectEquals(
      stringMeasure.bitsProcessed,
      4 + 7 + 48,
      'string: length + 7 + bytes',
    );

    final wideMeasure = MeasureStream();
    wideMeasure.serializeWideString(Ref<String>('мир'), 8);
    expectEquals(
      wideMeasure.bitsProcessed,
      3 + 96,
      'wstring: length + 32 per unit, no alignment',
    );
  });

  test('measure >= bits written for the golden-shaped ops at every offset', () {
    // a message with several aligning operations: the bound holds at all 8
    // starting offsets
    bool serializeMessage(BitStream stream) {
      final bytes = Uint8List.fromList(const [1, 2, 3]);
      return stream.serializeBits(Ref<int>(5), 3) &&
          stream.serializeBytes(bytes) &&
          stream.serializeString(Ref<String>('x'), 8) &&
          stream.serializeAlign() &&
          stream.serializeBits(Ref<int>(1), 1);
    }

    for (var offset = 0; offset < 8; offset++) {
      final writer = WriteStream(Uint8List(64));
      if (offset > 0) {
        writer.serializeBits(Ref<int>(0), offset);
      }
      expect(serializeMessage(writer), 'write at offset $offset');

      final measure = MeasureStream();
      if (offset > 0) {
        measure.serializeBits(Ref<int>(0), offset);
      }
      expect(serializeMessage(measure), 'measure at offset $offset');
      expect(
        measure.bitsProcessed >= writer.bitsProcessed,
        'offset $offset: bound holds',
      );
    }
  });

  test('reset clears the count', () {
    final measure = MeasureStream();
    measure.serializeUint32(Ref<int>(0));
    measure.reset();
    expectEquals(measure.bitsProcessed, 0, 'cleared');
  });
}
