//go:build cgo

package irgx

// The window plane: a search confined to a region, while every zero-width
// assertion in the pattern still reads the whole text.
//
// That second half is the whole point, and it is what makes these verbs
// irreducible to the ones in find.go. Slicing the text to the same region asks a
// DIFFERENT question, because a slice moves the haystack's edges: `$`, `\z` and
// `\b` then answer about the slice. Confining the match does not move them.
//
//	re := irgx.MustCompile(`b$`)
//	re.MatchStringIn("abc", 0, 2) // false: `$` is still the end of "abc"
//	re.MatchString("abc"[0:2])    // true:  `$` moved to the cut
//
// Neither is expressible in terms of the other, which is why both exist. stdlib
// [regexp] has neither - it offers no bound at all past the start of the text -
// so nothing here is mirroring an API.
//
// Fitting is EXISTENCE, not the leftmost match measured against the ceiling:
// `\w+` over "abcd" within [0,2) matches on the strength of "ab", even though
// the match [Regexp.FindStringIndex] reports is "abcd" and overruns.

import "strconv"

// Windows reports whether this pattern can be searched inside a window.
//
// A property of the pattern rather than of the call, because it is really a
// property of the engine arm that compiled it. The linear engine windows: the
// bound is a ceiling on its walk, and nothing about that ceiling changed what its
// assertions were reading. PCRE2 cannot, structurally - its subject has one
// length, so stopping at the bound would mean claiming the subject ends there,
// which moves the very anchors it was asked about. So a pattern that needed the
// PCRE arm (lookaround, backreferences) reports false here, and the verbs below
// panic for it rather than quietly answering a different question.
//
// The unwindowed verbs are unaffected either way.
func (re *Regexp) Windows() bool { return re.windows() }

// MatchStringIn reports whether some match of this pattern fits entirely inside
// s[from:to].
//
// to is a ceiling on the match, not a new end of the text: every assertion still
// reads all of s, so `$`, `\z` and `\b` answer about the real edges no matter
// where the window was drawn. to == len(s) is the inert case and behaves exactly
// like [Regexp.MatchString].
//
// It panics on the bounds a slice expression panics on - from or to outside s, or
// crossed - because a miscomputed bound is a bug worth hearing about rather than
// clamping into a wrong answer. It also panics for a pattern that reports false
// from [Regexp.Windows].
func (re *Regexp) MatchStringIn(s string, from, to int) bool {
	checkWindow(len(s), from, to)
	return re.matchIn(s, from, to)
}

// MatchIn reports whether some match fits entirely inside b[from:to].
func (re *Regexp) MatchIn(b []byte, from, to int) bool {
	return re.MatchStringIn(borrow(b), from, to)
}

// FindAllStringIndexIn returns the byte offsets of every match lying entirely
// inside s[from:to], at most n of them, or nil when there are none. A negative n
// means all of them.
//
// Offsets are into s, not into the window, so s[loc[0]:loc[1]] is the matched
// text without any adjustment. The window bounds mean what they mean in
// [Regexp.MatchStringIn], and the same bounds panic.
func (re *Regexp) FindAllStringIndexIn(s string, from, to, n int) [][]int {
	checkWindow(len(s), from, to)
	return pairs(re.spansIn(s, from, to, n))
}

// FindAllIndexIn returns the byte offsets of every match lying entirely inside
// b[from:to], at most n of them.
func (re *Regexp) FindAllIndexIn(b []byte, from, to, n int) [][]int {
	return re.FindAllStringIndexIn(borrow(b), from, to, n)
}

// checkWindow refuses a window that names no region of a text of length size.
//
// Spelled as a panic with a slice expression's own vocabulary because that is
// what the caller wrote wrong: these are the exact bounds `s[from:to]` rejects,
// and the ABI answers a crossed pair with the same code it uses for an
// out-of-range one, so passing it down would lose which mistake it was.
func checkWindow(size, from, to int) {
	if from < 0 || to > size || from > to {
		panic("irregex: window [" + strconv.Itoa(from) + ":" + strconv.Itoa(to) +
			"] is not a region of a text of length " + strconv.Itoa(size))
	}
}
