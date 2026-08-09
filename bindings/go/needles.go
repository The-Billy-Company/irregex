//go:build cgo

package irgx

// The needle plane: many literals, one pass, with attribution.
//
// The question a regex alternation answers slowly. `(alpha|beta|…|omega)` makes
// the engine carry an automaton wide enough for every branch through every byte;
// a wordlist scanner reads the same bytes once and reports which words it saw.
// For a fixed vocabulary - a stopword list, a set of tokens to redact, a
// blocklist - this is the plane, and the tier it seats is REPORTED rather than
// chosen ([Needles.Shape]) so a host can price a scan before running it.
//
// Three questions, cheapest first: [Needles.MatchString] stops at the first hit
// and attributes nothing, [Needles.Which] says which needles occur, and
// [Needles.FindAllString] says where each occurrence is. Ask the cheapest one
// that answers your question - they are not the same cost.

/*
#cgo CFLAGS: -I${SRCDIR}
#include "shim.h"

static int32_t go_needles_compile(const irgx_needle *list, size_t count,
                                  uint32_t flags, size_t *refused,
                                  irgx_needles **out, irgx_fault *f) {
  int32_t st = irgx_needles_compile(list, count, flags, refused, out);
  capture(st, f);
  return st;
}

static int32_t go_needles_describe(const irgx_needles *h,
                                   irgx_needle_shape *out, irgx_fault *f) {
  int32_t st = irgx_needles_describe(h, out);
  capture(st, f);
  return st;
}

static int32_t go_needles_is_match(irgx_needles *h, const uint8_t *text,
                                   size_t len, irgx_fault *f) {
  int32_t st = irgx_needles_is_match(h, text, len);
  capture(st, f);
  return st;
}

static int32_t go_needles_which(irgx_needles *h, const uint8_t *text, size_t len,
                                uint32_t *out, size_t cap, size_t *written,
                                irgx_fault *f) {
  int32_t st = irgx_needles_which(h, text, len, out, cap, written);
  capture(st, f);
  return st;
}

static int32_t go_needles_find_all(irgx_needles *h, const uint8_t *text,
                                   size_t len, irgx_occurrence *out, size_t cap,
                                   size_t *written, irgx_fault *f) {
  int32_t st = irgx_needles_find_all(h, text, len, out, cap, written);
  capture(st, f);
  return st;
}
*/
import "C"

import (
	"runtime"
	"strconv"
	"unsafe"
)

// Tier names the machine that ended up seating a needle set. It is a
// consequence of the needles rather than a knob, and it is here so a host that
// wants to know what a scan will cost can ask instead of guessing.
type Tier uint32

const (
	// TierNone means nothing was seated.
	TierNone Tier = C.IRGX_NEEDLE_TIER_NONE
	// TierMemmem is one needle: a plain substring find.
	TierMemmem Tier = C.IRGX_NEEDLE_TIER_MEMMEM
	// TierLiteralSet is a few needles: SIMD multi-substring.
	TierLiteralSet Tier = C.IRGX_NEEDLE_TIER_LITERAL_SET
	// TierTrawl is many needles: Aho-Corasick.
	TierTrawl Tier = C.IRGX_NEEDLE_TIER_TRAWL
)

func (t Tier) String() string {
	switch t {
	case TierNone:
		return "none"
	case TierMemmem:
		return "memmem"
	case TierLiteralSet:
		return "literal-set"
	case TierTrawl:
		return "trawl"
	}
	return "tier " + strconv.FormatUint(uint64(t), 10)
}

// NeedleShape is what a compiled set is, and which machine answers about it.
type NeedleShape struct {
	// PresenceTier answers [Needles.MatchString]; AttributedTier answers
	// [Needles.Which] and [Needles.FindAllString]. They can differ: presence is
	// sometimes answerable by a cheaper machine than attribution, and a host
	// budgeting a scan needs the one it will actually use.
	PresenceTier, AttributedTier Tier
	// Count is how many needles were SEATED, which a refusal makes smaller than
	// the number handed in.
	Count int
	// Longest is the longest seated needle, in bytes; Bytes is all of them.
	Longest, Bytes int
}

