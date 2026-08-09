//go:build cgo

package irgx

// Maximal munch: the longest match BEGINNING at an offset, among many patterns.
// The lexer primitive, and a different question from every other verb here.

import (
	"errors"
	"strconv"
	"sync"
)

// Why is the reason a terminal could not be seated in a [Munch].
//
// Carried rather than inferred because the four have different owners and
// different repairs. [WhyStates] and [WhyBufferAnchor] in particular are a budget
// and a wall, and a caller acts on the difference: the first says a bigger build
// would take this terminal, the second that none ever will.
type Why uint32

const (
	// WhySyntax means the parser would not accept the terminal at all.
	WhySyntax Why = 0
	// WhyStates means the subset construction reached this build's state bound.
	// Not a statement about regular languages - a statement about this build.
	WhyStates Why = 1
	// WhyWordContext means a \b was reached through the terminal's body, with no
	// left context to resolve it against. A scan begins where you point it, so
	// there is no byte before the cursor for the assertion to read.
	WhyWordContext Why = 2
	// WhyBufferAnchor means a \A or \z, which no budget admits: the position it
	// asserts is not something a machine determinized over the terminal alone
	// can see. A scan is already anchored where you point it, which leaves \A
	// redundant and \z unsatisfiable - drop it from the terminal.
	WhyBufferAnchor Why = 3
)

func (w Why) String() string {
	switch w {
	case WhySyntax:
		return "syntax"
	case WhyStates:
		return "state bound"
	case WhyWordContext:
		return "word boundary with no left context"
	case WhyBufferAnchor:
		return "buffer anchor"
	}
	// A reason a newer engine reports and this build has never heard of, which
	// is a thing to log rather than a thing to crash on.
	return "unknown reason " + strconv.FormatUint(uint64(w), 10)
}

// Refusal is one terminal a [Munch] could not seat.
type Refusal struct {
	// Pattern is its index in the list [CompileMunch] was given.
	Pattern int
	// Why is the reason it was refused.
	Why Why
}

func (r Refusal) String() string {
	return "terminal " + strconv.Itoa(r.Pattern) + ": " + r.Why.String()
}

// Token is what a scan found at one cursor.
type Token struct {
	// Length is how far the winner reached from the cursor, in bytes. Zero is a
	// real answer: a terminal that accepts the empty string won, which is a live
	// lexer hazard rather than a miss.
	Length int
	// Patterns is every terminal that reached Length, ascending. More than one
	// is the ordinary case - `if` is both the keyword and an identifier - and
	// resolving that tie is the lexer's business, not the engine's, so the whole
	// tie is reported rather than a winner being invented.
	Patterns []int
}

// Munch is a lexer slate: many terminals, each asked only at the cursor.
//
// stdlib regexp has no such type, and the loop it makes you write instead is the
// reason this one exists. A lexer already knows where it is; what it needs is
// which of its terminals wins THERE and how far it reaches. Written out of
// [Regexp.FindStringIndex] that is N anchored searches at every cursor position,
// quadratic in the number of terminals and reading the same bytes N times.
//
//	lex := irgx.MustCompileMunch(`if`, `[a-z]+`, `[0-9]+`, `\s+`)
//
//	for at := 0; at < len(src); {
//		tok, ok := lex.Scan(src, at)
//		if !ok {
//			break
//		}
//		…
//		at += max(tok.Length, 1)
//	}
//
// Compilation is PARTIAL, which is the one place this differs from [Set] on
// policy and why they are two types. A slate of a hundred and fifty terminals
// where one is outside the linear grammar is a working lexer, so the rest are
// seated and the refusals are reported by [Munch.Declined]; a classifier that
// silently dropped a pattern would misreport which patterns matched, while a
// lexer that refused to build over one bad terminal would simply not lex.
//
// There is no automaton surface here on purpose: a host stepping DFA states
// would be a second opinion about what a pattern means, and one engine that
// disagrees with itself is worse than one that is missing a verb.
//
// A Munch is safe for concurrent use by multiple goroutines, by the same means a
// [Regexp] is: the C handle owns the permission set each scan rewrites, so the
// Munch keeps a pool and lends one out per call.
type Munch struct {
	exprs    []string
	flags    uint32
	seated   int
	declined []Refusal
	pool     sync.Pool
}

// Which reading of the cursor a scan asks for. Not exported: they are the
// [Munch.Scan] / [Munch.ScanShortest] pair, which reads better at a call site
// than a mode constant threaded through it.
const (
	pickLongest  = 0
	pickShortest = 1
)

// CompileMunch compiles every terminal as one lexer slate. See
// [CompileOpts.CompileMunch] for the flags.
func CompileMunch(exprs ...string) (*Munch, error) { return CompileOpts{}.CompileMunch(exprs...) }

// MustCompileMunch is [CompileMunch] with a panic instead of an error, for a
// lexer fixed at compile time.
func MustCompileMunch(exprs ...string) *Munch { return CompileOpts{}.MustCompileMunch(exprs...) }

