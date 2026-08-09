//go:build cgo

package irgx_test

// The needle plane, against `strings` - which is a genuine oracle here, because
// "which of these literals occur where" is a question the stdlib answers by a
// completely different method (a naive scan) than the tiered machines behind this
// plane (memmem, a literal set, Aho-Corasick). Same question, unrelated
// implementations, so a disagreement is a real defect in one of them.
//
// The tier the engine picked is deliberately NOT asserted as a fixed value: it
// is a planning decision the engine is free to improve, and a test that pinned
// it would fail on an optimization. What is asserted is that the ANSWER does not
// depend on which tier answered - checked by driving the same probes through set
// sizes that cross every tier boundary.

import (
	"slices"
	"strings"
	"testing"

	irgx "github.com/The-Billy-Company/irregex/bindings/go/v2"
)

var needleTexts = []string{
	"", "a", "abc", "the quick brown fox", "aaaa", "abcabcabc",
	"héllo wörld", "ABC", "xyz", "\x00abc\x00", strings.Repeat("ab", 200) + "needle",
}

// occurrences is every start of needle in text, INCLUDING overlaps - which is the
// question this plane answers and the one `strings.Count` does not.
func occurrences(text, needle string) []int {
	if needle == "" {
		return nil
	}
	out := []int{}
	for i := 0; i+len(needle) <= len(text); i++ {
		if text[i:i+len(needle)] == needle {
			out = append(out, i)
		}
	}
	return out
}

// needleSets crosses the tier boundaries: one needle (memmem), a handful (a
// literal set), and enough to reach the automaton.
var needleSets = [][]string{
	{"abc"},
	{"abc", "xyz"},
	{"a", "ab", "abc"}, // nested, so attribution cannot be resolved by length
	{"the", "quick", "brown", "fox", "lazy", "dog"},
	{"aa"}, // overlapping in "aaaa": 0, 1, 2
	{"héllo", "wörld"},
	{"\x00abc"},
	{"needle", "ab"},
	strings.Fields("alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon"),
}

func TestFindAllIsEveryOccurrenceOfEveryNeedleIncludingOverlaps(t *testing.T) {
	for _, list := range needleSets {
		set, err := irgx.CompileNeedles(list...)
		if err != nil {
			t.Fatalf("CompileNeedles(%q): %v", list, err)
		}
		// No partial-set escape here: a compile that returned seats every needle
		// it was given, so the oracle below covers the whole list or nothing did.
		if got := set.Len(); got != len(list) {
			t.Fatalf("CompileNeedles(%q) seated %d of %d", list, got, len(list))
		}
		for _, text := range needleTexts {
			want := []irgx.Occurrence{}
			for i, needle := range list {
				for _, at := range occurrences(text, needle) {
					want = append(want, irgx.Occurrence{Needle: i, Start: at, End: at + len(needle)})
				}
			}
			got := slices.Clone(set.FindAllString(text))
			// Report order is the engine's business; the SET of hits is the answer.
			cmp := func(a, b irgx.Occurrence) int {
				if a.Start != b.Start {
					return a.Start - b.Start
				}
				return a.Needle - b.Needle
			}
			slices.SortFunc(got, cmp)
			slices.SortFunc(want, cmp)
			if !slices.Equal(got, want) {
				t.Errorf("FindAll(%q, %q) = %v, want %v", list, text, got, want)
			}
		}
		set.Close()
	}
}

func TestMatchAndWhichAgreeWithFindAllAndWithStrings(t *testing.T) {
	for _, list := range needleSets {
		set, err := irgx.CompileNeedles(list...)
		if err != nil {
			t.Fatalf("CompileNeedles(%q): %v", list, err)
		}
		if got := set.Len(); got != len(list) {
			t.Fatalf("CompileNeedles(%q) seated %d of %d", list, got, len(list))
		}
		for _, text := range needleTexts {
			wantAny := slices.ContainsFunc(list, func(n string) bool { return strings.Contains(text, n) })
			if got := set.MatchString(text); got != wantAny {
				t.Errorf("Match(%q, %q) = %v, want %v", list, text, got, wantAny)
			}
			want := []int{}
			for i, needle := range list {
				if strings.Contains(text, needle) {
					want = append(want, i)
				}
			}
			got := slices.Clone(set.WhichString(text))
			slices.Sort(got)
			if !slices.Equal(got, want) {
				t.Errorf("Which(%q, %q) = %v, want %v", list, text, got, want)
			}
			// The three verbs are three views of one answer, so they cannot
			// disagree with each other either - presence and attribution are
			// sometimes different machines, and this is where that shows.
			if (len(got) > 0) != set.MatchString(text) {
				t.Errorf("Which said %v but Match said %v for %q", got, set.MatchString(text), text)
			}
			for _, occ := range set.FindAllString(text) {
				if !slices.Contains(got, occ.Needle) {
					t.Errorf("FindAll attributed a hit to needle %d, which Which did not list", occ.Needle)
				}
			}
		}
		set.Close()
	}
}

