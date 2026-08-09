//go:build cgo

package irgx_test

// The literal plane, against the strongest oracle available to it: Go's own
// Unicode tables. `unicode.SimpleFold` walks the same simple-fold orbits this
// engine folds with, and `unicode.Greek`/`unicode.Nd`/`unicode.L` are the same
// properties by the same names, so the table verbs can be checked against a
// second independent implementation rather than against themselves.
//
// The promise verbs have no such oracle - no stdlib extracts a prefilter from a
// pattern - so they are checked as the SOUNDNESS property they actually claim:
// whatever the promise admits must be a superset of what the engine matches.
// That is the only assertion worth making about a prefilter, because it is the
// one whose violation loses a match.

import (
	"slices"
	"testing"
	"unicode"

	irgx "github.com/The-Billy-Company/irregex/bindings/go/v2"
)

// orbit is the fold class of r per the stdlib, sorted so the comparison is
// order-free - a cycle has no first element.
func orbit(r rune) []rune {
	out := []rune{r}
	for f := unicode.SimpleFold(r); f != r; f = unicode.SimpleFold(f) {
		out = append(out, f)
	}
	slices.Sort(out)
	return out
}

// The engine's tables and the stdlib's are usually different Unicode editions,
// so the sound comparison is one-directional. Unicode's Case_Folding stability
// policy freezes an assigned codepoint's fold once it ships, and a newer edition
// only ADDS codepoints - so every orbit the older stdlib knows must survive
// intact in the engine, while the engine may know orbits the stdlib has never
// heard of. Subset, therefore, not equality: the direction that holds across
// editions is still a real oracle, and the direction that does not is where new
// assignments live.
func TestFoldOrbitContainsEveryFoldTheStdlibKnows(t *testing.T) {
	for _, r := range []rune{
		'a', 'z', 'A', 'Z', '0', '_', ' ', 0x7f, // ASCII, folding and not
		'k', 'K', 0x212a, // the KELVIN class: the case a ±0x20 host gets wrong
		's', 'S', 0x17f, // long s
		0x3c3, 0x3c2, 0x3a3, // sigma, final sigma, capital sigma
		0xdf, 0x1e9e, // sharp s: simple folding leaves SS out of this orbit
		'é', 'É', 0x130, 0x131, // dotted/dotless I
		0x10400, 0x10428, // Deseret, above the BMP
		0x4e00, unicode.MaxRune, // uncased, and the top of the range
	} {
		got := irgx.FoldOrbit(r)
		if !slices.Contains(got, r) {
			t.Errorf("FoldOrbit(%q) = %U, which omits %U itself", r, got, r)
		}
		for _, want := range orbit(r) {
			if !slices.Contains(got, want) {
				t.Errorf("FoldOrbit(%q) = %U, missing %U which the stdlib folds with it", r, got, want)
			}
		}
	}
}

// An orbit is an equivalence class, so it has to be closed: every member's own
// orbit is the same set. A table that mapped only "up" would pass a spot check
// on 'k' and fail here on U+212A.
func TestFoldOrbitsAreClosedUnderThemselves(t *testing.T) {
	for _, seed := range []rune{'k', 0x212a, 0x3c2, 0x1e9e, 0x131} {
		want := slices.Clone(irgx.FoldOrbit(seed))
		slices.Sort(want)
		for _, member := range want {
			got := slices.Clone(irgx.FoldOrbit(member))
			slices.Sort(got)
			if !slices.Equal(got, want) {
				t.Errorf("orbit of %U is %U but orbit of its member %U is %U", seed, want, member, got)
			}
		}
	}
}

func TestFoldOrbitPanicsOutsideTheCodepointRange(t *testing.T) {
	for _, cp := range []rune{-1, unicode.MaxRune + 1} {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("FoldOrbit(%d) did not panic", cp)
				}
			}()
			irgx.FoldOrbit(cp)
		}()
	}
}

