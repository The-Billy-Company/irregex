package irgx_test

import (
	"errors"
	"math/rand"
	"reflect"
	"regexp"
	"strings"
	"testing"

	irgx "github.com/The-Billy-Company/irregex/bindings/go/v2"
)

func TestCompileErrorNamesTheProblem(t *testing.T) {
	re, err := irgx.Compile("a(")
	if err == nil {
		t.Fatalf("Compile(%q) = %v, want an error", "a(", re)
	}
	// An unclosed group is malformed rather than merely outside this grammar,
	// so the seam reports it as a defect with a position; the class carries
	// that, and the generic seam error stays reachable underneath it.
	var bad *irgx.SyntaxError
	if !errors.As(err, &bad) {
		t.Fatalf("error is %T, want *irgx.SyntaxError", err)
	}
	if bad.At < 0 || bad.At > len("a(") {
		t.Errorf("At = %d, outside %q", bad.At, "a(")
	}
	var typed *irgx.Error
	if !errors.As(err, &typed) {
		t.Fatalf("error %T does not unwrap to *irgx.Error", err)
	}
	if typed.Status >= 0 {
		t.Errorf("Status = %d, want a negative status", typed.Status)
	}
	// The message has to carry the pattern, the engine's word for the defect,
	// and where it stopped; a bare status number is not an error a caller can
	// act on.
	for _, want := range []string{`a(`, "compile", "BadPattern", "at byte"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q does not mention %q", err, want)
		}
	}
}

// Lookaround is outside the default grammar. Refusing it at compile time is the
// contract; answering "no match" would be a lie.
func TestLookaroundNeedsPCRE(t *testing.T) {
	if _, err := irgx.Compile(`foo(?=bar)`); err == nil {
		t.Fatal("lookaround compiled under the linear grammar, want an error")
	}
	re, err := irgx.CompileOpts{PCRE: true}.Compile(`foo(?=bar)`)
	if err != nil {
		t.Fatalf("PCRE compile: %v", err)
	}
	if got := re.FindAllString("foobar foobaz", -1); !reflect.DeepEqual(got, []string{"foo"}) {
		t.Errorf("FindAllString = %q, want [foo]", got)
	}
}

func TestMustCompilePanics(t *testing.T) {
	defer func() {
		recovered := recover()
		if recovered == nil {
			t.Fatal("MustCompile of a bad pattern returned normally")
		}
		if msg, ok := recovered.(string); !ok || !strings.Contains(msg, "a(") {
			t.Errorf("panic value %v does not name the pattern", recovered)
		}
	}()
	irgx.MustCompile("a(")
}

// A nullable pattern is where a regexp package's conventions show, and where
// this one used to disagree with the standard library: it reported the engine's
// own sequence, which suppresses an empty match abutting the previous one and
// keeps the ones inside a multi-byte rune. Both are defensible - they are what
// ripgrep prints - and neither is what a Go caller swapping this in for regexp
// is entitled to. The binding now thins the engine's answer to Go's rule, and
// this is the assertion of that.
//
// The stdlib column is computed live rather than written down, so the test
// tracks the standard library instead of a snapshot of it.
//
// The one thing deliberately kept out of the comparison is the word class on
// non-ASCII text: Go's \b, \B and \w are ASCII-only, this engine's are Unicode
// by default, and TestWordClassIsUnicodeWhereStdlibIsASCII below is where that
// difference is asserted rather than papered over. Everything else - including
// what a `.` consumes - already agrees rune for rune.
func TestNullablePatternsMatchStdlib(t *testing.T) {
	const ascii, anyText = true, false
	for _, group := range []struct {
		asciiOnly bool // is a word class in play, and so the text has to stay ASCII?
		patterns  []string
	}{
		{anyText, []string{`a*`, `x?`, ``, `b*`, `(?:)`, `a|`, `[0-9]*`, `.*`, `(a)*`, `l*`, `é*`, `.?`}},
		{ascii, []string{`\b`, `\B`, `\w*`, `\b*`}},
	} {
		texts := []string{"", "abc", "aaa", "bbb", "ab cd", "axbxc", "a\nb", "  ", "abcb"}
		if !group.asciiOnly {
			texts = append(texts, "héllo", "é", "aéa")
		}
		for _, pat := range group.patterns {
			std, err := regexp.Compile(pat)
			if err != nil {
				t.Fatalf("stdlib rejected %q, which makes it useless as an oracle here: %v", pat, err)
			}
			re := irgx.MustCompile(pat)
			for _, text := range texts {
				want := std.FindAllStringIndex(text, -1)
				if got := re.FindAllStringIndex(text, -1); !reflect.DeepEqual(got, want) {
					t.Errorf("%q over %q = %v, stdlib regexp = %v", pat, text, got, want)
				}
			}
		}
	}
}

