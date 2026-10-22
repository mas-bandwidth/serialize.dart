// The three streams: WriteStream, ReadStream and MeasureStream.
//
// Each implements the full serialize surface STANDARD.md specifies, written
// out per mode: Dart has no templates, so the per-stream specialization the
// C++ reference gets from instantiation is written three times here.
//
// Writes assume trusted data (STANDARD.md): caller contracts on the write
// and measure paths are asserted, active in debug, compiled out in release.
// Reads VALIDATE ALWAYS: every refusal rule of STANDARD.md binds in every
// build mode, out-of-range or truncated input refuses cleanly as a false
// return, and hostile bytes never throw. A failure is terminal: ReadStream
// latches it, and every later read on that stream fails until reset. Every
// refusal names its rule from the closed list in refusal.dart, and the
// stream keeps the first one.
//
// Dart has no by-reference parameters, so values pass through [Ref] holders.
// serializeBytes fills its Uint8List in place.

import 'dart:convert';
import 'dart:typed_data';

import 'bitpacker.dart';
import 'bits.dart';
import 'float32.dart';
import 'int128.dart';
import 'refusal.dart';

/// A mutable holder standing in for the reference implementation's
/// by-reference parameters: the writer reads [value], the reader assigns it.
final class Ref<T> {
  /// The held value.
  T value;

  /// Creates a holder with an initial value.
  Ref(this.value);
}

// ---------------------------------------------------------------------------
// Shared declaration arithmetic
// ---------------------------------------------------------------------------

// The quantization parameters shared by the write, read and measure
// implementations of serializeCompressedFloat, computed into a reused
// module-level holder (filled and consumed within a single call, no user
// code in between, so sharing is safe and allocation-free).
final class _FloatParams {
  double min = 0;
  double delta = 0;
  int maxIntegerValue = 0;
  int bits = 0;
}

final _FloatParams _floatParams = _FloatParams();

// Derives the compressed float wire constants from a (min,max,res)
// declaration, mirroring serialize_compressed_float_params: every step is
// float32, including the parameters themselves (they are float parameters in
// the reference, so they round to float32 at this boundary). A declaration
// whose delta or values is not finite in float32 is non-conforming
// (STANDARD.md, adopted 2026-08-15) — asserted in debug, per the
// writer-trusted model; the clamp below remains the release backstop.
void _compressedFloatParams(double min, double max, double resolution) {
  min = fround(min);
  max = fround(max);
  resolution = fround(resolution);
  assert(min < max && resolution > 0);

  final delta = fround(max - min);
  var values = fround(delta / resolution);
  assert(delta.isFinite);
  assert(values.isFinite);

  // clamp so the integer conversion below is defined even for pathological
  // delta / res (the !>= form also catches NaN)
  if (!(values >= 1.0)) {
    values = 1.0;
  } else if (values > 4294967040.0) {
    // largest float32 below 2^32
    values = 4294967040.0;
  }

  final maxIntegerValue = values.ceil();

  _floatParams.min = min;
  _floatParams.delta = delta;
  _floatParams.maxIntegerValue = maxIntegerValue;
  _floatParams.bits = bitsRequired(0, maxIntegerValue);
}

// The wire parameters shared by the write, read and measure implementations
// of serializeFixed on 64-bit-or-narrower storage, computed into a reused
// module-level holder. The declaration is part of the message format, never
// data: the reference validates it with static asserts, so violating it here
// is caller misuse, asserted in debug.
final class _FixedParams {
  int width = 0;
  bool signed = false;
  int bits = 0;
  int rawMin = 0;
  int rawRange = 0;
}

final _FixedParams _fixedParams = _FixedParams();

// The whole-unit capacity checks of serialize_fixed_internal, as a predicate
// the asserts above call: the format is read as signed exactly when min < 0,
// and the signedness never reaches the wire — for the same bounds, signed
// and unsigned storage produce identical bytes.
bool _fixedBoundsFit(int integerBits, int min, int max) {
  if (min < 0) {
    if (integerBits < 65 && min < -(1 << (integerBits - 1))) {
      return false;
    }
    if (integerBits < 64 && max > (1 << (integerBits - 1)) - 1) {
      return false;
    }
  } else if (integerBits < 64 && max > mask64(integerBits)) {
    return false;
  }
  return true;
}

void _fixedPointParams(int integerBits, int fractionBits, int min, int max) {
  final width = integerBits + fractionBits;
  assert(integerBits >= 1 && fractionBits >= 0);
  assert(width == 8 || width == 16 || width == 32 || width == 64);
  assert(min <= max);
  assert(_fixedBoundsFit(integerBits, min, max));

  // shift the whole-unit bounds into raw fixed point units: wraps two's
  // complement in the unsigned 64-bit domain, exactly as the reference
  final rawMin = min << fractionBits;
  final rawMax = max << fractionBits;

  _fixedParams.width = width;
  _fixedParams.signed = min < 0;
  _fixedParams.rawMin = rawMin;
  _fixedParams.rawRange = rawMax - rawMin;
  _fixedParams.bits = min == max ? 0 : bitsRequired64(rawMin, rawMax);
}

// The wide (128-bit storage) counterpart, in the unsigned 128-bit domain.
final class _FixedParams128 {
  int bits = 0;
  UInt128 rawMin = UInt128.zero;
  UInt128 rawRange = UInt128.zero;
}

final _FixedParams128 _fixedParams128 = _FixedParams128();

void _fixedPointParams128(int integerBits, int fractionBits, int min, int max) {
  assert(integerBits >= 1 && fractionBits >= 0);
  assert(integerBits + fractionBits == 128);
  assert(min <= max);
  assert(_fixedBoundsFit(integerBits, min, max));

  final rawMin = Int128.fromInt(min).toUnsigned() << fractionBits;
  final rawMax = Int128.fromInt(max).toUnsigned() << fractionBits;

  _fixedParams128.rawMin = rawMin;
  _fixedParams128.rawRange = rawMax - rawMin;
  // the wire cost, computed in the 64-bit domain exactly as the reference:
  // the range in whole units is exact in 64 bits, and shifting it left adds
  // exactly fractionBits to its bit length. Zero for the degenerate range,
  // on every storage width (STANDARD.md, adopted 2026-08-15).
  _fixedParams128.bits = min == max
      ? 0
      : bitsRequired64(min, max) + fractionBits;
}

// The relative-integer ladder tiers of serialize_int_relative_internal:
// payload bounds per tier, after the tier's flag bit says the difference
// fits. The final tier has no bounds — it transmits current as 32 raw bits.
const List<int> _relativeTierMin = [2, 7, 24, 281, 4378];
const List<int> _relativeTierMax = [6, 23, 280, 4377, 69914];

