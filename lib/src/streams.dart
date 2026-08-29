// The three streams: WriteStream, ReadStream and MeasureStream.
//
// Each implements the full serialize surface of the reference (serialize.h),
// specialized per mode exactly as the C++ templates instantiate per stream —
// the family's ports without templates (C#, JavaScript) carry the same
// per-stream specialization, and this port follows them.
//
// Writes assume trusted data (STANDARD.md): caller contracts on the write
// and measure paths are asserted, active in debug, compiled out in release.
// Reads VALIDATE ALWAYS: every refusal rule of STANDARD.md binds in every
// build mode, out-of-range or truncated input refuses cleanly as a false
// return, and hostile bytes never throw.
//
// Dart has no by-reference parameters, so values pass through [Ref] holders,
// the same shape as the JavaScript port's {value} holders. serializeBytes
// fills its Uint8List in place.

import 'dart:convert';
import 'dart:typed_data';

import 'bitpacker.dart';
import 'bits.dart';
import 'float32.dart';
import 'int128.dart';

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

// The whole-unit capacity checks of serialize_fixed_internal, translated as
// the JavaScript port translates them: the format is read as signed exactly
// when min < 0, and the signedness never reaches the wire — for the same
// bounds, signed and unsigned storage produce identical bytes.
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

/*
    The string and wstring payloads are well formed BY CONTRACT (STANDARD.md,
    adopted 2026-08-15): a Dart String carrying an unpaired surrogate is a
    writer contract violation on both paths — utf8.encode would replace it,
    and the wstring wire forbids it — debug-asserted per the writes-trusted
    doctrine. Referenced only from asserts; compiled out in release.
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

  /// Serializes a bit-transparent IEEE-754 single-precision float.
  bool serializeFloat(Ref<double> value);

  /// Serializes a bit-transparent IEEE-754 double-precision float.
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

  /// Serializes a null-terminated UTF-8 string against a buffer size.
  bool serializeString(Ref<String> value, int bufferSize);

  /// Serializes a wide string: one 32-bit group per UTF-16 code unit.
  bool serializeWideString(Ref<String> value, int bufferSize);

  /// Serializes an alignment to the next byte boundary.
  bool serializeAlign();

  /// Serializes [current] relative to [previous], current > previous.
  bool serializeIntRelative(int previous, Ref<int> current);

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

  /// Writes the low [bits] bits of the held value, bits in [1,32].
  bool serializeBits(Ref<int> value, int bits) {
    assert(bits >= 1 && bits <= 32);
    _writer.writeBits(value.value, bits);
    return true;
  }

  /// Writes the low [bits] bits of the held value, bits in [1,64]: a single
  /// group for 32 bits or fewer, otherwise the low 32-bit group first, then
  /// the remaining bits - 32 high bits (STANDARD.md's splitting rule).
  bool serializeBits64(Ref<int> value, int bits) {
    assert(bits >= 1 && bits <= 64);
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
    // the diff is exact: int32 bounds keep max - min within [0, 2^32 - 1],
    // the unsigned domain the reference's bits_required computes in
    final bits = min == max ? 0 : (max - min).bitLength;
    if (bits == 0) {
      return true; // degenerate range: the value IS the range, nothing to send
    }
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
  /// identical to [serializeInt64] over the same bounds.
  bool serializeInt128(Ref<Int128> value, Int128 min, Int128 max) {
    assert(min < max);
    assert(value.value >= min);
    assert(value.value <= max);
    final bits = bitsRequired128(min.toUnsigned(), max.toUnsigned());
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
  /// the held value, as one 32-bit group. Bit transparent: every pattern is
  /// legal on the wire and NaN payloads ride byte-for-byte.
  bool serializeFloat(Ref<double> value) {
    _writer.writeBits(float32BitsFromDouble(value.value), 32);
    return true;
  }

  /// Writes the 64 bits of the IEEE-754 double-precision representation of
  /// the held value, as one 64-bit group. Bit transparent.
  bool serializeDouble(Ref<double> value) {
    final bits = float64BitsFromDouble(value.value);
    _writer.writeBits(bits & 0xFFFFFFFF, 32);
    _writer.writeBits(bits >>> 32, 32);
    return true;
  }

  /// Writes the held value quantized to a resolution (STANDARD.md,
  /// "compressed_float"). The value is clamped into [min,max] and quantized
  /// in float32 with TWO roundings — the product rounds before 0.5 is added
  /// — and the quantized integer is clamped to the step count (the normative
  /// integer clamp, 2026-08-23). Writing a non-finite value is
  /// non-conforming and asserts in debug. Lossy by construction.
  bool serializeCompressedFloat(
    Ref<double> value,
    double min,
    double max,
    double resolution,
  ) {
    _compressedFloatParams(min, max, resolution);
    final params = _floatParams;
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
  /// The payload is well-formed UTF-8 by the writer's contract; a Dart
  /// string with unpaired surrogates violates it (debug-asserted).
  bool serializeString(Ref<String> value, int bufferSize) {
    assert(_isValidUtf16(value.value)); // the writer's contract, debug only
    final encoded = utf8.encode(value.value);
    assert(encoded.length < bufferSize);
    final length = Ref<int>(encoded.length);
    serializeInt(length, 0, bufferSize - 1);
    serializeBytes(encoded);
    return true;
  }

  /// Writes a wide string: the length in UTF-16 code units as serializeInt
  /// in [0,bufferSize-1], then each code unit as a 32-bit group. No
  /// alignment is performed anywhere in this operation. bufferSize counts
  /// wide characters, not bytes. The payload is well-formed UTF-16 by the
  /// writer's contract (debug-asserted); surrogate pairs are valid — they
  /// are how astral text travels.
  bool serializeWideString(Ref<String> value, int bufferSize) {
    assert(_isValidUtf16(value.value)); // the writer's contract, debug only
    final string = value.value;
    assert(string.length < bufferSize);
    final length = Ref<int>(string.length);
    serializeInt(length, 0, bufferSize - 1);
    for (var i = 0; i < string.length; i++) {
      _writer.writeBits(string.codeUnitAt(i), 32);
    }
    return true;
  }

  /// Writes an alignment: zero bits pad until the bit index is a multiple
  /// of 8. If the stream is already aligned, nothing is written.
  bool serializeAlign() {
    _writer.writeAlign();
    return true;
  }

  /// Writes [current] relative to [previous], where current > previous: the
  /// ladder of one-bit flags (STANDARD.md, "int_relative"). The values are
  /// unsigned 32-bit; no wrap semantics exist — a caller with a wrapping
  /// counter unwraps it before serializing.
  bool serializeIntRelative(int previous, Ref<int> current) {
    assert(previous >= 0 && previous <= 0xFFFFFFFF);
    assert(current.value >= 0 && current.value <= 0xFFFFFFFF);
    assert(previous < current.value);
    // subtract in the unsigned domain
    final difference = (current.value - previous) & 0xFFFFFFFF;

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
/// defined position.
final class ReadStream implements BitStream {
  final BitReader _reader;

  /// Creates a read stream over the bitpacked data in [data]. Any length is
  /// supported; no allocation slack past the data is required.
  ReadStream(Uint8List data) : _reader = BitReader(data);

  /// Points the stream at a data array and clears all read state.
  void reset(Uint8List data) => _reader.reset(data);

  /// False.
  bool get isWriting => false;

  /// True: this stream assigns ref values.
  bool get isReading => true;

  /// Reads [bits] bits into the holder, bits in [1,32]. Returns false if the
  /// read would pass the end of the data.
  bool serializeBits(Ref<int> value, int bits) {
    assert(bits >= 1 && bits <= 32);
    if (_reader.wouldReadPastEnd(bits)) {
      return false;
    }
    value.value = _reader.readBits(bits);
    return true;
  }

  /// Reads [bits] bits into the holder, bits in [1,64]: a single group for
  /// 32 bits or fewer, otherwise the low 32-bit group then the high
  /// remainder.
  bool serializeBits64(Ref<int> value, int bits) {
    assert(bits >= 1 && bits <= 64);
    if (bits <= 32) {
      if (_reader.wouldReadPastEnd(bits)) {
        return false;
      }
      value.value = _reader.readBits(bits);
      return true;
    }
    if (_reader.wouldReadPastEnd(32)) {
      return false;
    }
    final lo = _reader.readBits(32);
    if (_reader.wouldReadPastEnd(bits - 32)) {
      return false;
    }
    final hi = _reader.readBits(bits - 32);
    value.value = (hi << 32) | lo;
    return true;
  }

  /// Reads a ranged 32-bit integer. The decoded value is guaranteed to be
  /// in [min,max] if this returns true; an out-of-range offset smuggled
  /// into the bit headroom is refused.
  bool serializeInt(Ref<int> value, int min, int max) {
    assert(min <= max);
    // the diff is exact: int32 bounds keep max - min within [0, 2^32 - 1]
    final bits = min == max ? 0 : (max - min).bitLength;
    if (bits == 0) {
      value.value = min; // degenerate range: the value IS the range
      return true;
    }
    if (_reader.wouldReadPastEnd(bits)) {
      return false;
    }
    final unsignedValue = _reader.readBits(bits);
    if (unsignedValue > max - min) {
      return false;
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
      value.value = min; // degenerate range: the value IS the range
      return true;
    }
    if (_reader.wouldReadPastEnd(bits)) {
      return false;
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
      return false;
    }
    // add in the unsigned domain: wraps two's complement
    value.value = unsignedValue + min;
    return true;
  }

  /// Reads a ranged 128-bit integer: 32-bit groups least significant first,
  /// offset checked against the range in the unsigned domain — reject,
  /// never clamp.
  bool serializeInt128(Ref<Int128> value, Int128 min, Int128 max) {
    assert(min < max);
    final minU = min.toUnsigned();
    final maxU = max.toUnsigned();
    final bits = bitsRequired128(minU, maxU);
    if (_reader.wouldReadPastEnd(bits)) {
      return false;
    }
    final offset = _readGroups(bits);
    if (offset > maxU - minU) {
      return false;
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
    var lo = 0;
    var hi = 0;
    for (var half = 0; half < 2; half++) {
      if (_reader.wouldReadPastEnd(32)) {
        return false;
      }
      final low = _reader.readBits(32);
      if (_reader.wouldReadPastEnd(32)) {
        return false;
      }
      final high = _reader.readBits(32);
      if (half == 0) {
        lo = (high << 32) | low;
      } else {
        hi = (high << 32) | low;
      }
    }
    value.value = UInt128(hi, lo);
    return true;
  }

  /// Reads a boolean from one bit.
  bool serializeBool(Ref<bool> value) {
    if (_reader.wouldReadPastEnd(1)) {
      return false;
    }
    value.value = _reader.readBits(1) != 0;
    return true;
  }

  /// Reads a bit-transparent float: the holder receives exactly the bits
  /// read — no canonicalization, no quieting, no refusal of any pattern.
  bool serializeFloat(Ref<double> value) {
    if (_reader.wouldReadPastEnd(32)) {
      return false;
    }
    value.value = doubleFromFloat32Bits(_reader.readBits(32));
    return true;
  }

  /// Reads a bit-transparent double.
  bool serializeDouble(Ref<double> value) {
    if (_reader.wouldReadPastEnd(32)) {
      return false;
    }
    final lo = _reader.readBits(32);
    if (_reader.wouldReadPastEnd(32)) {
      return false;
    }
    final hi = _reader.readBits(32);
    value.value = doubleFromFloat64Bits((hi << 32) | lo);
    return true;
  }

  /// Reads a compressed float: exactly the declaration's bit count, decoded
  /// as quantum index / step count * delta + min, every step rounding to
  /// float32 — the product rounds BEFORE min is added, which the conformance
  /// vectors pin bit-exactly. An integer above the step count is refused.
  bool serializeCompressedFloat(
    Ref<double> value,
    double min,
    double max,
    double resolution,
  ) {
    _compressedFloatParams(min, max, resolution);
    final params = _floatParams;
    if (_reader.wouldReadPastEnd(params.bits)) {
      return false;
    }
    final integerValue = _reader.readBits(params.bits);
    if (integerValue > params.maxIntegerValue) {
      return false;
    }
    final normalized = fround(
      fround(integerValue.toDouble()) /
          fround(params.maxIntegerValue.toDouble()),
    );
    // the product must round to float32 BEFORE min is added: a fused decode
    // is one ulp off whenever min is non-zero
    final scaled = fround(normalized * params.delta);
    value.value = fround(scaled + params.min);
    return true;
  }

  /// Reads data.length bytes into [data]: an align first — its padding
  /// verified zero — then a straight copy. On refusal data is untouched.
  bool serializeBytes(Uint8List data) {
    if (!serializeAlign()) {
      return false;
    }
    // compare in bytes rather than bits, consistent with the 64-bit
    // bookkeeping of the reference
    if (data.length > _reader.bitsRemaining ~/ 8) {
      return false;
    }
    _reader.readBytes(data);
    return true;
  }

  /// Reads a UTF-8 string. Malformed payloads are refused in every build
  /// mode (STANDARD.md, adopted 2026-08-15): an interior NUL among the
  /// transmitted bytes fails the read — the two-lengths smuggling primitive
  /// — and so does invalid UTF-8. On refusal the holder is untouched.
  bool serializeString(Ref<String> value, int bufferSize) {
    final length = Ref<int>(0);
    if (!serializeInt(length, 0, bufferSize - 1)) {
      return false;
    }
    final bytes = Uint8List(length.value);
    if (!serializeBytes(bytes)) {
      return false;
    }
    // interior NUL first: NUL is valid UTF-8, so the validator below cannot
    // catch it, and a conforming writer derives the length from the
    // terminator, so a zero byte only arrives doctored
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] == 0) {
        return false;
      }
    }
    if (!_isValidUtf8(bytes, bytes.length)) {
      return false;
    }
    value.value = utf8.decode(bytes);
    return true;
  }

  /// Reads a wide string: each 32-bit group carries one UTF-16 code unit.
  /// Malformed payloads are refused in every build mode: a group above
  /// 0xFFFF is not a code unit, an unpaired surrogate fails the read — a
  /// high without its low, a low with no high before it, or a dangling high
  /// as the final group — and so does an interior NUL group. Well-formed
  /// surrogate pairs pass: they are how astral text travels.
  bool serializeWideString(Ref<String> value, int bufferSize) {
    final length = Ref<int>(0);
    if (!serializeInt(length, 0, bufferSize - 1)) {
      return false;
    }
    final units = Uint16List(length.value);
    var pending = false; // a high surrogate awaiting its pair
    for (var i = 0; i < length.value; i++) {
      if (_reader.wouldReadPastEnd(32)) {
        return false;
      }
      final character = _reader.readBits(32);
      if (character > 0xFFFF) {
        return false; // not a UTF-16 code unit: nothing conforming emits one
      }
      if (character == 0) {
        return false; // interior NUL: the two-lengths smuggling primitive
      }
      if (pending) {
        if (character < 0xDC00 || character > 0xDFFF) {
          return false; // high surrogate without its low
        }
        pending = false;
      } else if (character >= 0xDC00 && character <= 0xDFFF) {
        return false; // low surrogate with no high before it
      } else if (character >= 0xD800 && character <= 0xDBFF) {
        pending = true;
      }
      units[i] = character;
    }
    if (pending) {
      return false; // the final group is a dangling high surrogate
    }
    value.value = String.fromCharCodes(units);
    return true;
  }

  /// Reads an alignment: skips ahead to the next byte boundary, verifying
  /// the padding bits are zero, and refuses if they are not.
  bool serializeAlign() {
    if (_reader.wouldReadPastEnd(_reader.alignBits)) {
      return false;
    }
    return _reader.readAlign();
  }

  /// Reads a relative integer: the ladder of one-bit flags. The final tier
  /// carries the absolute value, and the reader verifies current > previous
  /// — refusing otherwise, since the absolute form carries no ordering
  /// guarantee of its own.
  bool serializeIntRelative(int previous, Ref<int> current) {
    assert(previous >= 0 && previous <= 0xFFFFFFFF);
    if (_reader.wouldReadPastEnd(1)) {
      return false;
    }
    if (_reader.readBits(1) != 0) {
      // reconstruct in the unsigned domain
      current.value = (previous + 1) & 0xFFFFFFFF;
      return true;
    }
    for (var tier = 0; tier < _relativeTierMin.length; tier++) {
      if (_reader.wouldReadPastEnd(1)) {
        return false;
      }
      if (_reader.readBits(1) != 0) {
        // the tier payload is serialize_int over the tier's bounds
        final tierMin = _relativeTierMin[tier];
        final tierMax = _relativeTierMax[tier];
        final bits = (tierMax - tierMin).bitLength;
        if (_reader.wouldReadPastEnd(bits)) {
          return false;
        }
        final offset = _reader.readBits(bits);
        if (offset > tierMax - tierMin) {
          return false;
        }
        current.value = (previous + tierMin + offset) & 0xFFFFFFFF;
        return true;
      }
    }
    // the final tier transmits current itself, as 32 raw bits
    if (_reader.wouldReadPastEnd(32)) {
      return false;
    }
    current.value = _reader.readBits(32);
    if (current.value <= previous) {
      return false;
    }
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
      // alone — the raw value is min << fractionBits
      value.value = _storageValue(params.rawMin, params.width, params.signed);
      return true;
    }
    final bits = params.bits;
    int offset;
    if (bits <= 32) {
      if (_reader.wouldReadPastEnd(bits)) {
        return false;
      }
      offset = _reader.readBits(bits);
    } else {
      if (_reader.wouldReadPastEnd(32)) {
        return false;
      }
      final lo = _reader.readBits(32);
      if (_reader.wouldReadPastEnd(bits - 32)) {
        return false;
      }
      final hi = _reader.readBits(bits - 32);
      offset = (hi << 32) | lo;
    }
    // reject raw values outside [rawMin,rawMax] smuggled into the bit
    // headroom. reject, never clamp
    if (unsignedGreaterThan(offset, params.rawRange)) {
      return false;
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
      value.value = params.rawMin.toSigned();
      return true;
    }
    if (_reader.wouldReadPastEnd(params.bits)) {
      return false;
    }
    final offset = _readGroups(params.bits);
    if (offset > params.rawRange) {
      return false;
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

  /// Measures [bits] bits, bits in [1,32].
  bool serializeBits(Ref<int> value, int bits) {
    assert(bits >= 1 && bits <= 32);
    _bitsWritten += bits;
    return true;
  }

  /// Measures [bits] bits, bits in [1,64].
  bool serializeBits64(Ref<int> value, int bits) {
    assert(bits >= 1 && bits <= 64);
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

  /// Measures a ranged 128-bit integer.
  bool serializeInt128(Ref<Int128> value, Int128 min, Int128 max) {
    assert(min < max);
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
    final encoded = utf8.encode(value.value);
    assert(encoded.length < bufferSize);
    final length = Ref<int>(encoded.length);
    serializeInt(length, 0, bufferSize - 1);
    serializeBytes(encoded);
    return true;
  }

  /// Measures a wide string: the length field plus 32 bits per UTF-16 code
  /// unit. No alignment anywhere in this operation.
  bool serializeWideString(Ref<String> value, int bufferSize) {
    assert(_isValidUtf16(value.value));
    assert(value.value.length < bufferSize);
    final length = Ref<int>(value.value.length);
    serializeInt(length, 0, bufferSize - 1);
    _bitsWritten += 32 * value.value.length;
    return true;
  }

  /// Measures an align: always the worst case of 7 bits, because alignment
  /// cost depends on the bit position the message is later written at, which
  /// a measure does not know. Exact-from-zero accounting is non-conforming.
  bool serializeAlign() {
    _bitsWritten += alignBits;
    return true;
  }

  /// Measures a relative integer: the exact ladder cost for this value.
  bool serializeIntRelative(int previous, Ref<int> current) {
    assert(previous >= 0 && previous <= 0xFFFFFFFF);
    assert(current.value >= 0 && current.value <= 0xFFFFFFFF);
    assert(previous < current.value);
    final difference = (current.value - previous) & 0xFFFFFFFF;
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