// The one place this package answers a different question from regexp, stated
// as a difference rather than discovered as one.
//
// Go's \b, \B and \w are defined on ASCII: regexp reads "héllo" as three words
// because é is not a word character to it, and finds no word at all in "é".
// This engine is Unicode by default, as rust-regex and PCRE2 with UTF are, so é
// is a letter and "héllo" is one word. Compiling with ASCII: true asks for Go's
// alphabet back, and gets it.
//
// This is the improvement the ASCII-only groups in the test above are held out
// of, so neither claim can quietly turn into the other.
func TestWordClassIsUnicodeWhereStdlibIsASCII(t *testing.T) {
	const text = "héllo"
	std := regexp.MustCompile(`\b`).FindAllStringIndex(text, -1)
	if want := [][]int{{0, 0}, {1, 1}, {3, 3}, {6, 6}}; !reflect.DeepEqual(std, want) {
		t.Fatalf("stdlib \\b over %q = %v, want %v - the premise of this test moved", text, std, want)
	}
	// Unicode: one word, so two boundaries.
	if got, want := irgx.MustCompile(`\b`).FindAllStringIndex(text, -1), ([][]int{{0, 0}, {6, 6}}); !reflect.DeepEqual(got, want) {
		t.Errorf("unicode \\b over %q = %v, want %v", text, got, want)
	}
	// And asking for Go's alphabet gives Go's answer back, exactly.
	if got := (irgx.CompileOpts{ASCII: true}).MustCompile(`\b`).FindAllStringIndex(text, -1); !reflect.DeepEqual(got, std) {
		t.Errorf("ascii \\b over %q = %v, stdlib regexp = %v", text, got, std)
	}
}

// The other deliberate difference, for the same reason: stated here so the
// shared comparison above can leave malformed text out without losing it.
//
// Go's regexp decodes a byte that begins no valid rune as U+FFFD and lets `.`
// consume it, so `.` finds two "characters" in the two junk bytes below. A
// Unicode `.` here means one well-formed scalar value, as it does in rust-regex
// and in ripgrep, so it matches neither byte and only the empty positions
// around them remain. Neither package loses data - the bytes are still there to
// slice - they disagree about whether invalid input should be silently repaired
// into characters that were never written.
func TestInvalidUTF8IsNotSilentlyRepaired(t *testing.T) {
	const junk = "\xff\xfe"
	if got, want := regexp.MustCompile(`.`).FindAllStringIndex(junk, -1), ([][]int{{0, 1}, {1, 2}}); !reflect.DeepEqual(got, want) {
		t.Fatalf("stdlib . over junk = %v, want %v - the premise of this test moved", got, want)
	}
	// No scalar value, so only the zero-width positions between the bytes.
	if got, want := irgx.MustCompile(`.*`).FindAllStringIndex(junk, -1), ([][]int{{0, 0}, {1, 1}, {2, 2}}); !reflect.DeepEqual(got, want) {
		t.Errorf(".* over junk = %v, want %v", got, want)
	}
	// The bytes are still reachable - by asking for bytes. Under Unicode, \xff
	// names the scalar U+00FF, which is encoded 0xC3 0xBF and is genuinely not
	// present here; dropping to the byte alphabet is how you say the byte.
	if got := irgx.MustCompile(`\xff`).FindAllStringIndex(junk, -1); got != nil {
		t.Errorf("unicode \\xff over junk = %v, want no match: U+00FF is not encoded here", got)
	}
	if got, want := (irgx.CompileOpts{ASCII: true}).MustCompile(`\xff`).FindAllStringIndex(junk, -1), ([][]int{{0, 1}}); !reflect.DeepEqual(got, want) {
		t.Errorf("byte \\xff over junk = %v, want %v", got, want)
	}
}

// The same claim, over patterns nobody would think to write down. The two rules
// the binding applies - ignore an empty match abutting the previous one, resume
// one rune on after an empty one - interact, and the interaction is what a
// hand-written table misses: an empty match skipped by the rune step still
// counts as "previous" for the abutting rule, and a limit has to be applied
// after the thinning or a walk asked for n can come back with n-1.
func TestStdlibAgreementOverAGeneratedSlate(t *testing.T) {
	// Tokens rather than characters, so the alphabet is exactly what it says.
	// Drawing single runes from a set containing a backslash spells escapes
	// nobody chose - it produced \b, whose ASCII-vs-Unicode difference is the
	// deliberate one asserted above, and would have kept rediscovering it here
	// instead of checking iteration.
	tokens := []string{"a", "b", "é", "\n", ".", "*", "?", "+", "|", "(", ")", "[ab]", "[^a]", `\s`, `\S`, `\.`, "{1,2}", "0-9"}
	texts := []string{"", "abc", "héllo", "aéb", "a\nb\n", "bbb", "the quick brown"}
	rng := rand.New(rand.NewSource(0xB1A57))
	var buf strings.Builder
	compiled := 0
	for i := 0; i < 4000; i++ {
		buf.Reset()
		for n := rng.Intn(6) + 1; n > 0; n-- {
			buf.WriteString(tokens[rng.Intn(len(tokens))])
		}
		pat := buf.String()
		std, err := regexp.Compile(pat)
		if err != nil {
			continue
		}
		re, err := irgx.Compile(pat)
		if err != nil {
			continue // a grammar difference, not an iteration difference
		}
		compiled++
		for _, text := range texts {
			want := std.FindAllStringIndex(text, -1)
			if got := re.FindAllStringIndex(text, -1); !reflect.DeepEqual(got, want) {
				t.Fatalf("%q over %q = %v, stdlib regexp = %v", pat, text, got, want)
			}
			// A limit is a view over the settled sequence, so the first n of the
			// full answer and a walk asked for n have to be the same n.
			for _, n := range []int{1, 2, 3} {
				want := std.FindAllStringIndex(text, n)
				if got := re.FindAllStringIndex(text, n); !reflect.DeepEqual(got, want) {
					t.Fatalf("%q over %q limit %d = %v, stdlib regexp = %v", pat, text, n, got, want)
				}
			}
		}
	}
	// The generator is not so hostile that the loop above asserted nothing.
	if compiled < 200 {
		t.Fatalf("only %d patterns compiled on both sides; the slate is not exercising anything", compiled)
	}
}

