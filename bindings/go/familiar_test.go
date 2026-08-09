//go:build cgo

package irgx_test

// The regexp-shaped doors, against the two oracles that can actually judge them:
// the standard library for the quoting table, and the ENGINE'S OWN other path for
// what the quoting means. The second is the one with teeth - Fixed mode reaches a
// substring machine that never sees the escapes at all, so if QuoteMeta escaped
// too little (or escaped something into a different meaning) the two paths report
// different offsets over the same text.

import (
	"encoding/json"
	"regexp"
	"strings"
	"testing"
	"unicode/utf8"

	irgx "github.com/The-Billy-Company/irregex/bindings/go/v2"
)

// nasty is one string per way a literal can look like syntax, plus the bytes a
// naive quoter forgets: NUL, a newline, a lone backslash, and multi-byte text
// whose continuation bytes must not be treated as punctuation.
var nasty = []string{
	"", "a", ".", "\\", "a.b", "a\\.b", "*", "+?", "()", "[]", "{}", "^$", "|",
	"a{2,3}", "[a-z]", "(?i)", "\\d", "\\x00", "\x00", "\n", "\t", "\r\n",
	"C:\\Users\\g\\file (1).txt", "1+1=2?", "$HOME/**/*.go", "a|b", "[[:alpha:]]",
	"héllo.wörld", "🙂+", "-", "#", "/", "~", "!", "&", "'", `"`, "%", "@", ":", ";",
	"<>", "=", ",", "_", " ", "  a  ",
}

// Every byte on its own, which is where a missing entry in the table shows up as
// either a compile error or a pattern matching something else.
func everyByte() []string {
	out := make([]string, 256)
	for b := range 256 {
		out[b] = string([]byte{byte(b)})
	}
	return out
}

// The table is the grammar's, and the standard library's regexp has the same one.
// Equality here is what makes the function predictable to a Go host - a quoted
// filename printed in a log reads the way it reads everywhere else in Go.
func TestQuoteMetaEscapesWhatTheStandardLibraryEscapes(t *testing.T) {
	for _, s := range append(nasty, everyByte()...) {
		if got, want := irgx.QuoteMeta(s), regexp.QuoteMeta(s); got != want {
			t.Errorf("QuoteMeta(%q) = %q, stdlib says %q", s, got, want)
		}
	}
}

// The claim, checked against the engine rather than against a table: a quoted
// literal compiles, and it finds exactly the occurrences the engine's OWN literal
// machine finds for the unquoted text. Two unrelated paths through the engine, so
// a disagreement is a real defect.
func TestAQuotedLiteralFindsWhatFixedModeFinds(t *testing.T) {
	fixed := irgx.CompileOpts{Fixed: true}
	for _, needle := range append(nasty, everyByte()...) {
		if needle == "" {
			continue // the empty pattern is refused by Fixed, and quoting it is a no-op
		}
		re, err := irgx.Compile(irgx.QuoteMeta(needle))
		if err != nil {
			t.Errorf("QuoteMeta(%q) = %q, which does not compile: %v", needle, irgx.QuoteMeta(needle), err)
			continue
		}
		lit, err := fixed.Compile(needle)
		if err != nil {
			t.Fatalf("Fixed.Compile(%q): %v", needle, err)
		}
		for _, hay := range []string{needle, "x" + needle + "y", needle + needle, "nothing here", "a.b*c"} {
			got := re.FindAllStringIndex(hay, -1)
			want := lit.FindAllStringIndex(hay, -1)
			if len(got) != len(want) {
				t.Errorf("quoted %q over %q found %v, Fixed found %v", needle, hay, got, want)
				continue
			}
			for i := range got {
				if got[i][0] != want[i][0] || got[i][1] != want[i][1] {
					t.Errorf("quoted %q over %q found %v, Fixed found %v", needle, hay, got, want)
					break
				}
			}
		}
	}
}

