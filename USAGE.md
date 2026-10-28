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
      stream.serializeFloat(player.heading) &&
      stream.serializeEnd(); // the packet ends here: see "The end of a packet"
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
range, nonzero alignment padding, a malformed string, a non-finite float,
anything after the end of the packet — returns `false`, and hostile bytes
never throw.

**Every refusal has a reason.** `ReadStream.refusal` is the `Refusal`
behind the first refused read since the stream was created or reset, or
`null` while nothing has been refused. The list is the standard's, closed,
and `Refusal.name` spells each one exactly as the standard and the shared
corpus do:

| `Refusal` | `name` | the rule that refused |
|---|---|---|
| `pastEnd` | `past_end` | a read needs more bits than the stream holds |
| `valueOutOfRange` | `value_out_of_range` | a ranged offset past its span, a string length past its buffer, a compressed integer past its step count, an int_relative outside its domain or not increasing |
| `nonzeroPadding` | `nonzero_padding` | a set bit in an align's padding, or in the final byte's padding at the end |
| `trailingData` | `trailing_data` | a whole byte or more after the end of the packet |
| `nonFiniteFloat` | `non_finite_float` | a float or double that is NaN or an infinity, or a compressed float decode that is not finite |
| `invalidUtf8` | `invalid_utf8` | a string payload that is not well-formed UTF-8 |
| `embeddedNul` | `embedded_nul` | a zero byte among a string's bytes |
| `nonCanonical` | `non_canonical` | an int_relative absolute tier carrying a difference a bounded tier takes |
| `rejected` | `rejected` | the bytes were well formed, and you refused the value they carry |

The later refusals of a failed stream are echoes of the first and keep its
reason.

**Your own refusal is `rejected`.** When the bytes are well formed but your
validation says no (an enum value you do not know, two fields that
contradict each other), call `ReadStream.reject()`: it latches `rejected`,
terminal like any refusal, and returns `false`, so it reads
`return reader.reject();`. Inside a nested object, returning `false` from
your `Serializable.serialize` does the same: `serializeObject` latches
`rejected` when nothing inside the object refused, and keeps the inner
read's reason when something did. A refused stream always reports a reason.

`reject()` and `fail([reason])` are on every stream, so one serialize
function can refuse whichever stream it is handed: on a `ReadStream`,
`fail(reason)` latches that reason exactly as a read that refused for it
would, and `fail()` with no reason records `rejected`. On a `WriteStream`
or `MeasureStream`, `fail` records nothing, never throws, and returns
`false`, in every build. `reject()` is read only: on a write or a measure
it is caller misuse, an `AssertionError` in the checked build like any
other write misuse, and `false` with nothing recorded in release
(reference IMPLEMENTING.md U9). `refusalName(reader.refusal)` spells the
reason, and `none` while nothing has been refused.

**A bad declaration on a read refuses, never throws.** The declarations a
read is handed are checked before any bits move, in every build: a `bits`
count outside its range, `serializeInt` bounds outside int32, a `min` above
its `max`, a string `bufferSize` below 1, an `int_relative` `previous`
outside its domain, a fixed point declaration that does not fit its Q
format, and a compressed float declaration that is not conforming (or
precomputed constants `compressedFloatParams` would never derive) all
refuse as `value_out_of_range`, and a stream that already refused keeps its
first reason (IMPLEMENTING.md U5, U7, U16). On a write or a measure the
same declarations are caller error, asserted in the checked build.

**A refused read leaves its destination unwritten.** The `Ref` holder you
passed still holds exactly what it held before the call, so a caller that
trusts the holder over the return code is never handed a value the stream
did not carry. Two things the rule does not reach: `serializeBytes` and
`serializeString` read into a buffer you own, and its contents after a
refusal are unspecified; and a sequence of reads over
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
r.refusal; // -> Refusal.pastEnd, and r.refusal!.name is 'past_end'

r.reset(Uint8List.fromList([0x00])); // point at fresh data, state cleared
r.serializeBits(v, 8); // -> true