// The whole point of byte offsets: an index this package returns has to slice
// the caller's own string, with no translation, for text that is not ASCII.
func TestNonASCIIOffsetsSliceTheCallersString(t *testing.T) {
	const text = "le CAFÉ noir, le café clair"
	re := irgx.CompileOpts{IgnoreCase: true}.MustCompile("café")
	locs := re.FindAllStringIndex(text, -1)
	if len(locs) != 2 {
		t.Fatalf("FindAllStringIndex = %v, want two matches", locs)
	}
	// É is two bytes, so a codepoint-indexed answer would be 3..7 here and the
	// slice below would come out mangled rather than merely wrong.
	if want := []int{3, 8}; !reflect.DeepEqual(locs[0], want) {
		t.Errorf("first match at %v, want %v", locs[0], want)
	}
	if got := text[locs[0][0]:locs[0][1]]; got != "CAFÉ" {
		t.Errorf("text[%d:%d] = %q, want %q", locs[0][0], locs[0][1], got, "CAFÉ")
	}
	if got := text[locs[1][0]:locs[1][1]]; got != "café" {
		t.Errorf("text[%d:%d] = %q, want %q", locs[1][0], locs[1][1], got, "café")
	}
	// And the strings the package slices itself must be the same strings.
	if got := re.FindAllString(text, -1); !reflect.DeepEqual(got, []string{"CAFÉ", "café"}) {
		t.Errorf("FindAllString = %q", got)
	}
}

func TestUnicodeClassesAreOnByDefault(t *testing.T) {
	const text = "naïve café"
	unicode := irgx.MustCompile(`\w+`).FindAllString(text, -1)
	if !reflect.DeepEqual(unicode, []string{"naïve", "café"}) {
		t.Errorf("unicode \\w+ = %q, want [naïve café]", unicode)
	}
	ascii := irgx.CompileOpts{ASCII: true}.MustCompile(`\w+`).FindAllString(text, -1)
	if reflect.DeepEqual(ascii, unicode) {
		t.Errorf("ASCII \\w+ = %q, which is what Unicode gave; the flag did nothing", ascii)
	}
	if !reflect.DeepEqual(ascii, []string{"na", "ve", "caf"}) {
		t.Errorf("ASCII \\w+ = %q, want [na ve caf]", ascii)
	}
}

// SubexpNames is indexed by group number, so the table has to be walked out of
// the engine: reading it off the pattern source is a second, worse parser, and
// every row here is a shape that parser has to get right to produce the same
// slice. Each pattern legal under both grammars is asserted under both, because
// the two arms keep their names in different places - the linear parser's own
// storage and PCRE2's name table - and a binding that only walked one would
// still look correct.
func TestSubexpNamesAreIndexedByGroupNumber(t *testing.T) {
	for _, tc := range []struct {
		name     string
		pattern  string
		pcreOnly bool
		want     []string
	}{
		{"namedAndUnnamedInterleave", `(?P<a>x)(?<b>y)(z)`, false, []string{"", "a", "b", ""}},
		{"aNonCapturingGroupTakesNoNumber", `(?:x)(?P<a>y)`, false, []string{"", "a"}},
		{"anEscapedParenOpensNoGroup", `\((?P<a>x)\)`, false, []string{"", "a"}},
		{"anEscapedParenBeforeANameIsText", `\(?P<no>x`, false, []string{""}},
		{"aParenInsideAClassIsALiteral", `[(?P<no>]x`, false, []string{""}},
		{"anUnnamedGroupComesFirst", `(z)(?P<a>x)`, false, []string{"", "", "a"}},
		{"namesNest", `(?P<outer>(?P<inner>x))`, false, []string{"", "outer", "inner"}},
		{"onlyOneBranchIsNamed", `(a)|(?P<b>c)`, false, []string{"", "", "b"}},
		// A spelling only PCRE2 has, and the one no scan of the source can be
		// trusted with: it is a name written without the angle brackets a scan
		// looks for, so it goes missing rather than coming back wrong.
		{"pcreSpellsANameWithQuotes", `(?'q'x)`, true, []string{"", "q"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			for _, pcre := range []bool{false, true} {
				if tc.pcreOnly && !pcre {
					continue
				}
				re, err := irgx.CompileOpts{PCRE: pcre}.Compile(tc.pattern)
				if err != nil {
					t.Fatalf("pcre=%v: compile %q: %v", pcre, tc.pattern, err)
				}
				if got := re.SubexpNames(); !reflect.DeepEqual(got, tc.want) {
					t.Errorf("pcre=%v: SubexpNames = %q, want %q", pcre, got, tc.want)
				}
				if got, want := re.NumSubexp(), len(tc.want)-1; got != want {
					t.Errorf("pcre=%v: NumSubexp = %d, want %d", pcre, got, want)
				}
				// The two directions have to agree, since a caller reaches for
				// whichever one its code already has.
				for number, name := range tc.want {
					if name == "" {
						continue
					}
					if got := re.SubexpIndex(name); got != number {
						t.Errorf("pcre=%v: SubexpIndex(%q) = %d, want %d", pcre, name, got, number)
					}
				}
				if got := re.SubexpIndex("absent"); got != -1 {
					t.Errorf("pcre=%v: SubexpIndex of an undeclared name = %d, want -1", pcre, got)
				}
			}
		})
	}
}

