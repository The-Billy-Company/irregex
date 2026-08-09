//go:build cgo

package irgx

// The literal plane: what a pattern PROMISES about the bytes any match must
// contain, plus the Unicode tables the engine itself decides with.
//
// This is the input an indexer needs. A prefilter is only allowed to skip a
// document when skipping it cannot lose a match, and that permission is not a
// property of the literals - it is a property of the VERDICT that comes with
// them. Read [Promise] before you read a set: the same three strings are a
// guarantee under [VerdictExact] and a guess under [VerdictCandidate], and a
// filter built on the wrong one drops real matches silently.
//
// The tables are here for the same reason. A host that folds case with its own
// Unicode data is a host whose prefilter and this engine disagree about what a
// letter is, and the disagreement shows up as a missing result rather than as an
// error. [FoldOrbit] is the table -i folds with; [UnicodeVersion] is which
// edition of it.

/*
#cgo CFLAGS: -I${SRCDIR}
#include "shim.h"

static int32_t go_literals_open(irgx_regex *re, irgx_literals **out,
                                irgx_fault *f) {
  int32_t st = irgx_literals_open(re, out);
  capture(st, f);
  return st;
}

static int32_t go_literals_promise(const irgx_literals *lits, irgx_promise *out,
                                   irgx_fault *f) {
  int32_t st = irgx_literals_promise(lits, out);
  capture(st, f);
  return st;
}

static int32_t go_literals_set(const irgx_literals *lits, uint32_t place,
                               uint32_t *verdict, irgx_text *out, size_t cap,
                               size_t *written, irgx_fault *f) {
  int32_t st = irgx_literals_set(lits, place, verdict, out, cap, written);
  capture(st, f);
  return st;
}

static int32_t go_fold_orbit(uint32_t cp, uint32_t *out, size_t cap,
                             size_t *written, irgx_fault *f) {
  int32_t st = irgx_fold_orbit(cp, out, cap, written);
  capture(st, f);
  return st;
}

static int32_t go_property_ranges(const uint8_t *name, size_t len,
                                  irgx_range *out, size_t cap, size_t *written,
                                  irgx_fault *f) {
  int32_t st = irgx_property_ranges(name, len, out, cap, written);
  capture(st, f);
  return st;
}

static int32_t go_property_has(const uint8_t *name, size_t len, uint32_t cp,
                               irgx_fault *f) {
  int32_t st = irgx_property_has(name, len, cp);
  capture(st, f);
  return st;
}

static int32_t go_unicode_version(irgx_text *out, irgx_fault *f) {
  int32_t st = irgx_unicode_version(out);
  capture(st, f);
  return st;
}
*/
import "C"

import (
	"runtime"
	"strconv"
	"unicode"
	"unsafe"
)

// Place names one of the four literal sets a pattern can promise.
type Place uint32

const (
	// Required is a set every match must contain SOMEWHERE.
	PlaceRequired Place = C.IRGX_PLACE_REQUIRED
	// Prefix is a set every match must BEGIN with.
	PlacePrefix Place = C.IRGX_PLACE_PREFIX
	// Suffix is a set every match must END with.
	PlaceSuffix Place = C.IRGX_PLACE_SUFFIX
	// Whole is a set a match must equal outright.
	PlaceWhole Place = C.IRGX_PLACE_WHOLE
	// placeCount is how many there are, and the width of [Promise]'s arrays.
	placeCount = C.IRGX_PLACE_COUNT
)

func (p Place) String() string {
	switch p {
	case PlaceRequired:
		return "required"
	case PlacePrefix:
		return "prefix"
	case PlaceSuffix:
		return "suffix"
	case PlaceWhole:
		return "whole"
	}
	return "place " + strconv.FormatUint(uint64(p), 10)
}

// Verdict is how much a literal set PROVES, which is the only thing that makes
// one safe to filter with.
type Verdict uint32

