// TestDifferentialAgainstSerializeGo: the fuzz differential of the Dart port
// against the family's Go port, github.com/mas-bandwidth/serialize.go/v2
// v2.0.0 (pinned in go.mod), format 2.0.
//
// Dart has no native coverage-guided fuzzer, so this is the family's
// differential pattern (serialize.lua, serialize.luau, serialize.nut): a Go
// host generates random programs, each a sequence of 1 to 24 operations drawn
// from every operation the Dart port has, with values in range (finite floats
// only, well-formed UTF-8 with no zero byte), ended by an end as a packet
// reader must (STANDARD.md end), and for each program:
//
//  1. serialize.go writes it, and the Dart port (fuzz/driver.dart, compiled
//     once per run with asserts on) writes it; the bytes must be equal, the
//     bit counts must be equal, and the Dart MeasureStream must never
//     under-measure what the Dart WriteStream wrote.
//  2. Each side reads the other's bytes; the decoded values must equal the
//     program's (floats by bit pattern; a compressed float by the value
//     serialize.go itself decodes from its own bytes, since quantization is
//     lossy), and the Dart reader must consume every bit the writer wrote.
//  3. For 1 in 4 programs the bytes are mutated (bit flips, truncation,
//     extension) and both readers must agree on accept or refuse, on the
//     index of the step that refused, on the refusal reason (STANDARD.md,
//     Refusal reasons), on every value decoded before it, and a refused Dart
//     read must leave its destination untouched.
//
// ROUNDS AND SEEDS. A round is -programs programs drawn from math/rand/v2 PCG
// seeded (-seed, round index); no clock reaches the generator. With
// -duration 0 (the default) the test runs round 0 only: a fixed, repeatable
// run. With -duration D it runs rounds 0, 1, 2, ... until D is spent (the CI
// smoke: 60 s on the fixed seed; the nightly: longer, on a seed that changes
// every night and is printed in the log). A red round prints the seed and the
// round, and -failures DIR writes its disagreements to a file for upload;
// -seed S -rounds-from R -duration 0 replays it.
//
// The driver takes programs as text, one process per batch of programs, the
// batch in a file in a t.TempDir(), and prints results as lowercase hex
// lines (fuzz/driver.dart, THE REQUESTS).
//
// THE NEGATIVE CONTROL. The test-only flag -sabotage-widen-int makes the Go
// side write every non-degenerate int range one bit wider; with it the test
// must go red (the CI step runs it and requires the red). The same sabotaged
// writer also runs inside every normal round, over the same programs, through
// the same comparison, and the round fails unless that comparison goes red.
package fuzz

import (
	"bufio"
	"bytes"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"math"
	"math/rand/v2"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	serialize "github.com/mas-bandwidth/serialize.go/v2"
)

var (
	sabotageWidenInt = flag.Bool("sabotage-widen-int", false,
		"test only: the Go writer writes every non-degenerate int range one bit wider, so the differential must go red")
	seedFlag = flag.Uint64("seed", 0x5e7a11a15e7a11a1,
		"the generator seed; round r draws from PCG(seed, r)")
	durationFlag = flag.Duration("duration", 0,
		"run rounds until this much time is spent; 0 runs exactly one round")
	programsFlag = flag.Int("programs", 2000, "programs per round")
	roundsFrom   = flag.Int("rounds-from", 0, "the first round to run (to replay a red round)")
	failuresDir  = flag.String("failures", "",
		"a directory to write each red round's disagreements to (the nightly uploads it)")
	driverFlag = flag.String("driver", "",
		"a prebuilt fuzz/driver.dart executable; empty compiles it with $DART (default dart)")
)

const (
	batchSize = 500
	maxOps    = 24
	writeCap  = 8192 // bytes; a multiple of 8 (BitWriter stores 8-byte words)
)

// ---------------------------------------------------------------------------
// the program model

type step struct {
	kind  string
	width int // bits / bits64 width; object span; string buffer size
	ib    int // fixed integer bits
	fb    int // fixed fraction bits
	min   serialize.Int128
	max   serialize.Int128
	prev  int32
	fmin  float32
	fmax  float32
	fres  float32
	u     serialize.Uint128 // numeric value bits (signed kinds sign extended)
	b     bool
	data  []byte // bytes, string (UTF-8)
}

var minInt128 = serialize.Int128{Lo: 0, Hi: 1 << 63}
var maxInt128 = serialize.Int128{Lo: math.MaxUint64, Hi: math.MaxInt64}

func hex128(lo, hi uint64) string     { return fmt.Sprintf("%016x%016x", hi, lo) }
func hexI(x serialize.Int128) string  { return hex128(x.Lo, x.Hi) }
func hexU(x serialize.Uint128) string { return hex128(x.Lo, x.Hi) }
func hexS(x int64) string             { return hexI(serialize.Int128From64(x)) }
func hexBytes(b []byte) string        { return "x" + fmt.Sprintf("%x", b) }

// text renders a step as the driver's program spelling (fuzz/driver.dart,
// THE PROGRAM TEXT).
func (s *step) text() string {
	switch s.kind {
	case "bits", "bits64":
		return fmt.Sprintf("%s %d %s", s.kind, s.width, hexU(s.u))
	case "uint8", "uint16", "uint32", "uint64", "uint128", "float", "double":
		return s.kind + " " + hexU(s.u)
	case "bool":
		if s.b {
			return "bool 1"
		}
		return "bool 0"
	case "int", "int64", "int128":
		return fmt.Sprintf("%s %s %s %s", s.kind, hexI(s.min), hexI(s.max), hexU(s.u))
	case "fixed64", "fixed128":
		return fmt.Sprintf("%s %d %d %s %s %s", s.kind, s.ib, s.fb, hexI(s.min), hexI(s.max), hexU(s.u))
	case "int_relative":
		return fmt.Sprintf("int_relative %s %s", hexS(int64(s.prev)), hexU(s.u))
	case "cfloat":
		return fmt.Sprintf("%s %s %s %s %s", s.kind,
			hexU(serialize.Uint128{Lo: uint64(math.Float32bits(s.fmin))}),
			hexU(serialize.Uint128{Lo: uint64(math.Float32bits(s.fmax))}),
			hexU(serialize.Uint128{Lo: uint64(math.Float32bits(s.fres))}), hexU(s.u))
	case "bytes":
		return "bytes " + hexBytes(s.data)
	case "string":
		return fmt.Sprintf("%s %d %s", s.kind, s.width, hexBytes(s.data))
	case "align":
		return "align"
	case "end":
		return "end"
	case "object":
		return fmt.Sprintf("object %d", s.width)
	}
	panic("no text for step kind " + s.kind)
}