// PCRE2 lets two groups share a name, which the numbered table reports as the
// same spelling twice. SubexpIndex has to answer with the first of them, as the
// standard library's does, rather than with whichever one was written last.
func TestDuplicateNamesResolveToTheFirstGroup(t *testing.T) {
	re, err := irgx.CompileOpts{PCRE: true}.Compile(`(?J)(?<d>a)|(?<d>b)`)
	if err != nil {
		t.Fatalf("compile: %v", err)
	}
	if got, want := re.SubexpNames(), []string{"", "d", "d"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("SubexpNames = %q, want %q", got, want)
	}
	if got := re.SubexpIndex("d"); got != 1 {
		t.Errorf("SubexpIndex(d) = %d, want 1", got)
	}
	// A template resolves through that same table, so ${d} is group 1 for every
	// match - including the one that took the other branch and left group 1
	// unentered. Ambiguous, but predictable, which is the property being kept.
	if got := re.ReplaceAllString("b a", "[${d}]"); got != "[] [a]" {
		t.Errorf("ReplaceAllString = %q, want [] [a]", got)
	}
}

func TestGroupsNumberedAndNamed(t *testing.T) {
	re := irgx.MustCompile(`(?P<user>\w+)@(\w+)`)
	if got := re.NumSubexp(); got != 2 {
		t.Fatalf("NumSubexp = %d, want 2", got)
	}
	if got, want := re.SubexpNames(), []string{"", "user", ""}; !reflect.DeepEqual(got, want) {
		t.Errorf("SubexpNames = %q, want %q", got, want)
	}
	if got := re.SubexpIndex("user"); got != 1 {
		t.Errorf("SubexpIndex(user) = %d, want 1", got)
	}
	// A name the pattern does not declare is an answer, not an error.
	if got := re.SubexpIndex("nope"); got != -1 {
		t.Errorf("SubexpIndex(nope) = %d, want -1", got)
	}
	if got := re.SubexpIndex(""); got != -1 {
		t.Errorf(`SubexpIndex("") = %d, want -1`, got)
	}
	const text = "write to bob@host today"
	if got, want := re.FindStringSubmatch(text), []string{"bob@host", "bob", "host"}; !reflect.DeepEqual(got, want) {
		t.Errorf("FindStringSubmatch = %q, want %q", got, want)
	}
	if got, want := re.FindStringSubmatchIndex(text), []int{9, 17, 9, 12, 13, 17}; !reflect.DeepEqual(got, want) {
		t.Errorf("FindStringSubmatchIndex = %v, want %v", got, want)
	}
}

// A group the match did not enter must stay distinguishable from a group that
// matched empty. Reporting both as "" would quietly lose the difference, which
// is exactly the bug the C ABI's {-1,-1} exists to prevent.
func TestNonParticipatingGroupIsNotEmptyString(t *testing.T) {
	re := irgx.MustCompile(`(a)|(b)`)
	index := re.FindStringSubmatchIndex("b")
	if want := []int{0, 1, -1, -1, 0, 1}; !reflect.DeepEqual(index, want) {
		t.Fatalf("FindStringSubmatchIndex(b) = %v, want %v", index, want)
	}
	if got := re.FindSubmatch([]byte("b")); got[1] != nil {
		t.Errorf("FindSubmatch group 1 = %q, want nil for a group that did not participate", got[1])
	}
	// The empty-group case, for contrast: it matched, and it matched nothing.
	empty := irgx.MustCompile(`(a*)b`)
	if got := empty.FindStringSubmatchIndex("b"); !reflect.DeepEqual(got, []int{0, 1, 0, 0}) {
		t.Errorf("(a*)b over %q = %v, want [0 1 0 0]", "b", got)
	}
	if got := empty.FindSubmatch([]byte("b")); got[1] == nil || len(got[1]) != 0 {
		t.Errorf("FindSubmatch group 1 = %v, want an empty but non-nil slice", got[1])
	}
}

func TestFlagsChangeBehaviour(t *testing.T) {
	for _, tc := range []struct {
		name    string
		opts    irgx.CompileOpts
		pattern string
		text    string
		want    []string
		// plain is what the same pattern does with no flags, asserted so that a
		// flag that silently did nothing cannot pass.
		plain []string
	}{
		{"fixed", irgx.CompileOpts{Fixed: true}, `a.c`, "a.c abc", []string{"a.c"}, []string{"a.c", "abc"}},
		{"ignoreCase", irgx.CompileOpts{IgnoreCase: true}, `abc`, "ABC abc", []string{"ABC", "abc"}, []string{"abc"}},
		{"word", irgx.CompileOpts{Word: true}, `cat`, "cat concatenate", []string{"cat"}, []string{"cat", "cat"}},
		{"smartCaseFolds", irgx.CompileOpts{SmartCase: true}, `abc`, "ABC abc", []string{"ABC", "abc"}, []string{"abc"}},
		{"ascii", irgx.CompileOpts{ASCII: true}, `\w+`, "café", []string{"caf"}, []string{"café"}},
		{"pcre", irgx.CompileOpts{PCRE: true}, `(\w)\1`, "aa ab", []string{"aa"}, nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			re, err := tc.opts.Compile(tc.pattern)
			if err != nil {
				t.Fatalf("compile: %v", err)
			}
			if got := re.FindAllString(tc.text, -1); !reflect.DeepEqual(got, tc.want) {
				t.Errorf("with flag: %q, want %q", got, tc.want)
			}
			plain, err := irgx.Compile(tc.pattern)
			if err != nil {
				if tc.plain != nil {
					t.Fatalf("plain compile: %v", err)
				}
				return // the flag is what makes the pattern legal at all
			}
			if got := plain.FindAllString(tc.text, -1); !reflect.DeepEqual(got, tc.plain) {
				t.Errorf("without flag: %q, want %q", got, tc.plain)
			}
		})
	}
}

