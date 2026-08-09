//go:build cgo

package irgx_test

// What a lexer slate must answer: the longest reading at the cursor, and whose.
//
// stdlib regexp has no counterpart to a munch, but it has a counterpart to the
// QUESTION. `^(?:terminal)` matched at a cursor with regexp.FindStringIndex over
// the remaining text is one terminal's reading of that cursor, and the maximum
// over the terminals is the maximal munch by definition. Slow and obviously
// correct, which is what an oracle is for.
//
// stdlib regexp is leftmost-FIRST for an alternation but leftmost-longest is not
// what a single anchored terminal needs here: each terminal is asked alone, so
// its own greedy reading is its reach, and the longest-wins comparison happens in
// the oracle rather than inside a pattern.

import (
	"regexp"
	"slices"
	"strings"
	"testing"

	irgx "github.com/The-Billy-Company/irregex/bindings/go/v2"
)

// terminals in the shapes a real lexer has: a keyword that is also an identifier
// (the tie), two overlapping numeric readings (the longest wins), a nullable
// terminal (the empty-token hazard), and a non-ASCII literal.
var terminals = []string{
	"if", "[a-z]+", "[0-9]+", "[0-9]+[.][0-9]+", `\s+`, "x*", "héllo", "==", "=",
}

var lexTexts = []string{
	"", "if", "iffy", "if x", "42", "3.14", "3.", "a==b", "a=b",
	"héllo wörld", "\t\n ", "qqq", "x", "if42",
}

// munchAt is the maximal munch at `at`, computed with stdlib regexp.
func munchAt(t *testing.T, text string, at int) (int, []int) {
	t.Helper()
	best, winners := -1, []int(nil)
	for i, terminal := range terminals {
		// Anchored at the cursor by construction: the pattern must match at the
		// start of what remains, which is exactly what a munch scan asks.
		rx := regexp.MustCompile(`^(?:` + terminal + `)`)
		loc := rx.FindStringIndex(text[at:])
		if loc == nil {
			continue
		}
		switch reach := loc[1]; {
		case reach > best:
			best, winners = reach, []int{i}
		case reach == best:
			winners = append(winners, i)
		}
	}
	return best, winners
}

func TestMunchReadsEveryCursorAsStdlibReadsIt(t *testing.T) {
	lex := irgx.MustCompileMunch(terminals...)
	if got := lex.Len(); got != len(terminals) {
		t.Fatalf("seated %d of %d terminals, declined %v", got, len(terminals), lex.Declined())
	}
	for _, text := range lexTexts {
		// Every position including len(text), which asks the only question left
		// at the end of the input: does anything accept the empty string.
		for at := 0; at <= len(text); at++ {
			tok, ok := lex.Scan(text, at)
			length, winners := munchAt(t, text, at)
			if length < 0 {
				if ok {
					t.Errorf("Scan(%q, %d) = %+v, want no match", text, at, tok)
				}
				continue
			}
			if !ok {
				t.Errorf("Scan(%q, %d) found nothing, want length %d %v", text, at, length, winners)
				continue
			}
			if tok.Length != length || !slices.Equal(tok.Patterns, winners) {
				t.Errorf("Scan(%q, %d) = (%d, %v), want (%d, %v)",
					text, at, tok.Length, tok.Patterns, length, winners)
			}
		}
	}
}

func TestMunchReportsTheWholeTieRatherThanResolvingIt(t *testing.T) {
	// `if` is the keyword AND an identifier, and both reach length 2. Which one
	// a lexer wants is its own business - precedence by declaration order,
	// usually - so the engine names both instead of inventing a winner. A single
	// answer here would make keyword recognition impossible.
	lex := irgx.MustCompileMunch("if", "[a-z]+")
	tok, ok := lex.Scan("if", 0)
	if !ok || tok.Length != 2 || !slices.Equal(tok.Patterns, []int{0, 1}) {
		t.Fatalf("Scan(%q) = (%+v, %v), want length 2 winners [0 1]", "if", tok, ok)
	}
}

func TestMunchTakesTheLongestReading(t *testing.T) {
	lex := irgx.MustCompileMunch("=", "==", "[0-9]+", "[0-9]+[.][0-9]+")
	for _, c := range []struct {
		text string
		want int
	}{{"==", 2}, {"=", 1}, {"3.14", 4}, {"3", 1}} {
		if tok, ok := lex.Scan(c.text, 0); !ok || tok.Length != c.want {
			t.Errorf("Scan(%q) = (%+v, %v), want length %d", c.text, tok, ok, c.want)
		}
	}
}