// Same one-directional reading as the fold orbits, and for the same reason: a
// codepoint the older stdlib places in a script or category must still be there
// in the newer edition, while the newer edition assigns codepoints the stdlib
// leaves out. So the assertion is containment - and it is the assertion with
// teeth anyway, since a class the engine has NARROWED is a pattern that silently
// stops matching text it used to.
func TestPropertyRangesContainEveryCodepointTheStdlibAssigns(t *testing.T) {
	for name, table := range map[string]*unicode.RangeTable{
		"Greek": unicode.Greek, "Cyrillic": unicode.Cyrillic, "Han": unicode.Han,
		"Nd": unicode.Nd, "Lu": unicode.Lu, "Ll": unicode.Ll, "Zs": unicode.Zs,
	} {
		ranges, err := irgx.PropertyRanges(name)
		if err != nil {
			t.Errorf("PropertyRanges(%q): %v", name, err)
			continue
		}
		// Ascending, non-overlapping, non-adjacent - the header's own claim, and
		// the shape a binary search over the ranges needs.
		for i, r := range ranges {
			if r.Lo > r.Hi {
				t.Errorf("%s range %d is inverted: %U..%U", name, i, r.Lo, r.Hi)
			}
			if i > 0 && r.Lo <= ranges[i-1].Hi+1 {
				t.Errorf("%s range %d (%U..%U) touches or overlaps %d (%U..%U)",
					name, i, r.Lo, r.Hi, i-1, ranges[i-1].Lo, ranges[i-1].Hi)
			}
		}
		holds := func(cp rune) bool {
			return slices.ContainsFunc(ranges, func(q irgx.RuneRange) bool { return q.Lo <= cp && cp <= q.Hi })
		}
		// Every codepoint the stdlib assigns to this property, checked against the
		// engine's ranges - free, since the ranges are already in Go memory.
		for cp := rune(0); cp <= unicode.MaxRune; cp++ {
			if unicode.Is(table, cp) && !holds(cp) {
				t.Errorf("%s: the stdlib assigns %U, the engine's ranges do not", name, cp)
			}
		}
		// PropertyHas is a binary search over the same table, so it must answer
		// exactly what the materialized ranges say - at both edges of every range
		// and one codepoint outside them, which is where an off-by-one lives.
		for _, r := range ranges {
			for _, cp := range []rune{r.Lo - 1, r.Lo, r.Hi, r.Hi + 1} {
				if cp < 0 || cp > unicode.MaxRune {
					continue
				}
				has, err := irgx.PropertyHas(name, cp)
				if err != nil {
					t.Fatalf("PropertyHas(%q, %U): %v", name, cp, err)
				}
				if has != holds(cp) {
					t.Errorf("%s: PropertyHas(%U) = %v but its own ranges say %v", name, cp, has, holds(cp))
				}
			}
		}
	}
}

// Property names are matched the way UAX #44 says to match them - case, spaces,
// hyphens and underscores ignored, with `gc=`/`sc=` keys accepted - so a pattern
// written `\p{General_Category=Nd}` and one written `\p{nd}` name one class. A
// binding that pre-validated names against a hardcoded list would break the half
// of these spellings it had never heard of.
func TestPropertyNamesMatchLoosely(t *testing.T) {
	nd, err := irgx.PropertyRanges("Nd")
	if err != nil {
		t.Fatalf("PropertyRanges(\"Nd\"): %v", err)
	}
	for _, spelling := range []string{"nd", "ND", "Nd ", " nd", "gc=Nd", "General_Category=Nd", "decimalnumber"} {
		got, err := irgx.PropertyRanges(spelling)
		if err != nil {
			t.Errorf("PropertyRanges(%q): %v", spelling, err)
			continue
		}
		if !slices.Equal(got, nd) {
			t.Errorf("PropertyRanges(%q) named a different class than \"Nd\"", spelling)
		}
	}
	// "Any" is the whole range, and the one property that is not in the table.
	if got, err := irgx.PropertyRanges("Any"); err != nil || len(got) == 0 || got[0].Lo != 0 {
		t.Errorf("PropertyRanges(\"Any\") = %v, %v; want the whole codepoint range", got, err)
	}
}

// A misspelled property is an error, not an empty class: silently answering
// "nothing is in Grek" turns a typo into a pattern that quietly never matches.
func TestAnUnknownPropertyIsAnErrorRatherThanAnEmptyClass(t *testing.T) {
	// An unrecognized KEY fails closed too: `xx=Greek` names a property form this
	// engine does not implement, and answering Greek anyway would be a guess.
	for _, name := range []string{"", "Grek", "NotAProperty", "xx=Greek", "gc=NotACategory"} {
		if ranges, err := irgx.PropertyRanges(name); err == nil {
			t.Errorf("PropertyRanges(%q) = %d ranges, want an error", name, len(ranges))
		}
		if has, err := irgx.PropertyHas(name, 'a'); err == nil {
			t.Errorf("PropertyHas(%q, 'a') = %v, want an error", name, has)
		}
	}
}

