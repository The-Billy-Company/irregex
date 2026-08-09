//go:build cgo

package irgx

// The two ways a compile can be refused, which the ABI reports as two different
// status codes rather than two spellings of one fault name. Everything here is
// decided from that code; nothing in this package compares a fault string.

import (
	"errors"
	"strconv"
)

// ErrNeedsPCRE reports a pattern the default grammar declined and the vendored
// PCRE2 grammar accepts - lookaround, a backreference, an atomic group. Nothing
// is wrong with the pattern; the linear-time engine has no way to express it,
// which is a routing fact and not a defect. The remedy is one flag:
//
//	re, err := irgx.Compile(pat)
//	if errors.Is(err, irgx.ErrNeedsPCRE) {
//		re, err = irgx.CompileOpts{PCRE: true}.Compile(pat)
//	}
//	if err != nil {
//		return err
//	}
//
// The engine decides this by handing the refused pattern to PCRE2, so the set
// it covers is whatever PCRE2 can express rather than a list somebody keeps up
// to date. A pattern that is simply malformed comes back as a [*SyntaxError]
// instead, and no flag rescues that one.
//
// [Compile] returns this wrapped in a sentence naming the pattern, so match it
// with [errors.Is] rather than by comparison.
var ErrNeedsPCRE = errors.New("pattern needs the PCRE2 grammar: set CompileOpts.PCRE")

// ErrNoIndex reports that a corpus has no persisted narrowing tier: nobody has
// run an index over it. Nothing is wrong, and it is not an empty index - there
// is no index - so the honest response is to read every file, exactly as a host
// with no sieve at all would.
//
// It is the third answer [OpenSieve] can give, and the reason it is an error
// rather than a nil handle is that "no index" and "an index that admits nothing"
// must not be spellable the same way. Match it with [errors.Is]:
//
//	s, err := irgx.OpenSieve("")
//	switch {
//	case errors.Is(err, irgx.ErrNoIndex):
//		return readEverything()
//	case err != nil:
//		return err
//	}
var ErrNoIndex = errors.New("no narrowing index has been built over this corpus")

// SyntaxError is a pattern that no grammar here accepts: an unclosed group, a
// reversed class range, a quantifier with nothing to quantify. Setting
// [CompileOpts.PCRE] does not rescue it, which is exactly what separates it
// from [ErrNeedsPCRE].
//
//	var bad *irgx.SyntaxError
//	if errors.As(err, &bad) {
//		log.Printf("%s\n%*s", bad.Expr, bad.At+1, "^")
//	}
//
// It unwraps to the [*Error] the seam produced, for a caller that wants the
// status code or the rest of the engine's fault detail.
type SyntaxError struct {
	// Expr is the pattern, exactly as it was passed to Compile.
	Expr string
	// At is the byte offset into Expr the engine stopped at, or -1 when it
	// reported no position. Byte 0 is a real offset, so absence cannot be
	// spelled as one.
	At int
	// Reason is the engine's own word for the defect.
	Reason string

	err *Error
}

func (e *SyntaxError) Error() string {
	msg := "irregex: compile " + strconv.Quote(e.Expr) + ": " + e.Reason
	if e.At >= 0 {
		msg += " at byte " + strconv.Itoa(e.At)
	}
	return msg
}

func (e *SyntaxError) Unwrap() error {
	if e.err == nil {
		return nil
	}
	return e.err
}

// SetError is a pattern a [Set] refused, and where in the list it was. With one
// pattern "unsupported" is the whole diagnosis; with two hundred it is not
// something a caller can act on, so the index travels with the reason.
//
// It wraps the error a lone [Compile] of that pattern would have returned, so
// the two ways of asking still work through it:
//
//	if errors.Is(err, irgx.ErrNeedsPCRE) { … }  // that one pattern needs PCRE2
//
//	var bad *irgx.SetError
//	if errors.As(err, &bad) { log.Printf("pattern %d: %v", bad.Index, bad.Err) }
type SetError struct {
	// Index is the position of the refused pattern in the compile list.
	Index int
	// Expr is that pattern, exactly as it was passed.
	Expr string
	// Err is the refusal itself: a [*SyntaxError], or an error matching
	// [ErrNeedsPCRE].
	Err error
}

func (e *SetError) Error() string {
	return "irregex: set pattern " + strconv.Itoa(e.Index) + ": " + e.Err.Error()
}

func (e *SetError) Unwrap() error { return e.Err }
