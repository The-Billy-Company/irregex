//go:build cgo

package irgx

// The codex plane: count, locate and restore WITHOUT the text.
//
// A self-index. It answers questions about a text it does not store, and it can
// hand the text back - so once you have built one you can throw the original
// away, and [Codex.Text] reconstructs it from the index alone.
//
// The reason to want one is [Codex.Count]: how many times a needle occurs, in
// time proportional to the NEEDLE and independent of the corpus. Not "fast for a
// scan" - it never looks at the corpus. The occurrences are never enumerated in
// order to count them, which is why counting a rare needle and counting a needle
// that occurs a million times cost the same.
//
// Locating costs more than counting, and an index can be built without the
// ability to do it at all ([NoLocate]). That is not a degraded index: counting
// stays exact, the index gets smaller, and [Codex.Locate] DECLINES rather than
// answering emptily - the remedy is real, so it is reported as one.

/*
#cgo CFLAGS: -I${SRCDIR}
#include "shim.h"

static int32_t go_codex_build(const uint8_t *text, size_t len,
                              const irgx_codex_options *opts, irgx_codex **out,
                              irgx_fault *f) {
  int32_t st = irgx_codex_build(text, len, opts, out);
  capture(st, f);
  return st;
}

static int32_t go_codex_load(const uint8_t *bytes, size_t len, irgx_codex **out,
                             irgx_fault *f) {
  int32_t st = irgx_codex_load(bytes, len, out);
  capture(st, f);
  return st;
}

static int32_t go_codex_measure(const irgx_codex *cx, irgx_codex_stats *out,
                                irgx_fault *f) {
  int32_t st = irgx_codex_measure(cx, out);
  capture(st, f);
  return st;
}

static int32_t go_codex_count(const irgx_codex *cx, const uint8_t *pattern,
                              size_t len, size_t *out, irgx_fault *f) {
  int32_t st = irgx_codex_count(cx, pattern, len, out);
  capture(st, f);
  return st;
}

static int32_t go_codex_locate(const irgx_codex *cx, const uint8_t *pattern,
                               size_t len, size_t *out, size_t cap,
                               size_t *written, irgx_fault *f) {
  int32_t st = irgx_codex_locate(cx, pattern, len, out, cap, written);
  capture(st, f);
  return st;
}

static int32_t go_codex_position(const irgx_codex *cx, size_t row, size_t *out,
                                 irgx_fault *f) {
  int32_t st = irgx_codex_position(cx, row, out);
  capture(st, f);
  return st;
}

static int32_t go_codex_rows_whole(const irgx_codex *cx, irgx_codex_rows *out,
                                   irgx_fault *f) {
  int32_t st = irgx_codex_rows_whole(cx, out);
  capture(st, f);
  return st;
}

static int32_t go_codex_rows_extend(const irgx_codex *cx, irgx_codex_rows *rows,
                                    uint8_t byte, irgx_fault *f) {
  int32_t st = irgx_codex_rows_extend(cx, rows, byte);
  capture(st, f);
  return st;
}

static int32_t go_codex_extract(irgx_codex *cx, size_t at, uint8_t *out,
                                size_t cap, size_t *written, irgx_fault *f) {
  int32_t st = irgx_codex_extract(cx, at, out, cap, written);
  capture(st, f);
  return st;
}

static int32_t go_codex_save(irgx_codex *cx, uint8_t *out, size_t cap,
                             size_t *written, irgx_fault *f) {
  int32_t st = irgx_codex_save(cx, out, cap, written);
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

// NoLocate is the [CodexOpts.SampleRate] that builds NO locate layer: the index
// counts exactly, occupies less, and declines to say where.
//
// Reach for it when the question is "how many" or "does this occur", which is
// most of them. [Codex.Locate] and [Codex.Position] then return ok == false
// forever, which is the honest report of a structure that was never built rather
// than a text with no matches.
const NoLocate uint32 = C.IRGX_NO_LOCATE

// CodexOpts are build options. The zero value is this build's own defaults.
type CodexOpts struct {
	// SampleRate trades index size against locate speed: larger is smaller and
	// slower, 0 takes this build's default, and [NoLocate] builds no locate
	// layer at all.
	SampleRate uint32
	// PlainOnly forbids the compressed wavelet form, so the index has a
	// predictable size rather than a smaller one. The default picks whichever is
	// smaller per block, which is what you want unless you are budgeting bytes
	// ahead of time.
	PlainOnly bool
}

func (o CodexOpts) raw() C.irgx_codex_options {
	out := C.irgx_codex_options{sample_rate: C.uint32_t(o.SampleRate)}
	out.struct_size = C.uint32_t(unsafe.Sizeof(out))
	if o.PlainOnly {
		out.encoding = C.IRGX_CODEX_PLAIN_ONLY
	}
	return out
}

// CodexStats is what an index cost and what it can still do.
type CodexStats struct {
	// SampleRate is the rate the locate layer was built at, or 0 when there is
	// none. Deliberately 0 rather than [NoLocate]: this is a measurement, and
	// the sentinel belongs to the request.
	SampleRate uint32
	// Locates is whether [Codex.Locate] can answer at all.
	Locates bool
	// TextLen is the length of the text this index stands for - which need not
	// exist any more.
	TextLen int
	// IndexBytes is the whole index; TreeBytes the wavelet layer; LocateBytes
	// the sampled positions. The last is what [NoLocate] buys back.
	IndexBytes, TreeBytes, LocateBytes int
}

// Rows is a half-open row interval [Lo, Hi) in the index: the set of suffixes a
// pattern prefix still admits.
//
// You need this only to drive the backward search yourself with [Codex.Whole] and
// [Codex.Extend] - for instance to share the work between needles with a common
// suffix, or to stop as soon as an interval empties. [Codex.Count] and
// [Codex.Locate] do it for you.
type Rows struct{ Lo, Hi int }

// Width is how many suffixes the interval admits, which for a completed pattern
// is its occurrence count.
func (r Rows) Width() int {
	if r.Hi <= r.Lo {
		return 0
	}
	return r.Hi - r.Lo
}

// Codex is a self-index over one text.
//
// It is NOT safe for concurrent use by multiple goroutines: [Codex.Extract] and
// [Codex.Save] decode through scratch the handle owns. Build one per goroutine,
// or guard it.
type Codex struct{ ptr *C.irgx_codex }

// MaxCodexTextLen is the longest text this build can index, so a host can refuse
// before allocating rather than after.
func MaxCodexTextLen() int { return int(C.irgx_codex_max_text_len()) }

// BuildCodex builds a self-index over text.
func BuildCodex(text []byte, opts CodexOpts) (*Codex, error) {
	return BuildCodexString(borrow(text), opts)
}

// BuildCodexString builds a self-index over s.
//
// The index absorbs what it needs during this call, so s is not retained and may
// be released - or overwritten - the moment this returns. That is the whole
// point: the index stands in for the text.
func BuildCodexString(s string, opts CodexOpts) (*Codex, error) {
	if len(s) > MaxCodexTextLen() {
		return nil, refuse("index a text of " + strconv.Itoa(len(s)) +
			" bytes, past this build's ceiling of " + strconv.Itoa(MaxCodexTextLen()))
	}
	raw := opts.raw()
	var (
		ptr   *C.irgx_codex
		fault C.irgx_fault
	)
	st := C.go_codex_build(bytePtr(s), C.size_t(len(s)), &raw, &ptr, &fault)
	runtime.KeepAlive(s)
	if st != C.IRGX_OK {
		return nil, newError(st, &fault, "index a text of "+strconv.Itoa(len(s))+" bytes")
	}
	return adopt(ptr), nil
}

// LoadCodex rebuilds an index from a [Codex.Save] image.
//
// Fails closed: any framing, seal or structural violation is an error, and so is
// an image a newer build wrote. There is no partial load, because half an index
// would answer confidently and wrongly.
func LoadCodex(image []byte) (*Codex, error) {
	if len(image) == 0 {
		return nil, refuse("load a self-index from an empty image")
	}
	var (
		ptr   *C.irgx_codex
		fault C.irgx_fault
	)
	st := C.go_codex_load((*C.uint8_t)(&image[0]), C.size_t(len(image)), &ptr, &fault)
	runtime.KeepAlive(image)
	if st != C.IRGX_OK {
		return nil, newError(st, &fault, "load a self-index from "+strconv.Itoa(len(image))+" bytes")
	}
	return adopt(ptr), nil
}

func adopt(ptr *C.irgx_codex) *Codex {
	cx := &Codex{ptr: ptr}
	runtime.SetFinalizer(cx, (*Codex).Close)
	return cx
}

// Close releases the index. Idempotent, and it cannot fail.
//
// Safe as a finalizer: every answer here is a number or a Go slice copied out of
// the decoder, so nothing a caller holds points inside the index.
func (cx *Codex) Close() {
	if cx.ptr != nil {
		C.irgx_codex_free(cx.ptr)
		cx.ptr = nil
		runtime.SetFinalizer(cx, nil)
	}
}

// Len is the length of the text this index stands for - the buffer a full
// [Codex.Text] wants. A pure getter: it cannot refuse.
func (cx *Codex) Len() int { return int(C.irgx_codex_len(cx.ptr)) }

// Measure reports what the index cost and what it can still do.
func (cx *Codex) Measure() CodexStats {
	var (
		raw   C.irgx_codex_stats
		fault C.irgx_fault
	)
	raw.struct_size = C.uint32_t(unsafe.Sizeof(raw))
	if st := C.go_codex_measure(cx.ptr, &raw, &fault); st < 0 {
		panic(newError(st, &fault, "measure a self-index"))
	}
	return CodexStats{
		SampleRate:  uint32(raw.sample_rate),
		Locates:     raw.locates != 0,
		TextLen:     int(raw.text_len),
		IndexBytes:  int(raw.index_bytes),
		TreeBytes:   int(raw.tree_bytes),
		LocateBytes: int(raw.locate_bytes),
	}
}

// Count is how many times pattern occurs, overlapping occurrences counted.
//
// The operation this whole plane exists for, answered in one rank step per
// pattern byte and independent of the length of the text. The empty pattern
// counts 0 - a search answer rather than the vacuous n+1 the mathematics gives,
// which is what a host looping over user input needs.
func (cx *Codex) Count(pattern string) int {
	var (
		out   C.size_t
		fault C.irgx_fault
	)
	if st := C.go_codex_count(cx.ptr, bytePtr(pattern), C.size_t(len(pattern)), &out, &fault); st < 0 {
		panic(newError(st, &fault, "count "+strconv.Quote(pattern)+" in a self-index"))
	}
	runtime.KeepAlive(pattern)
	return int(out)
}

// Locate is where pattern occurs, as ascending byte offsets into the text.
//
// ok is false when this index was built without a locate layer ([NoLocate]).
// That is a declinature, not an empty answer: counting is still exact, and the
// remedy is to rebuild with a sample rate. An empty slice with ok true means the
// pattern genuinely does not occur.
func (cx *Codex) Locate(pattern string) (at []int, ok bool) {
	var fault C.irgx_fault
	// The count is one cheap crossing and it is exact, so sizing from it means
	// the sink never retries and never over-allocates.
	want := cx.Count(pattern)
	found, st := drain(want, func(buf []C.size_t) (int, int32) {
		var written C.size_t
		st := C.go_codex_locate(cx.ptr, bytePtr(pattern), C.size_t(len(pattern)),
			head(buf), C.size_t(len(buf)), &written, &fault)
		return int(written), int32(st)
	})
	runtime.KeepAlive(pattern)
	if st == C.IRGX_STALE {
		return nil, false
	}
	if st < 0 {
		panic(newError(C.int32_t(st), &fault, "locate "+strconv.Quote(pattern)+" in a self-index"))
	}
	out := make([]int, len(found))
	for i, p := range found {
		out[i] = int(p)
	}
	return out, true
}

// Position is the text offset one row stands for.
//
// ok is false when the index holds no locate layer. There are Len()+1 rows - the
// sentinel suffix owns the last one - and a row outside that range panics, the
// way a slice index does.
func (cx *Codex) Position(row int) (at int, ok bool) {
	if row < 0 || row > cx.Len() {
		panic("irregex: Codex.Position: row " + strconv.Itoa(row) +
			" is outside an index of " + strconv.Itoa(cx.Len()+1) + " rows")
	}
	var (
		out   C.size_t
		fault C.irgx_fault
	)
	st := C.go_codex_position(cx.ptr, C.size_t(row), &out, &fault)
	if st == C.IRGX_STALE {
		return 0, false
	}
	if st < 0 {
		panic(newError(st, &fault, "read the position of row "+strconv.Itoa(row)))
	}
	return int(out), true
}

// Whole is the row interval of the empty pattern: every row. Where an incremental
// backward search starts.
func (cx *Codex) Whole() Rows {
	var (
		raw   C.irgx_codex_rows
		fault C.irgx_fault
	)
	if st := C.go_codex_rows_whole(cx.ptr, &raw, &fault); st < 0 {
		panic(newError(st, &fault, "read the whole row interval of a self-index"))
	}
	return Rows{Lo: int(raw.lo), Hi: int(raw.hi)}
}

// Extend narrows a row interval by one byte, extending the pattern LEFTWARD -
// one backward-search step, so you can drive your own search.
//
// Two rank queries: the cost is the length of the pattern, not the length of the
// text. live is false the moment the interval empties, and an empty interval
// stays empty under every further step, so a caller may stop at the first false
// without checking again.
//
//	rows, live := cx.Whole(), true
//	for i := len(pat) - 1; i >= 0 && live; i-- {
//		rows, live = cx.Extend(rows, pat[i])
//	}
//	// live == (rows.Width() > 0), and Width is the occurrence count
func (cx *Codex) Extend(rows Rows, b byte) (narrowed Rows, live bool) {
	raw := C.irgx_codex_rows{lo: C.size_t(rows.Lo), hi: C.size_t(rows.Hi)}
	var fault C.irgx_fault
	st := C.go_codex_rows_extend(cx.ptr, &raw, C.uint8_t(b), &fault)
	if st < 0 {
		panic(newError(st, &fault, "extend the row interval ["+strconv.Itoa(rows.Lo)+
			","+strconv.Itoa(rows.Hi)+") of a self-index"))
	}
	return Rows{Lo: int(raw.lo), Hi: int(raw.hi)}, st == C.IRGX_MATCH
}

// Extract reconstructs at most n bytes of the text from offset at - the index
// decoding bytes it never stored.
//
// It returns fewer than n only at the end of the text. at == Len() is legal and
// yields nothing; an at past the end panics, because that is caller arithmetic
// rather than a short text.
func (cx *Codex) Extract(at, n int) []byte {
	total := cx.Len()
	if at < 0 || at > total {
		panic("irregex: Codex.Extract: offset " + strconv.Itoa(at) +
			" is outside a text of length " + strconv.Itoa(total))
	}
	want := min(max(n, 0), total-at)
	if want == 0 {
		return nil
	}
	buf := make([]byte, want)
	var (
		written C.size_t
		fault   C.irgx_fault
	)
	st := C.go_codex_extract(cx.ptr, C.size_t(at), (*C.uint8_t)(&buf[0]),
		C.size_t(want), &written, &fault)
	if st < 0 {
		panic(newError(st, &fault, "extract "+strconv.Itoa(want)+" bytes at "+strconv.Itoa(at)))
	}
	// *written is how many bytes REMAIN from at, not how many were decoded, so
	// it is a ceiling to clamp against rather than a length to trust.
	return buf[:min(want, int(written))]
}

// Text reconstructs the whole text. The index IS the text - this is the proof,
// and the reason a host may delete the original.
func (cx *Codex) Text() []byte { return cx.Extract(0, cx.Len()) }

// Save serializes the index, for [LoadCodex] to rebuild later.
func (cx *Codex) Save() []byte {
	var fault C.irgx_fault
	// A count-only probe first: *written is the size the image NEEDS, so one
	// sizing crossing buys an allocation that is exact instead of a guess that
	// doubles.
	image, st := drain(0, func(buf []byte) (int, int32) {
		var written C.size_t
		st := C.go_codex_save(cx.ptr, (*C.uint8_t)(head(buf)), C.size_t(len(buf)),
			&written, &fault)
		return int(written), int32(st)
	})
	if st < 0 {
		panic(newError(C.int32_t(st), &fault, "serialize a self-index"))
	}
	return image
}
