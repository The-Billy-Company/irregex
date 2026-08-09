//go:build cgo

package irgx

// The doors a Go host expects because `regexp` has them, rather than because the
// C ABI does. Everything else in this package is a verb the engine exports; these
// four are the remaining shape of the standard library's own type, answered out
// of facts the engine already holds so they cannot drift from it.
//
// What is deliberately NOT here, and why, is at the bottom of the file.

import "strconv"

// QuoteMeta returns a pattern that matches s literally, escaping every byte the
// grammar would otherwise read as syntax.
//
// The set escaped is the grammar's, not a guess, and it is asserted rather than
// assumed: the tests drive every byte through both engine arms and check that the
// quoted form compiles and matches exactly the byte it stands for. So a future
// grammar that makes one more byte special fails a test here instead of silently
// mis-quoting a caller's filename.
//
// [CompileOpts.Fixed] is the better answer when the whole pattern is a literal -
// it takes the same text with no escaping at all and picks a substring machine
// over a regex one. Quoting is for the case Fixed cannot serve: a literal that
// has to be SPLICED into a larger pattern, `"^" + QuoteMeta(name) + "$"`.
func QuoteMeta(s string) string {
	// One pass to decide, so the common case (nothing to escape) returns the
	// caller's own string with no allocation at all.
	extra := 0
	for i := range len(s) {
		if special(s[i]) {
			extra++
		}
	}
	if extra == 0 {
		return s
	}
	out := make([]byte, 0, len(s)+extra)
	for i := range len(s) {
		if b := s[i]; special(b) {
			out = append(out, '\\', b)
		} else {
			out = append(out, b)
		}
	}
	return string(out)
}

// special is the grammar's syntax set. A multi-byte codepoint is never special -
// its continuation bytes are all >= 0x80 - so this is a byte test rather than a
// rune one, and quoting never has to decode. NUL is absent on purpose: both
// engine arms take a raw zero byte literally, and the patterns carry an explicit
// length rather than a terminator, so escaping it would only make the output
// harder to read.
func special(b byte) bool {
	switch b {
	case '\\', '.', '+', '*', '?', '(', ')', '|', '[', ']', '{', '}', '^', '$':
		return true
	}
	return false
}

// LiteralPrefix returns a literal string that must begin any match of re, and
// whether that literal IS the whole pattern.
//
// Read out of the pattern's own literal plane rather than re-derived here, so it
// agrees with what the search actually prefilters on. A pattern whose matches may
// begin several different ways ("foo|bar") has no single required prefix and gets
// the empty string - which is a true statement about it, not a failure.
//
// complete is the caller's license to stop using a regex engine: when it is true,
// matching re is the same question as searching for prefix, and [Needles] or
// strings.Index answers it for less. It says nothing about capture groups -
// "(foo)bar" is complete, and a caller that needs the group still needs the
// engine.
//
// It is that license, rather than the standard library's "the literal comprises
// the entire regexp", which is why an ANCHORED literal is not complete here:
// regexp calls "^foo$" complete, but substring-searching for "foo" answers a
// different question than matching "^foo$" does, and the whole value of the
// boolean is that a caller may act on it without re-reading the pattern.
func (re *Regexp) LiteralPrefix() (prefix string, complete bool) {
	lits, err := re.Literals()
	if err != nil {
		// The plane declines for a pattern it cannot read - a PCRE2 program has
		// no inspectable literals - and declining means promising nothing, which
		// is exactly what the empty prefix says.
		return "", false
	}
	defer lits.Close()
	// EXACT means the set is the pattern's whole language, so a one-member exact
	// whole-set is a pattern that matches precisely one string.
	if whole, verdict := lits.Set(PlaceWhole); verdict == VerdictExact && len(whole) == 1 {
		return whole[0], true
	}
	// Otherwise the strongest true statement is a prefix EVERY match starts with,
	// which needs the set to be a single member and to be a set the engine is
	// willing to prefilter on. More than one member is an alternation, and a
	// VerdictNone set proves nothing about where a match may begin.
	if pre, verdict := lits.Set(PlacePrefix); verdict.Eliminates() && len(pre) == 1 {
		return pre[0], false
	}
	return "", false
}