const (
	// VerdictNone means there is no set: it proves nothing either way, and the
	// document has to be scanned.
	VerdictNone Verdict = C.IRGX_LITERALS_NONE
	// VerdictCandidate means the absence of EVERY member proves no match, while
	// the presence of one proves nothing and must still be verified.
	VerdictCandidate Verdict = C.IRGX_LITERALS_CANDIDATE
	// VerdictExact means containment and matching are one question, so a hit
	// needs no verification pass.
	VerdictExact Verdict = C.IRGX_LITERALS_EXACT
)

// Eliminates reports whether a document containing NO member of this set can be
// skipped without losing a match.
//
// The ordering the C header states as `verdict >= IRGX_LITERALS_CANDIDATE`, said
// as a predicate so a caller never has to remember which direction the constants
// run in. That comparison is the whole safety property of a prefilter, and it is
// exactly the kind of thing that gets inverted once and then read as correct.
func (v Verdict) Eliminates() bool { return v >= VerdictCandidate }

func (v Verdict) String() string {
	switch v {
	case VerdictNone:
		return "none"
	case VerdictCandidate:
		return "candidate"
	case VerdictExact:
		return "exact"
	}
	return "verdict " + strconv.FormatUint(uint64(v), 10)
}

// Unbounded is [Promise.MaxLen] for a pattern with no upper bound at all - `a+`,
// `.*`. Spelled as a negative length because no measured length can be one, so
// the sentinel cannot collide with an answer.
const Unbounded = -1

// Promise is the whole-pattern promise: what every match must look like, and how
// much each of the four sets proves.
type Promise struct {
	// Verdict is what each set proves, indexed by [Place].
	Verdict [placeCount]Verdict
	// Count is how many members each set holds, indexed by [Place]. It is the
	// exact cap [Literals.Set] needs, so reading a set never retries.
	Count [placeCount]int
	// Anchored is whether every match must start at the beginning of the text.
	Anchored bool
	// Nullable is whether the pattern can match the empty string.
	Nullable bool
	// MinLen and MaxLen bound a match in bytes. MaxLen is [Unbounded] when the
	// pattern has no ceiling.
	MinLen, MaxLen int
	// FirstBytes is a 256-bit set of the bytes a match may BEGIN with, as four
	// little-endian words: bit (b & 63) of FirstBytes[b >> 6]. All-zero means
	// UNKNOWN rather than "no byte can start a match" - read it through
	// [Promise.MayStartWith], which knows the difference.
	FirstBytes [4]uint64
	// Signature fingerprints the LANGUAGE the pattern denotes rather than its
	// text, so two spellings that accept the same set share it. For keying a
	// derived artifact across spellings.
	Signature [2]uint64
}

// MayStartWith reports whether a match could begin with b.
//
// An empty first-byte set means the engine could not compute one, which is a
// promise of NOTHING rather than a promise that nothing starts a match - so this
// answers true for every byte in that case. Reading the bitset directly and
// forgetting that distinction turns "I don't know" into "skip everything".
func (p Promise) MayStartWith(b byte) bool {
	if p.FirstBytes == [4]uint64{} {
		return true
	}
	return p.FirstBytes[b>>6]&(1<<(b&63)) != 0
}

// Literals is what one pattern promises about its matches.
//
// It is NOT safe for concurrent use by multiple goroutines, unlike [Regexp]: it
// is a raw engine handle rather than a pooled one, because a promise is read
// once at index-build time rather than on every search. Open one per goroutine,
// or read it once into a [Promise] and share that - a Promise is a plain value
// and copying it is free.
//
// The handle copies what it needs out of the pattern, so it borrows nothing from
// the [Regexp] it came from and the two are closed independently.
type Literals struct{ ptr *C.irgx_literals }

