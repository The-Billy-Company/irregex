package irgx_test

// A [Set] is asked against the only oracle that can settle it: the same patterns
// compiled one at a time. That is the property the type promises - one pass and N
// passes name the same patterns - and it is the one a caller loses if the slate's
// prefilter ever over-rejects, so almost everything below is that comparison over
// a corpus chosen to include the cases a prefilter is most likely to get wrong:
// anchors, a nullable pattern, a word boundary, a non-ASCII literal, and a
// pattern that matches nothing at all.

import (
	"errors"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"testing"

	irgx "github.com/The-Billy-Company/irregex/bindings/go/v2"
)

var (
	setPatterns = []string{`^b`, `c$`, `a\sb`, `x*`, `\bcat\b`, `\d+`, `héllo`, `q`}
	setTexts    = []string{
		"", "abc", "a\nb", "ab\ncd", "\n", "abc\n", "b",
		"a cat sat", "concatenate", "42", "héllo", "no match here",
	}
)

// oneAtATime is the oracle: which patterns match, asked of N separate Regexps.
func oneAtATime(t *testing.T, exprs []string, text string) []int {
	t.Helper()
	var hits []int
	for i, expr := range exprs {
		if irgx.MustCompile(expr).MatchString(text) {
			hits = append(hits, i)
		}
	}
	return hits
}

func TestSetNamesWhatOneAtATimeNames(t *testing.T) {
	set := irgx.MustCompileSet(setPatterns...)
	for _, text := range setTexts {
		want := oneAtATime(t, setPatterns, text)
		if got := set.WhichString(text); !reflect.DeepEqual(got, want) {
			t.Errorf("Which(%q) = %v, one at a time = %v", text, got, want)
		}
		// The boolean is a separate engine path - it may answer from a literal
		// scan without running a pattern - so it is asked separately rather than
		// derived from the indices.
		if got, wantAny := set.MatchString(text), len(want) != 0; got != wantAny {
			t.Errorf("Match(%q) = %v, want %v", text, got, wantAny)
		}
	}
}

// TestSetEverySubsetAgrees is the same claim under composition. A slate's
// prefilter is built from the patterns it holds, so removing one changes how the
// others are searched for; a set that is right at full membership can still be
// wrong at a subset. 255 subsets is cheap enough to just do all of them.
func TestSetEverySubsetAgrees(t *testing.T) {
	for mask := 1; mask < 1<<len(setPatterns); mask++ {
		var exprs []string
		for i, expr := range setPatterns {
			if mask&(1<<i) != 0 {
				exprs = append(exprs, expr)
			}
		}
		set := irgx.MustCompileSet(exprs...)
		for _, text := range setTexts {
			want := oneAtATime(t, exprs, text)
			if got := set.WhichString(text); !reflect.DeepEqual(got, want) {
				t.Fatalf("subset %v: Which(%q) = %v, one at a time = %v", exprs, text, got, want)
			}
		}
	}
}

func TestSetMatchesBytesAndStringsAlike(t *testing.T) {
	set := irgx.MustCompileSet(setPatterns...)
	for _, text := range setTexts {
		if got, want := set.Match([]byte(text)), set.MatchString(text); got != want {
			t.Errorf("Match(%q) = %v, MatchString = %v", text, got, want)
		}
		if got, want := set.Which([]byte(text)), set.WhichString(text); !reflect.DeepEqual(got, want) {
			t.Errorf("Which(%q) = %v, WhichString = %v", text, got, want)
		}
	}
}

// TestSetEmpty pins the degenerate set as an answer rather than an error: a
// config file that listed no patterns matches nothing, and both verbs say so.
func TestSetEmpty(t *testing.T) {
	set := irgx.MustCompileSet()
	if set.Len() != 0 {
		t.Errorf("Len() = %d, want 0", set.Len())
	}
	for _, text := range []string{"", "anything"} {
		if set.MatchString(text) {
			t.Errorf("empty set matched %q", text)
		}
		if got := set.WhichString(text); got != nil {
			t.Errorf("empty set Which(%q) = %v, want nil", text, got)
		}
	}
}

func TestSetFlagsReachEveryPattern(t *testing.T) {
	for _, tc := range []struct {
		name string
		opts irgx.CompileOpts
		pats []string
		text string
		want []int
	}{
		{"ignoreCase", irgx.CompileOpts{IgnoreCase: true}, []string{"abc", "xyz"}, "ABC", []int{0}},
		{"caseSensitive", irgx.CompileOpts{}, []string{"abc", "xyz"}, "ABC", nil},
		{"word", irgx.CompileOpts{Word: true}, []string{"cat", "dog"}, "concatenate", nil},
		{"wordOff", irgx.CompileOpts{}, []string{"cat", "dog"}, "concatenate", []int{0}},
		{"fixed", irgx.CompileOpts{Fixed: true}, []string{`a.c`, `x*`}, "abc", nil},
		{"fixedLiteral", irgx.CompileOpts{Fixed: true}, []string{`a.c`, `x*`}, "a.c x*", []int{0, 1}},
		// SmartCase is resolved per pattern, against each pattern's own text, so
		// one set can hold a folded pattern and a literal one.
		{"smartCase", irgx.CompileOpts{SmartCase: true}, []string{"abc", "ABC"}, "AbC", []int{0}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			set := tc.opts.MustCompileSet(tc.pats...)
			if got := set.WhichString(tc.text); !reflect.DeepEqual(got, tc.want) {
				t.Errorf("Which(%q) = %v, want %v", tc.text, got, tc.want)
			}
			// And the same flags through the single-pattern door agree.
			for i, expr := range tc.pats {
				want := contains(tc.want, i)
				if got := tc.opts.MustCompile(expr).MatchString(tc.text); got != want {
					t.Errorf("pattern %d (%q) alone = %v, in the set = %v", i, expr, got, want)
				}
			}
		})
	}
}