// PCRE2 is a different grammar reached by a different arm, and a quoting table
// that only holds for one of them is a trap for a host that sets the flag.
func TestAQuotedLiteralIsLiteralUnderPCRE2Too(t *testing.T) {
	pcre := irgx.CompileOpts{PCRE: true}
	for _, needle := range append(nasty, everyByte()...) {
		// PCRE2 is compiled in UTF mode, where a pattern that is not valid UTF-8
		// is refused before any quoting question arises - so a lone 0x80..0xFF
		// byte is out of this arm's domain rather than a quoting failure. The
		// linear engine takes those bytes literally, and the test above covers
		// them there.
		if needle == "" || !utf8.ValidString(needle) {
			continue
		}
		// "\n" was excluded here once: a pattern whose whole language was a lone
		// newline found nothing under this arm while the linear engine reported
		// it. That was not a quoting question - the quoted form of "\n" is "\n" -
		// but the shadow gate built at line grain answering a buffer question,
		// and it is fixed in the engine. The needle stays in the set now,
		// because this loop is where it would come back.
		re, err := pcre.Compile(irgx.QuoteMeta(needle))
		if err != nil {
			t.Errorf("PCRE2 refuses QuoteMeta(%q) = %q: %v", needle, irgx.QuoteMeta(needle), err)
			continue
		}
		hay := "x" + needle + "y"
		span := re.FindStringIndex(hay)
		if span == nil {
			t.Errorf("quoted %q does not match %q under PCRE2", needle, hay)
			continue
		}
		if got := hay[span[0]:span[1]]; got != needle {
			t.Errorf("quoted %q matched %q under PCRE2", needle, got)
		}
	}
}

// Splicing is the reason the function exists, so the anchored form has to hold: a
// name quoted between ^ and $ matches that name and nothing that merely contains
// it.
func TestQuotingIsSafeToSpliceIntoALargerPattern(t *testing.T) {
	for _, name := range []string{"a.b", "file (1).txt", "x+y", "[draft]", "3$"} {
		re := irgx.MustCompile("^" + irgx.QuoteMeta(name) + "$")
		if !re.MatchString(name) {
			t.Errorf("^%s$ does not match %q", irgx.QuoteMeta(name), name)
		}
		for _, near := range []string{name + "x", "x" + name, strings.ToUpper(name) + "!"} {
			if near != name && re.MatchString(near) {
				t.Errorf("^%s$ also matches %q", irgx.QuoteMeta(name), near)
			}
		}
	}
}

// The prefix is a promise about every match, so the test is every match: if the
// engine reports a span, the text at that span has to start with the prefix. A
// prefix that is merely SOMETIMES right is the bug this catches, because a caller
// uses it to skip files.
func TestALiteralPrefixBeginsEveryMatchItClaims(t *testing.T) {
	hay := "foo foobar barfoo FOO xyz fooo f o o baz bar\nfoo"
	for _, pattern := range []string{
		"foo", "foo+", "foobar", "foo(bar)?", "foo\\d*", "^foo", "foo|foobar",
		"foo|bar", "[fb]oo", ".*foo", "(foo|foo)", "f.o", "", "x*", "\\bfoo\\b",
	} {
		re := irgx.MustCompile(pattern)
		prefix, complete := re.LiteralPrefix()
		for _, span := range re.FindAllStringIndex(hay, -1) {
			if got := hay[span[0]:span[1]]; !strings.HasPrefix(got, prefix) {
				t.Errorf("%q claims prefix %q but matched %q", pattern, prefix, got)
			}
		}
		if !complete {
			continue
		}
		// complete is the licence to stop using the engine, so it has to mean the
		// pattern's whole language is that one string: every match IS the prefix,
		// and the prefix itself matches.
		if !re.MatchString(prefix) {
			t.Errorf("%q claims to be exactly %q, which it does not match", pattern, prefix)
		}
		for _, span := range re.FindAllStringIndex(hay, -1) {
			if got := hay[span[0]:span[1]]; got != prefix {
				t.Errorf("%q claims to be exactly %q but matched %q", pattern, prefix, got)
			}
		}
	}
}