func programText(steps []step) string {
	parts := make([]string, len(steps))
	for i := range steps {
		parts[i] = steps[i].text()
	}
	return strings.Join(parts, " ")
}

// programValue is the rendered value the program states for step i, the
// token a reader must decode ("-" for a step with no value of its own).
func programValue(s *step) string {
	switch s.kind {
	case "bool":
		if s.b {
			return "1"
		}
		return "0"
	case "bytes", "string":
		return hexBytes(s.data)
	case "align", "end", "object":
		return "-"
	}
	return hexU(s.u)
}

// ---------------------------------------------------------------------------
// the generator (seeded, values in range)

type gen struct{ r *rand.Rand }

func (g *gen) u64LE(n uint64) uint64 {
	if n == math.MaxUint64 {
		return g.r.Uint64()
	}
	return g.r.Uint64N(n + 1)
}

func (g *gen) u128LE(n serialize.Uint128) serialize.Uint128 {
	if n.Hi == 0 {
		return serialize.Uint128{Lo: g.u64LE(n.Lo)}
	}
	for {
		hi := g.u64LE(n.Hi)
		lo := g.r.Uint64()
		if hi < n.Hi || lo <= n.Lo {
			return serialize.Uint128{Lo: lo, Hi: hi}
		}
	}
}

// range64 draws [min,max] inside [lo,hi]: the full range, a degenerate one, a
// power-of-two width (exactly 2^k and 2^k - 1, the bits_required edges), an
// edge-hugging one, or a random pair (STANDARD.md int (ranged)).
func (g *gen) range64(lo, hi int64) (int64, int64) {
	span := uint64(hi) - uint64(lo)
	at := func(off uint64) int64 { return int64(uint64(lo) + off) }
	switch g.r.IntN(6) {
	case 0:
		return lo, hi
	case 1:
		v := at(g.u64LE(span))
		return v, v
	case 2:
		w := uint64(1) << g.r.IntN(64)
		if g.r.IntN(2) == 0 {
			w--
		}
		if w > span {
			w = span
		}
		start := g.u64LE(span - w)
		return at(start), at(start + w)
	case 3:
		w := g.u64LE(min(span, 300))
		if g.r.IntN(2) == 0 {
			return lo, at(w)
		}
		return at(span - w), hi
	default:
		a, b := at(g.u64LE(span)), at(g.u64LE(span))
		if a > b {
			a, b = b, a
		}
		return a, b
	}
}

// pick64 draws a value in [min,max], favouring the edges.
func (g *gen) pick64(lo, hi int64) int64 {
	span := uint64(hi) - uint64(lo)
	switch g.r.IntN(6) {
	case 0:
		return lo
	case 1:
		return hi
	case 2:
		if span > 0 {
			return int64(uint64(lo) + 1)
		}
		return lo
	case 3:
		if span > 0 {
			return int64(uint64(hi) - 1)
		}
		return hi
	}
	return int64(uint64(lo) + g.u64LE(span))
}

func (g *gen) range128() (serialize.Int128, serialize.Int128) {
	switch g.r.IntN(5) {
	case 0:
		return minInt128, maxInt128
	case 1:
		v := serialize.Int128{Lo: g.r.Uint64(), Hi: g.r.Uint64()}
		return v, v
	case 2:
		a, b := g.range64(math.MinInt64, math.MaxInt64)
		return serialize.Int128From64(a), serialize.Int128From64(b)
	case 3:
		k := g.r.IntN(128)
		w := serialize.Uint128From64(1).Lsh(uint(k))
		if g.r.IntN(2) == 0 {
			w = w.Sub(serialize.Uint128From64(1))
		}
		full := serialize.Uint128{Lo: math.MaxUint64, Hi: math.MaxUint64}
		start := g.u128LE(full.Sub(w))
		base := minInt128.Uint128()
		return start.Add(base).Int128(), start.Add(w).Add(base).Int128()
	default:
		a := serialize.Int128{Lo: g.r.Uint64(), Hi: g.r.Uint64()}
		b := serialize.Int128{Lo: g.r.Uint64(), Hi: g.r.Uint64()}
		if a.Cmp(b) > 0 {
			a, b = b, a
		}
		return a, b
	}
}

func (g *gen) pick128(lo, hi serialize.Int128) serialize.Int128 {
	switch g.r.IntN(4) {
	case 0:
		return lo
	case 1:
		return hi
	}
	span := hi.Uint128().Sub(lo.Uint128())
	return lo.Uint128().Add(g.u128LE(span)).Int128()
}

// fixedCapacity is serialize.go's fixedPointCapacity (stream.go), restated:
// the whole unit bounds a Q format holds (STANDARD.md fixed).
func fixedCapacity(integerBits int, signed bool) (int64, int64) {
	if signed {
		if integerBits >= 65 {
			return math.MinInt64, math.MaxInt64
		}
		lo := int64(-(uint64(1) << (integerBits - 1)))
		if integerBits >= 64 {
			return lo, math.MaxInt64
		}
		return lo, int64(uint64(1)<<(integerBits-1) - 1)
	}
	if integerBits >= 63 {
		return 0, math.MaxInt64
	}
	return 0, int64(uint64(1)<<integerBits - 1)
}

