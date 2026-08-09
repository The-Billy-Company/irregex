//go:build cgo

package irgx

// The line plane: the grid a grep-shaped host rebuilds by hand, and the one
// place the off-by-one lives.
//
// Every verb above answers in byte offsets; a person reads rows. The translation
// is not `bytes.Count(text, "\n")` plus one, and the two ways it is not are both
// silent: a final line with no terminator is still a line, and an offset sitting
// ON a terminator belongs to the line that terminator ENDS rather than the one
// after it. Getting either wrong shifts every number a caret is drawn under.
//
// Content and terminator are reported separately because a host needs both and
// they are not derivable from each other. Render with ContentEnd, slice the next
// line from TermEnd, and no code here has to guess whether the file ended "\n",
// "\r\n", or with nothing at all.

/*
#cgo CFLAGS: -I${SRCDIR}
#include "shim.h"

static int32_t go_lines_count(const uint8_t *text, size_t len, uint64_t *out,
                              irgx_fault *f) {
  int32_t st = irgx_lines_count(text, len, out);
  capture(st, f);
  return st;
}

static int32_t go_lines_split(const uint8_t *text, size_t len, irgx_line *out,
                              size_t cap, size_t *written, irgx_fault *f) {
  int32_t st = irgx_lines_split(text, len, out, cap, written);
  capture(st, f);
  return st;
}

static int32_t go_lines_context(const uint8_t *text, size_t len, size_t at,
                                size_t before, size_t after, irgx_line *out,
                                size_t cap, size_t *written, size_t *center,
                                irgx_fault *f) {
  int32_t st = irgx_lines_context(text, len, at, before, after, out, cap,
                                  written, center);
  capture(st, f);
  return st;
}
*/
import "C"

import (
	"runtime"
	"strconv"
)

// Line is one row of the grid over a text.
//
// All four numbers are about the text they were measured in: Start, ContentEnd
// and TermEnd are byte offsets into it, so text[l.Start:l.ContentEnd] is the row
// as a reader sees it and text[l.Start:l.TermEnd] is the row as the file stores
// it.
type Line struct {
	// Number is 1-based, matching what -n prints and where an editor jumps.
	// Clamping a band at the top of a file shortens it; it never renumbers.
	Number int
	// Start is the offset of the row's first byte.
	Start int
	// ContentEnd is one past the last CONTENT byte: the terminator is excluded,
	// and a CRLF's '\r' is KEPT, which is ripgrep's default without --crlf and
	// what the matching engines in this package see. A host that strips the
	// '\r' for display but matches on the unstripped bytes stays consistent
	// with them.
	ContentEnd int
	// TermEnd is one past the terminator, so the next row's Start. It equals
	// the length of the text for a final unterminated row, which is still a row.
	TermEnd int
}

// LineCount returns how many lines text holds.
//
// An unterminated tail counts, because a host printing n rows has to print that
// one too. Empty text holds no lines.
func LineCount(text []byte) int { return LineCountString(borrow(text)) }

// LineCountString returns how many lines s holds.
func LineCountString(s string) int {
	var (
		count C.uint64_t
		fault C.irgx_fault
	)
	st := C.go_lines_count(bytePtr(s), C.size_t(len(s)), &count, &fault)
	runtime.KeepAlive(s)
	if st < 0 {
		panic(newError(st, &fault, "count the lines of a text of length "+strconv.Itoa(len(s))))
	}
	return int(count)
}

// Lines returns the whole grid over text, or nil when it is empty.
func Lines(text []byte) []Line { return LinesString(borrow(text)) }

// LinesString returns the whole grid over s, or nil when s is empty.
//
// One pass: the engine reports the count the text holds rather than the count
// that fit, so the buffer is sized from the answer and never doubled toward it.
func LinesString(s string) []Line {
	var fault C.irgx_fault
	rows, st := drain(0, func(buf []C.irgx_line) (int, int32) {
		var written C.size_t
		st := C.go_lines_split(bytePtr(s), C.size_t(len(s)), head(buf),
			C.size_t(len(buf)), &written, &fault)
		return int(written), int32(st)
	})
	runtime.KeepAlive(s)
	if st < 0 {
		panic(newError(C.int32_t(st), &fault, "split a text of length "+strconv.Itoa(len(s))+" into lines"))
	}
	return goLines(rows)
}

// LineContext returns the band of rows around byte at, and which row of the band
// holds it.
func LineContext(text []byte, at, before, after int) (band []Line, center int) {
	return LineContextString(borrow(text), at, before, after)
}

// LineContextString returns up to before rows preceding the row holding at, that
// row, and up to after rows following it - the -B / -A band, as one answer.
//
// center is the BAND-RELATIVE index of the row holding at, which is the number a
// caret needs and one a caller cannot derive from len(band): a band clipped at
// the start of the text has fewer preceding rows than it asked for. It is -1
// when the band is empty.
//
// at == len(s) is legal and lands on the tail. It panics for an at outside s, as
// a slice expression does, because a miscomputed offset is a bug worth hearing
// about rather than a band drawn somewhere else.
func LineContextString(s string, at, before, after int) (band []Line, center int) {
	if at < 0 || at > len(s) {
		panic("irregex: LineContext: byte " + strconv.Itoa(at) +
			" is outside a text of length " + strconv.Itoa(len(s)))
	}
	if before < 0 || after < 0 {
		panic("irregex: LineContext: context [-" + strconv.Itoa(before) + ",+" +
			strconv.Itoa(after) + "] is not a band")
	}
	var (
		fault C.irgx_fault
		mid   C.size_t
	)
	// The exact ceiling, so the retry never happens: a band is the row holding
	// `at` plus at most `before` before it and `after` after it.
	rows, st := drain(before+after+1, func(buf []C.irgx_line) (int, int32) {
		var written C.size_t
		st := C.go_lines_context(bytePtr(s), C.size_t(len(s)), C.size_t(at),
			C.size_t(before), C.size_t(after), head(buf), C.size_t(len(buf)),
			&written, &mid, &fault)
		return int(written), int32(st)
	})
	runtime.KeepAlive(s)
	if st < 0 {
		panic(newError(C.int32_t(st), &fault, "read the lines around byte "+strconv.Itoa(at)))
	}
	if len(rows) == 0 {
		return nil, -1
	}
	return goLines(rows), int(mid)
}

// goLines copies the engine's rows out of the C buffer. The buffer is Go memory
// the C call filled, so this is not a lifetime question - it is a type one, and
// a copy is the only way to hand back a []Line rather than a []C.irgx_line the
// caller's package cannot name.
func goLines(rows []C.irgx_line) []Line {
	if len(rows) == 0 {
		return nil
	}
	out := make([]Line, len(rows))
	for i, r := range rows {
		out[i] = Line{
			Number:     int(r.number),
			Start:      int(r.start),
			ContentEnd: int(r.content_end),
			TermEnd:    int(r.term_end),
		}
	}
	return out
}
