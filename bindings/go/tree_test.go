//go:build cgo

package irgx_test

// The tree plane, against an oracle assembled in Go from the same files on disk:
// read every file the corpus is allowed to read, split it into lines, run the
// pattern over each line, and that is the answer. The engine gets there by a
// completely different route - a directory walk, a prefilter, a line-oriented
// searcher over mapped bytes - so the two agreeing is evidence rather than
// tautology.
//
// Every corpus here is a t.TempDir with its own files, so nothing depends on the
// repository this runs in.

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"

	irgx "github.com/The-Billy-Company/irregex/bindings/go/v2"
)

// corpus writes files into a fresh temp dir and returns it. Keys are relative
// paths using '/'; a key with a directory component gets its parents made.
func corpus(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for name, body := range files {
		path := filepath.Join(root, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

var treeFiles = map[string]string{
	"a.txt":       "alpha\nbeta\ngamma\n",
	"b.txt":       "beta again\nBETA shouting\n",
	"sub/c.txt":   "nested beta\nnothing here\n",
	"sub/d.md":    "beta in markdown\n",
	"unterm.txt":  "beta with no trailing newline",
	"empty.txt":   "",
	"nomatch.txt": "zeta\n",
}

// lineHits is the oracle: every (path, line number, line) the pattern hits,
// reading the files directly. It walks the tree itself rather than asking the
// engine which files were eligible, so an engine that skipped a file it should
// have read shows up as a missing record.
func lineHits(t *testing.T, root string, re *regexp.Regexp, invert bool) []string {
	t.Helper()
	out := []string{}
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		body, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		text := string(body)
		if text == "" {
			return nil
		}
		for i, line := range strings.Split(strings.TrimSuffix(text, "\n"), "\n") {
			if re.MatchString(line) != invert {
				out = append(out, filepath.ToSlash(rel)+":"+itoa(i+1)+":"+line)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	slices.Sort(out)
	return out
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for ; n > 0; n /= 10 {
		b = append([]byte{byte('0' + n%10)}, b...)
	}
	return string(b)
}

// found renders a cursor the same way the oracle renders a hit, with the path
// made relative so the two are comparable.
func found(t *testing.T, root string, cur *irgx.Cursor) []string {
	t.Helper()
	out := []string{}
	for _, rec := range cur.All() {
		rel, err := filepath.Rel(root, rec.Path)
		if err != nil {
			rel = rec.Path
		}
		if rec.Kind != irgx.KindLine {
			continue
		}
		out = append(out, filepath.ToSlash(rel)+":"+itoa(rec.Number)+":"+rec.Line)
	}
	slices.Sort(out)
	return out
}

func TestSearchingACorpusFindsExactlyWhatReadingItFinds(t *testing.T) {
	root := corpus(t, treeFiles)
	tree, err := irgx.OpenCorpus(root)
	if err != nil {
		t.Fatalf("OpenCorpus: %v", err)
	}
	defer tree.Close()

	for _, c := range []struct {
		opts   irgx.SearchOpts
		oracle string
	}{
		{irgx.SearchOpts{Pattern: "beta"}, "beta"},
		{irgx.SearchOpts{Pattern: "beta", IgnoreCase: true}, "(?i)beta"},
		{irgx.SearchOpts{Pattern: "b.ta"}, "b.ta"},
		{irgx.SearchOpts{Pattern: "^beta"}, "^beta"},
		{irgx.SearchOpts{Pattern: "beta$"}, "beta$"},
		{irgx.SearchOpts{Pattern: "b.ta", Fixed: true}, `b\.ta`},
		{irgx.SearchOpts{Pattern: "beta", Word: true}, `\bbeta\b`},
		{irgx.SearchOpts{Pattern: "zeta|alpha"}, "zeta|alpha"},
		{irgx.SearchOpts{Pattern: "nothing-is-here"}, "nothing-is-here"},
	} {
		cur, err := tree.Search(context.Background(), c.opts)
		if err != nil {
			t.Errorf("Search(%+v): %v", c.opts, err)
			continue
		}
		got := found(t, root, cur)
		cur.Close()
		if want := lineHits(t, root, regexp.MustCompile(c.oracle), false); !slices.Equal(got, want) {
			t.Errorf("Search(%q) =\n  %v\nwant\n  %v", c.opts.Pattern, got, want)
		}
	}
}

// Invert is a line-level complement, and the adverse case is the file with no
// trailing newline plus the empty file: a plane that manufactured a phantom last
// line would report one record too many, and only inversion makes that visible
// (a phantom empty line matches no pattern but IS a non-match).
func TestInvertIsTheComplementOverTheSameLineGrid(t *testing.T) {
	root := corpus(t, treeFiles)
	tree, err := irgx.OpenCorpus(root)
	if err != nil {
		t.Fatalf("OpenCorpus: %v", err)
	}
	defer tree.Close()
	cur, err := tree.Search(context.Background(), irgx.SearchOpts{Pattern: "beta", Invert: true})
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	defer cur.Close()
	if got, want := found(t, root, cur), lineHits(t, root, regexp.MustCompile("beta"), true); !slices.Equal(got, want) {
		t.Errorf("inverted search =\n  %v\nwant\n  %v", got, want)
	}
}

// Count is what the cursor holds, and All has to hand back exactly that many -
// which is the batching contract: a refill that dropped or duplicated a record at
// a batch boundary shows here and nowhere else. The batch is 32 internally, so a
// corpus with more hits than that crosses it repeatedly.
func TestCountAndIterationAgreeAcrossBatchBoundaries(t *testing.T) {
	var body strings.Builder
	for i := range 200 {
		body.WriteString("hit " + itoa(i) + "\n")
	}
	root := corpus(t, map[string]string{"many.txt": body.String()})
	tree, err := irgx.OpenCorpus(root)
	if err != nil {
		t.Fatalf("OpenCorpus: %v", err)
	}
	defer tree.Close()
	cur, err := tree.Search(context.Background(), irgx.SearchOpts{Pattern: "hit"})
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	defer cur.Close()
	if cur.Count() != 200 {
		t.Fatalf("Count() = %d, want 200", cur.Count())
	}
	// Drain one at a time so every batch boundary is crossed by Next, and check
	// the numbers arrive in order with none missing.
	seen := 0
	for rec, ok := cur.Next(); ok; rec, ok = cur.Next() {
		if rec.Number != seen+1 {
			t.Fatalf("record %d has line number %d", seen, rec.Number)
		}
		if want := "hit " + itoa(seen); rec.Line != want {
			t.Fatalf("record %d is %q, want %q", seen, rec.Line, want)
		}
		seen++
	}
	if seen != 200 {
		t.Errorf("Next yielded %d records, Count said %d", seen, cur.Count())
	}
	// Exhausted is exhausted, and asking again is not an error.
	if _, ok := cur.Next(); ok {
		t.Error("Next kept yielding past the end")
	}
}

// MaxResults is a cap on the cursor, not on the search, and 1 is the existence
// probe - the shape a "does this corpus mention X" caller uses.
func TestMaxResultsCapsTheCursorAndOneIsAnExistenceProbe(t *testing.T) {
	root := corpus(t, treeFiles)
	tree, err := irgx.OpenCorpus(root)
	if err != nil {
		t.Fatalf("OpenCorpus: %v", err)
	}
	defer tree.Close()
	for _, cap := range []int{1, 2, 3} {
		cur, err := tree.Search(context.Background(), irgx.SearchOpts{Pattern: "beta", MaxResults: cap})
		if err != nil {
			t.Fatalf("Search: %v", err)
		}
		if got := len(cur.All()); got > cap {
			t.Errorf("MaxResults %d yielded %d records", cap, got)
		}
		if got := cur.Count(); got == 0 {
			t.Errorf("MaxResults %d found nothing, but the corpus mentions beta", cap)
		}
		cur.Close()
	}
}

// Context is the band around a hit, and a context record is marked as one so a
// renderer can tell a hit from its surroundings without re-running the pattern.
func TestContextRecordsSurroundTheHitAndAreLabelled(t *testing.T) {
	root := corpus(t, map[string]string{"c.txt": "one\ntwo\nthree\nfour\nfive\n"})
	tree, err := irgx.OpenCorpus(root)
	if err != nil {
		t.Fatalf("OpenCorpus: %v", err)
	}
	defer tree.Close()
	cur, err := tree.Search(context.Background(), irgx.SearchOpts{Pattern: "three", Before: 1, After: 1})
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	defer cur.Close()
	var lines, kinds []string
	for _, rec := range cur.All() {
		lines = append(lines, rec.Line)
		kinds = append(kinds, rec.Kind.String())
	}
	if want := []string{"two", "three", "four"}; !slices.Equal(lines, want) {
		t.Errorf("band = %v, want %v", lines, want)
	}
	if want := []string{"context", "line", "context"}; !slices.Equal(kinds, want) {
		t.Errorf("kinds = %v, want %v", kinds, want)
	}
}

// Spans locate the match inside the line, and they are offsets into the line the
// record carries - so slicing the line by the span has to reproduce the matched
// text, and the stdlib is the oracle for what that text is.
func TestSpansIndexTheLineTheRecordCarries(t *testing.T) {
	root := corpus(t, map[string]string{"s.txt": "alpha beta alpha\n"})
	tree, err := irgx.OpenCorpus(root)
	if err != nil {
		t.Fatalf("OpenCorpus: %v", err)
	}
	defer tree.Close()
	cur, err := tree.Search(context.Background(), irgx.SearchOpts{Pattern: "alpha"})
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	defer cur.Close()
	recs := cur.All()
	if len(recs) != 1 {
		t.Fatalf("got %d records, want one line", len(recs))
	}
	rec := recs[0]
	if len(rec.Spans) == 0 {
		t.Fatal("a matching line carries no spans")
	}
	for _, span := range rec.Spans {
		if span[0] < 0 || span[1] > len(rec.Line) || span[0] > span[1] {
			t.Fatalf("span %v is not inside %q", span, rec.Line)
		}
		if got := rec.Line[span[0]:span[1]]; got != "alpha" {
			t.Errorf("span %v cuts %q, want \"alpha\"", span, got)
		}
	}
}

// A record's strings are Go strings, so they outlive both the cursor and the
// corpus. This is the C-memory borrow the whole plane turns on: if a record
// aliased the engine's arena, this test would read freed memory - which is the
// bug the copy at the boundary exists to make impossible.
func TestRecordsOutliveTheCursorAndTheCorpus(t *testing.T) {
	root := corpus(t, treeFiles)
	tree, err := irgx.OpenCorpus(root)
	if err != nil {
		t.Fatalf("OpenCorpus: %v", err)
	}
	cur, err := tree.Search(context.Background(), irgx.SearchOpts{Pattern: "beta"})
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	kept := cur.All()
	if len(kept) == 0 {
		t.Fatal("nothing to keep")
	}
	before := slices.Clone(kept)
	cur.Close()
	tree.Close()
	for i, rec := range kept {
		if rec.Path != before[i].Path || rec.Line != before[i].Line {
			t.Fatalf("record %d changed after Close: %+v was %+v", i, rec, before[i])
		}
		if !strings.Contains(strings.ToLower(rec.Line), "beta") {
			t.Fatalf("record %d reads %q after Close", i, rec.Line)
		}
	}
}

// The empty pattern is a refusal rather than "every line": it is almost always a
// variable that was never filled in, and answering the whole corpus is the
// least useful reading of it.
func TestSearchRefusesTheEmptyPatternAndNegativeBounds(t *testing.T) {
	tree, err := irgx.OpenCorpus(corpus(t, treeFiles))
	if err != nil {
		t.Fatalf("OpenCorpus: %v", err)
	}
	defer tree.Close()
	for _, opts := range []irgx.SearchOpts{
		{Pattern: ""},
		{Pattern: "beta", Before: -1},
		{Pattern: "beta", After: -1},
		{Pattern: "beta", MaxResults: -1},
		{Pattern: "beta", Timeout: -time.Second},
	} {
		if cur, err := tree.Search(context.Background(), opts); err == nil {
			cur.Close()
			t.Errorf("Search(%+v) succeeded, want a refusal", opts)
		}
	}
}

// A pattern the engine cannot compile is a compile error from the SEARCH, not a
// panic and not an empty result set.
func TestAnUncompilablePatternIsAnErrorFromSearch(t *testing.T) {
	tree, err := irgx.OpenCorpus(corpus(t, treeFiles))
	if err != nil {
		t.Fatalf("OpenCorpus: %v", err)
	}
	defer tree.Close()
	if cur, err := tree.Search(context.Background(), irgx.SearchOpts{Pattern: "a("}); err == nil {
		cur.Close()
		t.Error("Search(\"a(\") succeeded, want a syntax error")
	}
}

// A cancelled context is the CONTEXT's answer, so errors.Is against the stdlib
// sentinels holds - a caller that cancelled should not have to parse an engine
// fault to learn it was its own doing.
func TestACancelledContextIsReportedAsTheContextsError(t *testing.T) {
	tree, err := irgx.OpenCorpus(corpus(t, treeFiles))
	if err != nil {
		t.Fatalf("OpenCorpus: %v", err)
	}
	defer tree.Close()

	dead, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := tree.Search(dead, irgx.SearchOpts{Pattern: "beta"}); !errors.Is(err, context.Canceled) {
		t.Errorf("search under a cancelled context = %v, want context.Canceled", err)
	}
	expired, stop := context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
	defer stop()
	if _, err := tree.Search(expired, irgx.SearchOpts{Pattern: "beta"}); !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("search under an expired deadline = %v, want context.DeadlineExceeded", err)
	}
}

// Searching a closed corpus is a refusal, not a use-after-free. Ten goroutines
// sharing one Corpus is the shape that finds this, and the mutex is why it is
// safe: the handle owns scratch, so Search serializes rather than racing.
func TestAClosedCorpusRefusesAndSearchesSerialize(t *testing.T) {
	root := corpus(t, treeFiles)
	tree, err := irgx.OpenCorpus(root)
	if err != nil {
		t.Fatalf("OpenCorpus: %v", err)
	}
	done := make(chan int, 8)
	for range 8 {
		go func() {
			cur, err := tree.Search(context.Background(), irgx.SearchOpts{Pattern: "beta"})
			if err != nil {
				done <- -1
				return
			}
			n := len(cur.All())
			cur.Close()
			done <- n
		}()
	}
	first := <-done
	for range 7 {
		if got := <-done; got != first {
			t.Errorf("concurrent searches disagreed: %d vs %d", got, first)
		}
	}
	tree.Close()
	if cur, err := tree.Search(context.Background(), irgx.SearchOpts{Pattern: "beta"}); err == nil {
		cur.Close()
		t.Error("searching a closed corpus succeeded")
	}
}

// No roots means the working directory, which is what a bare command-line search
// does. Checked by chdir into a temp corpus so the assertion does not depend on
// the repository this test runs in.
func TestNoRootsMeansTheWorkingDirectory(t *testing.T) {
	root := corpus(t, map[string]string{"only.txt": "unmistakable-token\n"})
	t.Chdir(root)
	tree, err := irgx.OpenCorpus()
	if err != nil {
		t.Fatalf("OpenCorpus(): %v", err)
	}
	defer tree.Close()
	cur, err := tree.Search(context.Background(), irgx.SearchOpts{Pattern: "unmistakable-token"})
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	defer cur.Close()
	if got := cur.Count(); got != 1 {
		t.Errorf("a bare corpus found %d hits in its own working directory, want 1", got)
	}
}