// float32Bits draws a FINITE pattern (STANDARD.md, Finite values only: a
// writer is handed finite values only), favouring the edges a reader must
// keep bit exact; non-finite patterns reach the readers through the mutants.
func (g *gen) float32Bits() uint32 {
	sign := uint32(g.r.IntN(2)) << 31
	switch g.r.IntN(8) {
	case 0:
		return sign | 0x7f7fffff // the largest finite
	case 1:
		return sign | 0x00800000 // the smallest normal
	case 2:
		return sign | 0x007fffff // the largest subnormal
	case 3:
		return sign // zero, either sign
	case 4: // a subnormal
		return sign | (1 + g.r.Uint32N(0x7fffff))
	}
	for {
		if b := g.r.Uint32(); b&0x7f800000 != 0x7f800000 {
			return b
		}
	}
}

func (g *gen) float64Bits() uint64 {
	sign := uint64(g.r.IntN(2)) << 63
	switch g.r.IntN(8) {
	case 0:
		return sign | 0x7fefffffffffffff
	case 1:
		return sign | 0x0010000000000000
	case 2:
		return sign | 0x000fffffffffffff
	case 3:
		return sign
	case 4:
		return sign | (1 + g.r.Uint64N(0xfffffffffffff))
	}
	for {
		if b := g.r.Uint64(); b&0x7ff0000000000000 != 0x7ff0000000000000 {
			return b
		}
	}
}

func (g *gen) runeOf() rune {
	switch g.r.IntN(4) {
	case 0:
		return rune(0x80 + g.r.IntN(0x800-0x80))
	case 1:
		for {
			r := rune(0x800 + g.r.IntN(0x10000-0x800))
			if r < 0xd800 || r > 0xdfff {
				return r
			}
		}
	case 2:
		return rune(0x10000 + g.r.IntN(0x110000-0x10000))
	}
	return rune(1 + g.r.IntN(0x7f)) // ASCII, never NUL (STANDARD.md string)
}

func (g *gen) compressed(s *step) {
	s.fmin = float32(math.Round((g.r.Float64()*2000-1000)*8) / 8)
	widths := []float32{0.5, 1, 10, 100, 1000, 3.25, 0.001}
	width := widths[g.r.IntN(len(widths))]
	s.fmax = s.fmin + width
	if !(s.fmin < s.fmax) {
		s.fmax = s.fmin + 1
	}
	delta := s.fmax - s.fmin
	switch g.r.IntN(4) {
	case 0: // the integer clamp's edge: a quantized range in [2^23, 2^24)
		s.fres = delta / float32((1<<23)+g.r.IntN(1<<23))
	case 1:
		s.fres = delta * 2 // one step
	default:
		res := []float32{0.001, 0.01, 0.1, 0.5, 1, 0.37, 0.0001}
		s.fres = res[g.r.IntN(len(res))]
	}
	if !(s.fres > 0) {
		s.fres = 0.5
	}
	var v float32
	switch g.r.IntN(5) {
	case 0:
		v = s.fmin
	case 1:
		v = s.fmax
	case 2: // a half-quantum boundary
		v = s.fmin + (float32(g.r.IntN(64))+0.5)*s.fres
	default:
		v = s.fmin + float32(g.r.Float64())*delta
	}
	if !(v >= s.fmin) {
		v = s.fmin
	}
	if !(v <= s.fmax) {
		v = s.fmax
	}
	s.u = serialize.Uint128{Lo: uint64(math.Float32bits(v))}
}

// leafKinds is every operation the Dart port has (BitStream in
// lib/src/streams.dart) except object and end, which program() places.
var leafKinds = []string{
	"bits", "bits64", "bool", "uint8", "uint16", "uint32", "uint64", "uint128",
	"int", "int64", "int128", "fixed64", "fixed128", "int_relative",
	"float", "double", "cfloat", "bytes", "string", "align",
}

// fixedStorage is the storage widths the Dart serializeFixed takes (8, 16,
// 32 or 64 bits, integerBits + fractionBits exactly).
var fixedStorage = []int{8, 16, 32, 64}

func (g *gen) leaf(kind string) step {
	s := step{kind: kind}
	switch kind {
	case "bits":
		s.width = 1 + g.r.IntN(32)
		s.u = serialize.Uint128{Lo: g.r.Uint64() & (math.MaxUint64 >> (64 - s.width))}
	case "bits64":
		s.width = 1 + g.r.IntN(64)
		s.u = serialize.Uint128{Lo: g.r.Uint64() & (math.MaxUint64 >> (64 - s.width))}
	case "bool":
		s.b = g.r.IntN(2) == 0
	case "uint8":
		s.u = serialize.Uint128{Lo: uint64(g.r.Uint32N(1 << 8))}
	case "uint16":
		s.u = serialize.Uint128{Lo: uint64(g.r.Uint32N(1 << 16))}
	case "uint32":
		s.u = serialize.Uint128{Lo: uint64(g.r.Uint32())}
	case "uint64":
		s.u = serialize.Uint128{Lo: g.r.Uint64()}
	case "uint128":
		s.u = serialize.Uint128{Lo: g.r.Uint64(), Hi: g.r.Uint64()}
	case "int":
		a, b := g.range64(math.MinInt32, math.MaxInt32)
		s.min, s.max = serialize.Int128From64(a), serialize.Int128From64(b)
		s.u = serialize.Int128From64(g.pick64(a, b)).Uint128()
	case "int64":
		a, b := g.range64(math.MinInt64, math.MaxInt64)
		s.min, s.max = serialize.Int128From64(a), serialize.Int128From64(b)
		s.u = serialize.Int128From64(g.pick64(a, b)).Uint128()
	case "int128":
		s.min, s.max = g.range128()
		s.u = g.pick128(s.min, s.max).Uint128()
	case "fixed64":
		width := fixedStorage[g.r.IntN(len(fixedStorage))]
		s.ib = 1 + g.r.IntN(width)
		s.fb = width - s.ib
		lo, hi := fixedCapacity(s.ib, g.r.IntN(2) == 0)
		a, b := g.range64(lo, hi)
		s.min, s.max = serialize.Int128From64(a), serialize.Int128From64(b)
		rawMin := uint64(a) << s.fb
		rawRange := (uint64(b) << s.fb) - rawMin
		s.u = serialize.Int128From64(int64(rawMin + g.u64LE(rawRange))).Uint128()
	case "fixed128":
		s.ib = 1 + g.r.IntN(128)
		s.fb = 128 - s.ib
		lo, hi := fixedCapacity(s.ib, g.r.IntN(2) == 0)
		a, b := g.range64(lo, hi)
		s.min, s.max = serialize.Int128From64(a), serialize.Int128From64(b)
		rawMin := serialize.Int128From64(a).Uint128().Lsh(uint(s.fb))
		rawRange := serialize.Int128From64(b).Uint128().Lsh(uint(s.fb)).Sub(rawMin)
		s.u = rawMin.Add(g.u128LE(rawRange))
	case "int_relative":
		s.prev = int32(g.pick64(0, math.MaxInt32-1))
		buckets := [][2]int64{{1, 1}, {2, 6}, {7, 23}, {24, 280}, {281, 4377}, {4378, 69914}, {69915, math.MaxInt32}}
		bk := buckets[g.r.IntN(len(buckets))]
		d := g.pick64(bk[0], bk[1])
		if int64(s.prev)+d > math.MaxInt32 {
			d = math.MaxInt32 - int64(s.prev)
		}
		s.u = serialize.Int128From64(int64(s.prev) + d).Uint128()
	case "float":
		s.u = serialize.Uint128{Lo: uint64(g.float32Bits())}
	case "double":
		s.u = serialize.Uint128{Lo: g.float64Bits()}
	case "cfloat":
		g.compressed(&s)
	case "bytes":
		s.data = make([]byte, g.r.IntN(41))
		for i := range s.data {
			s.data[i] = byte(g.r.Uint32())
		}
	case "string":
		s.width = 1 + g.r.IntN(64)
		target := g.r.IntN(s.width) // fewer than bufferSize bytes
		var out []byte
		for {
			r := g.runeOf()
			if len(out)+utf8.RuneLen(r) > target {
				break
			}
			out = utf8.AppendRune(out, r)
		}
		s.data = out
	case "align":
	default:
		panic("no generator for " + kind)
	}
	return s
}

