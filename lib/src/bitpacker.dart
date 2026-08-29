// The bitpacker: the wire's foundation.
//
// BitWriter packs unsigned integer values into a buffer as a little-endian
// bit stream, least-significant-bit first, exactly as specified by
// STANDARD.md and byte-identical to the C, C++, C#, Go, Rust and JavaScript
// implementations. The scratch is the family's 64-bit accumulator, held
// bit-transparently in a Dart int. When it fills to 64 bits it is stored to
// the buffer as one little-endian 8-byte word and the bits that spilled past
// 64 carry over into the next scratch.
//
// Writes assume trusted data (STANDARD.md): caller contracts on the write
// path are asserted, active in debug and compiled out in release. The read
// side is different: the wire is a trust boundary, and the refusal surface —
// wouldReadPastEnd, readAlign, and the stream layer's checks above it —
// never throws on hostile data.

import 'dart:typed_data';

/// Bitpacks unsigned integer values to a buffer.
///
/// The buffer size must be a multiple of 8 bytes, because the writer stores
/// scratch words to memory 8 bytes at a time. Bytes past the end of the
/// written data are only ever written as zeros: the flushed scratch beyond
/// the bit index is zero, so trailing bits are zero by construction, as the
/// standard obliges writers to guarantee.
///
/// IMPORTANT: When you have finished writing, call [flushBits], otherwise the
/// last word of data will not get flushed to memory.
final class BitWriter {
  Uint8List _data;
  ByteData _view;
  int _scratch; // the 64-bit scratch, bits packed from the bottom
  int _scratchBits; // number of valid bits in scratch, in [0,63]
  int _numBits; // buffer capacity in bits
  int _wordIndex; // the next 8-byte word flushes to _data[_wordIndex * 8]

  // The bit index is not a stored field: it is _wordIndex * 64 + _scratchBits
  // by construction — every write path maintains that invariant — so the hot
  // path carries one less field update per write (see [bitsWritten]).

  /// Creates a bit writer that fills [buffer] with bitpacked data. The buffer
  /// length must be a multiple of 8.
  BitWriter(Uint8List buffer)
    : _data = buffer,
      _view = ByteData.sublistView(buffer),
      _scratch = 0,
      _scratchBits = 0,
      _numBits = buffer.length * 8,
      _wordIndex = 0 {
    assert(buffer.length % 8 == 0);
  }

  /// Points the writer at a buffer and clears all write state, allowing a
  /// single writer to be reused without allocating a new one. The buffer
  /// length must be a multiple of 8.
  void reset(Uint8List buffer) {
    assert(buffer.length % 8 == 0);
    if (!identical(buffer, _data)) {
      _data = buffer;
      _view = ByteData.sublistView(buffer);
    }
    _scratch = 0;
    _scratchBits = 0;
    _numBits = buffer.length * 8;
    _wordIndex = 0;
  }

  /// Writes the low [bits] bits of [value] to the buffer, without padding to
  /// the nearest byte. bits must be in [1,32]; bits of value above the count
  /// are ignored (the uint32 conversion the C#, Go and JavaScript ports
  /// perform at this boundary). Writing past the end of the buffer is a
  /// caller contract violation, asserted in debug.
  @pragma('vm:prefer-inline')
  void writeBits(int value, int bits) {
    assert(bits >= 1 && bits <= 32);
    assert(bitsWritten + bits <= _numBits);

    // mask to the bit count: bits of value above the count are ignored.
    // branchless: the int is 64 bits wide, so 1 << 32 does not overflow
    value &= (1 << bits) - 1;

    _scratch |= value << _scratchBits;

    final newScratchBits = _scratchBits + bits;

    if (newScratchBits >= 64) {
      _view.setUint64(_wordIndex * 8, _scratch, Endian.little);
      _wordIndex++;
      // recover the bits that spilled past 64. newScratchBits >= 64 with
      // bits <= 32 implies the shift is in [1,32]
      _scratch = value >>> (64 - _scratchBits);
      _scratchBits = newScratchBits - 64;
    } else {
      _scratchBits = newScratchBits;
    }
  }

  /// Pads the bit stream with zeros so the bit index becomes a multiple of 8.
  /// If the current bit index is already a multiple of 8, nothing is written.
  void writeAlign() {
    final remainderBits = _scratchBits & 7; // == bitsWritten % 8
    if (remainderBits != 0) {
      writeBits(0, 8 - remainderBits);
      assert(bitsWritten % 8 == 0);
    }
  }