// CompileMunch compiles every terminal under o as one lexer slate.
//
// Terminals that cannot be determinized are left out and reported by
// [Munch.Declined], and the rest lex. Only a slate where NOTHING could be seated
// is an error, and it wraps [ErrNeedsPCRE]: no anchored automaton could be built,
// so there is nothing to scan with.
//
// The flags are the slate's and cannot be a terminal's, which is forced rather
// than chosen: a munch determinizes every terminal TOGETHER, so "terminal 3 is
// case-insensitive" is not a thing the resulting machine can be.
//
// [CompileOpts.MultiLine] is refused rather than ignored. It asks for the
// line-anchor reading, which a scan anchored at the cursor cannot observe either
// way, and answering as if it had meant something would be worse than saying so.
func (o CompileOpts) CompileMunch(exprs ...string) (*Munch, error) {
	if abiMismatch != nil {
		return nil, abiMismatch
	}
	if o.MultiLine {
		return nil, errors.New("irregex: CompileMunch: MultiLine is not available on a munch: " +
			"a scan is anchored at the cursor you pass, so the line-anchor reading " +
			"it asks for cannot be observed either way")
	}
	flags := o.bits()
	l, err := compileLexer(exprs, flags)
	if err != nil {
		return nil, err
	}
	m := &Munch{exprs: append([]string(nil), exprs...), flags: flags}
	// Both facts a caller needs about the build - what got in, and what did not
	// - are read once here rather than per scan, on the handle that just
	// answered them.
	m.seated, m.declined = l.seated(), l.refusals(len(exprs))
	m.pool.Put(l)
	return m, nil
}

// MustCompileMunch is [CompileOpts.CompileMunch] with a panic instead of an error.
func (o CompileOpts) MustCompileMunch(exprs ...string) *Munch {
	m, err := o.CompileMunch(exprs...)
	if err != nil {
		panic(`irregex: CompileMunch: ` + err.Error())
	}
	return m
}

// Len returns how many terminals were actually seated.
//
// The admitted count, not the compile-list count - which is the number that
// matters, because a declined terminal can never win and so can never be named
// by a [Token]. Compare len([Munch.Patterns]) to learn whether anything was
// turned away.
func (m *Munch) Len() int { return m.seated }

// Patterns returns the source text of every terminal, indexed the way a [Token]
// names them. The slice is shared with the Munch and must not be modified.
func (m *Munch) Patterns() []string { return m.exprs }

// Declined returns every terminal that could not be seated, ascending, or nil
// when the slate took them all.
//
// A non-empty answer is a working lexer that will never emit those tokens, so it
// is worth checking once at startup rather than discovering as a mis-lex. The
// slice is shared with the Munch and must not be modified.
func (m *Munch) Declined() []Refusal { return m.declined }

// Scan returns the longest token beginning at exactly at, and whether anything
// accepted there.
//
// at == len(text) is legal and asks the only question left at the end of the
// input: does anything accept the empty string. Scan panics if at is outside
// text, as a slice expression does.
func (m *Munch) Scan(text string, at int) (Token, bool) {
	return m.scan(text, at, nil, pickLongest)
}

// ScanBytes is [Munch.Scan] over b.
func (m *Munch) ScanBytes(b []byte, at int) (Token, bool) { return m.Scan(borrow(b), at) }

// ScanShortest returns the shortest NON-EMPTY token beginning at at.
//
// The other reading of the same cursor rather than a different search, and what
// a delimiter wants so it does not swallow its own terminator. The empty reading
// is skipped because a nullable terminal accepts everywhere, and counting it
// would answer zero at every cursor.
func (m *Munch) ScanShortest(text string, at int) (Token, bool) {
	return m.scan(text, at, nil, pickShortest)
}

// ScanAmong is [Munch.Scan] restricted to the given terminal indices, for this
// call only.
//
// How a context-sensitive lexer is written: the permission set is what changes
// between "expecting an operand" and "expecting an operator", and rebuilding a
// slate per context would cost a compile. An empty allow permits nothing and
// answers false without a scan; a nil allow permits everything seated, which is
// what [Munch.Scan] passes.
func (m *Munch) ScanAmong(text string, at int, allow []int) (Token, bool) {
	if allow != nil && len(allow) == 0 {
		return Token{}, false
	}
	return m.scan(text, at, allow, pickLongest)
}

// ScanShortestAmong is [Munch.ScanShortest] restricted to the given terminals.
func (m *Munch) ScanShortestAmong(text string, at int, allow []int) (Token, bool) {
	if allow != nil && len(allow) == 0 {
		return Token{}, false
	}
	return m.scan(text, at, allow, pickShortest)
}

// String returns the terminals as a bracketed list, for a log line or a test
// failure.
func (m *Munch) String() string {
	quoted := make([]byte, 0, 16*len(m.exprs)+2)
	quoted = append(quoted, '[')
	for i, expr := range m.exprs {
		if i != 0 {
			quoted = append(quoted, ' ')
		}
		quoted = strconv.AppendQuote(quoted, expr)
	}
	return string(append(quoted, ']'))
}

func (m *Munch) scan(text string, at int, allow []int, pick uint32) (Token, bool) {
	if at < 0 || at > len(text) {
		panic("irregex: Munch.Scan: cursor " + strconv.Itoa(at) +
			" is outside a text of length " + strconv.Itoa(len(text)))
	}
	if m.seated == 0 {
		return Token{}, false
	}
	h := m.acquire()
	defer m.release(h)
	return h.scan(text, at, allow, pick, m.seated)
}

func (m *Munch) acquire() *lexer {
	if pooled := m.pool.Get(); pooled != nil {
		return pooled.(*lexer)
	}
	l, err := compileLexer(m.exprs, m.flags)
	if err != nil {
		panic(err)
	}
	return l
}

func (m *Munch) release(l *lexer) { m.pool.Put(l) }
