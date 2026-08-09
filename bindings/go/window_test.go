//go:build cgo

package irgx_test

// The window plane, against the one oracle that is sound for it.
//
// A window confines the match while leaving every assertion reading the whole
// text, so for a pattern that asserts nothing there is nothing left for the two
// readings to disagree about, and stdlib regexp over s[from:to] is exactly the
// question. That makes regexp an oracle for a verb it does not ship, over the
// whole grid, for precisely the patterns whose answer does not depend on the
// distinction - and the patterns whose answer DOES depend on it cannot use this
// oracle by construction, so they are their own test below.

import (
	"regexp"
	"slices"
	"testing"

	irgx "github.com/The-Billy-Company/irregex/bindings/go/v2"
)

// Patterns the oracle is competent at: assertion-free, so confining the match and
// cutting the text ask the same question, AND free of the perl classes, because
// stdlib's `\w` `\d` `\s` are ASCII-only where this engine's are Unicode by
// default (rg parity). `\w+` over "héllo" is [[0 6]] here and [[0 1] [3 6]] there,
// on the whole text with no window in sight - a divergence in what a class MEANS,
// which a window test has nothing to say about. `[a-z]+` and `[^x]` are the same
// question in both, and the probe agrees on them over every text below.
var windowPatterns = []string{"a", "x*", "", "a?", "bc", "[a-z]+", "b|abc", "a+b", "[^x]"}

var windowTexts = []string{"", "a", "abc", "aBaBa", "héllo", "ab\ncd", "a\n", "xxabxx"}

// cuts is every bound the slicing oracle is sound at: the character boundaries.
//
// The filter is the second way a slice is not a window, and it is easy to miss
// because it has nothing to do with assertions. Slicing does not merely move the
// edges, it RE-DECODES the bytes, and a cut inside a character changes which
// characters exist: "héllo"[1:2] is a lone 0xc3, which stdlib reads as one U+FFFD
// and matches `[^x]` against, while the same window over the real text contains
// no whole character at all and matches nothing. Both are right about their own
// question, so a mid-character cut is outside the oracle's competence rather than
// a disagreement, and it gets its own test below.
//
// utf8.RuneStart is not this predicate: it asks whether a byte COULD lead a
// character, and 0xc3 can, wherever it sits. Boundaries have to be walked.
func cuts(text string) []int {
	out := []int{}
	for at := range text { // ranging a string yields exactly the boundaries
		out = append(out, at)
	}
	return append(out, len(text))
}

func TestWindowConfinesTheMatchAndSlicingOraclesTheAssertionFreeHalf(t *testing.T) {
	for _, pattern := range windowPatterns {
		mine, theirs := irgx.MustCompile(pattern), regexp.MustCompile(pattern)
		for _, text := range windowTexts {
			bounds := cuts(text)
			for _, from := range bounds {
				for _, to := range bounds {
					if to < from {
						continue
					}
					got := mine.MatchStringIn(text, from, to)
					want := theirs.MatchString(text[from:to])
					if got != want {
						t.Errorf("MatchStringIn(%q, %q, %d, %d) = %v, want %v",
							pattern, text, from, to, got, want)
					}
				}
			}
		}
	}
}

func TestWindowedFindAgreesWithTheSlicedWalkOnOffsetsIntoTheWholeText(t *testing.T) {
	for _, pattern := range windowPatterns {
		mine, theirs := irgx.MustCompile(pattern), regexp.MustCompile(pattern)
		for _, text := range windowTexts {
			bounds := cuts(text)
			for _, from := range bounds {
				for _, to := range bounds {
					if to < from {
						continue
					}
					got := mine.FindAllStringIndexIn(text, from, to, -1)
					// Offsets are into the whole text, so the oracle's
					// window-relative ones are shifted to compare.
					want := theirs.FindAllStringIndex(text[from:to], -1)
					for _, loc := range want {
						loc[0] += from
						loc[1] += from
					}
					if !slices.EqualFunc(got, want, slices.Equal) {
						t.Errorf("FindAllStringIndexIn(%q, %q, %d, %d) = %v, want %v",
							pattern, text, from, to, got, want)
					}
				}
			}
		}
	}
}