// Literals extracts what this pattern promises about its matches.
//
// Close it when done, or let the garbage collector: a finalizer frees the handle
// either way. That is safe here only because nothing this type hands back
// aliases the handle's memory - [Literals.Set] copies its rows out - so there is
// no live Go value that a free could invalidate.
func (re *Regexp) Literals() (*Literals, error) {
	h := re.acquire()
	defer re.release(h)
	var (
		ptr   *C.irgx_literals
		fault C.irgx_fault
	)
	if st := C.go_literals_open(h.ptr, &ptr, &fault); st != C.IRGX_OK {
		return nil, newError(st, &fault, "read the literals of "+strconv.Quote(re.expr))
	}
	l := &Literals{ptr: ptr}
	runtime.SetFinalizer(l, (*Literals).Close)
	return l, nil
}

// Close releases the handle. It is idempotent, and a free cannot fail, which is
// why it returns nothing.
func (l *Literals) Close() {
	if l.ptr != nil {
		C.irgx_literals_free(l.ptr)
		l.ptr = nil
		runtime.SetFinalizer(l, nil)
	}
}

// Promise returns the whole-pattern promise. Read it before a set: it says
// whether the set you are about to read is a guarantee or a guess.
func (l *Literals) Promise() Promise {
	var (
		raw   C.irgx_promise
		fault C.irgx_fault
	)
	raw.struct_size = C.uint32_t(unsafe.Sizeof(raw))
	if st := C.go_literals_promise(l.ptr, &raw, &fault); st < 0 {
		panic(newError(st, &fault, "read a pattern's literal promise"))
	}
	p := Promise{
		Anchored: raw.anchored != 0,
		Nullable: raw.nullable != 0,
		MinLen:   int(raw.min_len),
		MaxLen:   int(raw.max_len),
	}
	if raw.max_len == C.IRGX_LEN_UNBOUNDED {
		p.MaxLen = Unbounded
	}
	for i := range p.Verdict {
		p.Verdict[i] = Verdict(raw.verdict[i])
		p.Count[i] = int(raw.count[i])
	}
	for i := range p.FirstBytes {
		p.FirstBytes[i] = uint64(raw.first_bytes[i])
	}
	for i := range p.Signature {
		p.Signature[i] = uint64(raw.signature[i])
	}
	return p
}

// Set returns one literal set and what it proves.
//
// The verdict travels WITH the bytes rather than being looked up separately,
// because the pair is what a filter needs and the half of it that is easy to
// forget is the half that makes the filter correct. A nil set and
// [VerdictNone] means this pattern promises nothing at this place.
//
// The members are copied out of the handle's arena, so they outlive
// [Literals.Close] and are safe to keep, index, and send to another goroutine.
func (l *Literals) Set(place Place) ([]string, Verdict) {
	if place >= placeCount {
		panic("irregex: Literals.Set: " + place.String() + " is not a literal set")
	}
	var (
		verdict C.uint32_t
		fault   C.irgx_fault
	)
	// The promise carries the exact count, so this could be sized from it - but
	// that is a second crossing to save a resize on a list of at most a few
	// dozen strings. The count-only probe is one crossing and exact.
	rows, st := drain(0, func(buf []C.irgx_text) (int, int32) {
		var written C.size_t
		st := C.go_literals_set(l.ptr, C.uint32_t(place), &verdict, head(buf),
			C.size_t(len(buf)), &written, &fault)
		return int(written), int32(st)
	})
	if st < 0 {
		panic(newError(C.int32_t(st), &fault, "read a pattern's "+place.String()+" literals"))
	}
	return goStrings(rows), Verdict(verdict)
}