// smartCase is the flag most easily faked by always folding, so it gets the
// half that only it can produce: an uppercase letter in the pattern turns
// folding off.
func TestSmartCaseRespectsThePattern(t *testing.T) {
	const text = "ABC abc Abc"
	smart := irgx.CompileOpts{SmartCase: true}.MustCompile("Abc").FindAllString(text, -1)
	if !reflect.DeepEqual(smart, []string{"Abc"}) {
		t.Errorf("smart case with an uppercase pattern = %q, want [Abc]", smart)
	}
	folded := irgx.CompileOpts{IgnoreCase: true}.MustCompile("Abc").FindAllString(text, -1)
	if len(folded) != 3 {
		t.Errorf("ignore case with the same pattern = %q, want three matches", folded)
	}
}

// Word filtering happens inside the search, not as a filter over its results,
// so a rejected span must not stop the search that follows it.
func TestWordSearchResumesPastARejectedSpan(t *testing.T) {
	re := irgx.CompileOpts{Word: true}.MustCompile(`cat`)
	if got := re.FindAllStringIndex("concatenate a cat", -1); !reflect.DeepEqual(got, [][]int{{14, 17}}) {
		t.Errorf("= %v, want the standalone cat at 14", got)
	}
}

func TestFindLimits(t *testing.T) {
	re := irgx.MustCompile(`a`)
	const text = "aaaaa"
	for _, tc := range []struct{ n, want int }{{-1, 5}, {0, 0}, {1, 1}, {3, 3}, {9, 5}} {
		if got := len(re.FindAllString(text, tc.n)); got != tc.want {
			t.Errorf("FindAllString(n=%d) returned %d matches, want %d", tc.n, got, tc.want)
		}
	}
	if got := re.FindAllString(text, 0); got != nil {
		t.Errorf("n=0 returned %v, want nil", got)
	}
}

// The first span window is a guess at how many matches will be wanted, so a
// text with more than that must still report every one of them. The engine
// answers a short window with the count the TEXT HAS rather than the count that
// fit, and the rows below are where those two numbers differ: everything at or
// past the window asks for more spans than the first pass could have written,
// so a reader that mistook the count for a length would index a buffer it never
// filled. The spans are checked one by one for the same reason - a plausible
// count over uninitialized memory is the failure this is looking for.
func TestAShortWindowStillReturnsTheWholeAnswer(t *testing.T) {
	const count = 20000
	text := strings.Repeat("a ", count)
	re := irgx.MustCompile(`a`)
	for _, n := range []int{-1, count + 1, count, count - 1, 8192, 4097, 4096, 4095, 1} {
		want := n
		if n < 0 || n > count {
			want = count
		}
		got := re.FindAllStringIndex(text, n)
		if len(got) != want {
			t.Fatalf("FindAllStringIndex(n=%d) found %d matches, want %d", n, len(got), want)
		}
		for i, loc := range got {
			if expect := []int{2 * i, 2*i + 1}; !reflect.DeepEqual(loc, expect) {
				t.Fatalf("n=%d: match %d at %v, want %v", n, i, loc, expect)
			}
		}
	}
}

func TestNoMatchAnswers(t *testing.T) {
	re := irgx.MustCompile(`zzz`)
	if re.MatchString("abc") {
		t.Error("MatchString found a match that is not there")
	}
	if got := re.FindStringIndex("abc"); got != nil {
		t.Errorf("FindStringIndex = %v, want nil", got)
	}
	if got := re.FindString("abc"); got != "" {
		t.Errorf("FindString = %q, want empty", got)
	}
	if got := re.Find([]byte("abc")); got != nil {
		t.Errorf("Find = %v, want nil", got)
	}
	if got := re.FindStringSubmatch("abc"); got != nil {
		t.Errorf("FindStringSubmatch = %v, want nil", got)
	}
	if got := re.FindAllString("abc", -1); got != nil {
		t.Errorf("FindAllString = %v, want nil", got)
	}
}

// anchorPatterns and anchorTexts are the grid that once caught the engine's two
// match verbs answering differently, and that its fix was accepted against.
// MatchString rides is_match and every other Find verb rides find_all, so the
// two drifting apart would split this package's answers down the middle.
var (
	anchorPatterns = []string{`^a`, `\Aa`, `c$`, `c\z`, `^abc$`, `\Aabc\z`, `b$`, `abc`, `a*`}
	anchorTexts    = []string{"\nabc", "abc\n", "x\nabc\ny", "ab\ncd", "abc", ""}
)

func TestMatchStringAgreesWithFind(t *testing.T) {
	pairs := 0
	for _, pattern := range anchorPatterns {
		re := irgx.MustCompile(pattern)
		for _, text := range anchorTexts {
			pairs++
			if got, want := re.MatchString(text), re.FindStringIndex(text) != nil; got != want {
				t.Errorf("%q over %q: MatchString = %v, FindStringIndex found one = %v",
					pattern, text, got, want)
			}
		}
	}
	if want := len(anchorPatterns) * len(anchorTexts); pairs != want {
		t.Fatalf("checked %d pairs, want %d", pairs, want)
	}
}