/*
    UTF-8 well-formedness, one validator with two callers (STANDARD.md,
    adopted 2026-08-15): the WRITE path's contract check — a debug-only
    assert per the writes-trusted doctrine — and the READ path's refusal rule
    ("Readers must refuse malformed string payloads"), which binds in every
    build mode, because the read side faces untrusted data. Rejects overlong
    encodings, surrogate code points, values above U+10FFFF, truncated
    sequences and stray continuation bytes. NUL bytes are VALID UTF-8: the
    interior-NUL refusal is a separate rule with its own reason.
*/
bool _isValidUtf8(Uint8List bytes, int length) {
  var i = 0;
  while (i < length) {
    final lead = bytes[i];
    if (lead < 0x80) {
      i += 1;
    } else if ((lead & 0xE0) == 0xC0) {
      if (lead < 0xC2) {
        return false; // overlong
      }
      if (i + 1 >= length) {
        return false;
      }
      if ((bytes[i + 1] & 0xC0) != 0x80) {
        return false;
      }
      i += 2;
    } else if ((lead & 0xF0) == 0xE0) {
      if (i + 2 >= length) {
        return false;
      }
      final byte1 = bytes[i + 1];
      final byte2 = bytes[i + 2];
      if ((byte1 & 0xC0) != 0x80 || (byte2 & 0xC0) != 0x80) {
        return false;
      }
      if (lead == 0xE0 && byte1 < 0xA0) {
        return false; // overlong
      }
      if (lead == 0xED && byte1 >= 0xA0) {
        return false; // surrogate code point
      }
      i += 3;
    } else if ((lead & 0xF8) == 0xF0) {
      if (lead > 0xF4) {
        return false; // above U+10FFFF
      }
      if (i + 3 >= length) {
        return false;
      }
      final byte1 = bytes[i + 1];
      final byte2 = bytes[i + 2];
      final byte3 = bytes[i + 3];
      if ((byte1 & 0xC0) != 0x80 ||
          (byte2 & 0xC0) != 0x80 ||
          (byte3 & 0xC0) != 0x80) {
        return false;
      }
      if (lead == 0xF0 && byte1 < 0x90) {
        return false; // overlong
      }
      if (lead == 0xF4 && byte1 >= 0x90) {
        return false; // above U+10FFFF
      }
      i += 4;
    } else {
      return false; // continuation or invalid lead byte
    }
  }
  return true;
}

// Does the payload open with the UTF-8 encoding of U+FEFF, EF BB BF?
bool _startsWithByteOrderMark(Uint8List bytes) =>
    bytes.length >= 3 &&
    bytes[0] == 0xEF &&
    bytes[1] == 0xBB &&
    bytes[2] == 0xBF;

/*
    The string payload is well formed BY CONTRACT (STANDARD.md, "string"): a
    Dart String carrying an unpaired surrogate is a writer contract violation
    — utf8.encode would silently replace it with U+FFFD — debug-asserted per
    the writes-trusted doctrine. Referenced only from asserts; compiled out in
    release.
*/
bool _isValidUtf16(String value) {
  var i = 0;
  while (i < value.length) {
    final unit = value.codeUnitAt(i);
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      if (i + 1 >= value.length) {
        return false; // dangling high surrogate
      }
      final next = value.codeUnitAt(i + 1);
      if (next < 0xDC00 || next > 0xDFFF) {
        return false; // high surrogate without its pair
      }
      i += 2;
    } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
      return false; // low surrogate with no high before it
    } else {
      i += 1;
    }
  }
  return true;
}

// ---------------------------------------------------------------------------
// The unified surface
// ---------------------------------------------------------------------------

/// An object that serializes itself through a stream: the operand of
/// [BitStream.serializeObject], and the shape a message type takes when one
/// function writes, reads and measures it.
abstract interface class Serializable {
  /// Serializes this object through [stream], returning false to refuse.
  bool serialize(BitStream stream);
}

/// The unified serialize surface implemented by [WriteStream], [ReadStream]
/// and [MeasureStream] — the C# port's IBitStream — so a single serialize
/// function per message type writes, reads and measures it.
abstract interface class BitStream {
  /// True when this stream consumes ref values (write and measure streams).
  bool get isWriting;

  /// True when this stream assigns ref values (the read stream).
  bool get isReading;

  /// Serializes the low [bits] bits of the held value, bits in [1,32].
  bool serializeBits(Ref<int> value, int bits);

  /// Serializes the low [bits] bits of the held value, bits in [1,64].
  bool serializeBits64(Ref<int> value, int bits);

  /// Serializes a ranged 32-bit integer in [min,max].
  bool serializeInt(Ref<int> value, int min, int max);

  /// Serializes a ranged 64-bit integer in [min,max].
  bool serializeInt64(Ref<int> value, int min, int max);

  /// Serializes a ranged 128-bit integer in [min,max].
  bool serializeInt128(Ref<Int128> value, Int128 min, Int128 max);

  /// Serializes an unsigned 8-bit integer: 8 raw bits.
  bool serializeUint8(Ref<int> value);

  /// Serializes an unsigned 16-bit integer: 16 raw bits.
  bool serializeUint16(Ref<int> value);

  /// Serializes an unsigned 32-bit integer: 32 raw bits.
  bool serializeUint32(Ref<int> value);

  /// Serializes an unsigned 64-bit integer: 64 raw bits, low 32 first.
  bool serializeUint64(Ref<int> value);

  /// Serializes an unsigned 128-bit integer: 128 raw bits, low half first.
  bool serializeUint128(Ref<UInt128> value);

  /// Serializes a boolean as one bit.
  bool serializeBool(Ref<bool> value);

  /// Serializes a finite IEEE-754 single-precision float, bit exactly.
  bool serializeFloat(Ref<double> value);

  /// Serializes a finite IEEE-754 double-precision float, bit exactly.
  bool serializeDouble(Ref<double> value);

  /// Serializes a float quantized to a resolution over [min,max].
  bool serializeCompressedFloat(
    Ref<double> value,
    double min,
    double max,
    double resolution,
  );

  /// Serializes data.length raw bytes, aligning first.
  bool serializeBytes(Uint8List data);

  /// Serializes a UTF-8 string against a buffer size.
  bool serializeString(Ref<String> value, int bufferSize);

  /// Serializes an alignment to the next byte boundary.
  bool serializeAlign();

  /// Serializes a nested object inline. It contributes no bytes of its own:
  /// whatever the object serializes appears at exactly this position, with
  /// no framing, length prefix or alignment around it.
  bool serializeObject(Serializable object);

  /// Serializes [current] relative to [previous], current > previous.
  bool serializeIntRelative(int previous, Ref<int> current);

  /// Serializes the end of the object: a reader calls it after the last
  /// field of the top-level object it was handed, and refuses any whole byte
  /// after it and any set bit in the final byte's padding. A writer's end
  /// emits nothing, and a measure's costs nothing.
  bool serializeEnd();

  /// Serializes a fixed point value on storage of 8, 16, 32 or 64 bits.
  bool serializeFixed(
    Ref<int> value,
    int integerBits,
    int fractionBits,
    int min,
    int max,
  );

  /// Serializes a fixed point value on 128-bit storage.
  bool serializeFixed128(
    Ref<Int128> value,
    int integerBits,
    int fractionBits,
    int min,
    int max,
  );

  /// The number of align bits required at the current bit index.
  int get alignBits;

  /// The number of bits processed so far.
  int get bitsProcessed;

  /// The number of bytes processed so far.
  int get bytesProcessed;
}

// ---------------------------------------------------------------------------
// WriteStream
// ---------------------------------------------------------------------------

/// Stream for writing bitpacked data: a wrapper around [BitWriter] providing
/// the unified serialize surface, so a single serialize function can write,
/// read and measure a message. Write operations always return true — all
/// checking on the write path is performed by debug asserts only, per the
/// writer-trusted doctrine.
final class WriteStream implements BitStream {
  final BitWriter _writer;

  /// Creates a write stream over [buffer]. The buffer length must be a
  /// multiple of 8, because the bit writer stores 8-byte words to memory.
  WriteStream(Uint8List buffer) : _writer = BitWriter(buffer);

  /// Points the stream at a buffer and clears all write state.
  void reset(Uint8List buffer) => _writer.reset(buffer);

  /// True: this stream consumes ref values.
  bool get isWriting => true;

  /// False.
  bool get isReading => false;

  /// Writes the low [bits] bits of the held value, bits in [1,32]. The value
  /// must fit in that many bits: a wider one is caller error, asserted here
  /// on the caller's own value, before the bit writer masks it.
  bool serializeBits(Ref<int> value, int bits) {
    assert(bits >= 1 && bits <= 32);
    assert(valueFitsInBits(value.value, bits));
    _writer.writeBits(value.value, bits);
    return true;
  }