// A pattern that is nothing but a literal is the case a caller most wants to
// detect, and the case where a wrong answer costs the most: complete=false there
// only wastes a regex, but complete=true on a pattern with syntax in it hands the
// caller a substring search for a question substrings cannot answer.
func TestCompleteIsExactlyTheWhollyLiteralPatterns(t *testing.T) {
	for _, c := range []struct {
		pattern      string
		wantComplete bool
	}{
		{"foo", true}, {"a", true}, {"WalletService", true}, {"(foo)bar", true},
		{"foo+", false}, {"foo.*", false}, {"foo|bar", false}, {"[fb]oo", false},
		// Anchored, and deliberately NOT complete: searching for "foo" is not the
		// same question as matching "^foo$", so the licence complete grants would
		// be wrong even though the standard library says true here.
		{"^foo$", false}, {"^foo", false},
		// The empty pattern promises nothing at all - no set, no verdict - and
		// answering "" / false is that absence rather than a claim.
		{"", false},
	} {
		prefix, complete := irgx.MustCompile(c.pattern).LiteralPrefix()
		if complete != c.wantComplete {
			t.Errorf("LiteralPrefix(%q) = %q/%v, want complete=%v", c.pattern, prefix, complete, c.wantComplete)
		}
		// A complete answer has to be usable as the pattern's replacement, which is
		// a claim about matching rather than about spelling - "(foo)bar" is
		// complete and its literal is "foobar", parentheses gone.
		if complete && !irgx.MustCompile(c.pattern).MatchString(prefix) {
			t.Errorf("LiteralPrefix(%q) = %q, which the pattern itself does not match", c.pattern, prefix)
		}
	}
}

// PCRE2 exposes no program to read literals out of, so the honest answer is the
// empty promise rather than a panic or a guess.
func TestAPCRE2PatternPromisesNoPrefix(t *testing.T) {
	re, err := (irgx.CompileOpts{PCRE: true}).Compile("(?<=x)foo")
	if err != nil {
		t.Skipf("PCRE2 refused the lookbehind: %v", err)
	}
	if prefix, complete := re.LiteralPrefix(); prefix != "" || complete {
		t.Errorf("a PCRE2 pattern claims prefix %q/%v, want the empty promise", prefix, complete)
	}
}

// The point of the text form is a config file, so the test is a config file: a
// *Regexp decodes from JSON and matches, and the value survives the round trip
// with its options intact.
func TestAPatternRoundTripsThroughItsTextForm(t *testing.T) {
	for _, c := range []struct {
		opts irgx.CompileOpts
		expr string
		want string // the marshalled text
	}{
		{irgx.CompileOpts{}, "foo\\d+", "foo\\d+"},
		{irgx.CompileOpts{IgnoreCase: true}, "foo", "(?i)foo"},
		{irgx.CompileOpts{MultiLine: true}, "^foo", "(?m)^foo"},
		{irgx.CompileOpts{DotAll: true}, "a.b", "(?s)a.b"},
		{irgx.CompileOpts{ASCII: true}, "\\w+", "(?-u)\\w+"},
		{irgx.CompileOpts{IgnoreCase: true, DotAll: true, ASCII: true}, "a.b", "(?is-u)a.b"},
	} {
		re := c.opts.MustCompile(c.expr)
		text, err := re.MarshalText()
		if err != nil {
			t.Errorf("MarshalText(%q, %+v): %v", c.expr, c.opts, err)
			continue
		}
		if string(text) != c.want {
			t.Errorf("MarshalText(%q, %+v) = %q, want %q", c.expr, c.opts, text, c.want)
		}
		var back irgx.Regexp
		if err := back.UnmarshalText(text); err != nil {
			t.Errorf("UnmarshalText(%q): %v", text, err)
			continue
		}
		// Meaning, not bytes: the reloaded pattern has to answer identically over
		// text that distinguishes the flags it was carrying.
		for _, s := range []string{"foo", "FOO", "foo1", "a\nb", "aXb", "héllo", "a_1", "\nfoo"} {
			if got, want := back.MatchString(s), re.MatchString(s); got != want {
				t.Errorf("%q (%+v) round-tripped as %q, which answers %v for %q instead of %v",
					c.expr, c.opts, text, got, s, want)
			}
		}
		if got := back.String(); got != string(text) {
			t.Errorf("the round-tripped pattern is %q, want %q", got, text)
		}
		// And the interfaces are really found by a decoder, not just present.
		var viaJSON struct{ Pattern *irgx.Regexp }
		blob, err := json.Marshal(struct{ Pattern *irgx.Regexp }{re})
		if err != nil {
			t.Errorf("json.Marshal: %v", err)
			continue
		}
		if err := json.Unmarshal(blob, &viaJSON); err != nil {
			t.Errorf("json.Unmarshal(%s): %v", blob, err)
			continue
		}
		if viaJSON.Pattern.String() != string(text) {
			t.Errorf("through JSON the pattern is %q, want %q", viaJSON.Pattern, text)
		}
	}
}