// program appends up to budget flat steps; an object spans the steps it
// contains (STANDARD.md object: no bytes of its own), nested at most twice.
func (g *gen) program(budget, depth int) []step {
	var out []step
	for len(out) < budget {
		if depth < 2 && budget-len(out) >= 2 && g.r.IntN(12) == 0 {
			inner := g.program(1+g.r.IntN(min(3, budget-len(out)-1)), depth+1)
			out = append(out, step{kind: "object", width: len(inner)})
			out = append(out, inner...)
			continue
		}
		out = append(out, g.leaf(leafKinds[g.r.IntN(len(leafKinds))]))
	}
	return out
}

// ---------------------------------------------------------------------------
// the Go side: one step runner for write and read (serialize.go's Stream)

type runner struct {
	steps    []step
	vals     []string
	endBits  []int64
	failIdx  int
	sabotage bool
}

type object struct {
	r        *runner
	from, to int
}

func (o *object) Serialize(s serialize.Stream) error {
	_, err := o.r.run(s, o.from, o.to)
	return err
}

func (r *runner) run(s serialize.Stream, from, to int) (int, error) {
	i := from
	for i < to {
		st := &r.steps[i]
		if st.kind == "object" {
			r.vals[i] = "-"
			if err := s.SerializeObject(&object{r: r, from: i + 1, to: i + 1 + st.width}); err != nil {
				if r.failIdx < 0 {
					r.failIdx = i
				}
				return i, err
			}
			r.endBits[i] = s.BitsProcessed()
			i += 1 + st.width
			continue
		}
		if err := r.one(s, i); err != nil {
			if r.failIdx < 0 {
				r.failIdx = i
			}
			return i, err
		}
		r.endBits[i] = s.BitsProcessed()
		i++
	}
	return to, nil
}

func (r *runner) one(s serialize.Stream, i int) error {
	st := &r.steps[i]
	set := func(v string) { r.vals[i] = v }
	switch st.kind {
	case "bits":
		v := uint32(st.u.Lo)
		if err := s.SerializeBits(&v, st.width); err != nil {
			return err
		}
		set(hex128(uint64(v), 0))
	case "bits64":
		v := st.u.Lo
		if err := s.SerializeBits64(&v, st.width); err != nil {
			return err
		}
		set(hex128(v, 0))
	case "bool":
		v := st.b
		if err := s.SerializeBool(&v); err != nil {
			return err
		}
		if v {
			set("1")
		} else {
			set("0")
		}
	case "uint8":
		v := uint8(st.u.Lo)
		if err := s.SerializeUint8(&v); err != nil {
			return err
		}
		set(hex128(uint64(v), 0))
	case "uint16":
		v := uint16(st.u.Lo)
		if err := s.SerializeUint16(&v); err != nil {
			return err
		}
		set(hex128(uint64(v), 0))
	case "uint32":
		v := uint32(st.u.Lo)
		if err := s.SerializeUint32(&v); err != nil {
			return err
		}
		set(hex128(uint64(v), 0))
	case "uint64":
		v := st.u.Lo
		if err := s.SerializeUint64(&v); err != nil {
			return err
		}
		set(hex128(v, 0))
	case "uint128":
		v := st.u
		if err := s.SerializeUint128(&v); err != nil {
			return err
		}
		set(hexU(v))
	case "int":
		v, lo, hi := int32(st.u.Lo), int32(st.min.Lo), int32(st.max.Lo)
		if r.sabotage && s.IsWriting() {
			// THE NEGATIVE CONTROL: this one int range one bit wider
			if bits := serialize.BitsRequired(uint32(lo), uint32(hi)); bits >= 1 && bits < 32 {
				off := uint32(v) - uint32(lo)
				return s.SerializeBits(&off, bits+1)
			}
		}
		if err := s.SerializeInt(&v, lo, hi); err != nil {
			return err
		}
		set(hexS(int64(v)))
	case "int64":
		v := int64(st.u.Lo)
		if err := s.SerializeInt64(&v, int64(st.min.Lo), int64(st.max.Lo)); err != nil {
			return err
		}
		set(hexS(v))
	case "int128":
		v := st.u.Int128()
		if err := s.SerializeInt128(&v, st.min, st.max); err != nil {
			return err
		}
		set(hexI(v))
	case "fixed64":
		v := int64(st.u.Lo)
		if err := s.SerializeFixed64(&v, st.ib, st.fb, int64(st.min.Lo), int64(st.max.Lo)); err != nil {
			return err
		}
		set(hexS(v))
	case "fixed128":
		v := st.u.Int128()
		if err := s.SerializeFixed128(&v, st.ib, st.fb, int64(st.min.Lo), int64(st.max.Lo)); err != nil {
			return err
		}
		set(hexI(v))
	case "int_relative":
		v := int32(st.u.Lo)
		if err := s.SerializeIntRelative(st.prev, &v); err != nil {
			return err
		}
		set(hexS(int64(v)))
	case "float":
		v := math.Float32frombits(uint32(st.u.Lo))
		if err := s.SerializeFloat32(&v); err != nil {
			return err
		}
		set(hex128(uint64(math.Float32bits(v)), 0))
	case "double":
		v := math.Float64frombits(st.u.Lo)
		if err := s.SerializeFloat64(&v); err != nil {
			return err
		}
		set(hex128(math.Float64bits(v), 0))
	case "cfloat":
		v := math.Float32frombits(uint32(st.u.Lo))
		if err := s.SerializeCompressedFloat32(&v, st.fmin, st.fmax, st.fres); err != nil {
			return err
		}
		set(hex128(uint64(math.Float32bits(v)), 0))
	case "bytes":
		data := make([]byte, len(st.data))
		if s.IsWriting() {
			copy(data, st.data)
		}
		if err := s.SerializeBytes(data); err != nil {
			return err
		}
		set(hexBytes(data))
	case "string":
		v := ""
		if s.IsWriting() {
			v = string(st.data)
		}
		if err := s.SerializeString(&v, st.width); err != nil {
			return err
		}
		set(hexBytes([]byte(v)))
	case "align":
		if err := s.SerializeAlign(); err != nil {
			return err
		}
		set("-")
	case "end":
		if err := s.SerializeEnd(); err != nil {
			return err
		}
		set("-")
	default:
		panic("no runner for " + st.kind)
	}
	return nil
}

