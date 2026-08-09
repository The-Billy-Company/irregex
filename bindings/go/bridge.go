//go:build cgo

package irgx

// The C seam. Everything that touches the engine lives here, so the rest of the
// package is ordinary Go.
//
// Each engine call is wrapped in a tiny C function that also captures the fault
// detail. That is not decoration: irgx_last_fault reports the last failure on
// THIS THREAD, and a goroutine is pinned to its thread only for the duration of
// a cgo call. Reading the fault in a second call could land on a different
// thread and find nothing, or find somebody else's failure. One call, one
// thread, one answer.

/*
#cgo CFLAGS: -I${SRCDIR}
#include "irgx.h"

static void capture(int32_t st, irgx_fault *f) {
  f->struct_size = (uint32_t)sizeof(*f);
  f->name = NULL;
  f->path = NULL;
  f->at_space = IRGX_AT_NONE;
  // A negative status does not imply a detail exists; name stays NULL then.
  // IRGX_STALE is not asked at all: a declinature installs no fault, so the
  // slot would answer with an older call's detail on this thread.
  if (st < 0 && st != IRGX_STALE && irgx_last_fault(f) != IRGX_MATCH) f->name = NULL;
}

static int32_t go_compile(const uint8_t *pat, size_t len, uint32_t flags,
                          irgx_regex **out, irgx_fault *f) {
  int32_t st = irgx_compile(pat, len, flags, out);
  capture(st, f);
  return st;
}

static int32_t go_is_match(irgx_regex *re, const uint8_t *text, size_t len,
                           irgx_fault *f) {
  int32_t st = irgx_is_match(re, text, len);
  capture(st, f);
  return st;
}

static int32_t go_find_all(irgx_regex *re, const uint8_t *text, size_t len,
                           irgx_span *out, size_t cap, size_t *written,
                           irgx_fault *f) {
  int32_t st = irgx_find_all(re, text, len, out, cap, written);
  capture(st, f);
  return st;
}

static int32_t go_captures(irgx_regex *re, const uint8_t *text, size_t len,
                           size_t from, irgx_span *out, size_t cap,
                           size_t *written, irgx_fault *f) {
  int32_t st = irgx_captures(re, text, len, from, out, cap, written);
  capture(st, f);
  return st;
}

static int32_t go_group_count(irgx_regex *re, uint32_t *out,
                              irgx_fault *f) {
  int32_t st = irgx_group_count(re, out);
  capture(st, f);
  return st;
}

static int32_t go_group_name(irgx_regex *re, uint32_t index,
                             irgx_text *out, irgx_fault *f) {
  int32_t st = irgx_group_name(re, index, out);
  capture(st, f);
  return st;
}

static int32_t go_slate_compile(const irgx_slate_pattern *pats, size_t count,
                                size_t *refused, irgx_slate **out,
                                irgx_fault *f) {
  int32_t st = irgx_slate_compile(pats, count, refused, out);
  capture(st, f);
  return st;
}

static int32_t go_slate_is_match(irgx_slate *s, const uint8_t *text, size_t len,
                                 irgx_fault *f) {
  int32_t st = irgx_slate_is_match(s, text, len);
  capture(st, f);
  return st;
}

static int32_t go_slate_which(irgx_slate *s, const uint8_t *text, size_t len,
                              uint32_t *out, size_t cap, size_t *written,
                              irgx_fault *f) {
  int32_t st = irgx_slate_which(s, text, len, out, cap, written);
  capture(st, f);
  return st;
}

static int32_t go_is_match_in(irgx_regex *re, const uint8_t *text, size_t len,
                              size_t from, size_t to, irgx_fault *f) {
  int32_t st = irgx_is_match_in(re, text, len, from, to);
  capture(st, f);
  return st;
}

static int32_t go_find_all_in(irgx_regex *re, const uint8_t *text, size_t len,
                              size_t from, size_t to, irgx_span *out,
                              size_t cap, size_t *written, irgx_fault *f) {
  int32_t st = irgx_find_all_in(re, text, len, from, to, out, cap, written);
  capture(st, f);
  return st;
}

static int32_t go_munch_compile(const irgx_munch_pattern *pats, size_t count,
                                uint32_t flags, irgx_munch **out,
                                irgx_fault *f) {
  int32_t st = irgx_munch_compile(pats, count, flags, out);
  capture(st, f);
  return st;
}

static int32_t go_munch_declined(const irgx_munch *m, irgx_munch_refusal *out,
                                 size_t cap, size_t *written, irgx_fault *f) {
  int32_t st = irgx_munch_declined(m, out, cap, written);
  capture(st, f);
  return st;
}

static int32_t go_munch_scan(irgx_munch *m, const uint8_t *text, size_t len,
                             size_t at, const uint32_t *allow, size_t nallow,
                             uint32_t pick, irgx_munch_token *tok,
                             uint32_t *out, size_t cap, irgx_fault *f) {
  int32_t st = irgx_munch_scan(m, text, len, at, allow, nallow, pick, tok, out, cap);
  capture(st, f);
  return st;
}
*/
import "C"