// An option with no inline spelling is REFUSED, not dropped. A silently
// downgraded pattern reads correctly in the config and matches wrongly at
// runtime, which is the failure a config file is least able to explain.
func TestAnUnwritableOptionRefusesToMarshal(t *testing.T) {
	for _, opts := range []irgx.CompileOpts{
		{PCRE: true}, {Fixed: true}, {Word: true}, {SmartCase: true},
		{IgnoreCase: true, Word: true},
	} {
		re := opts.MustCompile("foo")
		if text, err := re.MarshalText(); err == nil {
			t.Errorf("MarshalText(%+v) = %q, want a refusal", opts, text)
		}
		if _, err := re.AppendText(nil); err == nil {
			t.Errorf("AppendText(%+v) succeeded, want a refusal", opts)
		}
	}
}

// Decoding into a value that has already been USED is the trap: its pool holds
// handles compiled for the old pattern, and reusing one searches for the pattern
// the config no longer says. Driven a few times so the pool is really populated.
func TestDecodingOverAUsedPatternDoesNotKeepTheOldOne(t *testing.T) {
	re := irgx.MustCompile("foo")
	for range 8 {
		if !re.MatchString("foo") {
			t.Fatal(`MustCompile("foo") does not match "foo"`)
		}
	}
	if err := re.UnmarshalText([]byte("bar")); err != nil {
		t.Fatalf("UnmarshalText: %v", err)
	}
	for range 8 {
		if re.MatchString("foo") {
			t.Fatal(`after decoding "bar" the pattern still matches "foo"`)
		}
		if !re.MatchString("bar") {
			t.Fatal(`after decoding "bar" the pattern does not match "bar"`)
		}
	}
	if got := re.String(); got != "bar" {
		t.Errorf("String() = %q after decoding, want %q", got, "bar")
	}
	// A pattern the engine refuses leaves the value alone rather than half-decoded.
	if err := re.UnmarshalText([]byte("(unclosed")); err == nil {
		t.Error("UnmarshalText accepted an unclosed group")
	}
	if !re.MatchString("bar") || re.MatchString("foo") {
		t.Error("a failed decode changed what the pattern matches")
	}
	// Group structure follows too, not just the text.
	if err := re.UnmarshalText([]byte("(?P<who>b)(a)r")); err != nil {
		t.Fatalf("UnmarshalText: %v", err)
	}
	if got := re.NumSubexp(); got != 2 {
		t.Errorf("NumSubexp() = %d after decoding a two-group pattern, want 2", got)
	}
	if got := re.SubexpNames(); len(got) != 3 || got[1] != "who" {
		t.Errorf("SubexpNames() = %q after decoding, want the decoded pattern's names", got)
	}
}