// errKind is the refusal reason as STANDARD.md spells it (serialize.go v2's
// Refusal.String), the spelling the driver prints from ReadStream.refusal.
func errKind(err error) string {
	if err == nil {
		return "none"
	}
	var r serialize.Refusal
	if errors.As(err, &r) && r.String() != "" {
		return r.String()
	}
	return "other:" + err.Error()
}

// result is one side's outcome of a write or a read, in the driver's terms.
type result struct {
	ok       bool
	idx      int    // the refusing step, when !ok
	kind     string // the latched refusal reason, when !ok
	bytes    []byte // a write's flushed data
	bits     int64  // a write's bits written; a read's bits consumed
	measured int64  // a Dart write's MeasureStream bound
	vals     []string
	endBits  []int64
}

func goWrite(steps []step, capacity int, sabotage bool) result {
	r := &runner{steps: steps, vals: make([]string, len(steps)), endBits: make([]int64, len(steps)), failIdx: -1, sabotage: sabotage}
	ws := serialize.NewWriteStream(make([]byte, capacity))
	if _, err := r.run(ws, 0, len(steps)); err != nil {
		return result{idx: r.failIdx, kind: errKind(err)}
	}
	ws.Flush()
	return result{ok: true, bytes: append([]byte(nil), ws.Data()...), bits: ws.BitsProcessed(), endBits: r.endBits}
}

func goRead(steps []step, data []byte) result {
	r := &runner{steps: steps, vals: make([]string, len(steps)), endBits: make([]int64, len(steps)), failIdx: -1}
	rs := serialize.NewReadStream(data)
	if _, err := r.run(rs, 0, len(steps)); err != nil {
		return result{idx: r.failIdx, kind: errKind(err), vals: r.vals[:r.failIdx]}
	}
	return result{ok: true, bits: rs.BitsProcessed(), vals: r.vals}
}

// ---------------------------------------------------------------------------
// the Dart side: fuzz/driver.dart, compiled once per run

type request struct {
	id   string
	line string
}

func parseResult(fields []string, n int) (result, error) {
	// <id> w ok <bits> <measured> x<hex>       a write
	// <id> r ok <bits> <v0> ... <vn-1>         a read
	// <id> <w|r> refused <idx> <kind> <v0> ... <vidx-1>
	if len(fields) < 3 {
		return result{}, fmt.Errorf("short result line %q", strings.Join(fields, " "))
	}
	op, status := fields[1], fields[2]
	if status == "ok" && op == "w" {
		if len(fields) != 6 || !strings.HasPrefix(fields[5], "x") {
			return result{}, fmt.Errorf("bad write result %q", strings.Join(fields, " "))
		}
		bits, err := strconv.ParseInt(fields[3], 10, 64)
		if err != nil {
			return result{}, err
		}
		measured, err := strconv.ParseInt(fields[4], 10, 64)
		if err != nil {
			return result{}, err
		}
		b, err := decodeX(fields[5])
		return result{ok: true, bits: bits, measured: measured, bytes: b}, err
	}
	if status == "ok" && op == "r" {
		if len(fields) != 4+n {
			return result{}, fmt.Errorf("read result has %d values, the program has %d steps: %q", len(fields)-4, n, strings.Join(fields, " "))
		}
		bits, err := strconv.ParseInt(fields[3], 10, 64)
		return result{ok: true, bits: bits, vals: fields[4:]}, err
	}
	if status == "refused" && len(fields) >= 5 {
		idx, err := strconv.Atoi(fields[3])
		if err != nil {
			return result{}, err
		}
		res := result{idx: idx, kind: fields[4]}
		if op == "r" {
			if len(fields) != 5+idx {
				return result{}, fmt.Errorf("refused read states %d values before step %d: %q", len(fields)-5, idx, strings.Join(fields, " "))
			}
			res.vals = fields[5:]
		}
		return res, nil
	}
	return result{}, fmt.Errorf("bad result line %q", strings.Join(fields, " "))
}