// MarshalText implements [encoding.TextMarshaler], so a *Regexp is a field type
// in a JSON or TOML config rather than a string a decoder has to remember to
// compile.
//
// The text is the pattern, with any compile option that HAS an inline spelling
// written as a leading group - so the round trip preserves meaning and not just
// bytes. An option with no inline spelling ([CompileOpts.PCRE],
// [CompileOpts.Fixed], [CompileOpts.Word], [CompileOpts.SmartCase]) is refused
// rather than dropped: a case-insensitive pattern silently marshaling to a
// case-sensitive one is a config that reads correctly and matches wrongly.
func (re *Regexp) MarshalText() ([]byte, error) {
	inline, err := re.inlineFlags()
	if err != nil {
		return nil, err
	}
	return []byte(inline + re.expr), nil
}

// AppendText implements [encoding.TextAppender].
func (re *Regexp) AppendText(b []byte) ([]byte, error) {
	text, err := re.MarshalText()
	if err != nil {
		return b, err
	}
	return append(b, text...), nil
}

// UnmarshalText implements [encoding.TextUnmarshaler], compiling text with the
// default options - which is why [Regexp.MarshalText] writes the ones that can be
// written inline. A pattern the engine refuses is a decode error naming the
// position, the same as [Compile].
func (re *Regexp) UnmarshalText(text []byte) error {
	next, err := Compile(string(text))
	if err != nil {
		return err
	}
	// The pool holds handles compiled for the pattern this value USED to be, and
	// reusing one would search for the old pattern under the new name. Drained
	// rather than replaced, because a sync.Pool cannot be assigned over; the
	// handles carry finalizers, so dropping them releases their C memory.
	for re.pool.Get() != nil {
	}
	re.expr, re.flags, re.ngroup = next.expr, next.flags, next.ngroup
	re.names, re.index, re.nullable = next.names, next.index, next.nullable
	return nil
}

// inlineFlags spells the compile options as a leading group, or refuses.
func (re *Regexp) inlineFlags() (string, error) {
	if bad := re.flags &^ (flagIgnoreCase | flagMultiLine | flagDotAll | flagNoUnicode); bad != 0 {
		return "", refuse("write a pattern compiled with flags 0x" +
			strconv.FormatUint(uint64(bad), 16) + " as text: no inline spelling carries them")
	}
	set, clear := "", ""
	for _, f := range []struct {
		bit uint32
		on  string
		off string
	}{
		{flagIgnoreCase, "i", ""},
		{flagMultiLine, "m", ""},
		{flagDotAll, "s", ""},
		// ASCII is the ABSENCE of Unicode mode, so it is spelled by clearing the
		// flag the engine has on by default.
		{flagNoUnicode, "", "u"},
	} {
		if re.flags&f.bit == 0 {
			continue
		}
		set, clear = set+f.on, clear+f.off
	}
	switch {
	case set == "" && clear == "":
		return "", nil
	case clear == "":
		return "(?" + set + ")", nil
	default:
		return "(?" + set + "-" + clear + ")", nil
	}
}

// Absent on purpose, so a reader does not go looking:
//
//   - Longest, CompilePOSIX. Leftmost-longest is a different match semantics,
//     and the engine has no arm that reports it. A method that quietly returned
//     leftmost-first spans under a POSIX name would be worse than its absence.
//   - MatchReader, FindReaderIndex, FindReaderSubmatchIndex. The ABI searches a
//     buffer it can see all of; a rune reader would have to be drained into one
//     first, which a caller can do in a line and which no method here can do
//     without pretending to stream.
//   - Copy. Deprecated in the standard library, and pointless here: a *Regexp is
//     already safe for concurrent use, and its per-goroutine C scratch comes from
//     a pool rather than from the value.