// Agreement alone would still hold if both verbs read the buffer as lines, so
// these rows pin the reading itself. Each one is a case a per-line kernel calls
// a match: the buffer is one unit, ^ and \A match only at offset 0, $ and \z
// only at the end, and an interior newline is an ordinary byte.
func TestAnchorsSpanTheWholeBuffer(t *testing.T) {
	for _, tc := range []struct{ pattern, text string }{
		{`^a`, "\nabc"},
		{`^a`, "x\nabc\ny"},
		{`c$`, "abc\n"},
		{`c$`, "x\nabc\ny"},
		{`^abc$`, "\nabc"},
		{`^abc$`, "abc\n"},
		{`^abc$`, "x\nabc\ny"},
		{`b$`, "ab\ncd"},
	} {
		re := irgx.MustCompile(tc.pattern)
		if re.MatchString(tc.text) {
			t.Errorf("%q matched %q; the anchor is reading the text as lines",
				tc.pattern, tc.text)
		}
	}
	// The other half of the same rule: the anchors do match at the real ends.
	for _, tc := range []struct{ pattern, text string }{
		{`^a`, "abc"}, {`\Aa`, "abc\n"}, {`c$`, "abc"}, {`c\z`, "\nabc"}, {`^abc$`, "abc"},
	} {
		re := irgx.MustCompile(tc.pattern)
		if !re.MatchString(tc.text) {
			t.Errorf("%q did not match %q", tc.pattern, tc.text)
		}
	}
}

func TestByteAndStringHalvesAgree(t *testing.T) {
	re := irgx.MustCompile(`(\w+)@(\w+)`)
	const text = "a bob@host b eve@box"
	if !reflect.DeepEqual(re.FindStringIndex(text), re.FindIndex([]byte(text))) {
		t.Error("FindStringIndex and FindIndex disagree")
	}
	if !reflect.DeepEqual(re.FindStringSubmatchIndex(text), re.FindSubmatchIndex([]byte(text))) {
		t.Error("FindStringSubmatchIndex and FindSubmatchIndex disagree")
	}
	if !reflect.DeepEqual(re.FindAllStringIndex(text, -1), re.FindAllIndex([]byte(text), -1)) {
		t.Error("FindAllStringIndex and FindAllIndex disagree")
	}
	if got, want := string(re.Find([]byte(text))), re.FindString(text); got != want {
		t.Errorf("Find = %q, FindString = %q", got, want)
	}
	for i, group := range re.FindSubmatch([]byte(text)) {
		if got, want := string(group), re.FindStringSubmatch(text)[i]; got != want {
			t.Errorf("group %d: Find %q, FindString %q", i, got, want)
		}
	}
}

// A []byte result aliases the caller's slice, as the standard library's does,
// but it must not alias past its own end: a three-capacity view of a longer
// buffer would let an append scribble over the next match.
func TestByteResultsAreCapped(t *testing.T) {
	src := []byte("cat dog")
	got := irgx.MustCompile(`cat`).Find(src)
	if cap(got) != len(got) {
		t.Errorf("cap = %d, len = %d; the result can be appended into its neighbor", cap(got), len(got))
	}
}

func TestSplit(t *testing.T) {
	comma := irgx.MustCompile(`,`)
	for _, tc := range []struct {
		text string
		n    int
		want []string
	}{
		{"a,b,c", -1, []string{"a", "b", "c"}},
		{"a,b,c", 2, []string{"a", "b,c"}},
		{"a,b,c", 0, nil},
		{"a,b,c", 1, []string{"a,b,c"}},
		{"", -1, []string{""}},
		{",a,", -1, []string{"", "a", ""}},
		{"abc", -1, []string{"abc"}},
	} {
		if got := comma.Split(tc.text, tc.n); !reflect.DeepEqual(got, tc.want) {
			t.Errorf("Split(%q, %d) = %q, want %q", tc.text, tc.n, got, tc.want)
		}
	}
	// A separator that can match empty splits by the engine's rules, not the
	// standard library's, so it is asserted rather than assumed.
	if got := irgx.MustCompile(`x*`).Split("abc", -1); !reflect.DeepEqual(got, []string{"a", "b", "c"}) {
		t.Errorf(`x* Split("abc") = %q, want [a b c]`, got)
	}
}

