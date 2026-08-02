package irgx_test

import (
	"encoding/json"
	"os"
	"reflect"
	"strconv"
	"testing"

	irgx "github.com/The-Billy-Company/irregex/bindings/go"
)

// The cross-check against the reference implementation.
//
// The Python binding was written against this same C ABI first, is
// independently verified, and its test suite pins the exact match semantics.
// testdata/python_oracle.json is its answer for a shared corpus of patterns,
// flags and texts, produced by scripts/python_oracle.py; this test asserts the
// Go binding produces the same spans, byte for byte.
//
// It is the strongest oracle available here because it is not derived from this
// code: a plausible-looking mistake in the iteration or capture logic - an
// advance loop instead of find_all, a dropped empty match, a group reported as
// empty rather than absent - shows up as a disagreement with a table this
// package did not compute.

type oracleFile struct {
	Generator     string       `json:"generator"`
	EngineVersion string       `json:"engine_version"`
	Cases         []oracleCase `json:"cases"`
}

type oracleCase struct {
	Name    string          `json:"name"`
	Pattern string          `json:"pattern"`
	Flags   map[string]bool `json:"flags"`
	Text    string          `json:"text"`
	Spans   [][]int         `json:"spans"`
	Groups  [][][]int       `json:"groups"`
}

func (c oracleCase) opts() irgx.CompileOpts {
	// The Python binding spells the Unicode flag positively and defaults it on;
	// this binding spells its absence, so the zero value is the default. Same
	// bit either way.
	return irgx.CompileOpts{
		Fixed:      c.Flags["fixed"],
		IgnoreCase: c.Flags["ignore_case"],
		Word:       c.Flags["word"],
		SmartCase:  c.Flags["smart_case"],
		ASCII:      hasKey(c.Flags, "unicode") && !c.Flags["unicode"],
		PCRE:       c.Flags["pcre"],
	}
}

func hasKey(m map[string]bool, k string) bool { _, ok := m[k]; return ok }

func loadOracle(t *testing.T) oracleFile {
	t.Helper()
	raw, err := os.ReadFile("testdata/python_oracle.json")
	if err != nil {
		t.Fatalf("read oracle: %v", err)
	}
	var file oracleFile
	if err := json.Unmarshal(raw, &file); err != nil {
		t.Fatalf("parse oracle: %v", err)
	}
	if len(file.Cases) == 0 {
		t.Fatal("oracle is empty; regenerate it with scripts/python_oracle.py")
	}
	return file
}

func TestPythonOracleSpans(t *testing.T) {
	file := loadOracle(t)
	if file.EngineVersion != irgx.Version() {
		t.Logf("oracle was generated against engine %s, this build links %s",
			file.EngineVersion, irgx.Version())
	}
	for _, c := range file.Cases {
		t.Run(c.Name+"/"+strconv.Quote(c.Text), func(t *testing.T) {
			re, err := c.opts().Compile(c.Pattern)
			if err != nil {
				t.Fatalf("compile %q: %v", c.Pattern, err)
			}
			got := re.FindAllStringIndex(c.Text, -1)
			want := nonEmpty(c.Spans)
			if !reflect.DeepEqual(got, want) {
				t.Errorf("FindAllStringIndex(%q) = %v, reference says %v", c.Text, got, want)
			}
			// The same question through the []byte half, which must agree: both
			// sides of the API run the same engine call on the same bytes.
			if gotBytes := re.FindAllIndex([]byte(c.Text), -1); !reflect.DeepEqual(gotBytes, want) {
				t.Errorf("FindAllIndex(%q) = %v, reference says %v", c.Text, gotBytes, want)
			}
			// And the offsets have to be usable as offsets into the caller's own
			// string, which is the whole claim about byte indexing.
			for _, loc := range got {
				if loc[0] < 0 || loc[1] > len(c.Text) || loc[0] > loc[1] {
					t.Fatalf("span %v is not a slice of a %d-byte string", loc, len(c.Text))
				}
				_ = c.Text[loc[0]:loc[1]]
			}
		})
	}
}

func TestPythonOracleGroups(t *testing.T) {
	for _, c := range loadOracle(t).Cases {
		if len(c.Groups) == 0 {
			continue
		}
		t.Run(c.Name+"/"+strconv.Quote(c.Text), func(t *testing.T) {
			re, err := c.opts().Compile(c.Pattern)
			if err != nil {
				t.Fatalf("compile %q: %v", c.Pattern, err)
			}
			got := re.FindAllStringSubmatchIndex(c.Text, -1)
			want := flattenGroups(c.Groups)
			if !reflect.DeepEqual(got, want) {
				t.Errorf("FindAllStringSubmatchIndex(%q) = %v, reference says %v", c.Text, got, want)
			}
		})
	}
}

// MatchString has its own engine verb, so it gets its own check: it must agree
// with the span table about whether there is a match at all.
func TestPythonOracleMatch(t *testing.T) {
	for _, c := range loadOracle(t).Cases {
		re, err := c.opts().Compile(c.Pattern)
		if err != nil {
			t.Fatalf("compile %q: %v", c.Pattern, err)
		}
		if got, want := re.MatchString(c.Text), len(c.Spans) > 0; got != want {
			t.Errorf("%s: MatchString(%q) = %v, reference found %d spans",
				c.Name, c.Text, got, len(c.Spans))
		}
	}
}

// nonEmpty maps the JSON [] onto Go's nil, which is what the Find family
// returns for no matches, so DeepEqual compares like with like.
func nonEmpty(spans [][]int) [][]int {
	if len(spans) == 0 {
		return nil
	}
	return spans
}

func flattenGroups(groups [][][]int) [][]int {
	if len(groups) == 0 {
		return nil
	}
	out := make([][]int, len(groups))
	for i, match := range groups {
		flat := make([]int, 0, 2*len(match))
		for _, span := range match {
			flat = append(flat, span[0], span[1])
		}
		out[i] = flat
	}
	return out
}