// an offset smuggled into the bit headroom of a range is refused
final r2 = ReadStream(Uint8List.fromList([0xff]));
r2.serializeInt(ranged, 0, 200); // -> false: 8 bits carry 255, above max
r2.refusal; // -> Refusal.valueOutOfRange
```

One rule follows from clean refusal: check the result of any serialized
value that controls a loop before the loop uses it, or a truncated packet
spins the loop on garbage.

On the write side there is one misuse mechanism, the trap (reference
IMPLEMENTING.md U9), and in Dart the trap is `assert`. Caller contracts
(bit counts in range, values within their declared ranges, `serializeInt` bounds within int32, min ≤ max,
well-formed string payloads, buffers whose length is a multiple of 8
bytes, room in the buffer for the whole of a `bytes` or `string` before
any of it is written, finite `float`, `double` and `compressed_float`
values, `reject()` only on a read) are `assert` statements, the Dart form
of the family's debug asserts. A `MeasureStream` makes every check a
`WriteStream` makes except room and buffer size (U6). Write misuse never
latches: no reason is recorded, no operation returns `false` for it, and
the next write goes ahead. Every write and measure operation returns
`true`, except `fail` (always `false`) and `reject` (above):

- **Checked** (`dart run --enable-asserts`, and
  `dart compile exe --enable-asserts`): contract violations throw
  `AssertionError` at the call site, before a bit of the operation is
  written. That is the trap. Develop and test here.
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

`serializeInt` bounds are int32 (IMPLEMENTING.md U5). A `min` or `max`
outside int32 is asserted on write and measure, and refused as
`value_out_of_range` on read before any bits move: a range such as
`[0, 0xFFFFFFFF]` belongs in `serializeInt64`.

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

## Floats and doubles: finite, every one bit exact

`serializeFloat` (32 bits) and `serializeDouble` (64 bits) carry **finite**
values, and reproduce each one's pattern exactly: negative zero and the
subnormals keep their bits, never flushed or re-signed. NaN, with any
payload or sign, and both infinities are not values the format carries. A
reader refuses such a pattern as `non_finite_float`, tested on the raw bits
before any conversion, and leaves your `Ref` untouched; writing one is a
contract violation, asserted in checked builds. The check runs after the
narrowing to float32, so a finite double above the float32 range, which
narrows to an infinity, is caught too. Note that a float is 32 bits on the
wire: write `fround`ed values or you'll be surprised by the read-back.

```dart
w.serializeFloat(Ref(fround(3.1415926))); // float32 on the wire
w.serializeDouble(Ref(1.0 / 3.0));
w.serializeFloat(Ref(-0.0)); // -0 round trips as -0
// w.serializeFloat(Ref(double.nan)); // AssertionError in a checked build
```

The conversion helpers are exported for code that works with raw patterns:
`float32BitsFromDouble` / `doubleFromFloat32Bits`, `float64BitsFromDouble`
/ `doubleFromFloat64Bits`, `float32BitsAreFinite` / `float64BitsAreFinite`,
and `fround` — the float32 rounding boundary the compressed float
arithmetic is pinned to.

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
value is a contract violation (asserted in debug, clamped in release), and
so is a declaration whose top integer decodes to an infinity, even for a
value that decodes finite. Reads refuse integers smuggled above the
quantization ceiling (`value_out_of_range`), and a decode that rounds past
the float32 range (`non_finite_float`): over `[3 * 2^103, FLT_MAX]` at
resolution `2^104`, every operand is finite and the top integer still
decodes to `+inf`.

The constants a declaration implies (the step count, the bit count and
`delta`) cost a divide, a clamp and a ceil per call. Generated code pays
them once: `compressedFloatParams(min, max, resolution)` returns them, and
`serializeCompressedFloatPrecomputed(ref, maxIntegerValue, bits, delta, min)`
takes them, wire identical to the unified call on every stream.

```dart
final p = compressedFloatParams(0.0, 10.0, 0.01); // 1000 steps, 10 bits
w.serializeCompressedFloatPrecomputed(Ref(5.0), p.maxIntegerValue, p.bits, p.delta, 0.0);
```

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
unnested. A refusal inside a nested object propagates out of it, keeping
its reason, and on a read stream the failure state is consulted before the
object is entered, so a nested object on an already failed stream refuses
without running. A nested object never reads an end: only the packet's
top-level object does.

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

Reads validate the payload in every build mode. A zero byte among the
payload is refused as `embedded_nul`; malformed UTF-8 (overlongs,
surrogate code points, values above U+10FFFF, truncated sequences, stray
continuations, bytes that never appear in UTF-8) as `invalid_utf8`. The
NUL scan runs over the whole payload first, so a payload breaking both
rules is `embedded_nul`. The decoder is strict: a replacement character
never stands in for a byte the wire carried.

Every well-formed payload is accepted and handed back exactly: no
normalization (`e` followed by U+0301 stays three bytes, distinct from the
precomposed U+00E9), no stripped byte order mark — `dart:convert` drops a
leading one, and the reader puts it back — noncharacters such as U+FFFF,
and every plane.

A Dart string carrying an unpaired surrogate, or a U+0000, is a writer
contract violation (debug-asserted): `utf8.encode` would silently replace
a lone surrogate with U+FFFD, so it cannot reach the wire faithfully, and
a conforming reader refuses a NUL.

To bound text that may be too long, `copyString(source, destSize)` (the
reference's `serialize_copy_string`) returns the longest prefix that
`serializeString` with `bufferSize = destSize` accepts: the text before
the first U+0000, cut to at most `destSize - 1` UTF-8 bytes and never
inside a character. `destSize` counts UTF-8 bytes, not UTF-16 code units.
A `destSize` below 1, or a source with an unpaired surrogate, is write
misuse (an `AssertionError` in the checked build).

```dart
copyString('héllo', 3); // 'h': 'é' needs bytes 2 and 3, and only 2 fit
copyString('a\u0000b', 8); // 'a'
```

Format 2.0 removed `wstring`: text travels as `serializeString`. A Dart
string is UTF-16 already, and `serializeString` carries all of it.

## The end of a packet

`serializeEnd()` is the end of the packet's top-level object. **A reader
of a packet must call it after the last field**, and that is what makes
one packet one byte sequence: the end refuses a whole byte or more left
over as `trailing_data` (checked first, even when every leftover bit is
zero), and a set bit in the final byte's unused bits as
`nonzero_padding`. It never looks at the last field's own bits, and an
accepted end leaves the stream exactly consumed. A writer's end emits
nothing, since the writer already zeroes the padding, and a measure's costs
nothing, so the same serialize function ends all three:

```dart
bool serializePacket(BitStream stream, Packet packet) =>
    stream.serializeObject(packet.header) &&
    stream.serializeBits(packet.payload, 8) &&
    stream.serializeEnd();