func TestReplace(t *testing.T) {
	re := irgx.MustCompile(`(?P<user>\w+)@(\w+)`)
	for _, tc := range []struct{ template, want string }{
		{"$1", "bob and eve"},
		{"${user}", "bob and eve"},
		{"$2/$1", "host/bob and box/eve"},
		{"${user}s", "bobs and eves"}, // the braces end the name, the s is literal
		{"$users", " and "},           // without them the name runs on and matches nothing
		{"$user$$", "bob$ and eve$"},
		{"$nope", " and "},
		{"$0", "bob@host and eve@box"},
		{"-", "- and -"},
		{"$", "$ and $"},
	} {
		if got := re.ReplaceAllString("bob@host and eve@box", tc.template); got != tc.want {
			t.Errorf("ReplaceAllString(%q) = %q, want %q", tc.template, got, tc.want)
		}
	}
	if got := re.ReplaceAllString("${user}s", "x"); got != "${user}s" {
		t.Errorf("a text with no match came back changed: %q", got)
	}
	if got := re.ReplaceAllLiteralString("bob@host", "$1"); got != "$1" {
		t.Errorf("ReplaceAllLiteralString expanded the template: %q", got)
	}
	if got := re.ReplaceAllStringFunc("bob@host and eve@box", strings.ToUpper); got != "BOB@HOST and EVE@BOX" {
		t.Errorf("ReplaceAllStringFunc = %q", got)
	}
	if got := string(re.ReplaceAll([]byte("bob@host"), []byte("$2"))); got != "host" {
		t.Errorf("ReplaceAll = %q", got)
	}
	if got := string(re.ReplaceAllLiteral([]byte("bob@host"), []byte("$2"))); got != "$2" {
		t.Errorf("ReplaceAllLiteral = %q", got)
	}
	if got := string(re.ReplaceAllFunc([]byte("bob@host"), func(b []byte) []byte {
		return []byte(strings.ToUpper(string(b)))
	})); got != "BOB@HOST" {
		t.Errorf("ReplaceAllFunc = %q", got)
	}
}

// A replacement must not see the text it already wrote, which is what a naive
// rebuild that re-searches its own output would do.
func TestReplaceDoesNotRescanItsOutput(t *testing.T) {
	if got := irgx.MustCompile(`a`).ReplaceAllString("aaa", "aa"); got != "aaaaaa" {
		t.Errorf("= %q, want aaaaaa", got)
	}
}

func TestExpand(t *testing.T) {
	re := irgx.MustCompile(`(?P<key>\w+)=(?P<value>\w+)`)
	const text = "a=1 b=2"
	var out []byte
	for _, match := range re.FindAllStringSubmatchIndex(text, -1) {
		out = re.ExpandString(out, "$value:$key ", text, match)
	}
	if got := string(out); got != "1:a 2:b " {
		t.Errorf("ExpandString = %q, want %q", got, "1:a 2:b ")
	}
	src := []byte(text)
	if got := string(re.Expand(nil, []byte("$key"), src, re.FindSubmatchIndex(src))); got != "a" {
		t.Errorf("Expand = %q, want a", got)
	}
}

func TestEmptyPatternAndEmptyText(t *testing.T) {
	// A zero-length Go string may carry a nil data pointer, and the engine reads
	// null with length zero as the empty pattern, so this is also the test that
	// the binding hands the empty string across the seam untouched.
	re, err := irgx.Compile("")
	if err != nil {
		t.Fatalf("Compile(%q): %v", "", err)
	}
	// Expectations come from regexp rather than a literal, because the empty
	// pattern is precisely where a written-down answer rots: these rows used to
	// say [[0 0] [1 1]] and nil, the engine's grep walk, which dropped the empty
	// match at end-of-text and reported none at all in empty text.
	for _, text := range []string{"ab", "", "é"} {
		want := regexp.MustCompile("").FindAllStringIndex(text, -1)
		if got := re.FindAllStringIndex(text, -1); !reflect.DeepEqual(got, want) {
			t.Errorf("empty pattern over %q = %v, stdlib regexp = %v", text, got, want)
		}
	}
	if irgx.MustCompile(`a`).MatchString("") {
		t.Error("a matched the empty text")
	}
	if got := irgx.MustCompile(`a`).FindAll(nil, -1); got != nil {
		t.Errorf("Find over a nil slice = %v, want nil", got)
	}
	// The zero string, whose data pointer really is nil, where a "" literal's
	// may not be. This is the row that crosses the seam as null with length 0,
	// so it is the one that proves the binding needs nothing standing in for an
	// address.
	var zero string
	if _, err := irgx.Compile(zero); err != nil {
		t.Errorf("Compile(zero string): %v", err)
	}
	// The empty pattern matches the empty string - it is the one thing it most
	// obviously does. This row asserted the opposite until the pattern plane
	// stopped answering booleans out of the line model, where a text with no
	// lines had nothing to match against.
	if !re.MatchString(zero) {
		t.Error("empty pattern did not match the zero string")
	}
}

func TestPackageLevelHelpers(t *testing.T) {
	ok, err := irgx.MatchString(`^a`, "abc")
	if err != nil || !ok {
		t.Errorf("MatchString = %v, %v", ok, err)
	}
	if ok, err := irgx.Match(`^a`, []byte("bbc")); err != nil || ok {
		t.Errorf("Match = %v, %v", ok, err)
	}
	if _, err := irgx.MatchString(`a(`, "abc"); err == nil {
		t.Error("MatchString with a bad pattern returned no error")
	}
}

func TestStringAndVersions(t *testing.T) {
	if got := irgx.MustCompile(`a+b`).String(); got != "a+b" {
		t.Errorf("String = %q", got)
	}
	if irgx.Version() == "" || irgx.PCRE2Version() == "" {
		t.Error("the linked library reports no version")
	}
	if got := irgx.ABIVersion(); got != 2 {
		t.Errorf("ABIVersion = %d, want 2; the binding was written against ABI 2", got)
	}
}