func TestMunchLexesAWholeInputForward(t *testing.T) {
	// The loop the type exists for, and the property that matters about it:
	// every byte is accounted for exactly once, so a lexer built on this cannot
	// silently skip input.
	lex := irgx.MustCompileMunch("[a-z]+", "[0-9]+", `\s+`, `[=+]`)
	const src = "ab 12 + cd=3"
	var out strings.Builder
	for at := 0; at < len(src); {
		tok, ok := lex.Scan(src, at)
		if !ok {
			t.Fatalf("nothing accepted at byte %d of %q", at, src)
		}
		if tok.Length == 0 {
			t.Fatalf("empty token at byte %d would not advance", at)
		}
		out.WriteString(src[at : at+tok.Length])
		at += tok.Length
	}
	if out.String() != src {
		t.Errorf("lexed %q, want every byte of %q", out.String(), src)
	}
}

func TestMunchShortestIsTheOtherReadingOfTheSameCursor(t *testing.T) {
	lex := irgx.MustCompileMunch("[a-z]+", "x*")
	if tok, _ := lex.Scan("iffy", 0); tok.Length != 4 {
		t.Errorf("longest = %d, want 4", tok.Length)
	}
	// Shortest skips the empty reading, or a nullable terminal would answer zero
	// at every cursor and no lexer could use the verb.
	tok, ok := lex.ScanShortest("iffy", 0)
	if !ok || tok.Length != 1 {
		t.Errorf("shortest = (%+v, %v), want length 1", tok, ok)
	}
}

func TestMunchAllowRestrictsOneCallAndNotTheSlate(t *testing.T) {
	// Context-sensitive lexing without a compile per context, and it must not
	// leak into the next call.
	lex := irgx.MustCompileMunch("==", "=")
	if tok, _ := lex.Scan("==", 0); tok.Length != 2 {
		t.Errorf("unrestricted = %d, want 2", tok.Length)
	}
	// Forbidding `==` does not leave a hole: the scan re-runs under the
	// restriction, so `=` wins at length 1.
	tok, ok := lex.ScanAmong("==", 0, []int{1})
	if !ok || tok.Length != 1 || !slices.Equal(tok.Patterns, []int{1}) {
		t.Errorf("restricted = (%+v, %v), want length 1 winner [1]", tok, ok)
	}
	if tok, _ := lex.Scan("==", 0); tok.Length != 2 {
		t.Errorf("the restriction leaked into the next call: %d", tok.Length)
	}
	if _, ok := lex.ScanAmong("==", 0, []int{}); ok {
		t.Error("permitting nothing should match nothing")
	}
	if tok, ok := lex.ScanShortestAmong("==", 0, []int{0}); !ok || tok.Length != 2 {
		t.Errorf("shortest among = (%+v, %v), want length 2", tok, ok)
	}
}

func TestMunchSeatsWhatItCanAndSaysWhatItCouldNot(t *testing.T) {
	// The policy that makes this a different type from Set: a hundred and fifty
	// terminals where one is outside the linear grammar is a working lexer, and
	// erroring would make the fallback path the common path.
	lex, err := irgx.CompileMunch("ok", `(a)\1`, `\Ab`, `x\z`, `\bword`)
	if err != nil {
		t.Fatalf("a partial refusal must not be an error: %v", err)
	}
	if lex.Len() != 1 || len(lex.Patterns()) != 5 {
		t.Errorf("seated %d of %d", lex.Len(), len(lex.Patterns()))
	}
	want := []irgx.Refusal{
		{Pattern: 1, Why: irgx.WhySyntax},
		{Pattern: 2, Why: irgx.WhyBufferAnchor},
		{Pattern: 3, Why: irgx.WhyBufferAnchor},
		{Pattern: 4, Why: irgx.WhyWordContext},
	}
	if !slices.Equal(lex.Declined(), want) {
		t.Errorf("declined = %v, want %v", lex.Declined(), want)
	}
	// And the terminal that WAS seated still lexes, which is the point.
	if tok, ok := lex.Scan("ok", 0); !ok || tok.Length != 2 {
		t.Errorf("the seated terminal stopped working: (%+v, %v)", tok, ok)
	}
}