import (
	"fmt"
	"runtime"
	"strconv"
	"unicode/utf8"
	"unsafe"
)

// The pattern-semantics bits, taken from the header rather than mirrored in Go,
// so the option surface cannot drift from the ABI it compiles down to. Bits 3,
// 4 and 7 are absent on purpose: the sibling search library claims them, and one
// numbering across the family is the point.
const (
	flagFixed      = C.IRGX_FIXED
	flagIgnoreCase = C.IRGX_IGNORE_CASE
	flagWord       = C.IRGX_WORD
	flagSmartCase  = C.IRGX_SMART_CASE
	flagNoUnicode  = C.IRGX_NO_UNICODE
	flagPCRE       = C.IRGX_PCRE
	flagMultiLine  = C.IRGX_MULTILINE
	flagDotAll     = C.IRGX_DOTALL
)

// Which string irgx_fault.at is an offset into. Taken from the header for
// the same reason the flags are: the seam states the ruler now, where it used
// to be inferable from a NULL path, and re-deriving a three-clause conjunction
// here is how a caret ends up under the wrong string.
//
// atFile is unreachable from this plane and is declared anyway, because the set
// is what makes atPattern a choice rather than a boolean: there is no corpus
// behind libirgx - no session, no walk, nothing that opens a file - so every
// offset it can produce is a position in the pattern it was handed.
const (
	atNone    = C.IRGX_AT_NONE
	atFile    = C.IRGX_AT_FILE
	atPattern = C.IRGX_AT_PATTERN
)

// abiVersion is the only C-ABI version this binding speaks. The header promises
// it bumps on any breaking change, which is the whole reason to refuse another.
const abiVersion = 2

// abiMismatch is non-nil when the linked library reports a different ABI. That
// can only happen through the irgx_syslib escape hatch, where the caller
// supplied the library; the vendored archives are built against this header.
var abiMismatch error

func init() {
	if found := uint32(C.irgx_abi_version()); found != abiVersion {
		abiMismatch = fmt.Errorf(
			"irregex: ABI mismatch: this binding speaks ABI %d, the linked library reports %d",
			abiVersion, found)
	}
}

// Version reports the engine's semantic version, for example "1.0.0".
func Version() string { return C.GoString(C.irgx_version()) }

// PCRE2Version reports the vendored PCRE2 the [CompileOpts.PCRE] arm runs on.
// "Which regex grammar do I have" is two numbers; this is the second.
func PCRE2Version() string { return C.GoString(C.irgx_pcre2_version()) }

// ABIVersion reports the C-ABI version of the linked library.
func ABIVersion() uint32 { return uint32(C.irgx_abi_version()) }

// Error is a pattern the engine refused, or a call it could not complete.
type Error struct {
	// Op is what was attempted, for example `compile "a("`.
	Op string
	// Status is the IRGX_* code the call crossed the seam as, always
	// negative; a non-negative status is a result, not an error.
	Status int32
	// Reason is the library's own sentence for Status.
	Reason string
	// Fault is the per-incident detail the engine left behind, empty when it
	// had nothing to add. An argument guard, for instance, says nothing its
	// status does not already say.
	Fault string
	// At is the byte offset the fault is about, or -1. For a compile fault that
	// is an offset into the pattern.
	At int64
}

func (e *Error) Error() string {
	msg := "irregex: " + e.Op + ": " + e.Reason
	if e.Fault != "" {
		msg += " (" + e.Fault + ")"
	}
	if e.At >= 0 {
		msg += " at byte " + strconv.FormatInt(e.At, 10)
	}
	return msg
}

