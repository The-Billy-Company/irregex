//go:build cgo

package irgx

// Many patterns, one pass, and which of them hit. stdlib regexp has no such
// type, so nothing here is mirroring an API - the shape is Go's, the question is
// the engine's.

import (
	"errors"
	"strconv"
	"sync"
)

// Set is many patterns matched against one text in a single pass, keeping which
// pattern matched.
//
// The alternative a caller writes without it is a loop over N [Regexp] values,
// which reads the text N times, or one alternation `a|b|c`, which reads it once
// and then cannot say which branch hit. A Set is the third thing: one pass, and
// attribution.
//
//	kinds := irgx.MustCompileSet(`^func `, `^type `, `^var `)
//
//	for _, i := range kinds.WhichString(line) { … }
//
// It answers two questions and offers no cursor. A Set is a CLASSIFIER: once you
// know pattern 7 is in this text, [Regexp.FindAllIndex] on pattern 7 is the walk
// you were going to run anyway, over a text now known to be worth walking.
//
// The unit is the whole text, exactly as it is for a [Regexp]: `^` and `$` are
// the text's ends, `\s` can match a newline, and a nullable pattern matches the
// empty text. So [Set.MatchString] on a set naming pattern i agrees with
// [Regexp.MatchString] on pattern i alone, for every pattern and every text.
//
// A Set is safe for concurrent use by multiple goroutines, by the same means a
// [Regexp] is: the C handle owns the scratch its scans run in, so the Set keeps
// a pool and lends one out per call.
type Set struct {
	exprs []string
	flags uint32
	pool  sync.Pool
}

// CompileSet compiles every pattern as one set, or returns an error naming which
// of them the engine refused. See [CompileOpts.CompileSet] for the flags.
func CompileSet(exprs ...string) (*Set, error) { return CompileOpts{}.CompileSet(exprs...) }

// MustCompileSet is [CompileSet] with a panic instead of an error, for a set
// fixed at compile time.
func MustCompileSet(exprs ...string) *Set { return CompileOpts{}.MustCompileSet(exprs...) }

// CompileSet compiles every pattern under o as one set.
//
// A refusal is a [*SetError] naming the index that caused it and wrapping the
// error a lone [CompileOpts.Compile] of that pattern would have given, so
// [ErrNeedsPCRE] and [*SyntaxError] both still read through it. It is all or
// nothing: one refused pattern refuses the set rather than silently leaving a
// hole in the numbering.
//
// [CompileOpts.MultiLine] and [CompileOpts.DotAll] are refused rather than
// ignored. They are the two flags this plane cannot honor, and a caller who set
// one believes something about the answer they are about to get. A pattern whose
// own head says (?m) or (?s) is refused for the same reason, naming its index.
//
// The flags apply to every pattern, which is the honest shape for a set built
// from a config file or a flag: one text, one question, one set of semantics.
// A leading (?i) or (?-u) in a pattern is still that pattern's own, so one
// member can fold case without the rest of them folding.
func (o CompileOpts) CompileSet(exprs ...string) (*Set, error) {
	if abiMismatch != nil {
		return nil, abiMismatch
	}
	if err := o.setFlags(); err != nil {
		return nil, err
	}
	flags := o.bits()
	s, err := compileSlate(exprs, flags)
	if err != nil {
		return nil, err
	}
	set := &Set{exprs: append([]string(nil), exprs...), flags: flags}
	set.pool.Put(s)
	return set, nil
}

// MustCompileSet is [CompileOpts.CompileSet] with a panic instead of an error.
func (o CompileOpts) MustCompileSet(exprs ...string) *Set {
	set, err := o.CompileSet(exprs...)
	if err != nil {
		panic(`irregex: CompileSet: ` + err.Error())
	}
	return set
}

// setFlags reports the options a set cannot carry, before any of them cross the
// seam. The ABI refuses them too, but as an argument fault that names no field;
// this is the same refusal with the caller's own vocabulary in it.
func (o CompileOpts) setFlags() error {
	switch {
	case o.MultiLine:
		return errors.New("irregex: CompileSet: MultiLine is not available on a set")
	case o.DotAll:
		return errors.New("irregex: CompileSet: DotAll is not available on a set")
	}
	return nil
}

// Len returns how many patterns the set holds, which is also the ceiling on the
// length of a [Set.Which] answer.
func (s *Set) Len() int { return len(s.exprs) }

// Patterns returns the source text of every pattern, indexed the way
// [Set.Which] reports. The slice is shared with the Set and must not be
// modified.
func (s *Set) Patterns() []string { return s.exprs }

// MatchString reports whether any pattern in the set matches text.
//
// This is the cheap question and the one a batch workload spends its time in:
// the engine can reject a hopeless text on a literal scan, with no pattern
// running at all.
func (s *Set) MatchString(text string) bool {
	h := s.acquire()
	defer s.release(h)
	return h.anyMatch(text)
}

// Match reports whether any pattern in the set matches b.
func (s *Set) Match(b []byte) bool { return s.MatchString(borrow(b)) }

// WhichString returns the index of every pattern matching text, ascending, or
// nil when none do. The indices are positions in the list the set was compiled
// from, so [Set.Patterns] names them.
func (s *Set) WhichString(text string) []int {
	h := s.acquire()
	defer s.release(h)
	return h.which(text, len(s.exprs))
}

// Which returns the index of every pattern matching b, ascending.
func (s *Set) Which(b []byte) []int { return s.WhichString(borrow(b)) }

// String returns the patterns as a bracketed list, for a log line or a test
// failure.
func (s *Set) String() string {
	quoted := make([]byte, 0, 16*len(s.exprs)+2)
	quoted = append(quoted, '[')
	for i, expr := range s.exprs {
		if i != 0 {
			quoted = append(quoted, ' ')
		}
		quoted = strconv.AppendQuote(quoted, expr)
	}
	return string(append(quoted, ']'))
}

// acquire takes a slate out of the pool, recompiling when the pool is empty. It
// panics on a failure there for the reason [Regexp.acquire] does: these patterns
// already compiled once, where the error had somewhere to go.
func (s *Set) acquire() *slate {
	if pooled := s.pool.Get(); pooled != nil {
		return pooled.(*slate)
	}
	h, err := compileSlate(s.exprs, s.flags)
	if err != nil {
		panic(err)
	}
	return h
}

func (s *Set) release(h *slate) { s.pool.Put(h) }