func decodeX(tok string) ([]byte, error) {
	if strings.ToLower(tok) != tok {
		return nil, fmt.Errorf("byte string %q is not lowercase hex", tok)
	}
	return hex.DecodeString(tok[1:])
}

// buildDriver compiles fuzz/driver.dart once, asserts on, so every batch is a
// native process with no JIT warm-up (the smoke's budget goes to programs).
func buildDriver(t *testing.T, root string) string {
	t.Helper()
	if *driverFlag != "" {
		return *driverFlag
	}
	dart := os.Getenv("DART")
	if dart == "" {
		dart = "dart"
	} else if strings.ContainsRune(dart, os.PathSeparator) {
		// a path is taken from where the test runs (fuzz/), not from the
		// repository root the compile runs in
		abs, err := filepath.Abs(dart)
		if err != nil {
			t.Fatal(err)
		}
		dart = abs
	}
	exe := filepath.Join(t.TempDir(), "driver")
	cmd := exec.Command(dart, "compile", "exe", "--enable-asserts", "-o", exe, filepath.Join("fuzz", "driver.dart"))
	cmd.Dir = root
	out, err := cmd.CombinedOutput()
	if err != nil {
		// refused by name, never a skip: the differential is the gate
		t.Fatalf("dart compile exe fuzz/driver.dart failed (%v); is the Dart SDK on PATH and dart pub get run?\n%s", err, out)
	}
	return exe
}

func runDriver(t *testing.T, driver string, batch int, reqs []request) map[string][]string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, fmt.Sprintf("batch-%02d.txt", batch))
	var body bytes.Buffer
	for _, q := range reqs {
		body.WriteString(q.line)
		body.WriteByte('\n')
	}
	if err := os.WriteFile(path, body.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(driver, path)
	cmd.Dir = dir
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	// a run passes only on exit 0, an empty stderr and the driver's own
	// completion line: a throw, an assert or a crash fails the batch
	if err != nil || stderr.Len() != 0 {
		t.Fatalf("batch %d: the driver failed (%v); stderr:\n%s", batch, err, stderr.String())
	}
	out := map[string][]string{}
	sc := bufio.NewScanner(&stdout)
	sc.Buffer(make([]byte, 1<<20), 1<<24)
	done := false
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) == 0 {
			continue
		}
		if f[0] == "done" {
			if len(f) != 2 || f[1] != strconv.Itoa(len(reqs)) {
				t.Fatalf("batch %d: driver completion line %q, want done %d", batch, sc.Text(), len(reqs))
			}
			done = true
			continue
		}
		out[f[0]] = f
	}
	if !done {
		t.Fatalf("batch %d: the driver never printed its completion line; stdout:\n%s", batch, stdout.String())
	}
	return out
}

// ---------------------------------------------------------------------------
// comparison

type program struct {
	n        int
	steps    []step
	text     string
	goW      result // serialize.go's write
	canon    []string
	mutant   []byte
	mutation string
}

func (p *program) header() string {
	return fmt.Sprintf("program %d (%d steps): %s", p.n, len(p.steps), p.text)
}

// firstDifferingStep maps the first differing bit of two byte strings onto
// the step of the writer whose bits hold it.
func firstDifferingStep(a, b []byte, steps []step, endBits []int64) string {
	bit := int64(-1)
	for i := 0; i < max(len(a), len(b)); i++ {
		var x, y byte
		if i < len(a) {
			x = a[i]
		}
		if i < len(b) {
			y = b[i]
		}
		if x != y || i >= len(a) || i >= len(b) {
			d := x ^ y
			k := int64(0)
			for d != 0 && d&1 == 0 {
				d >>= 1
				k++
			}
			bit = int64(i)*8 + k
			break
		}
	}
	for i, e := range endBits {
		// an object's end is past every step it contains: the step that
		// holds the bit is the first leaf ending past it
		if steps[i].kind != "object" && e > bit {
			return fmt.Sprintf("step %d (bit %d)", i, bit)
		}
	}
	return fmt.Sprintf("past the last step (bit %d)", bit)
}

func compareWrite(p *program, goW, dartW result) string {
	if !goW.ok || !dartW.ok {
		return fmt.Sprintf("%s\n  a write refused: go ok=%v %d %s, dart ok=%v %d %s", p.header(), goW.ok, goW.idx, goW.kind, dartW.ok, dartW.idx, dartW.kind)
	}
	if !bytes.Equal(goW.bytes, dartW.bytes) {
		return fmt.Sprintf("%s\n  go bytes:   %x\n  dart bytes: %x\n  first differing step: %s",
			p.header(), goW.bytes, dartW.bytes, firstDifferingStep(goW.bytes, dartW.bytes, p.steps, goW.endBits))
	}
	return ""
}

// bothBytes is the pair of byte strings every disagreement prints.
func bothBytes(p *program, dart []byte) string {
	return fmt.Sprintf("\n  go bytes:   %x\n  dart bytes: %x", p.goW.bytes, dart)
}

func compareValues(p *program, who string, got, want []string) string {
	for i := range want {
		if i >= len(got) || got[i] != want[i] {
			g := "(none)"
			if i < len(got) {
				g = got[i]
			}
			return fmt.Sprintf("%s\n  %s: first differing step %d (%s): decoded %s, want %s", p.header(), who, i, p.steps[i].kind, g, want[i])
		}
	}
	return ""
}

func compareReads(p *program, what string, data []byte, a, b result) string {
	head := fmt.Sprintf("%s\n  %s bytes: %x\n", p.header(), what, data)
	if a.ok != b.ok {
		return head + fmt.Sprintf("  go ok=%v (refused step %d %s), dart ok=%v (refused step %d %s)", a.ok, a.idx, a.kind, b.ok, b.idx, b.kind)
	}
	if !a.ok {
		if a.idx != b.idx || a.kind != b.kind {
			return head + fmt.Sprintf("  go refused step %d (%s) with %s, dart refused step %d (%s) with %s",
				a.idx, p.steps[a.idx].kind, a.kind, b.idx, p.steps[min(max(b.idx, 0), len(p.steps)-1)].kind, b.kind)
		}
	} else if a.bits != b.bits {
		return head + fmt.Sprintf("  go consumed %d bits, dart %d", a.bits, b.bits)
	}
	if d := compareValues(p, what+": go vs dart", b.vals, a.vals); d != "" {
		return d
	}
	return ""
}