// Occurrence is one hit, attributed to the needle that produced it.
type Occurrence struct {
	// Needle indexes the list passed to [CompileNeedles], which is the list as
	// GIVEN - the set seats every needle or none, so the two never disagree.
	Needle int
	// Start and End are byte offsets into the text, half-open.
	Start, End int
}

// Needles is a compiled literal set.
//
// It is NOT safe for concurrent use by multiple goroutines: the handle owns the
// scratch its scans run in, so two goroutines sharing one corrupt a result
// rather than race a counter. Compile one per goroutine - compiling is pure - or
// guard it. [Needles.Shape] and [Needles.Len] are the same rule; nothing here is
// promised to be a concurrent reader.
type Needles struct {
	ptr   *C.irgx_needles
	given int
}

// CompileNeedles seats list into one scanner.
//
// A set is ALL OR NOTHING: a needle the machine will not seat refuses the whole
// call, so a returned set always holds every word you asked about and Len() is
// always len(list). There is no partial mode to check for before trusting a
// negative answer. The error names which needle caused a refusal.
//
// An empty needle is not a needle and the engine refuses the whole call.
func CompileNeedles(list ...string) (*Needles, error) {
	return compileNeedles(list, 0)
}

func compileNeedles(list []string, flags uint32) (*Needles, error) {
	// Two guards the engine would also catch, kept here because the crossing
	// cannot survive the input: `unsafe.StringData("")` is not required to
	// return a real address, and pinning that panics before the engine ever
	// sees the needle. Naming the index is the second reason, not the first -
	// a wordlist read from a file has a blank line in it eventually, and
	// "needle 41 is empty" is the sentence that fixes it.
	if len(list) == 0 {
		return nil, refuse("compile a needle set of no needles")
	}
	// One irgx_needle per needle, pointing at the caller's own bytes. Every
	// pointer is Go memory the C call reads and does not retain (the engine
	// copies what it keeps), so a Pinner covers the crossing exactly - and the
	// SLICE holding those pointers is itself Go memory containing Go pointers,
	// which cgo forbids passing without pinning them.
	var pin runtime.Pinner
	defer pin.Unpin()
	seats := make([]C.irgx_needle, len(list))
	for i, s := range list {
		if s == "" {
			return nil, refuse("compile a needle set whose needle " + strconv.Itoa(i) + " is empty")
		}
		p := bytePtr(s)
		pin.Pin(p)
		seats[i] = C.irgx_needle{needle: p, len: C.size_t(len(s))}
	}
	var (
		ptr   *C.irgx_needles
		fault C.irgx_fault
	)
	// NULL for the engine's `refused` slot, which the header permits. It is
	// written only for an empty or null needle, and the loop above answers both
	// before the crossing - so reading it here could only ever report the seed
	// this function put there.
	st := C.go_needles_compile(head(seats), C.size_t(len(seats)), C.uint32_t(flags),
		nil, &ptr, &fault)
	runtime.KeepAlive(list)
	runtime.KeepAlive(seats)
	if st != C.IRGX_OK {
		return nil, newError(st, &fault, "compile a set of "+strconv.Itoa(len(list))+" needles")
	}
	n := &Needles{ptr: ptr, given: len(list)}
	runtime.SetFinalizer(n, (*Needles).Close)
	return n, nil
}

// Close releases the scanner. Idempotent, and it cannot fail.
//
// Nothing this type returns borrows the handle - occurrences are numbers and
// [Needles.Which] returns indices - so a Close can never invalidate a value a
// caller is still holding, which is what makes the finalizer safe.
func (n *Needles) Close() {
	if n.ptr != nil {
		C.irgx_needles_free(n.ptr)
		n.ptr = nil
		runtime.SetFinalizer(n, nil)
	}
}

