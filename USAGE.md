# Using serialize.dart

Everything the library does, by example. The wire format itself is defined
by the C++ reference's
[STANDARD.md](https://github.com/mas-bandwidth/serialize/blob/main/STANDARD.md);
this document teaches the Dart surface that speaks it.

```dart
import 'package:serialize/serialize.dart';
```

The library is not on pub.dev yet — depend on it from git and that import
resolves unchanged. See [README.md](README.md#getting-it).

## One serialize function, three streams

The family's defining pattern: write, read and measure share a single
serialize function. Every operation returns a bool, values travel in
`Ref<T>` holders (the Dart translation of the family's ref parameters),
and the stream direction decides whether the holder is consumed or
filled.

```dart
class Player {
  final health = Ref<int>(0);
  final alive = Ref<bool>(false);
  final heading = Ref<double>(0);
}

bool serializePlayer(BitStream stream, Player player) {
  return stream.serializeInt(player.health, 0, 100) &&
      stream.serializeBool(player.alive) &&
      stream.serializeFloat(player.heading);
}

// write
final player = Player()
  ..health.value = 87
  ..alive.value = true
  ..heading.value = 1.25;
final writer = WriteStream(Uint8List(64)); // length a multiple of 8
serializePlayer(writer, player); // -> true
writer.flush(); // ALWAYS flush before touching the bytes
final wire = writer.data(); // a 5-byte view: 7 + 1 + 32 bits

// read
final reader = ReadStream(wire); // any length, no slack required
final decoded = Player();
serializePlayer(reader, decoded); // -> true
decoded.health.value; // 87

// measure
final measure = MeasureStream();
serializePlayer(measure, player); // -> true
measure.bitsProcessed; // 40
```

`WriteStream` needs a buffer whose length is a multiple of 8 (the writer
stores 64-bit words to memory). `ReadStream` accepts any data length and
never reads outside it. `MeasureStream` touches no memory at all — it
prices a message so you can size buffers; its bound is conservative (see
[Measuring](#measuring)).

All three streams expose `bitsProcessed`, `bytesProcessed`, `isWriting` /
`isReading`, and `reset(...)` for allocation-free reuse. `data()` returns
a view of the written bytes, not a copy.

## Writes trust, reads validate

The check model is the family standard's ("Writes assume trusted data"):
**the caller is responsible for well-formed writes**, and reads validate
everything, because the wire is a trust boundary.

On the read side, every failure — a truncated read, a value outside its
range, nonzero alignment padding, a malformed string — returns `false`,
and hostile bytes never throw.

**A refused read leaves its destination unwritten.** The `Ref` holder you
passed still holds exactly what it held before the call, so a caller that
trusts the holder over the return code is never handed a value the stream
did not carry. Two things the rule does not reach: `serializeBytes`,
`serializeString` and `serializeWideString` read into a buffer you own, and
its contents after a refusal are unspecified; and a sequence of reads over
an object or an array may leave earlier members written, because the rule
is per primitive read.

**A failure is terminal.** Nothing after the failing operation has a
defined position, so the stream latches: `failed` becomes true, and every
later read fails, consuming no bits and writing no destination — including
a zero-bit read of a degenerate range. Only `reset(...)`, which points the
stream at data again, clears it. The bit index is not the refusal point
afterwards; after a refusal the position is not part of the contract.

```dart
final r = ReadStream(Uint8List.fromList([0x00])); // 8 bits of data
r.serializeBits(v, 32); // -> false: past the end
r.serializeBits(v, 8); // -> false too: the stream is latched
r.failed; // -> true

r.reset(Uint8List.fromList([0x00])); // point at fresh data, state cleared
r.serializeBits(v, 8); // -> true

// an offset smuggled into the bit headroom of a range is refused
final r2 = ReadStream(Uint8List.fromList([0xff]));
r2.serializeInt(ranged, 0, 200); // -> false: 8 bits carry 255, above max
```

One rule follows from clean refusal: check the result of any serialized
value that controls a loop before the loop uses it, or a truncated packet
spins the loop on garbage.

On the write side, `WriteStream` and `MeasureStream` operations always
return `true` — caller contracts (bit counts in range, values within
their declared ranges, min ≤ max, well-formed string payloads, buffers
that fit) are `assert` statements, the Dart form of the family's debug
asserts:

- **Checked** (`dart run --enable-asserts`, and
  `dart compile exe --enable-asserts`): contract violations throw
  `AssertionError` at the call site. Develop and test here.
- **Release** (the default for `dart run`, `dart compile exe` and Flutter
  release builds): asserts do not exist, exactly as a C++ release build
  compiles `serialize_assert` to nothing. The caller is trusted; misuse
  produces garbage on the wire (which conforming readers refuse), never
  memory unsafety — Dart's own bounds semantics backstop the trusted
  path.

The wire for conforming writes is byte identical in both modes — the test
suite runs green under both.

## Raw bits

`serializeBits` moves the low `bits` of a non-negative value, 1 to 32.
`serializeBits64` is its 64-bit twin — Dart ints are 64 bits, so wide
values need no separate domain. Values wider than 32 bits go low 32-bit
dword first — the family's group rule.

```dart
final w = WriteStream(Uint8List(16));
w.serializeBits(Ref(5), 3); // 3 bits on the wire
w.serializeBits(Ref(0xdeadbeef), 32); // full width
w.serializeBits64(Ref(0x123456789abcdef0), 64); // low 32-bit group first
w.serializeAlign(); // zero-pads to the next byte boundary
w.flush();
```

`serializeAlign` writes zero bits up to the next byte boundary (nothing if
already aligned); the reader verifies the padding is zero and refuses
otherwise.

## Ranged integers

`serializeInt(ref, min, max)` is the format's defining operation: the
value rides as an offset from `min` in exactly `bitsRequired(min, max)`
bits. Both sides must state the same range — the range is part of the
message format, not the wire.

```dart
w.serializeInt(Ref(-37), -100, 100); // 8 bits
w.serializeInt(Ref(7), 7, 7); // degenerate range: ZERO bits
```

Reads refuse values smuggled into the bit headroom of a range (an offset
above `max - min` fails the read — reject, never clamp).

`serializeInt64` is the same operation across the full 64-bit domain,
with offsets computed in unsigned arithmetic so ranges wider than 2^63
are exact. `serializeInt128` extends it to 128 bits on the `Int128` pair
type, written in 32-bit groups least significant first; where the range
fits 64 bits the bytes are identical to `serializeInt64`.

`min <= max` is the legal relation on every ranged operation — `int`,
`int64`, `int128` and `fixed` — in every build mode. The degenerate range
is a field to accept, not a misuse: the writer emits nothing, the reader
consumes nothing and takes the value from `min`, and a measure adds zero,
on the 128-bit width exactly as on the narrower ones. `compressedFloat` is
not a ranged operation and is the exception: it quantizes across its
bounds, so it requires `min < max`.

```dart
w.serializeInt64(Ref(-5000000000), -5000000000, 5000000000); // 34 bits
w.serializeInt128(Ref(Int128.fromInt(-1)), Int128.minValue, Int128.maxValue); // 128 bits
```

`bitsRequired(min, max)`, `bitsRequired64` and `bitsRequired128` price a
range when designing a message format. They live in the **unsigned**
domain: 32/64-bit unsigned values are held bit-transparently in Dart's
signed 64-bit int, and 128-bit bounds are `UInt128`.

```dart
bitsRequired(0, 200); // 8: the cost of serializeInt over [-100, +100]
bitsRequired64(0, 5000000000); // 33
bitsRequired128(UInt128.zero, UInt128.fromInt(1) << 100); // 101
```

## The unsigned helpers and bool

Fixed-width conveniences. The 8/16/32/64-bit helpers take plain ints;
`serializeUint128` is always 128 bits on the `UInt128` pair, low 64-bit
half first. `serializeBool` is one bit.

```dart
w.serializeUint8(Ref(0x7f));
w.serializeUint16(Ref(0x1234));
w.serializeUint32(Ref(0x12345678));
w.serializeUint64(Ref(0x123456789abcdef0));
w.serializeUint128(Ref((UInt128.fromInt(1) << 100) + UInt128.fromInt(1)));
w.serializeBool(Ref(true));
```

Unsigned 64-bit values ride bit-transparently in Dart's signed int:
`0xFFFFFFFFFFFFFFFF` and `-1` are the same bits, and the wire neither
knows nor cares. The `Int128` / `UInt128` pairs are two's complement
`(hi, lo)` halves with the arithmetic, shift and comparison operators the
serialize surface needs; `fromInt` sign-extends, `toSigned()` /
`toUnsigned()` reinterpret bit-transparently.

## Floats and doubles: bit transparent

`serializeFloat` (32 bits) and `serializeDouble` (64 bits) reproduce the
transmitted pattern exactly — every pattern is legal on the wire: NaNs
with any payload, signaling NaNs, infinities, negative zero, denormals.
Float32 values ride a software narrowing/widening that never sets the
quiet bit. Note that a float is 32 bits on the wire: write `fround`ed
values or you'll be surprised by the read-back.

```dart
w.serializeFloat(Ref(fround(3.1415926))); // float32 on the wire
w.serializeDouble(Ref(1.0 / 3.0));
w.serializeFloat(Ref(-0.0)); // -0 round trips as -0
```

The bit-transparency helpers are exported for code that works with raw
patterns: `float32BitsFromDouble` / `doubleFromFloat32Bits`,
`float64BitsFromDouble` / `doubleFromFloat64Bits`, and `fround` — the
float32 rounding boundary the compressed float arithmetic is pinned to.

## The compressed float

`serializeCompressedFloat(ref, min, max, resolution)` quantizes into a
declared range at a resolution — the one lossy operation. The declaration
is part of the message format. The arithmetic is float32 with the
standard's two roundings on each side (every step passes through
`fround` — the roundings are part of the format, and the family's
discriminating vectors pin the decoded bit patterns exactly).

```dart
w.serializeCompressedFloat(Ref(5.0), 0.0, 10.0, 0.01); // 10 bits
// reading it back yields exactly 5.0: the value sits on a quantum.
// off-quantum values come back within the resolution; re-encoding a
// decoded value is byte-identical (the round trip is idempotent).
```

Finite values outside `[min, max]` clamp on write; writing a non-finite
value is a contract violation (asserted in debug, clamped in release);
reads refuse integers smuggled above the quantization ceiling.

## Nested objects

`serializeObject(object)` runs a nested `Serializable`'s own serialize
function inline. It is composition, not an encoding: it contributes no
bytes of its own, and inserts no framing, length prefix or alignment
around what the nested object writes.

```dart
class Header implements Serializable {
  final sequence = Ref<int>(0);
  final reliable = Ref<bool>(false);

  @override
  bool serialize(BitStream stream) =>
      stream.serializeBits(sequence, 16) && stream.serializeBool(reliable);
}

class Packet {
  final header = Header();
  final payload = Ref<int>(0);
}

bool serializePacket(BitStream stream, Packet packet) =>
    stream.serializeObject(packet.header) &&
    stream.serializeBits(packet.payload, 8);
```

Those 25 bits are exactly the bits the same three operations write
unnested. A refusal inside a nested object propagates out of it, and on a
read stream the failure state is consulted before the object is entered,
so a nested object on an already failed stream refuses without running.

## Raw bytes

`serializeBytes(data)` aligns to the byte boundary (the alignment is part
of the format, padding verified on read) and then bulk-copies. The count
is never transmitted: both sides agree by passing arrays of the same
length. On read, the `Uint8List` you pass is filled in place.

```dart
w.serializeBytes(Uint8List.fromList([0xde, 0xad, 0xbe, 0xef]));
// ...
final out = Uint8List(4);
r.serializeBytes(out); // out now holds the bytes
```

A zero-length array still performs (and verifies) the align.

## Strings: UTF-8 on the wire

`serializeString(ref, bufferSize)` sends the UTF-8 byte length as
`serializeInt(length, 0, bufferSize - 1)`, then the payload as
`serializeBytes` (which aligns). `bufferSize` is part of the message
format — the same string against different buffer sizes produces
different bytes — and the payload must fit `bufferSize - 1` bytes.

```dart
w.serializeString(Ref('golden'), 16);
final s = Ref('');
r.serializeString(s, 16); // s.value == 'golden'
```

Reads validate the payload in every build mode: malformed UTF-8
(overlongs, surrogate code points, values above U+10FFFF, truncated
sequences, stray continuations) and interior NULs fail the read. A Dart
string carrying an unpaired surrogate is a writer contract violation
(debug-asserted): `utf8.encode` would replace it, so it cannot reach the
wire faithfully.

## Wide strings: UTF-16 code units

`serializeWideString(ref, bufferSize)` sends the unit count, then one
32-bit group per UTF-16 code unit — never a code point — with no
alignment anywhere: the one place the wide path deliberately differs from
its narrow counterpart. A Dart string *is* a sequence of UTF-16 code
units, so astral characters are two groups on the wire, exactly as the
family's 2-byte-wchar_t ports split them. `bufferSize` counts wide
characters.

```dart
w.serializeWideString(Ref('\u{1f600}A'), 8); // 3 code units: 99 bits
```

Unpaired surrogates in a written string are a contract violation
(debug-asserted — the wide wire cannot carry ill-formed UTF-16, because
conforming readers refuse it). Reads refuse groups above 0xFFFF, interior
NUL groups, and unpaired, misordered or dangling surrogates.

## The relative integer

`serializeIntRelative(previous, ref)` prices strictly increasing
sequences — sequence numbers, ack chains. `current > previous` always, no
wrapping. A difference of 1 costs a single bit; small differences ride
payload tiers of 5/8/13/18/23 bits; past the ladder, six zero flags carry
`current` itself as 32 raw bits.

**The domain is 0 to 2^31 - 1 inclusive** (`intRelativeMax`), for both
`previous` and `current`. It belongs to the operation, not to Dart's int:
a `previous` of 2^31 is caller error exactly as a negative one is. The
reader reconstructs `current` in Dart's 64-bit int, which cannot wrap,
then checks the result against the domain and against `previous` — in the
one-bit tier, in each of the five bounded tiers, and in the absolute tier,
whose 32 raw bits are read unsigned, so a group with its top bit set is
outside the domain and refused. A refused read leaves your `Ref`
untouched, and latches the stream.

```dart
w.serializeIntRelative(100, Ref(101)); // 1 bit
w.serializeIntRelative(100, Ref(2100)); // a mid-ladder tier
// read side: pass the same previous, get current back
r.serializeIntRelative(100, seq); // seq.value == 101
```

`previous` is caller state, not wire: both sides already know it. Writing
`current <= previous`, or a `previous` outside the domain, is a contract
violation, asserted in checked builds. A caller with a wrapping counter
unwraps it before serializing: wrap-around is not an encoding this
operation carries.

## Fixed point

`serializeFixed(ref, integerBits, fractionBits, min, max)` carries
Q-format fixed point. `ref.value` is the **raw scaled integer** — the
real value times `2^fractionBits` — in storage of exactly
`integerBits + fractionBits` bits (8, 16, 32 or 64; the sign bit counts
toward `integerBits`). `min` and `max` are in **whole units**, part of
the message format. `serializeFixed128` is the 128-bit storage
counterpart: `integerBits + fractionBits` must equal 128, and the value
is a `Ref<Int128>`.

```dart
// -3.25 in Q8.8 over [-100, +100] whole units: raw is -3.25 * 256 = -832
w.serializeFixed(Ref(-832), 8, 8, -100, 100); // 16 bits

// 1234.5 in Q16.16 over [-2000, +2000]
w.serializeFixed(Ref(1234 * 65536 + 32768), 16, 16, -2000, 2000);

// 12345.5 in Q48.16 over [-100000, +100000]: 64-bit storage
w.serializeFixed(Ref(12345 * 65536 + 32768), 48, 16, -100000, 100000); // 34 bits

// Q64.64 over [-1000, +1000] whole units: 128-bit storage
final q6464 = Ref(Int128.fromInt(1) << 64); // exactly 1.0 in Q64.64
w.serializeFixed128(q6464, 64, 64, -1000, 1000);
```

The wire is the offset from `min << fractionBits` in exactly the bit
length of the raw range — byte identical to `serializeInt64` of the raw
value wherever storage fits 64 bits — and the round trip is **exact**: no
quantization, unlike the compressed float. A degenerate `min == max`
range costs zero bits on every storage width. Signedness never reaches
the wire: for the same bounds, signed and unsigned storage produce
identical bytes. Reads refuse raw values smuggled into the bit headroom;
an invalid declaration is caller misuse, asserted in debug.

## Measuring

`MeasureStream` prices a message without a buffer. For everything except
alignment it is exact; any operation that aligns (`serializeAlign`,
`serializeBytes`, `serializeString`) charges the worst case — 7 bits of
padding — because the measure stream cannot know what alignment the field
will land on inside your message. The guarantee is a bound, never
equality:

```dart
measure.bitsProcessed >= writer.bitsProcessed; // always true
```

Size buffers from the measured bound (rounded up to a multiple of 8 bytes
for `WriteStream`).

## The bitpacker underneath

`BitWriter` and `BitReader` are the streams' engine — the family wire on
Dart's native 64-bit integers — and are exported for code that wants raw
bitpacking without the serialize surface or its checks:

```dart
final bw = BitWriter(buffer);
bw.writeBits(5, 3);
bw.writeAlign();
bw.writeBytes(Uint8List.fromList([1, 2, 3]));
bw.flushBits();

final br = BitReader(bw.data());
br.readBits(3); // 5
br.readAlign(); // true: padding was zero
final out = Uint8List(3);
br.readBytes(out); // out is now [1, 2, 3]
```

The reader prices its windows **inside** the buffer: any data length is
supported and no slack past the data is required.

## Wire compatibility

The same values produce the same bytes in every family implementation.
This is not aspiration but pinned fact. `conformance/` holds the shared
corpus, vendored verbatim from the C++ reference and synced by CI, and the
test suite drives every vector in it through this reader — accepted
vectors must yield the stated value and consume the stated bits, refused
vectors must refuse. Beside it the suite carries the family's golden
vectors — including the golden wire message covering every operation
class, byte for byte — plus the discriminating float vectors, the string
and wide-string pins, every relative-integer tier, and the fixed point
shapes at every group count, all minted from the canonical C++
reference's own output. If your message serializes with the same
declarations on both ends, a stream written by any family implementation
reads in any other.

Two doctrines worth knowing at the edges:

- **Trailing bits**: writers zero the unused bits of the final byte;
  readers never reject a stream for their contents.
- **Past-end data**: bytes past the end of the data you hand `ReadStream`
  are never read, let alone interpreted.