func TestDifferentialAgainstSerializeGo(t *testing.T) {
	root, err := filepath.Abs("..")
	if err != nil {
		t.Fatal(err)
	}
	if *programsFlag < 1 {
		t.Fatalf("-programs %d: a round has at least one program", *programsFlag)
	}
	driver := buildDriver(t, root)

	t.Logf("seed %#x, programs per round %d, duration %v, first round %d (replay a red round with -seed %#x -rounds-from R -duration 0)",
		*seedFlag, *programsFlag, *durationFlag, *roundsFrom, *seedFlag)
	start := time.Now()
	rounds, programs := 0, 0
	for round := *roundsFrom; ; round++ {
		roundStart := time.Now()
		red := runRound(t, driver, *seedFlag, round)
		rounds++
		programs += *programsFlag
		if red {
			t.Errorf("round %d of seed %#x is red; replay: go test -run TestDifferentialAgainstSerializeGo -seed %#x -rounds-from %d -duration 0",
				round, *seedFlag, *seedFlag, round)
			break
		}
		if *sabotageWidenInt || *durationFlag <= 0 {
			break
		}
		// stop before a round that would overrun the budget
		if time.Since(start)+time.Since(roundStart) > *durationFlag {
			break
		}
	}
	t.Logf("%d rounds, %d programs in %v", rounds, programs, time.Since(start).Round(time.Millisecond))
}

// runRound runs one round of programs and reports whether it went red.
func runRound(t *testing.T, driver string, seed uint64, round int) bool {
	t.Helper()
	g := &gen{r: rand.New(rand.NewPCG(seed, uint64(round)))}
	count := *programsFlag
	progs := make([]*program, count)
	ops := 0
	for n := range progs {
		// a packet is one object and its end (STANDARD.md end)
		steps := append(g.program(1+g.r.IntN(maxOps), 0), step{kind: "end"})
		ops += len(steps)
		p := &program{n: n, steps: steps, text: programText(steps)}
		p.goW = goWrite(steps, writeCap, *sabotageWidenInt)
		if !p.goW.ok {
			t.Fatalf("%s\n  serialize.go refused its own in-range program at step %d (%s): a generator bug", p.header(), p.goW.idx, p.goW.kind)
		}
		self := goRead(steps, p.goW.bytes)
		if *sabotageWidenInt {
			// the expected values come from the honest writer; only the
			// bytes under comparison are sabotaged
			self = goRead(steps, goWrite(steps, writeCap, false).bytes)
		}
		// an accepted end consumes the final byte's padding: a read of the
		// whole packet consumes 8 * bytes bits (STANDARD.md end)
		if !self.ok || (!*sabotageWidenInt && self.bits != 8*int64(len(p.goW.bytes))) {
			t.Fatalf("%s\n  serialize.go does not read back its own bytes %x (ok=%v step %d %s)", p.header(), p.goW.bytes, self.ok, self.idx, self.kind)
		}
		p.canon = make([]string, len(steps))
		for i := range steps {
			p.canon[i] = programValue(&steps[i])
			if steps[i].kind == "cfloat" {
				// quantization is lossy: the value a reader must decode is
				// the one serialize.go decodes from its own bytes
				// (STANDARD.md compressed_float)
				p.canon[i] = self.vals[i]
			} else if self.vals[i] != p.canon[i] {
				t.Fatalf("%s\n  serialize.go decodes step %d as %s from its own bytes, the program states %s", p.header(), i, self.vals[i], p.canon[i])
			}
		}
		if g.r.IntN(4) == 0 {
			p.mutant, p.mutation = mutate(g, p.goW.bytes)
		}
		progs[n] = p
	}

	// every operation is drawn: a kind the generator never reaches would be
	// a hole in the differential, so it fails by name
	seen := map[string]int{}
	for _, p := range progs {
		for i := range p.steps {
			seen[p.steps[i].kind]++
		}
	}
	var counts []string
	for _, k := range append(append([]string{}, leafKinds...), "object", "end") {
		if seen[k] == 0 && count >= 1000 {
			t.Errorf("round %d: the generator drew no %s step in %d programs", round, k, count)
		}
		counts = append(counts, fmt.Sprintf("%s=%d", k, seen[k]))
	}
	if round == *roundsFrom {
		t.Logf("round %d operations drawn: %s", round, strings.Join(counts, " "))
	}

	var disagreements []string
	mutants, mutantRefusals := 0, 0
	dartBytes := make([][]byte, count)
	for b := 0; b*batchSize < count; b++ {
		batch := progs[b*batchSize : min((b+1)*batchSize, count)]
		var reqs []request
		for _, p := range batch {
			id := strconv.Itoa(p.n)
			reqs = append(reqs,
				request{id + "w", fmt.Sprintf("w %sw %d %s", id, writeCap, p.text)},
				request{id + "r", fmt.Sprintf("r %sr %s %s", id, hexBytes(p.goW.bytes), p.text)})
			if p.mutant != nil {
				reqs = append(reqs, request{id + "m", fmt.Sprintf("r %sm %s %s", id, hexBytes(p.mutant), p.text)})
			}
		}
		out := runDriver(t, driver, b, reqs)
		get := func(id string, n int) result {
			f, ok := out[id]
			if !ok {
				t.Fatalf("round %d batch %d: the driver gave no result for request %s", round, b, id)
			}
			res, err := parseResult(f, n)
			if err != nil {
				t.Fatalf("round %d batch %d: request %s: %v", round, b, id, err)
			}
			return res
		}
		for _, p := range batch {
			id := strconv.Itoa(p.n)
			n := len(p.steps)
			add := func(d string) {
				if d != "" {
					disagreements = append(disagreements, d)
				}
			}
			// (1) the bytes and bit counts are equal; the measure bounds them
			dartW := get(id+"w", n)
			add(compareWrite(p, p.goW, dartW))
			dartBytes[p.n] = dartW.bytes
			both := bothBytes(p, dartW.bytes)
			if dartW.ok {
				if dartW.bits != p.goW.bits {
					add(fmt.Sprintf("%s%s\n  dart wrote %d bits, go %d", p.header(), both, dartW.bits, p.goW.bits))
				}
				if dartW.measured < dartW.bits {
					add(fmt.Sprintf("%s%s\n  dart MeasureStream under-measures: %d bits measured, %d written", p.header(), both, dartW.measured, dartW.bits))
				}
			}
			// (2) each side reads the other's bytes and decodes the program
			dartR := get(id+"r", n)
			if !dartR.ok {
				add(fmt.Sprintf("%s%s\n  dart refused serialize.go's bytes at step %d with %s", p.header(), both, dartR.idx, dartR.kind))
			} else {
				if d := compareValues(p, "dart reading go's bytes", dartR.vals, p.canon); d != "" {
					add(d + both)
				}
				if dartR.bits != 8*int64(len(p.goW.bytes)) {
					add(fmt.Sprintf("%s%s\n  dart consumed %d bits of go's %d bytes, the end consumes them all", p.header(), both, dartR.bits, len(p.goW.bytes)))
				}
			}
			if dartW.ok {
				goR := goRead(p.steps, dartW.bytes)
				if !goR.ok {
					add(fmt.Sprintf("%s%s\n  go refused dart's bytes at step %d with %s", p.header(), both, goR.idx, goR.kind))
				} else if d := compareValues(p, "go reading dart's bytes", goR.vals, p.canon); d != "" {
					add(d + both)
				}
			}
			// (3) both readers agree on a mutant
			if p.mutant != nil {
				mutants++
				dartM := get(id+"m", n)
				goM := goRead(p.steps, p.mutant)
				if !goM.ok {
					mutantRefusals++
				}
				add(compareReads(p, "mutant ("+p.mutation+")", p.mutant, goM, dartM))
			}
		}
	}

	// the first round and every red round report in full; a long run's other
	// rounds are counted in the closing line
	if round == *roundsFrom || len(disagreements) > 0 {
		t.Logf("round %d: %d programs, %d operations, %d mutants (%d of them refused by serialize.go), %d disagreements",
			round, count, ops, mutants, mutantRefusals, len(disagreements))
	}
	for i, d := range disagreements {
		if i == 10 {
			t.Errorf("... and %d more disagreements", len(disagreements)-10)
			break
		}
		t.Errorf("disagreement:\n%s", d)
	}
	if len(disagreements) > 0 && *failuresDir != "" {
		writeFailures(t, seed, round, disagreements)
	}

	// THE NEGATIVE CONTROL, in every round: the same programs written by a
	// Go writer that widens each int range by one bit, through the same
	// comparison, must go red.
	controlRed := false
	if !*sabotageWidenInt {
		red, eligible := 0, 0
		first := ""
		for _, p := range progs {
			has := false
			for i := range p.steps {
				s := &p.steps[i]
				if s.kind == "int" {
					if bits := serialize.BitsRequired(uint32(int32(s.min.Lo)), uint32(int32(s.max.Lo))); bits >= 1 && bits < 32 {
						has = true
					}
				}
			}
			if !has {
				continue
			}
			eligible++
			if dartBytes[p.n] == nil {
				continue // a refused dart write is already a disagreement above
			}
			sab := goWrite(p.steps, writeCap, true)
			if d := compareWrite(p, sab, result{ok: true, bytes: dartBytes[p.n]}); d != "" {
				red++
				if first == "" {
					first = d
				}
			}
		}
		if red == 0 {
			controlRed = true
			t.Errorf("round %d negative control: the int range widened by one bit went green on all %d programs with a widenable int", round, eligible)
		} else if round == *roundsFrom {
			t.Logf("round %d negative control: the int range widened by one bit went red on %d of %d programs with a widenable int; the first:\n%s", round, red, eligible, first)
		}
	}
	return len(disagreements) > 0 || controlRed
}

