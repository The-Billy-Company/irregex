//go:build cgo

// Package irregex is a Go binding for the irregex engine: a linear-time regex
// over a buffer you already hold.
//
// The surface is stdlib [regexp]'s, because that is the API a Go programmer
// already has in their fingers. Compile a pattern once, share it, and call the
// Find family on it:
//
//	var word = irgx.MustCompile(`\w+`)
//
//	func first(s string) string { return word.FindString(s) }
//
// Four things are worth knowing before the API tour.
//
// A refused pattern says which refusal it is. [ErrNeedsPCRE] means the linear
// grammar declined a construct the vendored PCRE2 has, so recompiling with
// [CompileOpts.PCRE] set succeeds; a [*SyntaxError] means the text is malformed
// and carries the byte offset it went wrong at.
//
// A [Regexp] is safe for concurrent use by multiple goroutines, exactly as
// [regexp.Regexp] is, so a package-level var works. The C handle underneath is
// not - it owns the scratch its finds run in - so each Regexp keeps a pool of
// handles and hands one to a goroutine for the length of a call.
//
// Offsets are byte offsets into the string or slice you passed, so
// s[loc[0]:loc[1]] is the matched text with no translation, for ASCII and
// non-ASCII alike.
//
// The match sequence is [regexp]'s, down to the empty matches: the engine
// reports one at every offset a nullable pattern allows, and this package thins
// that to Go's two rules before you see it - an empty match abutting the
// previous one is dropped, and the scan resumes a rune past an empty match
// rather than a byte past it. See the package README for what does differ.
package irgx

import (
	"strconv"
	"sync"
)

// CompileOpts carries the engine's pattern semantics, which stdlib [regexp] has
// no vocabulary for. The zero value is what [Compile] uses.
//
// A struct rather than functional options: the flag set is closed by the C ABI,
// so there is nothing for an option function to extend, and a struct literal
// shows every choice at the call site.
//
//	re, err := irgx.CompileOpts{IgnoreCase: true, Word: true}.Compile("cat")
//
// A pattern may also ask for these itself, in the leading (?ims-u) form stdlib
// [regexp] uses. Where both speak, the pattern wins - it is the more specific
// statement, so CompileOpts{IgnoreCase: true}.Compile("(?-i)cat") is
// case-sensitive. Only a leading run is a whole-pattern flag, as in regexp
// itself; (?x), (?U) and (?R) are flags this grammar does not have and need
// PCRE.
type CompileOpts struct {
	// Fixed treats the pattern as a literal string rather than a regex, so a
	// pattern full of metacharacters is data instead of a syntax error. It wins
	// over PCRE, the way the engine's command line resolves the same pair.
	Fixed bool
	// IgnoreCase folds case.
	IgnoreCase bool
	// Word requires a match to stand alone: "cat" no longer matches inside
	// "concatenate". This is applied by the engine during the search, not as a
	// filter afterwards, so the search resumes correctly past a rejected span.
	Word bool
	// SmartCase folds case only when the pattern has no uppercase letter. It is
	// resolved at compile time against the same predicate the engine's -S runs.
	SmartCase bool
	// ASCII restricts classes, folding, and word boundaries to ASCII. Unicode
	// is the engine's default, which is why the field is spelled as its
	// absence: the zero value is the default.
	ASCII bool
	// PCRE selects the vendored PCRE2 grammar, which admits lookaround and
	// backreferences. The linear-time guarantee is PCRE2's problem then, not
	// the engine's.
	PCRE bool
	// MultiLine makes ^ and $ match at line boundaries as well as at the ends
	// of the text - the (?m) question, and nothing more. It does not change
	// what the text IS: the text is one buffer either way, \s matches a
	// newline, and a match may span one.
	//
	// A leading (?m) asks for the same thing and is equivalent. A Set has
	// nowhere to carry either spelling and refuses both.
	MultiLine bool
	// DotAll makes . match a newline - the (?s) question. A leading (?s) is
	// equivalent, and a Set refuses both.
	DotAll bool
}

func (o CompileOpts) bits() uint32 {
	return bit(o.Fixed, flagFixed) |
		bit(o.IgnoreCase, flagIgnoreCase) |
		bit(o.Word, flagWord) |
		bit(o.SmartCase, flagSmartCase) |
		bit(o.ASCII, flagNoUnicode) |
		bit(o.PCRE, flagPCRE) |
		bit(o.MultiLine, flagMultiLine) |
		bit(o.DotAll, flagDotAll)
}

func bit(on bool, flag uint32) uint32 {
	if on {
		return flag
	}
	return 0
}

// Regexp is a compiled pattern. It is safe for concurrent use by multiple
// goroutines.
type Regexp struct {
	expr   string
	flags  uint32
	ngroup int
	// names is indexed by group number; names[0] is always empty, and so is any
	// group the pattern did not name.
	names []string
	index map[string]int
	// nullable is whether the pattern can match the empty string, and so whether
	// the Go empty-match convention has anything to thin. Resolved once here
	// because it is a property of the pattern, and asked on every walk.
	nullable bool
	// pool holds per-goroutine C handles. sync.Pool rather than one handle under
	// a mutex, because the engine's scratch is the only thing that cannot be
	// shared and serializing every search on it would give up the concurrency a
	// caller asked for.
	pool sync.Pool
}