// newError turns a status and the fault captured alongside it into a Go error.
// irgx_status_message is a pure reader by contract, so asking it here cannot
// cost us the detail.
func newError(status C.int32_t, fault *C.irgx_fault, op string) *Error {
	err := &Error{
		Op:     op,
		Status: int32(status),
		Reason: C.GoString(C.irgx_status_message(status)),
		At:     -1,
	}
	if fault.name != nil {
		err.Fault = C.GoString(fault.name)
		// path is borrowed and only stays valid until this thread's next work
		// call, so it is copied out now or not at all. It is also not
		// NUL-terminated, hence the explicit length.
		if fault.path != nil {
			err.Fault += ": " + C.GoStringN((*C.char)(unsafe.Pointer(fault.path)), C.int(fault.path_len))
		}
		if fault.at_space != atNone {
			err.At = int64(fault.at)
		}
	}
	return err
}

// compileError says which of the two refusals this is, from the status code
// alone. The ABI reports them as different codes precisely so a caller never
// has to recognize a fault name, and nothing here does.
func compileError(status C.int32_t, fault *C.irgx_fault, expr string) error {
	// IRGX_STALE is the seam declining rather than failing: *out was never
	// written, so there is no handle to read or free, and there is no fault to
	// consult either.
	if status == C.IRGX_STALE {
		return fmt.Errorf("irregex: compile %s: %w", strconv.Quote(expr), ErrNeedsPCRE)
	}
	err := newError(status, fault, "compile "+strconv.Quote(expr))
	// SyntaxError.At is a position in Expr, so only an offset the engine
	// measured in the pattern may fill it. The same status carrying no position
	// is a cap or a limit rather than a defect in the text, and stays a plain
	// [Error].
	if status == C.IRGX_INVALID && fault.name != nil && fault.at_space == atPattern {
		return &SyntaxError{Expr: expr, At: int(err.At), Reason: err.Fault, err: err}
	}
	return err
}

// handle is one irgx_regex, which the header declares single-threaded: it
// owns the scratch its finds run in, so two goroutines sharing one would corrupt
// a match rather than race a counter. Ownership of that rule lives one layer up,
// in [Regexp], which keeps a pool of these and lends one out per call.
type handle struct{ ptr *C.irgx_regex }

func compileHandle(expr string, flags uint32) (*handle, error) {
	var (
		ptr   *C.irgx_regex
		fault C.irgx_fault
	)
	st := C.go_compile(bytePtr(expr), C.size_t(len(expr)), C.uint32_t(flags), &ptr, &fault)
	runtime.KeepAlive(expr)
	if st != C.IRGX_OK {
		return nil, compileError(st, &fault, expr)
	}
	h := &handle{ptr: ptr}
	// The finalizer is what frees a handle the pool dropped: sync.Pool empties
	// itself on a GC cycle, so without this every burst of concurrency would
	// leak the handles it grew to serve.
	runtime.SetFinalizer(h, (*handle).release)
	return h, nil
}

func (h *handle) release() {
	if h.ptr != nil {
		C.irgx_free(h.ptr)
		h.ptr = nil
	}
}

// bytePtr borrows the bytes behind s. Nothing in the C ABI retains a pointer it
// is handed: irgx_compile copies the pattern, and every search verb reads the
// text and returns.
//
// A zero-length Go string carries no promise of a non-nil data pointer, and it
// does not need one: every verb here reads NULL with length zero as the empty
// pattern or the empty text.
func bytePtr(s string) *C.uint8_t {
	return (*C.uint8_t)(unsafe.Pointer(unsafe.StringData(s)))
}

// borrow views b as a string without copying, so the search core is written once
// for both halves of the API. The view reaches the engine and is thrown away; no
// result is ever sliced out of it, because that would alias the caller's mutable
// buffer through an immutable string.
func borrow(b []byte) string {
	if len(b) == 0 {
		return ""
	}
	return unsafe.String(unsafe.SliceData(b), len(b))
}

// isMatch answers "is there a match" without materializing a span. It is the
// same walk findSpans runs, stopped at the first hit, so MatchString and
// FindStringIndex cannot disagree about the same text.
func (re *Regexp) isMatch(text string) bool {
	h := re.acquire()
	defer re.release(h)
	return re.matchOn(h, text)
}