  /// Writes the low [bits] bits of the held value, bits in [1,64]: a single
  /// group for 32 bits or fewer, otherwise the low 32-bit group first, then
  /// the remaining bits - 32 high bits (STANDARD.md's splitting rule). The
  /// value must fit in [bits] bits at every width, not only at 32 or fewer.
  bool serializeBits64(Ref<int> value, int bits) {
    assert(bits >= 1 && bits <= 64);
    assert(valueFitsInBits(value.value, bits));
    if (bits <= 32) {
      _writer.writeBits(value.value, bits);
    } else {
      _writer.writeBits(value.value & 0xFFFFFFFF, 32);
      _writer.writeBits(value.value >>> 32, bits - 32);
    }
    return true;
  }

  /// Writes a ranged 32-bit integer: value - min in bitsRequired(min,max)
  /// bits. A degenerate range writes nothing at all.
  bool serializeInt(Ref<int> value, int min, int max) {
    assert(min <= max);
    assert(value.value >= min);
    assert(value.value <= max);
    if (min == max) {
      return true; // degenerate range: the value IS the range, nothing to send
    }
    // the diff is exact: int32 bounds keep max - min within [0, 2^32 - 1],
    // the unsigned domain the reference's bits_required computes in
    final bits = (max - min).bitLength;
    // subtract in the unsigned domain: wraps when the range is wider than 2^31
    final unsignedValue = (value.value - min) & 0xFFFFFFFF;
    _writer.writeBits(unsignedValue, bits);
    return true;
  }

  /// Writes a ranged 64-bit integer, the only ranged 64-bit operation. Do
  /// not confuse with [serializeUint64], which is not ranged and always
  /// costs a full 64 bits.
  bool serializeInt64(Ref<int> value, int min, int max) {
    assert(min <= max);
    assert(value.value >= min);
    assert(value.value <= max);
    final bits = bitsRequired64(min, max);
    if (bits == 0) {
      return true; // degenerate range: the value IS the range, nothing to send
    }
    // subtract in the unsigned domain: wraps when the range is wider than 2^63
    final unsignedValue = value.value - min;
    if (bits <= 32) {
      _writer.writeBits(unsignedValue, bits);
    } else {
      // low dword first, then the high remainder: same convention as
      // serialize_bits and serialize_uint64
      _writer.writeBits(unsignedValue & 0xFFFFFFFF, 32);
      _writer.writeBits(unsignedValue >>> 32, bits - 32);
    }
    return true;
  }

  /// Writes a ranged 128-bit integer. The offset from min is computed in the
  /// unsigned 128-bit domain and written in 32-bit groups from least
  /// significant upward. Where the range fits 64 bits or fewer the bytes are
  /// identical to [serializeInt64] over the same bounds. A degenerate range
  /// where min == max is legal and costs zero bits, on this width exactly as
  /// on the narrower ones.
  bool serializeInt128(Ref<Int128> value, Int128 min, Int128 max) {
    assert(min <= max);
    assert(value.value >= min);
    assert(value.value <= max);
    final bits = bitsRequired128(min.toUnsigned(), max.toUnsigned());
    if (bits == 0) {
      return true; // degenerate range: the value IS the range, nothing to send
    }
    // subtract in the unsigned domain: wraps when the range is wider than 2^127
    final offset = value.value.toUnsigned() - min.toUnsigned();
    _writeGroups(offset, bits);
    return true;
  }

  void _writeGroups(UInt128 offset, int bits) {
    // 32-bit groups, least significant first: the same convention as
    // serialize_bits, serialize_uint64 and the wide fixed point path
    final group0 = offset.lo & 0xFFFFFFFF;
    final group1 = offset.lo >>> 32;
    final group2 = offset.hi & 0xFFFFFFFF;
    final group3 = offset.hi >>> 32;
    if (bits <= 32) {
      _writer.writeBits(group0, bits);
    } else if (bits <= 64) {
      _writer.writeBits(group0, 32);
      _writer.writeBits(group1, bits - 32);
    } else if (bits <= 96) {
      _writer.writeBits(group0, 32);
      _writer.writeBits(group1, 32);
      _writer.writeBits(group2, bits - 64);
    } else {
      _writer.writeBits(group0, 32);
      _writer.writeBits(group1, 32);
      _writer.writeBits(group2, 32);
      _writer.writeBits(group3, bits - 96);
    }
  }

  /// Writes an unsigned 8-bit integer: serializeBits at width 8.
  bool serializeUint8(Ref<int> value) => serializeBits(value, 8);

  /// Writes an unsigned 16-bit integer: serializeBits at width 16.
  bool serializeUint16(Ref<int> value) => serializeBits(value, 16);

  /// Writes an unsigned 32-bit integer: serializeBits at width 32.
  bool serializeUint32(Ref<int> value) => serializeBits(value, 32);

  /// Writes an unsigned 64-bit integer: 64 raw bits, low 32 first. Not
  /// ranged — see [serializeInt64] for the ranged operation.
  bool serializeUint64(Ref<int> value) => serializeBits64(value, 64);

  /// Writes an unsigned 128-bit integer: 128 raw bits, the low 64-bit half
  /// first, then the high half, each as serialize_bits(half, 64).
  bool serializeUint128(Ref<UInt128> value) {
    _writer.writeBits(value.value.lo & 0xFFFFFFFF, 32);
    _writer.writeBits(value.value.lo >>> 32, 32);
    _writer.writeBits(value.value.hi & 0xFFFFFFFF, 32);
    _writer.writeBits(value.value.hi >>> 32, 32);
    return true;
  }

  /// Writes a boolean as one bit: 1 for true, 0 for false.
  bool serializeBool(Ref<bool> value) {
    _writer.writeBits(value.value ? 1 : 0, 1);
    return true;
  }

  /// Writes the 32 bits of the IEEE-754 single-precision representation of
  /// the held value, as one 32-bit group. The value must be finite AFTER it
  /// narrows to float32 — a finite double above the float32 range narrows to
  /// an infinity — and a non-finite one is caller error, asserted in debug
  /// (STANDARD.md, "Finite values only"). Every finite pattern is bit exact,
  /// negative zero and the subnormals included.
  bool serializeFloat(Ref<double> value) {
    final bits = float32BitsFromDouble(value.value);
    assert(float32BitsAreFinite(bits));
    _writer.writeBits(bits, 32);
    return true;
  }

  /// Writes the 64 bits of the IEEE-754 double-precision representation of
  /// the held value, as one 64-bit group. The value must be finite, asserted
  /// in debug. Bit exact.
  bool serializeDouble(Ref<double> value) {
    final bits = float64BitsFromDouble(value.value);
    assert(float64BitsAreFinite(bits));
    _writer.writeBits(bits & 0xFFFFFFFF, 32);
    _writer.writeBits(bits >>> 32, 32);
    return true;
  }

