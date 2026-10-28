/// Bitpacked binary serialization for Dart: the serialize wire format 2.0,
/// byte-identical to the C, C++, C#, Go, Rust and JavaScript
/// implementations. STANDARD.md is the authority on every byte.
///
/// The public surface is the one reference IMPLEMENTING.md U15 allows: the
/// three streams and the unified [BitStream] surface, the refusal list and
/// [refusalName], [copyString], and the reference's own public helpers
/// ([BitReader], [BitWriter], [bitsRequired], [bitsRequired64],
/// [bitsRequired128], [valueFitsInBits], [compressedFloatParams],
/// [float32BitsAreFinite], [float64BitsAreFinite], [Int128], [UInt128]).
/// Beyond those it exports only Dart's language necessities: [fround] and the
/// float bit casts ([float32BitsFromDouble], [float64BitsFromDouble],
/// [doubleFromFloat32Bits], [doubleFromFloat64Bits]), because Dart has no
/// float32 type and no bit casts; and [Ref], the by-reference holder a
/// scalar needs so one serialize function can both read and write it.
library;

export 'src/bitpacker.dart' show BitReader, BitWriter;
export 'src/bits.dart' show bitsRequired, bitsRequired64, valueFitsInBits;
export 'src/float32.dart'
    show
        doubleFromFloat32Bits,
        doubleFromFloat64Bits,
        float32BitsAreFinite,
        float32BitsFromDouble,
        float64BitsAreFinite,
        float64BitsFromDouble,
        fround;
export 'src/int128.dart' show Int128, UInt128, bitsRequired128;
export 'src/refusal.dart' show Refusal, refusalName;
export 'src/streams.dart'
    show
        BitStream,
        MeasureStream,
        ReadStream,
        Ref,
        Serializable,
        WriteStream,
        compressedFloatParams,
        copyString;