// matchOn is isMatch on a handle the caller already holds, which is how Compile
// can settle nullability before the handle ever reaches the pool.
func (re *Regexp) matchOn(h *handle, text string) bool {
	var fault C.irgx_fault
	st := C.go_is_match(h.ptr, bytePtr(text), C.size_t(len(text)), &fault)
	runtime.KeepAlive(text)
	if st < 0 {
		panic(newError(st, &fault, "search with "+strconv.Quote(re.expr)))
	}
	return st == C.IRGX_MATCH
}

// firstWindow is how many spans the first irgx_find_all asks for. The header
// advises sizing the window at len+1, the most matches a text can hold; doing
// that unconditionally would allocate a 16 MB span buffer for a 1 MB text that
// probably has four matches.
const firstWindow = 4096

// findSpans is the authoritative match sequence for text, capped at limit when
// limit is positive and unbounded when it is negative.
//
// Every verb in this package routes through here rather than advancing a cursor
// over irgx_captures, because the engine owns where the matches ARE, and a
// find(from) loop written up here would re-derive that badly.
//
// What the engine does NOT own is which of them this package reports. The ABI
// hands back the complete byte-granular sequence - every empty match at every
// byte offset - and each language's regexp package then thins it to its own
// convention. Go's, from regexp.allMatches, is two rules: an empty match
// abutting the previous match is ignored, and after an empty match the scan
// resumes one RUNE on rather than one byte. Both are applied by goSequence.
//
// The window is a view over the answer, never a bound on the search: find_all
// reports how many matches the TEXT HAS rather than how many fit, so one short
// pass measures the retry it needs and there is at most one of them. The first
// window is a guess at how many spans will be wanted; the second is the count
// the engine gave, so it cannot come up short again.
//
// A nullable pattern is the only one whose sequence goSequence can change, so
// only it pays for the whole answer up front. Everything else - which is nearly
// everything - keeps the limited fetch, because the limit cannot then interact
// with a filter that will never drop a span.
func (re *Regexp) findSpans(h *handle, text string, limit int) [][2]int {
	if limit == 0 {
		return nil
	}
	if re.nullable {
		return truncate(goSequence(re.rawSpans(h, text, -1), text), limit)
	}
	return re.rawSpans(h, text, limit)
}

// rawSpans is the engine's own sequence, unthinned.
func (re *Regexp) rawSpans(h *handle, text string, limit int) [][2]int {
	buf := make([]C.irgx_span, window(firstWindow, len(text)+1, limit))
	want := window(re.fillSpans(h, text, buf), len(text)+1, limit)
	if want > len(buf) {
		buf = make([]C.irgx_span, want)
		if total := re.fillSpans(h, text, buf); total < want {
			want = total
		}
	}
	out := make([][2]int, want)
	for i := range out {
		out[i] = [2]int{int(buf[i].start), int(buf[i].end)}
	}
	return out
}

// fillSpans runs one find_all into buf and returns how many matches the text
// holds, which is not how many were written whenever buf is the shorter of the
// two. Nothing may be read past len(buf); everything beyond it is a count.
func (re *Regexp) fillSpans(h *handle, text string, buf []C.irgx_span) int {
	var (
		written C.size_t
		fault   C.irgx_fault
	)
	st := C.go_find_all(h.ptr, bytePtr(text), C.size_t(len(text)),
		&buf[0], C.size_t(len(buf)), &written, &fault)
	runtime.KeepAlive(text)
	if st < 0 {
		panic(newError(st, &fault, "search with "+strconv.Quote(re.expr)))
	}
	return int(written)
}

// goSequence thins the engine's byte-granular answer to the one stdlib regexp
// would have produced, so that swapping this package in does not change which
// matches a nullable pattern reports.
//
// Both rules come from regexp.allMatches and only ever REMOVE spans:
//
//   - an empty match starting exactly where the previous match ended is
//     ignored, and "previous" counts a match that was itself ignored - which is
//     why prevEnd is updated on both paths;
//   - after an empty match the scan resumes one rune on, so an empty match
//     inside a multi-byte rune is never reached. `l*` over "héllo" reports no
//     empty match at byte 2, the continuation byte of the é.
//
// Removal-only is what makes this safe to apply after the fact: the positions
// stdlib would visit are a subset of the ones the engine already searched, and
// at any shared position both find the same leftmost match.
func goSequence(spans [][2]int, text string) [][2]int {
	out := spans[:0:0]
	prevEnd, resume := -1, 0
	for _, sp := range spans {
		if sp[0] < resume {
			continue // inside a rune the stdlib scan stepped over
		}
		empty := sp[0] == sp[1]
		if empty {
			resume = sp[0] + runeWidth(text, sp[0])
		} else {
			resume = sp[1]
		}
		if !empty || sp[0] != prevEnd {
			out = append(out, sp)
		}
		prevEnd = sp[1]
	}
	return out
}