  /// Writes the held value quantized to a resolution (STANDARD.md,
  /// "compressed_float"). The value is clamped into [min,max] and quantized
  /// in float32 with TWO roundings — the product rounds before 0.5 is added
  /// — and the quantized integer is clamped to the step count (the normative
  /// integer clamp, 2026-08-23). Writing a non-finite value is
  /// non-conforming and asserts in debug, and so does a declaration whose
  /// top decodes to an infinity. Lossy by construction.
  bool serializeCompressedFloat(
    Ref<double> value,
    double min,
    double max,
    double resolution,
  ) {
    _compressedFloatParams(min, max, resolution);
    final params = _floatParams;
    // a declaration whose top integer decodes to an infinity is
    // non-conforming as a whole (STANDARD.md, format 2.0), so the writer
    // asserts it even for values that decode finite: the decode of
    // maxIntegerValue is min + delta, rounded once. Write side only: a
    // reader refuses the non-finite decode itself, as non_finite_float
    assert(fround(params.min + params.delta).isFinite);
    // the float parameter type of the reference: the value rounds to float32
    // at this boundary
    final value32 = fround(value.value);
    // writing a non-finite value (NaN, +/-Inf) through compressed_float is
    // non-conforming (STANDARD.md, adopted 2026-08-15) — assert in debug. In
    // release the clamp below remains the backstop.
    assert(value32.isFinite);

    // clamp with the !>= / !<= form so a NaN is forced into range
    var normalized = fround(fround(value32 - params.min) / params.delta);
    if (!(normalized >= 0.0)) {
      normalized = 0.0;
    } else if (!(normalized <= 1.0)) {
      normalized = 1.0;
    }
    // STANDARD.md pins this to float32 with TWO roundings: the product
    // rounds BEFORE 0.5 is added. Both fround calls are load bearing —
    // fused or widened arithmetic changes the wire.
    final scaled = fround(
      normalized * fround(params.maxIntegerValue.toDouble()),
    );
    var integerValue = fround(scaled + 0.5).floor();
    // STANDARD.md: the integer clamp is normative (2026-08-23, schema#109).
    // Once maxIntegerValue >= 2^23 the float32 ulp at the top of the range
    // reaches 1, so the rounded sum can exceed maxIntegerValue itself.
    if (integerValue > params.maxIntegerValue) {
      integerValue = params.maxIntegerValue;
    }
    _writer.writeBits(integerValue, params.bits);
    return true;
  }

  /// Writes an array of bytes: an align to the byte boundary first — the
  /// alignment is part of the format — then data.length raw bytes. The count
  /// is not written; both sides must already agree on it. A zero-length
  /// array still aligns and writes nothing else.
  bool serializeBytes(Uint8List data) {
    serializeAlign();
    _writer.writeBytes(data);
    return true;
  }

  /// Writes a UTF-8 string: the byte length as serializeInt in
  /// [0,bufferSize-1], then the bytes via [serializeBytes] — which aligns.
  /// The payload is well-formed UTF-8 with no zero byte by the writer's
  /// contract; a Dart string with an unpaired surrogate or a U+0000 violates
  /// it (debug-asserted).
  bool serializeString(Ref<String> value, int bufferSize) {
    assert(_isValidUtf16(value.value)); // the writer's contract, debug only
    assert(!value.value.contains('\u0000')); // likewise: no embedded NUL
    final encoded = utf8.encode(value.value);
    assert(encoded.length < bufferSize);
    final length = Ref<int>(encoded.length);
    serializeInt(length, 0, bufferSize - 1);
    serializeBytes(encoded);
    return true;
  }

  /// Writes an alignment: zero bits pad until the bit index is a multiple
  /// of 8. If the stream is already aligned, nothing is written.
  bool serializeAlign() {
    _writer.writeAlign();
    return true;
  }

  /// Writes a nested object inline, adding no bytes of its own.
  bool serializeObject(Serializable object) => object.serialize(this);

  /// Writes the end of the object: nothing at all. The unused bits of the
  /// final byte are already zero, which is what a reader's end checks.
  bool serializeEnd() => true;

  /// Writes [current] relative to [previous], where current > previous: the
  /// ladder of one-bit flags (STANDARD.md, "int_relative"). Both values lie
  /// in the domain, 0 to 2^31 - 1 inclusive, and no wrap semantics exist — a
  /// caller with a wrapping counter unwraps it before serializing.
  bool serializeIntRelative(int previous, Ref<int> current) {
    assert(previous >= 0 && previous <= intRelativeMax);
    assert(current.value >= 0 && current.value <= intRelativeMax);
    assert(previous < current.value);
    // the domain keeps the difference exact: no wrap to account for
    final difference = current.value - previous;

    if (difference == 1) {
      _writer.writeBits(1, 1);
      return true;
    }
    _writer.writeBits(0, 1);
    for (var tier = 0; tier < _relativeTierMin.length; tier++) {
      final tierMin = _relativeTierMin[tier];
      final tierMax = _relativeTierMax[tier];
      if (difference <= tierMax) {
        _writer.writeBits(1, 1);
        // the tier payload is serialize_int over the tier's bounds
        _writer.writeBits(difference - tierMin, (tierMax - tierMin).bitLength);
        return true;
      }
      _writer.writeBits(0, 1);
    }
    // the final tier transmits current itself, as 32 raw bits
    _writer.writeBits(current.value, 32);
    return true;
  }

  /// Writes a fixed point value held in integer storage of exactly
  /// integerBits + fractionBits bits (8, 16, 32 or 64), the sign bit
  /// counting toward integerBits. min and max are bounds in whole units.
  /// The raw value is written as an offset over the raw (scaled) bounds; a
  /// degenerate range costs zero bits. For 128-bit storage see
  /// [serializeFixed128].
  bool serializeFixed(
    Ref<int> value,
    int integerBits,
    int fractionBits,
    int min,
    int max,
  ) {
    _fixedPointParams(integerBits, fractionBits, min, max);
    final params = _fixedParams;
    if (min == max) {
      // degenerate range: the value IS the range, nothing to send
      // (STANDARD.md: min == max costs zero bits, on every storage width)
      assert(value.value == params.rawMin);
      return true;
    }
    // subtract in the unsigned domain
    final offset = value.value - params.rawMin;
    assert(!unsignedGreaterThan(offset, params.rawRange));
    final bits = params.bits;
    if (bits <= 32) {
      _writer.writeBits(offset, bits);
    } else {
      // low dword first, then the high remainder: same convention as
      // serialize_bits and serialize_int64
      _writer.writeBits(offset & 0xFFFFFFFF, 32);
      _writer.writeBits(offset >>> 32, bits - 32);
    }
    return true;
  }

  /// The 128-bit storage counterpart of [serializeFixed]: integerBits +
  /// fractionBits must equal 128, and the offset is written in 32-bit groups
  /// from least significant upward, exactly as serialize_bits splits wide
  /// values.
  bool serializeFixed128(
    Ref<Int128> value,
    int integerBits,
    int fractionBits,
    int min,
    int max,
  ) {
    _fixedPointParams128(integerBits, fractionBits, min, max);
    final params = _fixedParams128;
    if (min == max) {
      // degenerate range: zero bits, on every storage width — fractionBits
      // of zeros is NOT a degenerate encoding
      assert(value.value.toUnsigned() == params.rawMin);
      return true;
    }
    final offset = value.value.toUnsigned() - params.rawMin;
    assert(!(offset > params.rawRange));
    _writeGroups(offset, params.bits);
    return true;
  }

  /// Flushes the stream to memory. Always call this after you finish
  /// writing and before you call [data].
  void flush() => _writer.flushBits();

  /// The written portion of the buffer: a view, not a copy. Call [flush]
  /// first.
  Uint8List data() => _writer.data();

  /// The number of align bits required at the current bit index, in [0,7].
  int get alignBits => _writer.alignBits;

  /// The number of bits written so far.
  int get bitsProcessed => _writer.bitsWritten;

  /// The number of bytes written so far: effectively the packet size.
  int get bytesProcessed => _writer.bytesWritten;
}

// ---------------------------------------------------------------------------
// ReadStream
// ---------------------------------------------------------------------------