func TestAWindowIsAByteRangeAndItsStartIsWhereDecodingBegins(t *testing.T) {
	// A window is bytes, like every offset in this package and like a Go slice
	// expression, so a bound may land inside a character and is not refused for
	// it. What it means is worth pinning, because it is the one place a window
	// and a slice DO agree and it would be easy to assume otherwise: decoding
	// starts at `from`, so the é's two bytes are read as an é.
	//
	// (The Rust binding refuses a non-boundary bound instead. That is not drift:
	// its text type is `&str`, where such a bound cannot be taken at all without
	// unsafe and `is_char_boundary` is the stdlib's own convention. Each binding
	// follows its host language's text domain - the same reason Python's offsets
	// are characters and these are bytes.)
	const text = "héllo" // é is bytes 1 and 2
	dot := irgx.MustCompile(".")
	if got := dot.FindAllStringIndexIn(text, 1, 3, -1); !slices.EqualFunc(got, [][]int{{1, 3}}, slices.Equal) {
		t.Errorf("from inside a character: got %v, want the é at [[1 3]]", got)
	}
	// But only a WHOLE character: half of one is invalid UTF-8, and this engine
	// does not substitute U+FFFD for it the way stdlib does. Nothing matches,
	// where the sliced oracle reports one replacement character.
	if got := dot.FindAllStringIndexIn(text, 1, 2, -1); got != nil {
		t.Errorf("half a character matched %v, want nothing", got)
	}
	if got := regexp.MustCompile(".").FindAllStringIndex(text[1:2], -1); len(got) != 1 {
		t.Fatalf("the contrast is stdlib's U+FFFD substitution, got %v", got)
	}
}

func TestAnAssertionReadsTheWholeTextNoMatterWhereTheWindowIs(t *testing.T) {
	// Each case is one where confining the match and cutting the text give
	// OPPOSITE answers, which is what makes the verb irreducible to a slice: the
	// assertion is still reading bytes the window does not contain.
	for _, c := range []struct {
		pattern, text string
		from, to      int
	}{
		// `$` and `\z` are still the real end, so a window stopping short of it
		// satisfies neither - where the slice "ab" would satisfy both.
		{"b$", "abc", 0, 2},
		{`b\z`, "abc", 0, 2},
		// `^` is still the real start, symmetrically.
		{"^b", "abc", 1, 3},
		// And `\b` still resolves against the byte outside the window: there is
		// no boundary inside "abc" at offset 1, though the slice "b" has two.
		{`\bb\b`, "abc", 1, 2},
	} {
		if irgx.MustCompile(c.pattern).MatchStringIn(c.text, c.from, c.to) {
			t.Errorf("%q should not match within %q[%d:%d]", c.pattern, c.text, c.from, c.to)
		}
		if !regexp.MustCompile(c.pattern).MatchString(c.text[c.from:c.to]) {
			t.Fatalf("the slice is the contrast, so %q must match %q",
				c.pattern, c.text[c.from:c.to])
		}
	}
}

func TestAWindowAdmitsAShorterMatchTheUnwindowedVerbWouldNeverReport(t *testing.T) {
	// Fitting is existence, not the leftmost match measured against the ceiling.
	word := irgx.MustCompile(`\w+`)
	if got := word.FindStringIndex("abcd"); !slices.Equal(got, []int{0, 4}) {
		t.Fatalf("FindStringIndex = %v, want [0 4]", got)
	}
	if !word.MatchStringIn("abcd", 0, 2) {
		t.Error(`\w+ should fit in [0,2) on the strength of "ab"`)
	}
	if !word.MatchStringIn("abcd", 0, 1) {
		t.Error(`\w+ should fit in [0,1)`)
	}
	if word.MatchStringIn("abcd", 0, 0) {
		t.Error(`\w+ cannot fit in an empty window`)
	}
}

