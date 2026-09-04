// serialize_object: composition, not an encoding.
//
// STANDARD.md, "object": it invokes the object's own serialize function inline
// and contributes NO BYTES OF ITS OWN, with no framing, length prefix or
// alignment inserted around it. The rule is a statement about two streams
// being the same, so every case here has a flat twin performing the same
// operations unnested and demands identical bytes.

import 'dart:typed_data';

import 'package:serialize/serialize.dart';

import 'harness.dart';

/// Four bits, a bool and a byte, as a nested object.
final class _Fields implements Serializable {
  int nibble = 0;
  bool flag = false;
  int byte = 0;

  @override
  bool serialize(BitStream stream) {
    final nibbleRef = Ref<int>(nibble);
    if (!stream.serializeBits(nibbleRef, 4)) {
      return false;
    }
    nibble = nibbleRef.value;
    final flagRef = Ref<bool>(flag);
    if (!stream.serializeBool(flagRef)) {
      return false;
    }
    flag = flagRef.value;
    final byteRef = Ref<int>(byte);
    if (!stream.serializeBits(byteRef, 8)) {
      return false;
    }
    byte = byteRef.value;
    return true;
  }
}

/// A single align, as a nested object: the align belongs to the nested
/// operation and lands where that operation puts it, not at the boundary.
final class _JustAnAlign implements Serializable {
  @override
  bool serialize(BitStream stream) => stream.serializeAlign();
}

void run() {
  test('serializeObject: adds no bytes of its own', () {
    final nested = WriteStream(Uint8List(16));
    expect(
      nested.serializeObject(
        _Fields()
          ..nibble = 10
          ..flag = true
          ..byte = 106,
      ),
      'the nested write succeeds',
    );
    nested.flush();

    final flat = WriteStream(Uint8List(16));
    flat.serializeBits(Ref<int>(10), 4);
    flat.serializeBool(Ref<bool>(true));
    flat.serializeBits(Ref<int>(106), 8);
    flat.flush();

    expectEquals(nested.bitsProcessed, flat.bitsProcessed, 'bits written');
    expectBytes(
      nested.data(),
      flat.data(),
      'the nested bytes are the flat ones',
    );

    final fields = _Fields();
    final reader = ReadStream(nested.data());
    expect(reader.serializeObject(fields), 'the nested read succeeds');
    expectEquals(fields.nibble, 10, 'nibble');
    expectEquals(fields.flag, true, 'flag');
    expectEquals(fields.byte, 106, 'byte');
    expectEquals(reader.bitsProcessed, 13, 'bits consumed');
  });

  test('serializeObject: measures no bits of its own', () {
    final nested = MeasureStream();
    nested.serializeObject(_JustAnAlign());
    expectEquals(
      nested.bitsProcessed,
      7,
      'the align worst case, and nothing more',
    );
  });

  test('serializeObject: a refusal inside propagates out of the nesting', () {
    // three bits, then a nested align whose padding is not zero
    final stream = ReadStream(Uint8List.fromList(const [0xFD, 0xAB]));
    expect(stream.serializeBits(Ref<int>(0), 3), 'the first three bits');
    expect(!stream.serializeObject(_JustAnAlign()), 'the nested align refuses');
    // and the refusal is terminal, although byte 1 is present and readable
    final after = Ref<int>(0x77);
    expect(!stream.serializeBits(after, 8), 'the read after it refuses');
    expectEquals(after.value, 0x77, 'and writes nothing');
  });

  test('serializeObject: refuses on a stream that has already failed', () {
    // STANDARD.md: every read consults the failure state before it does
    // anything else, and object is named among them
    final stream = ReadStream(Uint8List(0));
    expect(!stream.serializeBits(Ref<int>(0), 8), 'the empty stream refuses');
    final fields = _Fields()..nibble = 9;
    expect(!stream.serializeObject(fields), 'the object refuses too');
    expectEquals(fields.nibble, 9, 'and nothing inside it was written');
  });
}