// Len is how many needles the set holds - the exact cap [Needles.Which] never
// has to retry at, and the number to compare against the list you handed in.
func (n *Needles) Len() int { return int(C.irgx_needles_len(n.ptr)) }

// Shape is what the set is and which machine answers about it.
func (n *Needles) Shape() NeedleShape {
	var (
		raw   C.irgx_needle_shape
		fault C.irgx_fault
	)
	raw.struct_size = C.uint32_t(unsafe.Sizeof(raw))
	if st := C.go_needles_describe(n.ptr, &raw, &fault); st < 0 {
		panic(newError(st, &fault, "describe a needle set"))
	}
	return NeedleShape{
		PresenceTier:   Tier(raw.presence_tier),
		AttributedTier: Tier(raw.attributed_tier),
		Count:          int(raw.count),
		Longest:        int(raw.longest),
		Bytes:          int(raw.bytes),
	}
}

// Match reports whether any needle occurs in b.
func (n *Needles) Match(b []byte) bool { return n.MatchString(borrow(b)) }

// MatchString reports whether any needle occurs in s.
//
// The cheapest question: it stops at the first hit and attributes nothing. Reach
// for it whenever "which one" is not part of what you need.
func (n *Needles) MatchString(s string) bool {
	var fault C.irgx_fault
	st := C.go_needles_is_match(n.ptr, bytePtr(s), C.size_t(len(s)), &fault)
	runtime.KeepAlive(s)
	if st < 0 {
		panic(newError(st, &fault, "scan a text of length "+strconv.Itoa(len(s))+" for any needle"))
	}
	return st == C.IRGX_MATCH
}

// Which returns the indices of the needles that occur in b.
func (n *Needles) Which(b []byte) []int { return n.WhichString(borrow(b)) }

// WhichString returns the ascending indices of the needles that occur in s -
// PRESENCE per needle, not one entry per occurrence, so a word appearing twenty
// times appears here once.
//
// The set's own length is the exact ceiling, so this is always one crossing.
func (n *Needles) WhichString(s string) []int {
	var fault C.irgx_fault
	hits, st := drain(n.Len(), func(buf []C.uint32_t) (int, int32) {
		var written C.size_t
		st := C.go_needles_which(n.ptr, bytePtr(s), C.size_t(len(s)), head(buf),
			C.size_t(len(buf)), &written, &fault)
		return int(written), int32(st)
	})
	runtime.KeepAlive(s)
	if st < 0 {
		panic(newError(C.int32_t(st), &fault, "scan a text of length "+strconv.Itoa(len(s))+" for which needles occur"))
	}
	if len(hits) == 0 {
		return nil
	}
	out := make([]int, len(hits))
	for i, h := range hits {
		out[i] = int(h)
	}
	return out
}

// FindAll returns every occurrence in b.
func (n *Needles) FindAll(b []byte) []Occurrence { return n.FindAllString(borrow(b)) }

// FindAllString returns every occurrence in s, each carrying the needle that
// produced it and its span.
//
// Occurrences are plain numbers, so the result outlives the scanner and needs
// nothing kept alive.
func (n *Needles) FindAllString(s string) []Occurrence {
	var fault C.irgx_fault
	// A guess: most texts hold few hits, and the engine reports the count that
	// EXISTS, so a busy one measures its own single retry.
	rows, st := drain(16, func(buf []C.irgx_occurrence) (int, int32) {
		var written C.size_t
		st := C.go_needles_find_all(n.ptr, bytePtr(s), C.size_t(len(s)), head(buf),
			C.size_t(len(buf)), &written, &fault)
		return int(written), int32(st)
	})
	runtime.KeepAlive(s)
	if st < 0 {
		panic(newError(C.int32_t(st), &fault, "find every needle in a text of length "+strconv.Itoa(len(s))))
	}
	if len(rows) == 0 {
		return nil
	}
	out := make([]Occurrence, len(rows))
	for i, r := range rows {
		out[i] = Occurrence{Needle: int(r.needle), Start: int(r.start), End: int(r.end)}
	}
	return out
}
