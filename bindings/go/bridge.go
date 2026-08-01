//go:build cgo

package irregex

// The C seam. Everything that touches the engine lives here, so the rest of the
// package is ordinary Go.
//
// Each engine call is wrapped in a tiny C function that also captures the fault
// detail. That is not decoration: irregex_last_fault reports the last failure on
// THIS THREAD, and a goroutine is pinned to its thread only for the duration of
// a cgo call. Reading the fault in a second call could land on a different
// thread and find nothing, or find somebody else's failure. One call, one
// thread, one answer.

/*
#cgo CFLAGS: -I${SRCDIR}
#include "irregex.h"

static void capture(int32_t st, irregex_fault *f) {
  f->struct_size = (uint32_t)sizeof(*f);
  f->name = NULL;
  f->path = NULL;
  f->at_space = IRREGEX_AT_NONE;
  // A negative status does not imply a detail exists; name stays NULL then.
  // IRREGEX_STALE is not asked at all: a declinature installs no fault, so the
  // slot would answer with an older call's detail on this thread.
  if (st < 0 && st != IRREGEX_STALE && irregex_last_fault(f) != IRREGEX_MATCH) f->name = NULL;
}

static int32_t go_compile(const uint8_t *pat, size_t len, uint32_t flags,
                          irregex_regex **out, irregex_fault *f) {
  int32_t st = irregex_compile(pat, len, flags, out);
  capture(st, f);
  return st;
}

static int32_t go_is_match(irregex_regex *re, const uint8_t *text, size_t len,
                           irregex_fault *f) {
  int32_t st = irregex_is_match(re, text, len);
  capture(st, f);
  return st;
}

static int32_t go_find_all(irregex_regex *re, const uint8_t *text, size_t len,
                           irregex_span *out, size_t cap, size_t *written,
                           irregex_fault *f) {
  int32_t st = irregex_find_all(re, text, len, out, cap, written);
  capture(st, f);
  return st;
}

static int32_t go_captures(irregex_regex *re, const uint8_t *text, size_t len,
                           size_t from, irregex_span *out, size_t cap,
                           size_t *written, irregex_fault *f) {
  int32_t st = irregex_captures(re, text, len, from, out, cap, written);
  capture(st, f);
  return st;
}

static int32_t go_group_count(irregex_regex *re, uint32_t *out,
                              irregex_fault *f) {
  int32_t st = irregex_group_count(re, out);
  capture(st, f);
  return st;
}

static int32_t go_group_name(irregex_regex *re, uint32_t index,
                             irregex_text *out, irregex_fault *f) {
  int32_t st = irregex_group_name(re, index, out);
  capture(st, f);
  return st;
}
*/
import "C"

import (
	"fmt"
	"runtime"
	"strconv"
	"unsafe"
)

// The pattern-semantics bits, taken from the header rather than mirrored in Go,
// so the option surface cannot drift from the ABI it compiles down to. Bits 3,
// 4 and 7 are absent on purpose: the sibling search library claims them, and one
// numbering across the family is the point.
const (
	flagFixed      = C.IRREGEX_FIXED
	flagIgnoreCase = C.IRREGEX_IGNORE_CASE
	flagWord       = C.IRREGEX_WORD
	flagSmartCase  = C.IRREGEX_SMART_CASE
	flagNoUnicode  = C.IRREGEX_NO_UNICODE
	flagPCRE       = C.IRREGEX_PCRE
)

// Which string irregex_fault.at is an offset into. Taken from the header for
// the same reason the flags are: the seam states the ruler now, where it used
// to be inferable from a NULL path, and re-deriving a three-clause conjunction
// here is how a caret ends up under the wrong string.
//
// atFile is unreachable from this plane and is declared anyway, because the set
// is what makes atPattern a choice rather than a boolean: there is no corpus
// behind libirregex - no session, no walk, nothing that opens a file - so every
// offset it can produce is a position in the pattern it was handed.
const (
	atNone    = C.IRREGEX_AT_NONE
	atFile    = C.IRREGEX_AT_FILE
	atPattern = C.IRREGEX_AT_PATTERN
)

// abiVersion is the only C-ABI version this binding speaks. The header promises
// it bumps on any breaking change, which is the whole reason to refuse another.
const abiVersion = 2

// abiMismatch is non-nil when the linked library reports a different ABI. That
// can only happen through the irregex_syslib escape hatch, where the caller
// supplied the library; the vendored archives are built against this header.
var abiMismatch error

func init() {
	if found := uint32(C.irregex_abi_version()); found != abiVersion {
		abiMismatch = fmt.Errorf(
			"irregex: ABI mismatch: this binding speaks ABI %d, the linked library reports %d",
			abiVersion, found)
	}
}

// Version reports the engine's semantic version, for example "0.3.0".
func Version() string { return C.GoString(C.irregex_version()) }

// PCRE2Version reports the vendored PCRE2 the [CompileOpts.PCRE] arm runs on.
// "Which regex grammar do I have" is two numbers; this is the second.
func PCRE2Version() string { return C.GoString(C.irregex_pcre2_version()) }

// ABIVersion reports the C-ABI version of the linked library.
func ABIVersion() uint32 { return uint32(C.irregex_abi_version()) }