// The property that matters about a prefilter: it may over-admit, never
// under-admit. If the first-byte set rejects a byte some matching text starts
// with, that text is never searched and the match is lost.
func TestThePromiseNeverRejectsAByteAMatchCanStartWith(t *testing.T) {
	texts := []string{"", "a", "abc", "xxabcxx", "ABC", "héllo", "a\nb", "zzz", "kelvin", "K"}
	for _, pattern := range []string{
		"abc", "a+bc", "(?i)abc", "foo|bar", "[a-z]+", "^abc$", "a.c",
		"x*", "", "(?i)k", "hé.lo", "abc|abd|xyz",
	} {
		re := irgx.MustCompile(pattern)
		lits, err := re.Literals()
		if err != nil {
			t.Fatalf("Literals(%q): %v", pattern, err)
		}
		promise := lits.Promise()
		for _, text := range texts {
			span := re.FindStringIndex(text)
			if span == nil {
				continue
			}
			if span[0] < len(text) && !promise.MayStartWith(text[span[0]]) {
				t.Errorf("%q matched %q at %d but the promise rejects the byte %q there",
					pattern, text, span[0], text[span[0]])
			}
			// A REQUIRED literal is a literal every match contains, so a match
			// whose text holds none of them means the extraction over-claimed.
			set, verdict := lits.Set(irgx.PlaceRequired)
			if verdict.Eliminates() && len(set) > 0 {
				matched := text[span[0]:span[1]]
				found := slices.ContainsFunc(set, func(lit string) bool {
					return substrings(matched, lit)
				})
				if !found {
					t.Errorf("%q claims every match contains one of %q, but %q does not",
						pattern, set, matched)
				}
			}
		}
		lits.Close()
	}
}

// substrings is Contains without importing strings for one call - and it is the
// literal question the REQUIRED claim makes.
func substrings(hay, needle string) bool {
	for i := 0; i+len(needle) <= len(hay); i++ {
		if hay[i:i+len(needle)] == needle {
			return true
		}
	}
	return false
}

// A verdict that eliminates has to come with something to eliminate BY, and an
// EXACT set is the pattern's whole language - anything in it must match.
func TestAnExactSetIsTheWholeLanguageAndAWholeMatchIsTheWholeText(t *testing.T) {
	for _, pattern := range []string{"abc", "foo|bar", "(?i)ab"} {
		re := irgx.MustCompile(pattern)
		lits, err := re.Literals()
		if err != nil {
			t.Fatalf("Literals(%q): %v", pattern, err)
		}
		for _, place := range []irgx.Place{irgx.PlaceRequired, irgx.PlacePrefix, irgx.PlaceSuffix, irgx.PlaceWhole} {
			set, verdict := lits.Set(place)
			if verdict.Eliminates() && len(set) == 0 {
				t.Errorf("%q: %s verdict is %s but the set is empty", pattern, place, verdict)
			}
			if verdict == irgx.VerdictExact {
				for _, lit := range set {
					if !re.MatchString(lit) {
						t.Errorf("%q: %s is EXACT and lists %q, which does not match", pattern, place, lit)
					}
				}
			}
			if place == irgx.PlaceWhole && verdict == irgx.VerdictExact {
				for _, lit := range set {
					if span := re.FindStringIndex(lit); span == nil || span[0] != 0 || span[1] != len(lit) {
						t.Errorf("%q: WHOLE lists %q, which is not a whole match (%v)", pattern, lit, span)
					}
				}
			}
		}
		lits.Close()
	}
}

// Nullable is the property that decides whether an empty text can be skipped, so
// a wrong answer is a lost match. The engine itself is the oracle: a pattern
// matches the empty string iff it is nullable.
func TestNullableAndAnchoredDescribeThePatternTheyCameFrom(t *testing.T) {
	for _, c := range []struct{ pattern string }{
		{"abc"}, {"a*"}, {""}, {"a?"}, {"^abc"}, {"^"}, {"x*y*"}, {"(a|)"},
	} {
		re := irgx.MustCompile(c.pattern)
		lits, err := re.Literals()
		if err != nil {
			t.Fatalf("Literals(%q): %v", c.pattern, err)
		}
		promise := lits.Promise()
		if want := re.MatchString(""); promise.Nullable != want {
			t.Errorf("%q: Nullable = %v, but matching the empty string is %v", c.pattern, promise.Nullable, want)
		}
		// Anchored is a claim about where a match may start: if it holds, no match
		// may begin past the start of the text.
		if promise.Anchored {
			if span := re.FindStringIndex("zzabc"); span != nil && span[0] != 0 {
				t.Errorf("%q claims anchored but matched %q at %d", c.pattern, "zzabc", span[0])
			}
		}
		lits.Close()
	}
}

// Closing twice is what a deferred Close plus an explicit one does, and it has to
// be harmless rather than a double free.
func TestClosingLiteralsTwiceIsHarmless(t *testing.T) {
	lits, err := irgx.MustCompile("abc").Literals()
	if err != nil {
		t.Fatalf("Literals: %v", err)
	}
	lits.Close()
	lits.Close()
}