// runeWidth is how far stdlib's scan advances past an empty match at i: the
// width of the rune starting there, and at least one byte so that invalid UTF-8
// cannot stall the walk.
func runeWidth(text string, i int) int {
	if i >= len(text) {
		return 1
	}
	_, w := utf8.DecodeRuneInString(text[i:])
	if w < 1 {
		return 1
	}
	return w
}

// truncate applies the caller's limit after the sequence is settled. It has to
// be after: thinning first and cutting second is the only order that can still
// return n matches when the thinning dropped one.
func truncate(spans [][2]int, limit int) [][2]int {
	if limit > 0 && len(spans) > limit {
		return spans[:limit]
	}
	return spans
}

// window is how many spans it is worth holding: never more than the text can
// hold, and never more than the caller asked to see.
func window(want, ceiling, limit int) int {
	if want > ceiling {
		want = ceiling
	}
	if limit > 0 && want > limit {
		want = limit
	}
	return want
}

// findGroups fills in the group detail for a match findSpans already blessed.
// The result holds 2*(NumSubexp()+1) offsets, with -1, -1 for a group the match
// did not enter.
//
// irgx_captures reports how many spans the PATTERN has rather than how many
// it wrote, so a window that came up short sizes its own retry without a second
// question.
func (re *Regexp) findGroups(h *handle, text string, start, end int) []int {
	if re.ngroup == 0 {
		return []int{start, end}
	}
	buf := make([]C.irgx_span, re.ngroup+1)
	var (
		written C.size_t
		fault   C.irgx_fault
	)
	for {
		st := C.go_captures(h.ptr, bytePtr(text), C.size_t(len(text)), C.size_t(start),
			&buf[0], C.size_t(len(buf)), &written, &fault)
		runtime.KeepAlive(text)
		if st < 0 {
			panic(newError(st, &fault, "read capture groups for "+strconv.Quote(re.expr)))
		}
		if st != C.IRGX_MATCH {
			// findSpans already reported a match here, so captures finding none
			// means the two arms disagree. Refusing beats inventing groups.
			panic(fmt.Errorf("irregex: engine disagreement: find_all reported a match at byte %d for %s, "+
				"captures found none", start, strconv.Quote(re.expr)))
		}
		if int(written) <= len(buf) {
			break
		}
		buf = make([]C.irgx_span, int(written))
	}
	// One span per group plus the whole match, by the header's contract. Reading
	// past what was written would be reading uninitialized C memory, so a short
	// answer is refused here rather than turned into garbage offsets.
	if int(written) != len(buf) {
		panic(fmt.Errorf("irregex: engine disagreement: captures wrote %d spans for %s, "+
			"which has %d groups", int(written), strconv.Quote(re.expr), re.ngroup))
	}
	if int(buf[0].start) != start || int(buf[0].end) != end {
		panic(fmt.Errorf("irregex: engine disagreement: find_all reported [%d,%d) for %s, "+
			"captures reported [%d,%d) from the same offset",
			start, end, strconv.Quote(re.expr), int(buf[0].start), int(buf[0].end)))
	}
	out := make([]int, 2*len(buf))
	for i, span := range buf {
		out[2*i], out[2*i+1] = int(span.start), int(span.end)
	}
	return out
}