  /// Writes an array of bytes to the bit stream: the aligned bulk copy under
  /// serialize_bytes. The bit index must be byte aligned (write an align
  /// first) and the write must fit the buffer — caller contracts, asserted.
  ///
  /// The body is fused, exactly as the C++ reference: one word store flushes
  /// the partial scratch word (its high bytes are zero and the payload
  /// overwrites them), one bulk copy lands the whole payload at the byte
  /// cursor, and one word load reloads the trailing partial word into the
  /// scratch — masked to its tail bits — so later writes pack into it exactly
  /// as if its bytes had gone through the packer.
  void writeBytes(Uint8List data) {
    final bytes = data.length;
    final startBits = bitsWritten;
    assert(startBits % 8 == 0);
    assert(startBits + bytes * 8 <= _numBits);

    // the head: one word store, not a byte loop. the buffer size is a
    // multiple of 8, so the word store stays in bounds (see flushBits).
    if (_scratchBits != 0) {
      _view.setUint64(_wordIndex * 8, _scratch, Endian.little);
    }

    // the body: the whole payload, straight in at the byte cursor
    _data.setRange(startBits >>> 3, (startBits >>> 3) + bytes, data);

    final newBits = startBits + bytes * 8;
    _wordIndex = newBits >>> 6;

    // the tail: reload the trailing partial word into the scratch, masked to
    // its tail bits. the load reads only the word the final flush is already
    // obliged to store, so it touches no memory the stream does not own.
    final tailBits = newBits & 63;
    if (tailBits != 0) {
      _scratch =
          _view.getUint64(_wordIndex * 8, Endian.little) &
          ((1 << tailBits) - 1);
    } else {
      _scratch = 0;
    }
    _scratchBits = tailBits;
  }

  /// Flushes any remaining bits in the scratch to memory. Call this once
  /// after you have finished writing. The flush stores a full 8-byte word:
  /// the buffer size is a multiple of 8 so this stays in bounds, and bytes
  /// past the written data are only ever written as zeros.
  ///
  /// flushBits ends the write: writing more bits after a mid-stream flush
  /// corrupts the stream, because the flushed partial word cannot be resumed.
  @pragma('vm:prefer-inline')
  void flushBits() {
    if (_scratchBits != 0) {
      _view.setUint64(_wordIndex * 8, _scratch, Endian.little);
    }
  }

  /// The number of align bits that would be written, if an align was written
  /// right now: in [0,7], where 0 means the stream is already byte aligned.
  int get alignBits => (8 - (_scratchBits & 7)) & 7;

  /// The number of bits written so far.
  @pragma('vm:prefer-inline')
  int get bitsWritten => _wordIndex * 64 + _scratchBits;

  /// The number of bits still available to write.
  @pragma('vm:prefer-inline')
  int get bitsAvailable => _numBits - bitsWritten;

  /// The number of bytes flushed to memory: the bits written rounded up to
  /// the next byte. This is the size of the packet to send after bitpacking.
  ///
  /// IMPORTANT: Call [flushBits] first, otherwise you risk missing the last
  /// word of data.
  int get bytesWritten => (bitsWritten + 7) >>> 3;

  /// The written portion of the buffer: a view of the first [bytesWritten]
  /// bytes of the buffer passed to the writer (not a copy).
  ///
  /// IMPORTANT: Call [flushBits] first, otherwise you risk missing the last
  /// word of data.
  Uint8List data() => Uint8List.sublistView(_data, 0, bytesWritten);
}

/// Reads bitpacked integer values from a buffer.
///
/// The reader relies on the user reconstructing the exact same set of bit
/// reads as bit writes when the buffer was written: this is an unattributed
/// bitpacked binary stream.
///
/// Any buffer size is supported, and the reader prices its 64-bit windows
/// INSIDE the buffer, like the C and JavaScript implementations: within the
/// first bytes - 8 of the buffer a window is a direct word load at the
/// current byte; past that it would run off the end, so [reset] assembles the
/// final window up front from the bytes that are there, and every read in the
/// last 8 bytes shifts that instead. THE CALLER'S ALLOCATION CONTRACT IS
/// THEREFORE EMPTY: no slack past the data is required, unlike the C++
/// reader. STANDARD.md declares both stances conforming, because
/// loaded-but-uninterpreted bytes can never influence a decoded value or an
/// accept/reject decision — here nothing past the data is even loaded.
final class BitReader {
  Uint8List _data;
  ByteData _view;
  int _numBits; // data length in bits
  int _bitsRead; // bits read so far
  int _tailBase; // byte index the tail window starts at
  int _tailWord; // the final 64-bit window, assembled at reset