final r = ReadStream(Uint8List.fromList([0x05, 0x00]));
r.serializeBits(v, 3); // -> true
r.serializeEnd(); // -> false: a whole byte after the packet
r.refusal; // -> Refusal.trailingData
```

Hand the reader exactly the bytes the writer reported (`writer.data()`):
a buffer with spare bytes after the packet is refused at its end. Like
every read, an end on a failed stream refuses with the first reason.

## The relative integer

`serializeIntRelative(previous, ref)` prices strictly increasing
sequences — sequence numbers, ack chains. `current > previous` always, no
wrapping. A difference of 1 costs a single bit; small differences ride
payload tiers of 5/8/13/18/23 bits; past the ladder, six zero flags carry
`current` itself as 32 raw bits.

**The domain is 0 to 2^31 - 1 inclusive**, for both
`previous` and `current`. It belongs to the operation, not to Dart's int:
a `previous` of 2^31 is caller error exactly as a negative one is. The
reader reconstructs `current` in Dart's 64-bit int, which cannot wrap,
then checks the result against the domain and against `previous` — in the
one-bit tier, in each of the five bounded tiers, and in the absolute tier,
whose 32 raw bits are read unsigned, so a group with its top bit set is
outside the domain and refused (`value_out_of_range`). The absolute tier
is canonical too: carrying a `current` no more than 69914 above
`previous`, which a bounded tier takes, it is a second encoding of the
value and refused as `non_canonical`, after the domain rule. A refused
read leaves your `Ref` untouched, and latches the stream.

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
vectors must refuse for the reason they state. Beside it the suite carries
the family's golden vectors — including the golden wire message covering
every operation class, byte for byte — plus the discriminating float
vectors, the string pins, every relative-integer tier, and the fixed point
shapes at every group count, all minted from the canonical C++
reference's own output. If your message serializes with the same
declarations on both ends, a stream written by any family implementation
reads in any other.

Two doctrines worth knowing at the edges:

- **Trailing bits**: writers zero the unused bits of the final byte. A
  field read never looks at them; the packet's end refuses a set one, and
  refuses any byte after the packet.
- **Past-end data**: bytes past the end of the data you hand `ReadStream`
  are never read, let alone interpreted.