/// Stream for reading bitpacked data: a wrapper around [BitReader] providing
/// the unified serialize surface. The wire is a trust boundary: every
/// refusal rule of STANDARD.md binds in every build mode, a refused
/// operation returns false, and hostile bytes never throw. A failed read is
/// terminal for the stream — nothing after the failing operation has a
/// defined position — and [refusal] names the rule that refused it.
///
/// A packet reader calls [serializeEnd] after the last field of the packet's
/// top-level object: without it, trailing bytes and padding go unexamined.
final class ReadStream implements BitStream {
  final BitReader _reader;
  Refusal? _refusal;

  /// Creates a read stream over the bitpacked data in [data]. Any length is
  /// supported; no allocation slack past the data is required.
  ReadStream(Uint8List data) : _reader = BitReader(data);

  /// Points the stream at a data array and clears all read state, including
  /// the failure latch and its reason: re-initialization is the one
  /// operation that clears a failure (STANDARD.md, "Reader Obligations").
  void reset(Uint8List data) {
    _reader.reset(data);
    _refusal = null;
  }

  /// Refuses the current read for [reason] and latches the failure, so every
  /// later read on this stream fails too, consuming no bits and writing no
  /// destination. The FIRST refusal's reason is kept: a later refusal on a
  /// failed stream is an echo of it. Always returns false, so a refusing read
  /// reads `return _refuse(Refusal.pastEnd);`.
  ///
  /// The latch is the recommended form: the bit index is poisoned past the
  /// end of the data and the past-end check already on every read path does
  /// the rest, which costs the read path nothing. The zero-bit paths — a
  /// degenerate range consumes nothing and so has no past-end check of its
  /// own — ask [BitReader.wouldReadPastEnd] for zero bits to see the latch.
  bool _refuse(Refusal reason) {
    _refusal ??= reason;
    _reader.poison();
    return false;
  }

  /// Why this stream refused: the reason for the first refused read since the
  /// stream was created or [reset], spelled by [Refusal.name] exactly as
  /// STANDARD.md spells it. Null while nothing has been refused, and on a
  /// stream that failed only because a caller's own [Serializable.serialize]
  /// returned false without a refused read, which names no wire rule.
  Refusal? get refusal => _refusal;

  /// True once a read on this stream has failed, and until [reset]. Every
  /// read after a failure fails: nothing after the failing operation has a
  /// defined position, so nothing after it is interpretable.
  bool get failed => _reader.wouldReadPastEnd(0);

  /// False.
  bool get isWriting => false;

  /// True: this stream assigns ref values.
  bool get isReading => true;

  /// Reads [bits] bits into the holder, bits in [1,32]. Returns false if the
  /// read would pass the end of the data.
  bool serializeBits(Ref<int> value, int bits) {
    assert(bits >= 1 && bits <= 32);
    if (_reader.wouldReadPastEnd(bits)) {
      return _refuse(Refusal.pastEnd);
    }
    value.value = _reader.readBits(bits);
    return true;
  }

  /// Reads [bits] bits into the holder, bits in [1,64]: a single group for
  /// 32 bits or fewer, otherwise the low 32-bit group then the high
  /// remainder.
  bool serializeBits64(Ref<int> value, int bits) {
    assert(bits >= 1 && bits <= 64);
    // one bounds check for the whole group: the two reads are sequential on
    // the same stream, so checking their sum accepts and refuses exactly the
    // same inputs as checking each in turn
    if (_reader.wouldReadPastEnd(bits)) {
      return _refuse(Refusal.pastEnd);
    }
    if (bits <= 32) {
      value.value = _reader.readBits(bits);
      return true;
    }
    final lo = _reader.readBits(32);
    final hi = _reader.readBits(bits - 32);
    value.value = (hi << 32) | lo;
    return true;
  }

  /// Reads a ranged 32-bit integer. The decoded value is guaranteed to be
  /// in [min,max] if this returns true; an out-of-range offset smuggled
  /// into the bit headroom is refused.
  bool serializeInt(Ref<int> value, int min, int max) {
    assert(min <= max);
    if (min == max) {
      // degenerate range: the value IS the range. Nothing is consumed, so
      // the latch is the only thing that can refuse here
      if (failed) {
        return false;
      }
      value.value = min;
      return true;
    }
    // the diff is exact: int32 bounds keep max - min within [0, 2^32 - 1]
    final bits = (max - min).bitLength;
    if (_reader.wouldReadPastEnd(bits)) {
      return _refuse(Refusal.pastEnd);
    }
    final unsignedValue = _reader.readBits(bits);
    if (unsignedValue > max - min) {
      return _refuse(Refusal.valueOutOfRange);
    }
    // add in the unsigned domain, then convert back to the signed 32-bit
    // value the range describes
    value.value = ((unsignedValue + min) & 0xFFFFFFFF).toSigned(32);
    return true;
  }

  /// Reads a ranged 64-bit integer, with the same refusal rules at 64 bits.
  bool serializeInt64(Ref<int> value, int min, int max) {
    assert(min <= max);
    final bits = bitsRequired64(min, max);
    if (bits == 0) {
      // degenerate range: the value IS the range, nothing is consumed
      if (failed) {
        return false;
      }
      value.value = min;
      return true;
    }
    if (_reader.wouldReadPastEnd(bits)) {
      return _refuse(Refusal.pastEnd);
    }
    int unsignedValue;
    if (bits <= 32) {
      unsignedValue = _reader.readBits(bits);
    } else {
      // low dword first, then the high remainder
      final lo = _reader.readBits(32);
      final hi = _reader.readBits(bits - 32);
      unsignedValue = (hi << 32) | lo;
    }
    // compare in the unsigned domain: the range may be wider than 2^63
    if (unsignedGreaterThan(unsignedValue, max - min)) {
      return _refuse(Refusal.valueOutOfRange);
    }
    // add in the unsigned domain: wraps two's complement
    value.value = unsignedValue + min;
    return true;
  }

  /// Reads a ranged 128-bit integer: 32-bit groups least significant first,
  /// offset checked against the range in the unsigned domain — reject,
  /// never clamp. A degenerate range where min == max consumes nothing and
  /// takes the value from min.
  bool serializeInt128(Ref<Int128> value, Int128 min, Int128 max) {
    assert(min <= max);
    final minU = min.toUnsigned();
    final maxU = max.toUnsigned();
    final bits = bitsRequired128(minU, maxU);
    if (bits == 0) {
      // degenerate range: nothing is consumed, so the latch is the only
      // thing that can refuse here. The zero-bit path never reaches
      // _readGroups, whose primitive reads 1 to 32 bits at a time
      if (failed) {
        return false;
      }
      value.value = min;
      return true;
    }
    if (_reader.wouldReadPastEnd(bits)) {
      return _refuse(Refusal.pastEnd);
    }
    final offset = _readGroups(bits);
    if (offset > maxU - minU) {
      return _refuse(Refusal.valueOutOfRange);
    }
    // add in the unsigned domain: wraps two's complement
    value.value = (offset + minU).toSigned();
    return true;
  }

  UInt128 _readGroups(int bits) {
    var group0 = 0;
    var group1 = 0;
    var group2 = 0;
    var group3 = 0;
    if (bits <= 32) {
      group0 = _reader.readBits(bits);
    } else if (bits <= 64) {
      group0 = _reader.readBits(32);
      group1 = _reader.readBits(bits - 32);
    } else if (bits <= 96) {
      group0 = _reader.readBits(32);
      group1 = _reader.readBits(32);
      group2 = _reader.readBits(bits - 64);
    } else {
      group0 = _reader.readBits(32);
      group1 = _reader.readBits(32);
      group2 = _reader.readBits(32);
      group3 = _reader.readBits(bits - 96);
    }
    return UInt128((group3 << 32) | group2, (group1 << 32) | group0);
  }