func TestMunchDistinguishesAWallFromABudget(t *testing.T) {
	// Two reasons a caller acts on differently: WhyStates says a bigger build
	// would take this terminal, WhyBufferAnchor that none ever will.
	if irgx.WhyStates == irgx.WhyBufferAnchor {
		t.Fatal("a budget and a wall must not be the same value")
	}
	lex := irgx.MustCompileMunch("a", `\Ab`)
	want := []irgx.Refusal{{Pattern: 1, Why: irgx.WhyBufferAnchor}}
	if !slices.Equal(lex.Declined(), want) {
		t.Errorf("declined = %v, want %v", lex.Declined(), want)
	}
	if got := lex.Declined()[0].String(); got != "terminal 1: buffer anchor" {
		t.Errorf("Refusal.String() = %q", got)
	}
	// A reason a newer engine reports says so rather than lying about which it is.
	if got := irgx.Why(99).String(); !strings.Contains(got, "unknown") {
		t.Errorf("Why(99).String() = %q, want it to admit it is unknown", got)
	}
}

func TestMunchWithNothingSeatedIsAnError(t *testing.T) {
	// No handle exists to read reasons from, so this is the one case that cannot
	// be a partial success.
	if _, err := irgx.CompileMunch(`(a)\1`); err == nil {
		t.Fatal("a slate that seated nothing must not compile")
	}
}

func TestMunchOfNoTerminalsMatchesNothing(t *testing.T) {
	lex := irgx.MustCompileMunch()
	if lex.Len() != 0 || lex.Declined() != nil {
		t.Errorf("empty slate: len %d declined %v", lex.Len(), lex.Declined())
	}
	if _, ok := lex.Scan("anything", 3); ok {
		t.Error("an empty slate matched something")
	}
}

func TestMunchCursorBounds(t *testing.T) {
	lex := irgx.MustCompileMunch("[a-z]+", "x*")
	// The end itself is legal, and answers about the empty string.
	if tok, ok := lex.Scan("if", 2); !ok || tok.Length != 0 {
		t.Errorf("Scan at the end = (%+v, %v), want an empty match", tok, ok)
	}
	for _, at := range []int{-1, 3} {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("cursor %d should panic like a slice expression", at)
				}
			}()
			lex.Scan("if", at)
		}()
	}
}

func TestMunchBytesAgreesWithString(t *testing.T) {
	lex := irgx.MustCompileMunch(`\w+`, `\s+`)
	for _, text := range lexTexts {
		for at := 0; at <= len(text); at++ {
			s, sok := lex.Scan(text, at)
			b, bok := lex.ScanBytes([]byte(text), at)
			if sok != bok || s.Length != b.Length || !slices.Equal(s.Patterns, b.Patterns) {
				t.Errorf("%q at %d: string (%+v,%v) != bytes (%+v,%v)", text, at, s, sok, b, bok)
			}
		}
	}
}

func TestMunchFlagsAreTheSlatesAndNotATerminals(t *testing.T) {
	// A munch determinizes every terminal together, so there is nowhere to put
	// "terminal 3 is case-insensitive" - the flag is the slate's.
	folded := irgx.CompileOpts{IgnoreCase: true}.MustCompileMunch("if", "[a-z]+")
	if tok, ok := folded.Scan("IF", 0); !ok || tok.Length != 2 {
		t.Errorf("IgnoreCase slate = (%+v, %v), want length 2", tok, ok)
	}
	if _, ok := irgx.MustCompileMunch("if").Scan("IF", 0); ok {
		t.Error("the default slate folded case")
	}
	// DotAll is carried, because it IS observable at an anchored cursor.
	if _, ok := irgx.MustCompileMunch(".").Scan("\n", 0); ok {
		t.Error("`.` matched a newline without DotAll")
	}
	if _, ok := (irgx.CompileOpts{DotAll: true}).MustCompileMunch(".").Scan("\n", 0); !ok {
		t.Error("DotAll did not reach the terminal")
	}
	// MultiLine is refused rather than ignored: it asks for the line-anchor
	// reading, which an anchored scan cannot observe either way.
	if _, err := (irgx.CompileOpts{MultiLine: true}).CompileMunch("a"); err == nil {
		t.Error("MultiLine should be refused on a munch")
	}
}

func TestMunchStringNamesItsTerminals(t *testing.T) {
	if got := irgx.MustCompileMunch("a", `\s+`).String(); got != `["a" "\\s+"]` {
		t.Errorf("String() = %s", got)
	}
}