func contains(hits []int, i int) bool {
	for _, hit := range hits {
		if hit == i {
			return true
		}
	}
	return false
}

// TestSetRefusesLineFlags pins the two flags a set cannot carry as a refusal
// naming the field, not a quietly different answer.
func TestSetRefusesLineFlags(t *testing.T) {
	for _, tc := range []struct {
		field string
		opts  irgx.CompileOpts
	}{
		{"MultiLine", irgx.CompileOpts{MultiLine: true}},
		{"DotAll", irgx.CompileOpts{DotAll: true}},
	} {
		_, err := tc.opts.CompileSet("a")
		if err == nil {
			t.Fatalf("%s: CompileSet succeeded, want a refusal", tc.field)
		}
		if !strings.Contains(err.Error(), tc.field) {
			t.Errorf("%s: error %q does not name the field", tc.field, err)
		}
	}
}

// TestSetRefusalNamesItsIndex is why [irgx.SetError] exists: with two hundred
// patterns, "one of them is unsupported" is not something a caller can act on.
func TestSetRefusalNamesItsIndex(t *testing.T) {
	for _, tc := range []struct {
		name  string
		pats  []string
		index int
		check func(*testing.T, error)
	}{
		{
			name: "malformed", pats: []string{`a`, `b`, `c(`}, index: 2,
			check: func(t *testing.T, err error) {
				var bad *irgx.SyntaxError
				if !errors.As(err, &bad) {
					t.Fatalf("error %v is not a *SyntaxError", err)
				}
				if bad.Expr != `c(` {
					t.Errorf("SyntaxError.Expr = %q, want %q", bad.Expr, `c(`)
				}
			},
		},
		{
			// A construct the linear grammar declines and PCRE2 has: the set is
			// refused for the same reason a lone Compile would be, and the same
			// one flag rescues it.
			name: "needsPCRE", pats: []string{`a`, `c(?=at)`}, index: 1,
			check: func(t *testing.T, err error) {
				if !errors.Is(err, irgx.ErrNeedsPCRE) {
					t.Fatalf("error %v does not match ErrNeedsPCRE", err)
				}
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := irgx.CompileSet(tc.pats...)
			if err == nil {
				t.Fatal("CompileSet succeeded, want a refusal")
			}
			var refused *irgx.SetError
			if !errors.As(err, &refused) {
				t.Fatalf("error %v is not a *SetError", err)
			}
			if refused.Index != tc.index {
				t.Errorf("SetError.Index = %d, want %d", refused.Index, tc.index)
			}
			if refused.Expr != tc.pats[tc.index] {
				t.Errorf("SetError.Expr = %q, want %q", refused.Expr, tc.pats[tc.index])
			}
			if !strings.Contains(err.Error(), strconv.Itoa(tc.index)) {
				t.Errorf("message %q does not name the index", err)
			}
			tc.check(t, err)
		})
	}
	// And the flag that rescues it does.
	if _, err := (irgx.CompileOpts{PCRE: true}).CompileSet(`a`, `c(?=at)`); err != nil {
		t.Errorf("PCRE set: %v", err)
	}
}

func TestSetConcurrent(t *testing.T) {
	set := irgx.MustCompileSet(setPatterns...)
	want := make([][]int, len(setTexts))
	for i, text := range setTexts {
		want[i] = set.WhichString(text)
	}
	var wg sync.WaitGroup
	for range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for range 50 {
				for i, text := range setTexts {
					if got := set.WhichString(text); !reflect.DeepEqual(got, want[i]) {
						t.Errorf("Which(%q) = %v, want %v", text, got, want[i])
						return
					}
				}
			}
		}()
	}
	wg.Wait()
}

func TestSetIntrospection(t *testing.T) {
	set := irgx.MustCompileSet(`a`, `b+`)
	if set.Len() != 2 {
		t.Errorf("Len() = %d, want 2", set.Len())
	}
	if got := set.Patterns(); !reflect.DeepEqual(got, []string{`a`, `b+`}) {
		t.Errorf("Patterns() = %v", got)
	}
	if got, want := set.String(), `["a" "b+"]`; got != want {
		t.Errorf("String() = %s, want %s", got, want)
	}
	// The patterns are the Set's own copy: a caller's slice going out from under
	// it must not change what a pooled recompile compiles.
	exprs := []string{`a`, `b`}
	kept := irgx.MustCompileSet(exprs...)
	exprs[0] = `zzz`
	if got := kept.Patterns()[0]; got != `a` {
		t.Errorf("after the caller's slice changed, Patterns()[0] = %q, want %q", got, `a`)
	}
}

func TestMustCompileSetPanics(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Error("MustCompileSet did not panic on a malformed pattern")
		}
	}()
	irgx.MustCompileSet(`a`, `b(`)
}