// resolve fills in the group count and the named-group table.
//
// The table is walked out of the engine, group number by group number, because
// the numbering is what [Regexp.SubexpNames] is indexed by and only the engine
// knows it. Reading the names off the pattern source instead means re-deriving
// the grammar: `\(` is not a group, `(?:` is one that takes no number, and a
// spelling the scan has not been taught - `(?'name'x)`, which PCRE2 accepts -
// is a name silently missing from the table.
func (re *Regexp) resolve(h *handle) error {
	var (
		count C.uint32_t
		fault C.irgx_fault
	)
	if st := C.go_group_count(h.ptr, &count, &fault); st < 0 {
		return newError(st, &fault, "count capture groups in "+strconv.Quote(re.expr))
	}
	re.ngroup = int(count)
	re.names = make([]string, re.ngroup+1)
	if re.ngroup == 0 {
		return nil
	}
	re.index = make(map[string]int, re.ngroup)
	// From 1: group 0 is the whole match, which is never named, and names[0]
	// stays empty for it the way stdlib regexp leaves it.
	for number := 1; number <= re.ngroup; number++ {
		var name C.irgx_text
		st := C.go_group_name(h.ptr, C.uint32_t(number), &name, &fault)
		if st < 0 {
			return newError(st, &fault, "name group "+strconv.Itoa(number)+" of "+strconv.Quote(re.expr))
		}
		if st != C.IRGX_MATCH {
			continue // a plain (...), which has no name rather than an empty one
		}
		// The bytes are the engine's own name storage and die with the handle,
		// so they are copied here; a Go string holding a C pointer would be a
		// use-after-free the moment the pool drops this handle.
		spelling := C.GoStringN((*C.char)(unsafe.Pointer(name.ptr)), C.int(name.len))
		re.names[number] = spelling
		// First wins, as stdlib regexp's SubexpIndex documents, for a grammar
		// that lets two groups share a name.
		if _, taken := re.index[spelling]; !taken {
			re.index[spelling] = number
		}
	}
	return nil
}

// slate is one irgx_slate: N compiled patterns and the scratch their scans run
// in. Single-threaded for the same reason a [handle] is, and pooled the same way
// one layer up, in [Set].
type slate struct{ ptr *C.irgx_slate }

// compileSlate compiles every expression as one slate under one flag word.
//
// A refusal names the pattern that caused it: the ABI writes the offending index
// into refused, and the thread's fault slot carries the reason, so the error a
// caller sees is the same [SyntaxError] or [ErrNeedsPCRE] a single Compile would
// have produced, tagged with where in the list it came from.
func compileSlate(exprs []string, flags uint32) (*slate, error) {
	var pin runtime.Pinner
	defer pin.Unpin()
	pats := make([]C.irgx_slate_pattern, len(exprs))
	for i, expr := range exprs {
		body := bytePtr(expr)
		// Each pattern's bytes are a Go pointer stored in Go memory that C is
		// about to read, which the cgo pointer rules forbid unless the target is
		// pinned. Pinning rather than copying into C memory: the ABI copies the
		// bytes itself during the compile, so they need to survive exactly this
		// call.
		if len(expr) != 0 {
			pin.Pin(body)
		}
		pats[i] = C.irgx_slate_pattern{
			pattern: body,
			len:     C.size_t(len(expr)),
			flags:   C.uint32_t(flags),
		}
	}
	var (
		ptr     *C.irgx_slate
		refused C.size_t
		fault   C.irgx_fault
	)
	// A slate of no patterns is a legitimate slate that matches nothing, but
	// &pats[0] is not addressable then.
	var list *C.irgx_slate_pattern
	if len(pats) != 0 {
		list = &pats[0]
	}
	st := C.go_slate_compile(list, C.size_t(len(pats)), &refused, &ptr, &fault)
	runtime.KeepAlive(exprs)
	if st != C.IRGX_OK {
		at := int(refused)
		if at >= len(exprs) {
			// No index was written: the refusal is about the call rather than
			// about any one pattern, an argument guard for instance.
			return nil, newError(st, &fault, "compile a set of "+strconv.Itoa(len(exprs))+" patterns")
		}
		return nil, &SetError{Index: at, Expr: exprs[at], Err: compileError(st, &fault, exprs[at])}
	}
	s := &slate{ptr: ptr}
	runtime.SetFinalizer(s, (*slate).release)
	return s, nil
}

func (s *slate) release() {
	if s.ptr != nil {
		C.irgx_slate_free(s.ptr)
		s.ptr = nil
	}
}

// anyMatch is the cheap question: does any pattern in the slate match text.
func (s *slate) anyMatch(text string) bool {
	var fault C.irgx_fault
	st := C.go_slate_is_match(s.ptr, bytePtr(text), C.size_t(len(text)), &fault)
	runtime.KeepAlive(text)
	if st < 0 {
		panic(newError(st, &fault, "match a set"))
	}
	return st == C.IRGX_MATCH
}

