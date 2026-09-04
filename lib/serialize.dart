/// Bitpacked binary serialization for native Dart: the serialize wire
/// format, byte-identical to the C, C++, C#, Go, Rust and JavaScript
/// implementations. STANDARD.md is the authority on every byte.
library;

export 'src/bitpacker.dart' show BitReader, BitWriter;
export 'src/bits.dart'
    show bitsRequired, bitsRequired64, intRelativeMax, valueFitsInBits;
export 'src/float32.dart'
    show
        doubleFromFloat32Bits,
        doubleFromFloat64Bits,
        float32BitsFromDouble,
        float64BitsFromDouble,
        fround;
export 'src/int128.dart' show Int128, UInt128, bitsRequired128;
export 'src/streams.dart'
    show BitStream, MeasureStream, ReadStream, Ref, Serializable, WriteStream;