// A needle index is an index into the list AS GIVEN. That only becomes visible
// with duplicates, where two indices are the same bytes: a machine that
// deduplicated internally and forgot to fan the attribution back out would
// report one of them and lose the other.
func TestDuplicateNeedlesKeepTheirOwnIndices(t *testing.T) {
	set, err := irgx.CompileNeedles("ab", "ab", "b")
	if err != nil {
		t.Fatalf("CompileNeedles: %v", err)
	}
	defer set.Close()
	which := slices.Clone(set.WhichString("xaby"))
	slices.Sort(which)
	if want := []int{0, 1, 2}; !slices.Equal(which, want) {
		t.Errorf("Which(\"xaby\") = %v, want %v - every index that matches, not one per distinct needle", which, want)
	}
}

// An empty needle is not a needle: it "occurs" at every offset, which would make
// every text a hit and every prefilter useless. The refusal names the offending
// index, because a wordlist read from a file has a blank line in it eventually.
func TestAnEmptyNeedleAndAnEmptySetAreRefused(t *testing.T) {
	for _, list := range [][]string{{}, {""}, {"abc", ""}, {"a", "", "c"}} {
		set, err := irgx.CompileNeedles(list...)
		if err == nil {
			set.Close()
			t.Errorf("CompileNeedles(%q) succeeded, want a refusal", list)
		}
	}
	if _, err := irgx.CompileNeedles("abc", ""); err == nil || !strings.Contains(err.Error(), "1") {
		t.Errorf("the refusal for a blank needle 1 was %v; it should name the index", err)
	}
}

// Shape describes the set, and the parts that are arithmetic over the input can
// be checked exactly. The tiers are not asserted - that is the planner's choice -
// but a tier of NONE alongside a non-empty set would be a machine that cannot
// answer, so the pair still has a floor.
func TestShapeMeasuresTheSetItWasBuiltFrom(t *testing.T) {
	list := []string{"alpha", "be", "gamma!"}
	set, err := irgx.CompileNeedles(list...)
	if err != nil {
		t.Fatalf("CompileNeedles: %v", err)
	}
	defer set.Close()
	shape := set.Shape()
	if shape.Count != set.Len() {
		t.Errorf("Shape().Count = %d but Len() = %d", shape.Count, set.Len())
	}
	// Unconditional: the set seats every needle or the compile above failed, so
	// the whole list is what Shape has to be measuring.
	if want := len(list); shape.Count != want {
		t.Errorf("Shape().Count = %d, want %d", shape.Count, want)
	}
	wantBytes, wantLongest := 0, 0
	for _, s := range list {
		wantBytes += len(s)
		wantLongest = max(wantLongest, len(s))
	}
	if shape.Bytes != wantBytes || shape.Longest != wantLongest {
		t.Errorf("Shape() = %d bytes / longest %d, want %d / %d",
			shape.Bytes, shape.Longest, wantBytes, wantLongest)
	}
	if shape.PresenceTier == irgx.TierNone || shape.AttributedTier == irgx.TierNone {
		t.Errorf("a seated set reports tier NONE: %+v", shape)
	}
}

func TestByteAndStringNeedleDoorsAgree(t *testing.T) {
	set, err := irgx.CompileNeedles("abc", "b")
	if err != nil {
		t.Fatalf("CompileNeedles: %v", err)
	}
	defer set.Close()
	for _, text := range needleTexts {
		if got, want := set.Match([]byte(text)), set.MatchString(text); got != want {
			t.Errorf("Match(%q) = %v, MatchString = %v", text, got, want)
		}
		if got, want := set.Which([]byte(text)), set.WhichString(text); !slices.Equal(got, want) {
			t.Errorf("Which(%q) = %v, WhichString = %v", text, got, want)
		}
		if got, want := set.FindAll([]byte(text)), set.FindAllString(text); !slices.Equal(got, want) {
			t.Errorf("FindAll(%q) = %v, FindAllString = %v", text, got, want)
		}
	}
}

func TestClosingNeedlesTwiceIsHarmless(t *testing.T) {
	set, err := irgx.CompileNeedles("abc")
	if err != nil {
		t.Fatalf("CompileNeedles: %v", err)
	}
	set.Close()
	set.Close()
}