  /// Reads an unsigned 8-bit integer.
  bool serializeUint8(Ref<int> value) => serializeBits(value, 8);

  /// Reads an unsigned 16-bit integer.
  bool serializeUint16(Ref<int> value) => serializeBits(value, 16);

  /// Reads an unsigned 32-bit integer.
  bool serializeUint32(Ref<int> value) => serializeBits(value, 32);

  /// Reads an unsigned 64-bit integer: 64 raw bits, low 32 first.
  bool serializeUint64(Ref<int> value) => serializeBits64(value, 64);

  /// Reads an unsigned 128-bit integer: the low 64-bit half first, then the
  /// high half, each half as serialize_bits(half, 64).
  bool serializeUint128(Ref<UInt128> value) {
    // one bounds check for all four groups: the reads are sequential on the
    // same stream, so checking their sum refuses exactly the same inputs
    if (_reader.wouldReadPastEnd(128)) {
      return _refuse(Refusal.pastEnd);
    }
    final loLow = _reader.readBits(32);
    final loHigh = _reader.readBits(32);
    final hiLow = _reader.readBits(32);
    final hiHigh = _reader.readBits(32);
    value.value = UInt128((hiHigh << 32) | hiLow, (loHigh << 32) | loLow);
    return true;
  }

  /// Reads a boolean from one bit.
  bool serializeBool(Ref<bool> value) {
    if (_reader.wouldReadPastEnd(1)) {
      return _refuse(Refusal.pastEnd);
    }
    value.value = _reader.readBits(1) != 0;
    return true;
  }

  /// Reads a finite float: the holder receives exactly the bits read — no
  /// flush, no canonicalization, negative zero and the subnormals kept. A
  /// pattern whose exponent field is all ones (NaN with any payload, either
  /// infinity) is refused as [Refusal.nonFiniteFloat], tested on the raw
  /// bits before any conversion, and the holder is untouched.
  bool serializeFloat(Ref<double> value) {
    if (_reader.wouldReadPastEnd(32)) {
      return _refuse(Refusal.pastEnd);
    }
    final bits = _reader.readBits(32);
    if (!float32BitsAreFinite(bits)) {
      return _refuse(Refusal.nonFiniteFloat);
    }
    value.value = doubleFromFloat32Bits(bits);
    return true;
  }

  /// Reads a finite double, bit exactly, with the same refusal at 64 bits.
  bool serializeDouble(Ref<double> value) {
    // one bounds check for both groups: the reads are sequential on the same
    // stream, so checking their sum refuses exactly the same inputs
    if (_reader.wouldReadPastEnd(64)) {
      return _refuse(Refusal.pastEnd);
    }
    final lo = _reader.readBits(32);
    final hi = _reader.readBits(32);
    final bits = (hi << 32) | lo;
    if (!float64BitsAreFinite(bits)) {
      return _refuse(Refusal.nonFiniteFloat);
    }
    value.value = doubleFromFloat64Bits(bits);
    return true;
  }

  /// Reads a compressed float: exactly the declaration's bit count, decoded
  /// as quantum index / step count * delta + min, every step rounding to
  /// float32 — the product rounds BEFORE min is added, which the conformance
  /// vectors pin bit-exactly. An integer above the step count is refused, and
  /// so is a decode that rounds past the float32 range: the holder never
  /// receives an infinity.
  bool serializeCompressedFloat(
    Ref<double> value,
    double min,
    double max,
    double resolution,
  ) {
    _compressedFloatParams(min, max, resolution);
    final params = _floatParams;
    if (_reader.wouldReadPastEnd(params.bits)) {
      return _refuse(Refusal.pastEnd);
    }
    final integerValue = _reader.readBits(params.bits);
    if (integerValue > params.maxIntegerValue) {
      return _refuse(Refusal.valueOutOfRange);
    }
    final normalized = fround(
      fround(integerValue.toDouble()) /
          fround(params.maxIntegerValue.toDouble()),
    );
    // the product must round to float32 BEFORE min is added: a fused decode
    // is one ulp off whenever min is non-zero
    final scaled = fround(normalized * params.delta);
    final decoded = fround(scaled + params.min);
    // every operand is finite and the integer is in range, and still the
    // final add can round past the float32 maximum (STANDARD.md, "The decode
    // must be finite"): refused whatever the declaration, holder untouched
    if (!decoded.isFinite) {
      return _refuse(Refusal.nonFiniteFloat);
    }
    value.value = decoded;
    return true;
  }

  /// Reads data.length bytes into [data]: an align first — its padding
  /// verified zero — then a straight copy. STANDARD.md leaves a caller-owned
  /// buffer's contents unspecified after a refusal, so portable callers must
  /// not read [data] back on a false return; this reader refuses before it
  /// copies anything, so here the buffer is in fact untouched.
  bool serializeBytes(Uint8List data) {
    // the align comes first, so set padding is refused as nonzero_padding
    // even when the payload would also run past the end
    if (!serializeAlign()) {
      return false; // refused by the align, which named the reason
    }
    // compare in bytes rather than bits, consistent with the 64-bit
    // bookkeeping of the reference
    if (data.length > _reader.bitsRemaining ~/ 8) {
      return _refuse(Refusal.pastEnd);
    }
    _reader.readBytes(data);
    return true;
  }