// Error is a pattern the engine refused, or a call it could not complete.
type Error struct {
	// Op is what was attempted, for example `compile "a("`.
	Op string
	// Status is the IRREGEX_* code the call crossed the seam as, always
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
// irregex_status_message is a pure reader by contract, so asking it here cannot
// cost us the detail.
func newError(status C.int32_t, fault *C.irregex_fault, op string) *Error {
	err := &Error{
		Op:     op,
		Status: int32(status),
		Reason: C.GoString(C.irregex_status_message(status)),
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
func compileError(status C.int32_t, fault *C.irregex_fault, expr string) error {
	// IRREGEX_STALE is the seam declining rather than failing: *out was never
	// written, so there is no handle to read or free, and there is no fault to
	// consult either.
	if status == C.IRREGEX_STALE {
		return fmt.Errorf("irregex: compile %s: %w", strconv.Quote(expr), ErrNeedsPCRE)
	}
	err := newError(status, fault, "compile "+strconv.Quote(expr))
	// SyntaxError.At is a position in Expr, so only an offset the engine
	// measured in the pattern may fill it. The same status carrying no position
	// is a cap or a limit rather than a defect in the text, and stays a plain
	// [Error].
	if status == C.IRREGEX_INVALID && fault.name != nil && fault.at_space == atPattern {
		return &SyntaxError{Expr: expr, At: int(err.At), Reason: err.Fault, err: err}
	}
	return err
}

// handle is one irregex_regex, which the header declares single-threaded: it
// owns the scratch its finds run in, so two goroutines sharing one would corrupt
// a match rather than race a counter. Ownership of that rule lives one layer up,
// in [Regexp], which keeps a pool of these and lends one out per call.
type handle struct{ ptr *C.irregex_regex }

func compileHandle(expr string, flags uint32) (*handle, error) {
	var (
		ptr   *C.irregex_regex
		fault C.irregex_fault
	)
	st := C.go_compile(bytePtr(expr), C.size_t(len(expr)), C.uint32_t(flags), &ptr, &fault)
	runtime.KeepAlive(expr)
	if st != C.IRREGEX_OK {
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
		C.irregex_free(h.ptr)
		h.ptr = nil
	}
}

// bytePtr borrows the bytes behind s. Nothing in the C ABI retains a pointer it
// is handed: irregex_compile copies the pattern, and every search verb reads the
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
	var fault C.irregex_fault
	st := C.go_is_match(h.ptr, bytePtr(text), C.size_t(len(text)), &fault)
	runtime.KeepAlive(text)
	if st < 0 {
		panic(newError(st, &fault, "search with "+strconv.Quote(re.expr)))
	}
	return st == C.IRREGEX_MATCH
}

// firstWindow is how many spans the first irregex_find_all asks for. The header
// advises sizing the window at len+1, the most matches a text can hold; doing
// that unconditionally would allocate a 16 MB span buffer for a 1 MB text that
// probably has four matches.
const firstWindow = 4096

// findSpans is the authoritative match sequence for text, capped at limit when
// limit is positive and unbounded when it is negative.
//
// Every verb in this package routes through here rather than advancing a cursor
// over irregex_captures, because the engine owns what a match sequence IS - when
// an empty match adjacent to the previous one counts, what happens at the end of
// the text, how word filtering interacts with resuming - and none of that is
// re-derivable from a find(from) loop.
//
// The window is a view over the answer, never a bound on the search: find_all
// reports how many matches the TEXT HAS rather than how many fit, so one short
// pass measures the retry it needs and there is at most one of them. The first
// window is a guess at how many spans will be wanted; the second is the count
// the engine gave, so it cannot come up short again.
func (re *Regexp) findSpans(h *handle, text string, limit int) [][2]int {
	if limit == 0 {
		return nil
	}
	buf := make([]C.irregex_span, window(firstWindow, len(text)+1, limit))
	want := window(re.fillSpans(h, text, buf), len(text)+1, limit)
	if want > len(buf) {
		buf = make([]C.irregex_span, want)
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
func (re *Regexp) fillSpans(h *handle, text string, buf []C.irregex_span) int {
	var (
		written C.size_t
		fault   C.irregex_fault
	)
	st := C.go_find_all(h.ptr, bytePtr(text), C.size_t(len(text)),
		&buf[0], C.size_t(len(buf)), &written, &fault)
	runtime.KeepAlive(text)
	if st < 0 {
		panic(newError(st, &fault, "search with "+strconv.Quote(re.expr)))
	}
	return int(written)
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
// irregex_captures reports how many spans the PATTERN has rather than how many
// it wrote, so a window that came up short sizes its own retry without a second
// question.
func (re *Regexp) findGroups(h *handle, text string, start, end int) []int {
	if re.ngroup == 0 {
		return []int{start, end}
	}
	buf := make([]C.irregex_span, re.ngroup+1)
	var (
		written C.size_t
		fault   C.irregex_fault
	)
	for {
		st := C.go_captures(h.ptr, bytePtr(text), C.size_t(len(text)), C.size_t(start),
			&buf[0], C.size_t(len(buf)), &written, &fault)
		runtime.KeepAlive(text)
		if st < 0 {
			panic(newError(st, &fault, "read capture groups for "+strconv.Quote(re.expr)))
		}
		if st != C.IRREGEX_MATCH {
			// findSpans already reported a match here, so captures finding none
			// means the two arms disagree. Refusing beats inventing groups.
			panic(fmt.Errorf("irregex: engine disagreement: find_all reported a match at byte %d for %s, "+
				"captures found none", start, strconv.Quote(re.expr)))
		}
		if int(written) <= len(buf) {
			break
		}
		buf = make([]C.irregex_span, int(written))
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
		fault C.irregex_fault
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
		var name C.irregex_text
		st := C.go_group_name(h.ptr, C.uint32_t(number), &name, &fault)
		if st < 0 {
			return newError(st, &fault, "name group "+strconv.Itoa(number)+" of "+strconv.Quote(re.expr))
		}
		if st != C.IRREGEX_MATCH {
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