func TestAnInertCeilingIsTheUnwindowedVerb(t *testing.T) {
	// Holds for every pattern, including the ones no slice can oracle.
	for _, pattern := range []string{"^b", `\bbc`, `\Bc`, "b$", `b\b`, `c\z`, "a", "x*", "", `\w+`, "."} {
		re := irgx.MustCompile(pattern)
		for _, text := range windowTexts {
			if got, want := re.MatchStringIn(text, 0, len(text)), re.MatchString(text); got != want {
				t.Errorf("an inert ceiling changed the answer for %q over %q: %v != %v",
					pattern, text, got, want)
			}
			got := re.FindAllStringIndexIn(text, 0, len(text), -1)
			want := re.FindAllStringIndex(text, -1)
			if !slices.EqualFunc(got, want, slices.Equal) {
				t.Errorf("an inert ceiling changed the walk for %q over %q: %v != %v",
					pattern, text, got, want)
			}
		}
	}
}

func TestWideningAWindowOnlyAdds(t *testing.T) {
	for _, pattern := range []string{"^b", `\bbc`, "b$", `b\b`, `c\z`, "a", "x*", "", `\w+`} {
		re := irgx.MustCompile(pattern)
		for _, text := range windowTexts {
			for from := 0; from <= len(text); from++ {
				for to := from; to < len(text); to++ {
					if re.MatchStringIn(text, from, to) && !re.MatchStringIn(text, from, to+1) {
						t.Errorf("widening lost a match: %q over %q, [%d,%d] matched but [%d,%d] did not",
							pattern, text, from, to, from, to+1)
					}
				}
			}
		}
	}
}

func TestAWindowedLimitCountsMatchesAndNotBytes(t *testing.T) {
	re := irgx.MustCompile("a")
	if got := re.FindAllStringIndexIn("aaaa", 0, 4, 2); !slices.EqualFunc(got, [][]int{{0, 1}, {1, 2}}, slices.Equal) {
		t.Errorf("n=2 = %v, want the first two", got)
	}
	if got := re.FindAllStringIndexIn("aaaa", 1, 3, -1); !slices.EqualFunc(got, [][]int{{1, 2}, {2, 3}}, slices.Equal) {
		t.Errorf("n=-1 = %v, want both inside the window", got)
	}
	if got := re.FindAllStringIndexIn("aaaa", 0, 4, 0); got != nil {
		t.Errorf("n=0 = %v, want nil", got)
	}
}

func TestABadWindowPanicsLikeASliceExpression(t *testing.T) {
	re := irgx.MustCompile("a")
	for _, c := range []struct{ from, to int }{{2, 1}, {0, 4}, {-1, 2}, {4, 4}} {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("window [%d:%d] of a 3-byte text should panic", c.from, c.to)
				}
			}()
			re.MatchStringIn("abc", c.from, c.to)
		}()
	}
}

func TestTheByteAndStringWindowedVerbsAgree(t *testing.T) {
	re := irgx.MustCompile(`\w+`)
	for _, text := range windowTexts {
		for from := 0; from <= len(text); from++ {
			for to := from; to <= len(text); to++ {
				if s, b := re.MatchStringIn(text, from, to), re.MatchIn([]byte(text), from, to); s != b {
					t.Errorf("%q[%d:%d]: string %v != bytes %v", text, from, to, s, b)
				}
				s := re.FindAllStringIndexIn(text, from, to, -1)
				b := re.FindAllIndexIn([]byte(text), from, to, -1)
				if !slices.EqualFunc(s, b, slices.Equal) {
					t.Errorf("%q[%d:%d]: string %v != bytes %v", text, from, to, s, b)
				}
			}
		}
	}
}

func TestWindowsIsAPropertyOfThePatternsEngine(t *testing.T) {
	// The linear engine windows; every pattern this package compiles by default
	// is on it.
	for _, pattern := range []string{"a", "^b", "b$", `\w+`, `c\z`, ""} {
		if !irgx.MustCompile(pattern).Windows() {
			t.Errorf("%q should window", pattern)
		}
	}
}