  /// Reads a UTF-8 string. Malformed payloads are refused in every build
  /// mode (STANDARD.md, "string"): a zero byte among the transmitted bytes
  /// is [Refusal.embeddedNul] — the two-lengths smuggling primitive — and a
  /// payload that is not well formed is [Refusal.invalidUtf8]. The NUL scan
  /// runs over the whole payload first, so a payload breaking both rules is
  /// embedded_nul. Every well-formed payload is accepted and decoded exactly:
  /// no normalization, no stripped byte order mark, no replacement. On
  /// refusal the holder is untouched.
  bool serializeString(Ref<String> value, int bufferSize) {
    final length = Ref<int>(0);
    if (!serializeInt(length, 0, bufferSize - 1)) {
      return false; // refused by the length field, which named the reason
    }
    final bytes = Uint8List(length.value);
    if (!serializeBytes(bytes)) {
      return false; // refused by the bytes, which named the reason
    }
    // interior NUL first: NUL is valid UTF-8, so the validator below cannot
    // catch it, and a conforming writer is never handed one, so a zero byte
    // only arrives doctored
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] == 0) {
        return _refuse(Refusal.embeddedNul);
      }
    }
    if (!_isValidUtf8(bytes, bytes.length)) {
      return _refuse(Refusal.invalidUtf8);
    }
    // the validator above has already refused everything malformed, and the
    // decoder stays strict regardless: a replacement character must never
    // stand in for a byte the wire carried
    final text = utf8.decode(bytes, allowMalformed: false);
    // dart:convert drops a LEADING byte order mark, and the wire's bytes are
    // the text: U+FEFF is a character like any other and must round trip
    // (STANDARD.md, "string": no stripped byte order mark). It is put back
    // here; one anywhere else in the payload is kept by the decoder itself
    value.value = _startsWithByteOrderMark(bytes) ? '\uFEFF$text' : text;
    return true;
  }

  /// Reads an alignment: skips ahead to the next byte boundary, verifying
  /// the padding bits are zero, and refuses if they are not.
  bool serializeAlign() {
    if (_reader.wouldReadPastEnd(_reader.alignBits)) {
      return _refuse(Refusal.pastEnd);
    }
    if (!_reader.readAlign()) {
      return _refuse(Refusal.nonzeroPadding);
    }
    return true;
  }

  /// Reads a nested object inline, consuming no bits of its own. The failure
  /// state is consulted first, so a nested object refuses on a stream that
  /// has already failed, and a refusal inside the object propagates out of
  /// the composition rather than being swallowed by it, keeping its reason.
  bool serializeObject(Serializable object) {
    if (failed) {
      return false;
    }
    if (!object.serialize(this)) {
      // the object's own serialize returned false: latch the failure so it
      // is terminal, keeping the reason of the read that refused, if any
      _reader.poison();
      return false;
    }
    return true;
  }

  /// Reads the end of the object (STANDARD.md, "end"). The object ends at
  /// the bit index after its last field, and the stream must end there too:
  /// a whole byte or more left over is [Refusal.trailingData], checked first,
  /// and otherwise the remaining zero to seven bits are the final byte's
  /// padding, read and required zero, or [Refusal.nonzeroPadding]. An
  /// accepted end leaves the stream exactly consumed. On a failed stream the
  /// end is refused like any read, keeping the first refusal's reason.
  bool serializeEnd() {
    if (failed) {
      return _refuse(Refusal.pastEnd); // an echo: the first reason is kept
    }
    final remaining = _reader.bitsRemaining;
    if (remaining >= 8) {
      return _refuse(Refusal.trailingData);
    }
    // fewer than 8 bits remain here, so this is all of them: the final
    // byte's padding. The field bits before it are the last field's and are
    // never read
    final paddingBits = remaining & 7;
    if (paddingBits > 0) {
      final padding = _reader.readBits(paddingBits);
      if (padding != 0) {
        return _refuse(Refusal.nonzeroPadding);
      }
    }
    return true;
  }

  /// Reads a relative integer: the ladder of one-bit flags. Every tier's
  /// reconstruction is checked (STANDARD.md, "int_relative"): the value is
  /// rebuilt in a width that cannot wrap, then compared against the domain —
  /// 0 to 2^31 - 1 inclusive — and against [previous], and the read is
  /// refused unless it lies in the domain and is strictly greater. That binds
  /// in the one-bit tier, in each bounded tier, and in the absolute tier,
  /// whose 32 raw bits are unsigned: a value with the top bit set is outside
  /// the domain and refused. Those refusals are [Refusal.valueOutOfRange].
  /// The absolute tier is canonical too: carrying a value no more than the
  /// last bounded tier's top above [previous], which a bounded tier would
  /// have taken, it is refused as [Refusal.nonCanonical], after the domain
  /// rule. The holder is untouched on refusal.
  bool serializeIntRelative(int previous, Ref<int> current) {
    assert(previous >= 0 && previous <= intRelativeMax);
    if (_reader.wouldReadPastEnd(1)) {
      return _refuse(Refusal.pastEnd);
    }
    if (_reader.readBits(1) != 0) {
      // Dart's int is 64 bits wide, so the reconstruction cannot wrap: the
      // check below is what keeps the result in the domain
      final reconstructed = previous + 1;
      if (reconstructed > intRelativeMax) {
        return _refuse(Refusal.valueOutOfRange);
      }
      current.value = reconstructed;
      return true;
    }
    for (var tier = 0; tier < _relativeTierMin.length; tier++) {
      if (_reader.wouldReadPastEnd(1)) {
        return _refuse(Refusal.pastEnd);
      }
      if (_reader.readBits(1) != 0) {
        // the tier payload is serialize_int over the tier's bounds
        final tierMin = _relativeTierMin[tier];
        final tierMax = _relativeTierMax[tier];
        final bits = (tierMax - tierMin).bitLength;
        if (_reader.wouldReadPastEnd(bits)) {
          return _refuse(Refusal.pastEnd);
        }
        final offset = _reader.readBits(bits);
        if (offset > tierMax - tierMin) {
          return _refuse(Refusal.valueOutOfRange);
        }
        final reconstructed = previous + tierMin + offset;
        // the domain and the order, as in every tier: the order holds by
        // construction while the payload decodes over its tier's minimum,
        // and is checked here rather than assumed
        if (reconstructed > intRelativeMax || reconstructed <= previous) {
          return _refuse(Refusal.valueOutOfRange);
        }
        current.value = reconstructed;
        return true;
      }
    }
    // the final tier transmits current itself, as 32 raw bits, read
    // unsigned: readBits returns the group zero extended, so a top bit set
    // shows up as a value above the domain rather than as a negative
    if (_reader.wouldReadPastEnd(32)) {
      return _refuse(Refusal.pastEnd);
    }
    final reconstructed = _reader.readBits(32);
    if (reconstructed > intRelativeMax || reconstructed <= previous) {
      return _refuse(Refusal.valueOutOfRange);
    }
    // the domain and ordering rule came first, so the difference here is
    // positive and exact in Dart's 64-bit int: a difference a bounded tier
    // carries has a shorter encoding, and this one is a second encoding of it
    if (reconstructed - previous <= _relativeTierMax.last) {
      return _refuse(Refusal.nonCanonical);
    }
    current.value = reconstructed;
    return true;
  }

  /// Reads a fixed point value on storage of 8, 16, 32 or 64 bits. The
  /// decoded offset is checked against the raw range — reject, never clamp.
  bool serializeFixed(
    Ref<int> value,
    int integerBits,
    int fractionBits,
    int min,
    int max,
  ) {
    _fixedPointParams(integerBits, fractionBits, min, max);
    final params = _fixedParams;
    if (min == max) {
      // degenerate range: the value IS the range, recovered from the range
      // alone — the raw value is min << fractionBits. Nothing is consumed
      if (failed) {
        return false;
      }
      value.value = _storageValue(params.rawMin, params.width, params.signed);
      return true;
    }
    final bits = params.bits;
    int offset;
    if (bits <= 32) {
      if (_reader.wouldReadPastEnd(bits)) {
        return _refuse(Refusal.pastEnd);
      }
      offset = _reader.readBits(bits);
    } else {
      if (_reader.wouldReadPastEnd(32)) {
        return _refuse(Refusal.pastEnd);
      }
      final lo = _reader.readBits(32);
      if (_reader.wouldReadPastEnd(bits - 32)) {
        return _refuse(Refusal.pastEnd);
      }
      final hi = _reader.readBits(bits - 32);
      offset = (hi << 32) | lo;
    }
    // reject raw values outside [rawMin,rawMax] smuggled into the bit
    // headroom. reject, never clamp
    if (unsignedGreaterThan(offset, params.rawRange)) {
      return _refuse(Refusal.valueOutOfRange);
    }
    // reconstruct in the unsigned domain, then convert: wraps two's
    // complement for signed storage
    value.value = _storageValue(
      params.rawMin + offset,
      params.width,
      params.signed,
    );
    return true;
  }

  static int _storageValue(int raw, int width, bool signed) => width == 64
      ? raw
      : (signed ? raw.toSigned(width) : raw.toUnsigned(width));

  /// Reads a fixed point value on 128-bit storage: 32-bit groups least
  /// significant first, offset checked against the raw range in the unsigned
  /// 128-bit domain.
  bool serializeFixed128(
    Ref<Int128> value,
    int integerBits,
    int fractionBits,
    int min,
    int max,
  ) {
    _fixedPointParams128(integerBits, fractionBits, min, max);
    final params = _fixedParams128;
    if (min == max) {
      // degenerate range: nothing is consumed, the value comes from min
      if (failed) {
        return false;
      }
      value.value = params.rawMin.toSigned();
      return true;
    }
    if (_reader.wouldReadPastEnd(params.bits)) {
      return _refuse(Refusal.pastEnd);
    }
    final offset = _readGroups(params.bits);
    if (offset > params.rawRange) {
      return _refuse(Refusal.valueOutOfRange);
    }
    value.value = (params.rawMin + offset).toSigned();
    return true;
  }

  /// The number of align bits required at the current bit index, in [0,7].
  int get alignBits => _reader.alignBits;

  /// The number of bits read so far.
  int get bitsProcessed => _reader.bitsRead;

  /// The number of bytes read so far: the bits read, rounded up to a byte.
  int get bytesProcessed => (_reader.bitsRead + 7) ~/ 8;
}