// which is the attribution: the index of every pattern matching text, ascending.
//
// The buffer is sized at the slate's length, which is the exact ceiling on the
// answer, so unlike a span walk this can never come up short and never needs a
// second pass.
func (s *slate) which(text string, count int) []int {
	if count == 0 {
		return nil
	}
	ids := make([]C.uint32_t, count)
	var (
		written C.size_t
		fault   C.irgx_fault
	)
	st := C.go_slate_which(s.ptr, bytePtr(text), C.size_t(len(text)),
		&ids[0], C.size_t(count), &written, &fault)
	runtime.KeepAlive(text)
	if st < 0 {
		panic(newError(st, &fault, "match a set"))
	}
	if written == 0 {
		return nil
	}
	out := make([]int, written)
	for i := range out {
		out[i] = int(ids[i])
	}
	return out
}

// windows reports whether this pattern's engine can honor a live `to` bound.
//
// A property of the pattern rather than of the call, because it is really a
// property of the arm that compiled it: the linear engine treats the bound as a
// ceiling on its walk, and PCRE2 structurally cannot, since its subject has one
// length and stopping there would move every anchor.
func (re *Regexp) windows() bool {
	h := re.acquire()
	defer re.release(h)
	return C.irgx_pattern_windows(h.ptr) == 1
}

// matchIn is [Regexp.matchOn] with a ceiling: is there a match of this pattern
// lying entirely inside text[from:to].
func (re *Regexp) matchIn(text string, from, to int) bool {
	h := re.acquire()
	defer re.release(h)
	var fault C.irgx_fault
	st := C.go_is_match_in(h.ptr, bytePtr(text), C.size_t(len(text)),
		C.size_t(from), C.size_t(to), &fault)
	runtime.KeepAlive(text)
	if st < 0 {
		panic(newError(st, &fault, "search with "+strconv.Quote(re.expr)))
	}
	return st == C.IRGX_MATCH
}

// spansIn is [Regexp.rawSpans] confined to text[from:to], thinned by the same
// Go convention so a windowed walk and an unwindowed one report the same
// sequence over the region they agree about.
func (re *Regexp) spansIn(text string, from, to, limit int) [][2]int {
	if limit == 0 {
		return nil
	}
	h := re.acquire()
	defer re.release(h)
	// A nullable pattern's sequence can be changed by the thinning, so it pays
	// for the whole answer before the limit applies - findSpans's reasoning,
	// which holds here for the same reason.
	want := limit
	if re.nullable {
		want = -1
	}
	spans := re.fillSpansIn(h, text, from, to, want)
	if re.nullable {
		return truncate(goSequence(spans, text), limit)
	}
	return spans
}

// fillSpansIn runs the windowed find_all, growing once if the first window came
// up short. Sized as rawSpans sizes it: find_all_in reports how many matches the
// REGION holds rather than how many fit, so one short pass measures its retry.
func (re *Regexp) fillSpansIn(h *handle, text string, from, to, limit int) [][2]int {
	buf := make([]C.irgx_span, window(firstWindow, to-from+1, limit))
	if len(buf) == 0 {
		// A zero-width window still has the one position in it to ask about,
		// and &buf[0] is not addressable when the slice is empty.
		buf = make([]C.irgx_span, 1)
	}
	total := re.oneFindIn(h, text, from, to, buf)
	want := window(total, to-from+1, limit)
	if want > len(buf) {
		buf = make([]C.irgx_span, want)
		if again := re.oneFindIn(h, text, from, to, buf); again < want {
			want = again
		}
	}
	out := make([][2]int, want)
	for i := range out {
		out[i] = [2]int{int(buf[i].start), int(buf[i].end)}
	}
	return out
}

// oneFindIn is a single windowed find_all, returning how many matches the region
// holds. Nothing may be read past len(buf); everything beyond it is a count.
func (re *Regexp) oneFindIn(h *handle, text string, from, to int, buf []C.irgx_span) int {
	var (
		written C.size_t
		fault   C.irgx_fault
	)
	st := C.go_find_all_in(h.ptr, bytePtr(text), C.size_t(len(text)),
		C.size_t(from), C.size_t(to), &buf[0], C.size_t(len(buf)), &written, &fault)
	runtime.KeepAlive(text)
	if st < 0 {
		panic(newError(st, &fault, "search with "+strconv.Quote(re.expr)))
	}
	return int(written)
}

// lexer is one irgx_munch: the anchored automata and the permission set each
// scan rewrites. Single-threaded for the same reason a [slate] is, and pooled the
// same way one layer up, in [Munch].
type lexer struct{ ptr *C.irgx_munch }