// writeFailures records a red round's disagreements, with its seed and
// round, for the nightly's artifact upload.
func writeFailures(t *testing.T, seed uint64, round int, disagreements []string) {
	t.Helper()
	if err := os.MkdirAll(*failuresDir, 0o755); err != nil {
		t.Errorf("failures directory: %v", err)
		return
	}
	var b strings.Builder
	fmt.Fprintf(&b, "seed %#x round %d\nreplay: cd fuzz && go test -run TestDifferentialAgainstSerializeGo -seed %#x -rounds-from %d -duration 0\n\n",
		seed, round, seed, round)
	for _, d := range disagreements {
		b.WriteString("disagreement:\n")
		b.WriteString(d)
		b.WriteString("\n\n")
	}
	path := filepath.Join(*failuresDir, fmt.Sprintf("seed-%x-round-%d.txt", seed, round))
	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		t.Errorf("failures file: %v", err)
		return
	}
	t.Logf("disagreements written to %s", path)
}

// mutate returns a copy of b with bit flips, a truncation or an extension,
// or, the hostile read, arbitrary bytes of about b's length.
func mutate(g *gen, b []byte) ([]byte, string) {
	m := append([]byte(nil), b...)
	choice := g.r.IntN(4)
	if len(m) == 0 && choice < 2 {
		choice = 2
	}
	switch choice {
	case 3:
		r := make([]byte, g.r.IntN(len(m)+9))
		for i := range r {
			r[i] = byte(g.r.Uint32())
		}
		return r, fmt.Sprintf("%d arbitrary bytes", len(r))
	case 0:
		n := 1 + g.r.IntN(3)
		for range n {
			bit := g.r.IntN(len(m) * 8)
			m[bit/8] ^= 1 << (bit % 8)
		}
		return m, fmt.Sprintf("%d bit flips", n)
	case 1:
		cut := 1 + g.r.IntN(len(m))
		return m[:len(m)-cut], fmt.Sprintf("truncated by %d bytes", cut)
	}
	n := 1 + g.r.IntN(8)
	for range n {
		m = append(m, byte(g.r.Uint32()))
	}
	return m, fmt.Sprintf("extended by %d bytes", n)
}