// ---------------------------------------------------------------------------
// MeasureStream
// ---------------------------------------------------------------------------

/// Stream for measuring how many bits a message would take to serialize. It
/// acts like a write stream (isWriting is true) but counts bits instead of
/// producing them. A measure is a BOUND, not the packet size (STANDARD.md,
/// "The Measure Stream"): every alignment-performing operation is charged
/// the worst case of 7 bits, and everything else exact width, so the bound
/// is sufficient at every starting bit position. A measure refuses nothing
/// at runtime — it sits on the trusted side of the boundary.
final class MeasureStream implements BitStream {
  int _bitsWritten = 0;

  /// Creates a measure stream with zero bits counted.
  MeasureStream();

  /// Clears the count, allowing a single measure stream to be reused.
  void reset() => _bitsWritten = 0;

  /// True: this stream consumes ref values, like a write stream.
  bool get isWriting => true;

  /// False.
  bool get isReading => false;

  /// Measures [bits] bits, bits in [1,32]. The value must fit in that many
  /// bits, the same caller contract a write is under.
  bool serializeBits(Ref<int> value, int bits) {
    assert(bits >= 1 && bits <= 32);
    assert(valueFitsInBits(value.value, bits));
    _bitsWritten += bits;
    return true;
  }

  /// Measures [bits] bits, bits in [1,64].
  bool serializeBits64(Ref<int> value, int bits) {
    assert(bits >= 1 && bits <= 64);
    assert(valueFitsInBits(value.value, bits));
    _bitsWritten += bits;
    return true;
  }

  /// Measures a ranged 32-bit integer: exactly bitsRequired(min,max) bits.
  bool serializeInt(Ref<int> value, int min, int max) {
    assert(min <= max);
    assert(value.value >= min);
    assert(value.value <= max);
    _bitsWritten += min == max ? 0 : (max - min).bitLength;
    return true;
  }

  /// Measures a ranged 64-bit integer.
  bool serializeInt64(Ref<int> value, int min, int max) {
    assert(min <= max);
    assert(value.value >= min);
    assert(value.value <= max);
    _bitsWritten += bitsRequired64(min, max);
    return true;
  }

  /// Measures a ranged 128-bit integer. A degenerate range where min == max
  /// adds zero bits.
  bool serializeInt128(Ref<Int128> value, Int128 min, Int128 max) {
    assert(min <= max);
    assert(value.value >= min);
    assert(value.value <= max);
    _bitsWritten += bitsRequired128(min.toUnsigned(), max.toUnsigned());
    return true;
  }

  /// Measures 8 bits.
  bool serializeUint8(Ref<int> value) => serializeBits(value, 8);

  /// Measures 16 bits.
  bool serializeUint16(Ref<int> value) => serializeBits(value, 16);

  /// Measures 32 bits.
  bool serializeUint32(Ref<int> value) => serializeBits(value, 32);

  /// Measures 64 bits.
  bool serializeUint64(Ref<int> value) => serializeBits64(value, 64);

  /// Measures 128 bits.
  bool serializeUint128(Ref<UInt128> value) {
    _bitsWritten += 128;
    return true;
  }

  /// Measures one bit.
  bool serializeBool(Ref<bool> value) {
    _bitsWritten += 1;
    return true;
  }

  /// Measures 32 bits.
  bool serializeFloat(Ref<double> value) {
    _bitsWritten += 32;
    return true;
  }

  /// Measures 64 bits.
  bool serializeDouble(Ref<double> value) {
    _bitsWritten += 64;
    return true;
  }

  /// Measures a compressed float: exactly the declaration's bit count.
  bool serializeCompressedFloat(
    Ref<double> value,
    double min,
    double max,
    double resolution,
  ) {
    _compressedFloatParams(min, max, resolution);
    _bitsWritten += _floatParams.bits;
    return true;
  }

  /// Measures an aligned byte array: the worst-case 7 align bits plus the
  /// bytes.
  bool serializeBytes(Uint8List data) {
    serializeAlign();
    _bitsWritten += data.length * 8;
    return true;
  }

  /// Measures a UTF-8 string: the length field plus the aligned bytes.
  bool serializeString(Ref<String> value, int bufferSize) {
    assert(_isValidUtf16(value.value));
    assert(!value.value.contains('\u0000'));
    final encoded = utf8.encode(value.value);
    assert(encoded.length < bufferSize);
    final length = Ref<int>(encoded.length);
    serializeInt(length, 0, bufferSize - 1);
    serializeBytes(encoded);
    return true;
  }

  /// Measures an align: always the worst case of 7 bits, because alignment
  /// cost depends on the bit position the message is later written at, which
  /// a measure does not know. Exact-from-zero accounting is non-conforming.
  bool serializeAlign() {
    _bitsWritten += alignBits;
    return true;
  }

  /// Measures a nested object inline, adding no bits of its own.
  bool serializeObject(Serializable object) => object.serialize(this);

  /// Measures the end of the object: nothing, it costs no bits.
  bool serializeEnd() => true;

  /// Measures a relative integer: the exact ladder cost for this value.
  bool serializeIntRelative(int previous, Ref<int> current) {
    assert(previous >= 0 && previous <= intRelativeMax);
    assert(current.value >= 0 && current.value <= intRelativeMax);
    assert(previous < current.value);
    // the domain keeps the difference exact: no wrap to account for
    final difference = current.value - previous;
    if (difference == 1) {
      _bitsWritten += 1;
      return true;
    }
    _bitsWritten += 1;
    for (var tier = 0; tier < _relativeTierMin.length; tier++) {
      _bitsWritten += 1;
      if (difference <= _relativeTierMax[tier]) {
        _bitsWritten += bitsRequired(
          _relativeTierMin[tier],
          _relativeTierMax[tier],
        );
        return true;
      }
    }
    _bitsWritten += 32;
    return true;
  }

  /// Measures a fixed point value on storage of 8, 16, 32 or 64 bits.
  bool serializeFixed(
    Ref<int> value,
    int integerBits,
    int fractionBits,
    int min,
    int max,
  ) {
    _fixedPointParams(integerBits, fractionBits, min, max);
    if (min == max) {
      assert(value.value == _fixedParams.rawMin);
      return true;
    }
    assert(
      !unsignedGreaterThan(
        value.value - _fixedParams.rawMin,
        _fixedParams.rawRange,
      ),
    );
    _bitsWritten += _fixedParams.bits;
    return true;
  }

  /// Measures a fixed point value on 128-bit storage.
  bool serializeFixed128(
    Ref<Int128> value,
    int integerBits,
    int fractionBits,
    int min,
    int max,
  ) {
    _fixedPointParams128(integerBits, fractionBits, min, max);
    if (min == max) {
      assert(value.value.toUnsigned() == _fixedParams128.rawMin);
      return true;
    }
    assert(
      !(value.value.toUnsigned() - _fixedParams128.rawMin >
          _fixedParams128.rawRange),
    );
    _bitsWritten += _fixedParams128.bits;
    return true;
  }

  /// Always the worst case of 7 bits: the measurement is conservative
  /// because the number of align bits depends on where the message lands.
  int get alignBits => 7;

  /// The number of bits measured so far.
  int get bitsProcessed => _bitsWritten;

  /// The number of bytes measured so far.
  int get bytesProcessed => (_bitsWritten + 7) ~/ 8;
}