// FoldOrbit returns every codepoint that case-folds together with cp, INCLUDING
// cp itself.
//
// The orbit, not a pair: 'k', 'K' and U+212A KELVIN SIGN are one class, so a
// host that folds by adding or subtracting 0x20 has a different idea of equality
// than the engine does. This is the table [CompileOpts.IgnoreCase] folds with.
//
// It panics for a cp outside the Unicode range, which is a caller's arithmetic
// rather than a property of any text.
func FoldOrbit(cp rune) []rune {
	if cp < 0 || cp > unicode.MaxRune {
		panic("irregex: FoldOrbit: " + strconv.FormatInt(int64(cp), 10) + " is not a codepoint")
	}
	var fault C.irgx_fault
	// An orbit is a handful of codepoints; four covers every class in the table
	// and the retry is there for the day one grows.
	orbit, st := drain(4, func(buf []C.uint32_t) (int, int32) {
		var written C.size_t
		st := C.go_fold_orbit(C.uint32_t(cp), head(buf), C.size_t(len(buf)), &written, &fault)
		return int(written), int32(st)
	})
	if st < 0 {
		panic(newError(C.int32_t(st), &fault, "fold "+strconv.QuoteRune(cp)))
	}
	out := make([]rune, len(orbit))
	for i, r := range orbit {
		out[i] = rune(r)
	}
	return out
}

// RuneRange is an inclusive codepoint range.
type RuneRange struct{ Lo, Hi rune }

// PropertyRanges returns the inclusive ranges of the Unicode property name
// ("Letter", "Greek", "Nd", …), ascending and non-overlapping.
//
// An unknown name is an error rather than an empty answer, so a misspelled
// property and a genuinely empty class cannot look alike.
func PropertyRanges(name string) ([]RuneRange, error) {
	var fault C.irgx_fault
	// A guess wide enough for the common scripts; a bigger property measures its
	// own retry in one extra pass.
	ranges, st := drain(256, func(buf []C.irgx_range) (int, int32) {
		var written C.size_t
		st := C.go_property_ranges(bytePtr(name), C.size_t(len(name)), head(buf),
			C.size_t(len(buf)), &written, &fault)
		return int(written), int32(st)
	})
	runtime.KeepAlive(name)
	if st < 0 {
		return nil, newError(C.int32_t(st), &fault, "read the ranges of Unicode property "+strconv.Quote(name))
	}
	out := make([]RuneRange, len(ranges))
	for i, r := range ranges {
		out[i] = RuneRange{Lo: rune(r.lo), Hi: rune(r.hi)}
	}
	return out, nil
}

// PropertyHas reports whether cp is in the Unicode property name - the
// membership test without materializing the ranges. An unknown property is an
// error, for the reason [PropertyRanges] gives.
func PropertyHas(name string, cp rune) (bool, error) {
	var fault C.irgx_fault
	st := C.go_property_has(bytePtr(name), C.size_t(len(name)), C.uint32_t(cp), &fault)
	runtime.KeepAlive(name)
	if st < 0 {
		return false, newError(st, &fault, "test Unicode property "+strconv.Quote(name))
	}
	return st == C.IRGX_MATCH, nil
}

// UnicodeVersion returns the Unicode edition these tables were generated from,
// for example "16.0.0".
//
// Worth checking once at startup against whatever your own tables say: a host
// whose Unicode disagrees with the engine's is a host whose prefilter and this
// engine disagree about what a letter is.
func UnicodeVersion() string {
	var (
		out   C.irgx_text
		fault C.irgx_fault
	)
	if st := C.go_unicode_version(&out, &fault); st < 0 {
		panic(newError(st, &fault, "read the engine's Unicode version"))
	}
	return goString(out)
}

// goString copies a borrowed span into a Go string.
//
// Every irgx_text the engine hands back points into an arena owned by some
// handle and dies when that handle is freed, so a Go string over those bytes
// would be a use-after-free waiting for a Close. There is exactly one rule in
// this binding and this is it: copy at the boundary.
func goString(t C.irgx_text) string {
	if t.ptr == nil || t.len == 0 {
		return ""
	}
	return C.GoStringN((*C.char)(unsafe.Pointer(t.ptr)), C.int(t.len))
}

// goStrings copies a run of borrowed spans, for the same reason.
func goStrings(rows []C.irgx_text) []string {
	if len(rows) == 0 {
		return nil
	}
	out := make([]string, len(rows))
	for i, r := range rows {
		out[i] = goString(r)
	}
	return out
}