// Compile parses expr and returns a Regexp, or an error naming what the engine
// refused. See [CompileOpts.Compile] for the two kinds of refusal, one of which
// a caller can retry.
func Compile(expr string) (*Regexp, error) { return CompileOpts{}.Compile(expr) }

// MustCompile is Compile with a panic instead of an error, for patterns fixed
// at compile time.
func MustCompile(expr string) *Regexp { return CompileOpts{}.MustCompile(expr) }

// Compile parses expr under o and returns a Regexp, or an error naming what the
// engine refused.
//
// A refusal is one of two things, and they are worth telling apart. A pattern
// outside the linear grammar - lookaround, a backreference, an atomic group -
// is an error here rather than a quiet non-match, and it matches
// [ErrNeedsPCRE]: the same text compiles with [CompileOpts.PCRE] set. A pattern
// nothing here accepts is a [*SyntaxError] carrying the offset it went wrong
// at, and no flag rescues it.
func (o CompileOpts) Compile(expr string) (*Regexp, error) {
	if abiMismatch != nil {
		return nil, abiMismatch
	}
	flags := o.bits()
	h, err := compileHandle(expr, flags)
	if err != nil {
		return nil, err
	}
	re := &Regexp{expr: expr, flags: flags}
	// Group metadata is resolved now, not lazily, because the Find family has no
	// error channel: a Regexp whose capture half could still fail would have to
	// answer a submatch question with a panic or a wrong answer.
	if err := re.resolve(h); err != nil {
		return nil, err
	}
	re.nullable = re.matchOn(h, "")
	re.pool.Put(h)
	return re, nil
}

// MustCompile is [CompileOpts.Compile] with a panic instead of an error.
func (o CompileOpts) MustCompile(expr string) *Regexp {
	re, err := o.Compile(expr)
	if err != nil {
		panic(`irregex: Compile(` + strconv.Quote(expr) + `): ` + err.Error())
	}
	return re
}

// MatchString reports whether s contains a match of pattern. It compiles the
// pattern on every call; keep a [Regexp] for anything you ask twice.
func MatchString(pattern, s string) (bool, error) {
	re, err := Compile(pattern)
	if err != nil {
		return false, err
	}
	return re.MatchString(s), nil
}

// Match reports whether b contains a match of pattern.
func Match(pattern string, b []byte) (bool, error) {
	re, err := Compile(pattern)
	if err != nil {
		return false, err
	}
	return re.Match(b), nil
}

// String returns the source text of the pattern.
func (re *Regexp) String() string { return re.expr }

// NumSubexp returns the number of capture groups, excluding the whole match.
func (re *Regexp) NumSubexp() int { return re.ngroup }

// SubexpNames returns the names of the capture groups, indexed by group number;
// the slot for an unnamed group is empty, and so is element 0, which stands for
// the whole match. The slice is shared with the Regexp and must not be modified.
func (re *Regexp) SubexpNames() []string { return re.names }

// SubexpIndex returns the number of the group named name, or -1. A name the
// pattern does not declare is an answer, not an error.
func (re *Regexp) SubexpIndex(name string) int {
	if number, ok := re.index[name]; ok {
		return number
	}
	return -1
}

// Earliest reports whether this pattern can report EARLIEST-mode spans: the
// first accepting position rather than the leftmost-first match.
//
// The sibling of [Regexp.Windows], and a property of the pattern for the same
// reason - it is really a property of the engine arm that compiled it. PCRE2
// declines because it exposes no inspectable program to walk, and so does any
// assertion-bearing pattern, whose determinized states depend on the gap they
// were entered at, which a walk starting mid-buffer cannot reconstruct.
//
// False is a REFUSAL rather than a slower path: the mode faults instead of
// quietly returning the leftmost-first match wearing an earliest label. Nothing
// in this package selects the mode - every Find here is leftmost-first, and the
// boolean verbs are unaffected either way, because existence does not depend on
// WHICH match is reported - so this is here for a host that drives the mode
// through the C ABI's own request struct and needs to know first.
func (re *Regexp) Earliest() bool { return re.earliest() }

// acquire takes a handle out of the pool, compiling a fresh one when the pool is
// empty. The compile is pure, so a handle per busy goroutine costs one compile
// each and nothing after that.
//
// It panics when a recompile fails. That can only be an allocation failure: the
// pattern already compiled once, in [Compile], where the error had somewhere to
// go. The Find family follows stdlib [regexp] in returning no error, so there is
// no honest alternative to failing loudly.
func (re *Regexp) acquire() *handle {
	if pooled := re.pool.Get(); pooled != nil {
		return pooled.(*handle)
	}
	h, err := compileHandle(re.expr, re.flags)
	if err != nil {
		panic(err)
	}
	return h
}

func (re *Regexp) release(h *handle) { re.pool.Put(h) }