  /// Creates a bit reader over the bitpacked data in [data]. Any length is
  /// supported, and no slack past the data is required.
  BitReader(Uint8List data)
    : _data = data,
      _view = ByteData.sublistView(data),
      _numBits = data.length * 8,
      _bitsRead = 0,
      _tailBase = 0,
      _tailWord = 0 {
    _assembleTail();
  }

  /// Points the reader at a data array and clears all read state, allowing a
  /// single reader to be reused. The data must not change while the reader is
  /// reading it.
  void reset(Uint8List data) {
    if (!identical(data, _data)) {
      _data = data;
      _view = ByteData.sublistView(data);
    }
    _numBits = data.length * 8;
    _bitsRead = 0;
    _assembleTail();
  }

  void _assembleTail() {
    final bytes = _data.length;
    if (bytes >= 8) {
      _tailBase = bytes - 8;
      _tailWord = _view.getUint64(_tailBase, Endian.little);
    } else {
      // a buffer shorter than 8 bytes is entirely in the tail window, zero
      // padded. Shifting from the low byte up IS the wire order.
      _tailBase = 0;
      var word = 0;
      for (var i = bytes - 1; i >= 0; i--) {
        word = (word << 8) | _data[i];
      }
      _tailWord = word;
    }
  }

  /// Would reading [bits] more bits read past the end of the data?
  @pragma('vm:prefer-inline')
  bool wouldReadPastEnd(int bits) => _bitsRead + bits > _numBits;

  /// Reads [bits] bits from the buffer and returns the integer value read,
  /// in [0,(1<<bits)-1]. bits must be in [1,32], and the read must not pass
  /// the end of the data — caller contracts, asserted: this is the
  /// trusted-caller form. Check [wouldReadPastEnd] first when the data is
  /// untrusted; the stream layer does exactly that and never calls this past
  /// the end.
  @pragma('vm:prefer-inline')
  int readBits(int bits) {
    assert(bits >= 1 && bits <= 32);
    assert(_bitsRead + bits <= _numBits);

    final byteIndex = _bitsRead >>> 3;
    int window;
    int shift;
    if (byteIndex < _tailBase) {
      // inside the buffer: a direct little-endian window load. byteIndex + 8
      // <= data.length - 1 here, so the load never runs off the end, and the
      // shift is the bit remainder, in [0,7].
      window = _view.getUint64(byteIndex, Endian.little);
      shift = _bitsRead & 7;
    } else {
      // the last 8 bytes: the window assembled at reset, shifted to where
      // this read starts. The bounds check already performed guarantees the
      // whole read fits the window: shift + bits <= 64, shift in [0,63].
      window = _tailWord;
      shift = _bitsRead - _tailBase * 8;
    }

    _bitsRead += bits;

    // branchless mask: the int is 64 bits wide, so 1 << 32 does not overflow
    return (window >>> shift) & ((1 << bits) - 1);
  }

  /// Reads an align, corresponding to a writeAlign call when the buffer was
  /// written, and skips ahead to the next byte boundary. Verifies that the
  /// padding bits are zero, as the standard requires, and returns false if
  /// they are not — which typically aborts the read. Never throws: nonzero
  /// padding is hostile data, not caller error. If the bit index is already a
  /// multiple of 8, nothing is read.
  bool readAlign() {
    final remainderBits = _bitsRead % 8;
    if (remainderBits != 0) {
      // this cannot read past the end: numBits is a multiple of 8, so an
      // unaligned bit index is always strictly inside the final byte
      final value = readBits(8 - remainderBits);
      assert(_bitsRead % 8 == 0);
      if (value != 0) {
        return false;
      }
    }
    return true;
  }

  /// Reads dest.length bytes from the bitpacked data into [dest]: the
  /// aligned bulk read under serialize_bytes. The bit index must be byte
  /// aligned (read an align first) and the read must not pass the end of the
  /// data — caller contracts, asserted: the stream layer bounds checks first
  /// and refuses as a value, with dest untouched on refusal.
  void readBytes(Uint8List dest) {
    assert(_bitsRead % 8 == 0);
    assert(_bitsRead + dest.length * 8 <= _numBits);

    // the bit index is byte aligned, so this is a straight copy of the data
    final byteIndex = _bitsRead >>> 3;
    dest.setRange(0, dest.length, _data, byteIndex);
    _bitsRead += dest.length * 8;
  }

  /// The number of align bits that would be read, if an align was read right
  /// now: in [0,7], where 0 means the stream is already byte aligned.
  int get alignBits => (8 - (_bitsRead % 8)) % 8;

  /// The number of bits read from the buffer so far.
  int get bitsRead => _bitsRead;

  /// The number of bits still available to read.
  int get bitsRemaining => _numBits - _bitsRead;
}
