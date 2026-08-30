# serialize.dart

A bitpacking serialization library for **Dart**. Part of the serialize
family, wire compatible with the
[C++](https://github.com/mas-bandwidth/serialize),
[C](https://github.com/mas-bandwidth/serialize.c),
[Go](https://github.com/mas-bandwidth/serialize.go),
[C#](https://github.com/mas-bandwidth/serialize.cs),
[Rust](https://github.com/mas-bandwidth/serialize.rs),
[JavaScript](https://github.com/mas-bandwidth/serialize.js),
[Java](https://github.com/mas-bandwidth/serialize.java) and
[Elixir](https://github.com/mas-bandwidth/serialize.elixir) libraries —
the same values produce the same bytes in every implementation, so a
stream written by one reads in any other.
[STANDARD.md](https://github.com/mas-bandwidth/serialize/blob/main/STANDARD.md)
in the C++ reference is the authority on every byte.

## The surface

The complete family operation set, on three streams sharing one
bool-returning serialize surface — `WriteStream`, `ReadStream` and
`MeasureStream` — so a single serialize function writes, reads and
measures. Values travel in `Ref<T>` holders (Dart has no by-reference
parameters). [USAGE.md](USAGE.md) teaches every operation by example.

- **Raw bits**: `serializeBits` (1–32), `serializeBits64` (1–64),
  `serializeAlign`.
- **Ranged integers**: `serializeInt`, `serializeInt64`,
  `serializeInt128` — offset from min in exactly the bit length of the
  range, unsigned-domain arithmetic so ranges wider than 2^63/2^127 are
  exact, zero bits for a degenerate range.
- **Unsigned helpers and bool**: `serializeUint8` / `16` / `32` / `64`,
  `serializeUint128` (the `UInt128` pair type), `serializeBool`.
- **Floats**: `serializeFloat` and `serializeDouble`, bit transparent both
  ways — every pattern legal, NaN payloads ride a software
  narrowing/widening that never sets the quiet bit;
  `serializeCompressedFloat`, quantizing in float32 with the standard's
  two roundings on each side.
- **Bytes and strings**: `serializeBytes` (aligned bulk copy, count
  agreed, not transmitted); `serializeString` (UTF-8 on the wire, payload
  validated on read in every mode); `serializeWideString` (one 32-bit
  group per UTF-16 code unit, no alignment anywhere).
- **The relative integer**: `serializeIntRelative` — the flag ladder for
  strictly increasing uint32 sequences, one bit for a difference of 1.
- **Fixed point**: `serializeFixed` at 8/16/32/64-bit storage and
  `serializeFixed128` at 128-bit storage — Q formats, the raw scaled
  integer as an exact ranged offset, byte identical to `serializeInt64`
  wherever storage fits 64 bits.
- **Range pricing**: `bitsRequired`, `bitsRequired64`, `bitsRequired128`.
- **128-bit values**: `Int128` and `UInt128`, two's complement pairs of
  64-bit halves, mirroring the family's emulated pair types.
- **The bitpacker underneath**: `BitWriter` and `BitReader`, the family
  wire on Dart's native 64-bit integers. The reader prices its windows
  **inside** the buffer — any data length is supported, no slack past the
  data required.

Pure Dart, zero dependencies.

## Quick example

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

final writer = WriteStream(Uint8List(64)); // length a multiple of 8
serializePlayer(writer, player);           // -> true
writer.flush();                            // always flush before touching the bytes
final wire = writer.data();                // 5 bytes: 7 + 1 + 32 bits

final reader = ReadStream(wire);           // any length, no slack required
serializePlayer(reader, decoded);          // -> true
```

## Toolchain

The Dart SDK is pinned per project, not taken from the system:
[tending/PINS.md](tending/PINS.md) records the exact version, download
URL and SHA-256. `dist/` is gitignored — re-fetch by the pinned URL,
verify the hash, and unpack so the SDK sits at
`dist/dart-sdk-3.13.2/bin/dart`. Every command below uses that binary.

## Testing

```
dist/dart-sdk-3.13.2/bin/dart run test/all.dart                    # release shape
dist/dart-sdk-3.13.2/bin/dart --enable-asserts run test/all.dart   # checked shape
```

The suite pins the family's golden vectors byte for byte — the golden
wire message covering every operation class, the discriminating
compressed-float vectors (bit patterns, not tolerances), the string and
wide-string pins, every relative-integer tier, and the fixed point
shapes at every group count — plus per-primitive unit suites, refusal
proofs for hostile input, and the measure bound. Run it in both assert
modes: writer contracts live in asserts, so the two runs cover both the
checked and release shapes of the library (see
[USAGE.md](USAGE.md#writes-trust-reads-validate)).

## Benchmark

```
dist/dart-sdk-3.13.2/bin/dart run bench/bench.dart                          # JIT
dist/dart-sdk-3.13.2/bin/dart compile exe bench/bench.dart -o bench.exe     # AOT
./bench.exe
```

[bench/bench.dart](bench/bench.dart) is an operation-for-operation
mirror of the family benchmark (serialize.c's `bench.c`, itself a mirror
of the C++ `bench.cpp`): the raw bitpacker, the representative stream
packet through write, read and measure, and three packet shapes, at the
same iteration counts with the same LCG-driven inputs and
best-of-five-trials discipline. Every row is golden gated before any row
is timed — the exact buffers the loops write are verified byte for byte
against pins produced by the C reference's own bench data paths, and a
bench that fails its goldens reports nothing. `--csv` emits the numbers
as `row,op,units,value`; `BENCH_BITPACKER_PASSES` and
`BENCH_STREAM_PACKETS` scale the loops for linearity checks.

Both runtime modes matter: JIT (`dart run`) is the iteration number, AOT
(`dart compile exe`) is the number that ships — Flutter release builds
are AOT. Asserts are off in both unless `--enable-asserts` is passed, so
a plain run measures the release shape.

Current AOT numbers at the family scale (4096 bitpacker passes, 1,000,000
packets per stream row), measured on a MacBook Air (Apple Silicon) —
only numbers from a quiet machine are meaningful, and only as ratios
between family legs measured back to back on the same machine:

```
bitpacker write:     745.3 MB/s
bitpacker read:     1001.7 MB/s
stream write:        742.4 MB/s  (15.9 M packets/s)
stream read:         512.9 MB/s  (11.0 M packets/s)
stream measure:                  37.4 M packets/s

int packet   (runtime):       write:   21.6 M packets/s   read:   15.9 M packets/s
bits packet  (runtime):       write:   32.8 M packets/s   read:   21.4 M packets/s
mixed packet (runtime):       write:   20.8 M packets/s   read:   13.4 M packets/s
```

## License

[BSD 3-Clause](LICENSE), © Más Bandwidth LLC.