// The two flags stdlib regexp spells inline. Go writes `(?m)^b`; the linear
// grammar declines an inline flag group rather than silently ignoring it, so
// CompileOpts is how you ask here. The oracle is stdlib's inline spelling, so
// this asserts the two spellings mean the same thing rather than restating what
// the flag does.
func TestMultiLineAndDotAllMeanWhatTheInlineFlagsMean(t *testing.T) {
	for _, c := range []struct {
		name   string
		pat    string
		opts   irgx.CompileOpts
		inline string
	}{
		{"caret", "^..", irgx.CompileOpts{MultiLine: true}, "(?m)^.."},
		{"dollar", "..$", irgx.CompileOpts{MultiLine: true}, "(?m)..$"},
		{"dot", ".", irgx.CompileOpts{DotAll: true}, "(?s)."},
		{"both", "^.", irgx.CompileOpts{MultiLine: true, DotAll: true}, "(?ms)^."},
		{"neither caret", "^..", irgx.CompileOpts{}, "^.."},
		{"neither dot", ".", irgx.CompileOpts{}, "."},
	} {
		t.Run(c.name, func(t *testing.T) {
			for _, text := range []string{"ab\ncd", "a\nb", "\n", "ab", "", "a\n"} {
				ours := c.opts.MustCompile(c.pat).FindAllStringIndex(text, -1)
				want := regexp.MustCompile(c.inline).FindAllStringIndex(text, -1)
				if !reflect.DeepEqual(ours, want) {
					t.Errorf("%q over %q: got %v, stdlib %q gives %v",
						c.pat, text, ours, c.inline, want)
				}
			}
		})
	}
}

// A pattern may carry its own flags, in the leading form stdlib regexp uses, and
// the two spellings are one answer. This is the plane where it matters most: a
// pattern out of a config file arrives without a CompileOpts a caller could have
// filled in, because filling it in would mean reading the pattern first.
func TestALeadingInlineFlagSaysWhatTheFieldSays(t *testing.T) {
	for _, c := range []struct {
		inline string
		body   string
		opts   irgx.CompileOpts
	}{
		{"(?i)AB", "AB", irgx.CompileOpts{IgnoreCase: true}},
		{"(?m)^c", "^c", irgx.CompileOpts{MultiLine: true}},
		{"(?s)b.c", "b.c", irgx.CompileOpts{DotAll: true}},
		{"(?ms)^c.", "^c.", irgx.CompileOpts{MultiLine: true, DotAll: true}},
	} {
		for _, text := range []string{"ab\ncd", "AB ab", "a\nb", "", "a\n"} {
			inline := irgx.MustCompile(c.inline).FindAllStringIndex(text, -1)
			field := c.opts.MustCompile(c.body).FindAllStringIndex(text, -1)
			want := regexp.MustCompile(c.inline).FindAllStringIndex(text, -1)
			if !reflect.DeepEqual(inline, field) || !reflect.DeepEqual(inline, want) {
				t.Errorf("%q over %q: inline %v, field %v, stdlib %v",
					c.inline, text, inline, field, want)
			}
		}
	}

	// The pattern is the more specific statement, so it beats the field.
	sensitive := (irgx.CompileOpts{IgnoreCase: true}).MustCompile("(?-i)ab")
	if got := sensitive.FindAllString("ab AB", -1); !reflect.DeepEqual(got, []string{"ab"}) {
		t.Errorf(`(?-i)ab under IgnoreCase: got %v, want ["ab"]`, got)
	}
	// And under Fixed the bytes are data, not a directive.
	data := (irgx.CompileOpts{Fixed: true}).MustCompile("(?i)ab")
	if got := data.FindAllString("(?i)ab AB", -1); !reflect.DeepEqual(got, []string{"(?i)ab"}) {
		t.Errorf(`(?i)ab under Fixed: got %v, want ["(?i)ab"]`, got)
	}
}

// Only the leading run is a whole-pattern flag, which is where stdlib regexp
// draws the line too, and (?U)/(?R) are letters this grammar does not have.
// Refusing beats honoring the letters it recognizes and dropping the rest.
func TestANonLeadingOrForeignInlineFlagIsDeclinedRatherThanIgnored(t *testing.T) {
	for _, pat := range []string{"a(?i)b", "(?U)a+"} {
		if _, err := irgx.Compile(pat); err == nil {
			t.Errorf("%q compiled on the linear arm; an ignored flag is the "+
				"failure mode CompileOpts exists to avoid", pat)
		}
		// The PCRE arm does honor them.
		if _, err := (irgx.CompileOpts{PCRE: true}).Compile(pat); err != nil {
			t.Errorf("%q on the PCRE arm: %v", pat, err)
		}
	}
}

// (?x) was on that list until verbose entered the grammar. There is no
// CompileOpts field for it - stdlib regexp has no such flag either - so the
// pattern's own head is how you ask, and a (?ix) asking for two things has to
// get both rather than whichever one the reader noticed first.
func TestALeadingVerboseFlagIsHonoredAlongsideTheOthers(t *testing.T) {
	for _, c := range []struct {
		pat, text string
		want      []string
	}{
		{"(?x) a b", "ab", []string{"ab"}},
		{"(?ix)a b", "AB", []string{"AB"}},
		// Without the i the space is still gone but the case is not, which is
		// the half a single-flag reading would have silently handed back.
		{"(?x)a b", "AB", nil},
		// # opens a comment that runs to the end of the line, so the pattern
		// here is one byte long.
		{"(?x)a  # the space and this text are not the pattern", "a", []string{"a"}},
	} {
		re, err := irgx.Compile(c.pat)
		if err != nil {
			t.Errorf("%q should compile on the linear arm: %v", c.pat, err)
			continue
		}
		if got := re.FindAllString(c.text, -1); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%q over %q: got %v, want %v", c.pat, c.text, got, c.want)
		}
	}
}