// compileLexer determinizes every terminal as one anchored slate.
//
// Partial refusal is success here, unlike [compileSlate]: a slate of a hundred
// and fifty terminals where one is outside the linear grammar is a working
// lexer, and the refusals are read back with declined. Only a slate where
// NOTHING could be seated is an error, and it declines rather than failing -
// there is no handle to read reasons from in that case.
func compileLexer(exprs []string, flags uint32) (*lexer, error) {
	var pin runtime.Pinner
	defer pin.Unpin()
	pats := make([]C.irgx_munch_pattern, len(exprs))
	for i, expr := range exprs {
		body := bytePtr(expr)
		// Pinned rather than copied into C memory, as compileSlate does it and
		// for the same reason: the ABI copies the bytes during the compile, so
		// they need to survive exactly this call.
		if len(expr) != 0 {
			pin.Pin(body)
		}
		pats[i] = C.irgx_munch_pattern{pattern: body, len: C.size_t(len(expr))}
	}
	var (
		ptr   *C.irgx_munch
		fault C.irgx_fault
	)
	// A munch of no terminals is a legitimate one that matches nothing, but
	// &pats[0] is not addressable then.
	var list *C.irgx_munch_pattern
	if len(pats) != 0 {
		list = &pats[0]
	}
	st := C.go_munch_compile(list, C.size_t(len(pats)), C.uint32_t(flags), &ptr, &fault)
	runtime.KeepAlive(exprs)
	if st == C.IRGX_STALE {
		return nil, fmt.Errorf("irregex: CompileMunch: not one of these %d terminals "+
			"could be determinized, so there is no lexer to build: %w", len(exprs), ErrNeedsPCRE)
	}
	if st != C.IRGX_OK {
		return nil, newError(st, &fault, "compile a munch of "+strconv.Itoa(len(exprs))+" terminals")
	}
	l := &lexer{ptr: ptr}
	runtime.SetFinalizer(l, (*lexer).release)
	return l, nil
}

func (l *lexer) release() {
	if l.ptr != nil {
		C.irgx_munch_free(l.ptr)
		l.ptr = nil
	}
}

// seated is how many terminals the slate actually took - the exact cap at which
// a scan's winner buffer can never come up short, since a declined terminal can
// never win and so can never be written.
func (l *lexer) seated() int { return int(C.irgx_munch_len(l.ptr)) }

// refusals is every terminal the slate could not take, ascending. The compile
// list is the exact cap: one refusal per pattern, so this never comes up short.
func (l *lexer) refusals(count int) []Refusal {
	if count == 0 {
		return nil
	}
	buf := make([]C.irgx_munch_refusal, count)
	var (
		written C.size_t
		fault   C.irgx_fault
	)
	st := C.go_munch_declined(l.ptr, &buf[0], C.size_t(count), &written, &fault)
	if st < 0 {
		panic(newError(st, &fault, "read a munch's refusals"))
	}
	if st != C.IRGX_MATCH || written == 0 {
		return nil
	}
	out := make([]Refusal, written)
	for i := range out {
		out[i] = Refusal{Pattern: int(buf[i].pattern), Why: Why(buf[i].why)}
	}
	return out
}

// scan is the token beginning at exactly at, among the permitted terminals.
// allow nil permits everything seated; pick selects the longest or the shortest
// non-empty reading.
func (l *lexer) scan(text string, at int, allow []int, pick uint32, cap int) (Token, bool) {
	ids := make([]C.uint32_t, cap)
	var (
		tok   C.irgx_munch_token
		fault C.irgx_fault
	)
	var permitted *C.uint32_t
	row := make([]C.uint32_t, len(allow))
	for i, id := range allow {
		row[i] = C.uint32_t(id)
	}
	if len(row) != 0 {
		permitted = &row[0]
	}
	var winners *C.uint32_t
	if cap != 0 {
		winners = &ids[0]
	}
	st := C.go_munch_scan(l.ptr, bytePtr(text), C.size_t(len(text)), C.size_t(at),
		permitted, C.size_t(len(row)), C.uint32_t(pick), &tok, winners, C.size_t(cap), &fault)
	runtime.KeepAlive(text)
	if st < 0 {
		panic(newError(st, &fault, "scan a munch"))
	}
	if st != C.IRGX_MATCH {
		return Token{}, false
	}
	out := make([]int, tok.count)
	for i := range out {
		out[i] = int(ids[i])
	}
	return Token{Length: int(tok.len), Patterns: out}, true
}
