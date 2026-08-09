//go:build cgo

package irgx_test

// The walk plane, over temp trees whose eligible set is derivable by hand from
// ripgrep's documented precedence: gitignore hides a file, `--hidden` reveals a
// dotfile, an explicit glob overrides a type filter, and a `!` rule in an ignore
// file un-hides what an earlier rule hid. Those are the rules a caller reasons
// with, so they are what the tests state - as file sets, not as counts, because a
// count that happens to match with the wrong two files in it is not agreement.
//
// The size and genus columns get a second, independent oracle: os.Stat for the
// size, and the tree plane's own eligibility for whether the walk and the search
// agree about which files exist at all.

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	irgx "github.com/The-Billy-Company/irregex/bindings/go/v2"
)

// eligible is the walk's answer as relative slash-paths, sorted.
func eligible(t *testing.T, root string, w *irgx.Walk) []string {
	t.Helper()
	out := []string{}
	for _, e := range w.All() {
		rel, err := filepath.Rel(root, e.Path)
		if err != nil {
			rel = e.Path
		}
		out = append(out, filepath.ToSlash(rel))
	}
	slices.Sort(out)
	return out
}

func openWalk(t *testing.T, spec irgx.WalkSpec) *irgx.Walk {
	t.Helper()
	w, err := irgx.OpenWalk(spec)
	if err != nil {
		t.Fatalf("OpenWalk(%+v): %v", spec, err)
	}
	t.Cleanup(w.Close)
	return w
}

func TestGitignoreHidesAFileAndNoIgnoreBringsItBack(t *testing.T) {
	root := corpus(t, map[string]string{
		".gitignore":  "ignored.txt\nbuild/\n",
		"kept.txt":    "a",
		"ignored.txt": "b",
		"build/o.txt": "c",
	})
	// A tree with no .git is still governed by its .gitignore only when the
	// requirement is lifted - which is ripgrep's own rule, and the reason a
	// walk over a scratch directory surprises people.
	w := openWalk(t, irgx.WalkSpec{Terms: []irgx.Term{irgx.RootOf(root)}, NoRequireGit: true})
	if want := []string{"kept.txt"}; !slices.Equal(eligible(t, root, w), want) {
		t.Errorf("walk = %v, want %v", eligible(t, root, w), want)
	}
	all := openWalk(t, irgx.WalkSpec{Terms: []irgx.Term{irgx.RootOf(root)}, NoIgnore: true, Hidden: true})
	if want := []string{".gitignore", "build/o.txt", "ignored.txt", "kept.txt"}; !slices.Equal(eligible(t, root, all), want) {
		t.Errorf("NoIgnore+Hidden walk = %v, want %v", eligible(t, root, all), want)
	}
}

// A negation in an ignore file re-admits what an earlier rule hid, and it is
// order-sensitive - which is why a walk cannot be modelled as a set of excluded
// globs applied in any order.
func TestANegatedIgnoreRuleReadmitsTheFileItNames(t *testing.T) {
	root := corpus(t, map[string]string{
		".gitignore": "*.log\n!keep.log\n",
		"a.log":      "x",
		"keep.log":   "y",
		"b.txt":      "z",
	})
	w := openWalk(t, irgx.WalkSpec{Terms: []irgx.Term{irgx.RootOf(root)}, NoRequireGit: true})
	if want := []string{"b.txt", "keep.log"}; !slices.Equal(eligible(t, root, w), want) {
		t.Errorf("walk = %v, want %v", eligible(t, root, w), want)
	}
}

func TestHiddenFilesAreOutUntilAskedFor(t *testing.T) {
	root := corpus(t, map[string]string{
		"seen.txt":        "a",
		".hidden.txt":     "b",
		".dir/inside.txt": "c",
	})
	w := openWalk(t, irgx.WalkSpec{Terms: []irgx.Term{irgx.RootOf(root)}})
	if want := []string{"seen.txt"}; !slices.Equal(eligible(t, root, w), want) {
		t.Errorf("default walk = %v, want %v", eligible(t, root, w), want)
	}
	h := openWalk(t, irgx.WalkSpec{Terms: []irgx.Term{irgx.RootOf(root)}, Hidden: true})
	if want := []string{".dir/inside.txt", ".hidden.txt", "seen.txt"}; !slices.Equal(eligible(t, root, h), want) {
		t.Errorf("hidden walk = %v, want %v", eligible(t, root, h), want)
	}
}

func TestGlobsAndTypesSelectAndTheLastGlobWins(t *testing.T) {
	root := corpus(t, map[string]string{
		"a.go": "package a", "b.go": "package b", "c.md": "# c", "d.json": "{}",
	})
	base := []irgx.Term{irgx.RootOf(root)}
	for _, c := range []struct {
		name  string
		terms []irgx.Term
		want  []string
	}{
		{"one glob", []irgx.Term{{Kind: irgx.Glob, Text: "*.go"}}, []string{"a.go", "b.go"}},
		{"a negated glob", []irgx.Term{{Kind: irgx.GlobNot, Text: "*.go"}}, []string{"c.md", "d.json"}},
		{"glob then negation", []irgx.Term{
			{Kind: irgx.Glob, Text: "*.go"}, {Kind: irgx.GlobNot, Text: "b.go"},
		}, []string{"a.go"}},
		{"a type", []irgx.Term{irgx.TypeOf("go")}, []string{"a.go", "b.go"}},
		{"a negated type", []irgx.Term{{Kind: irgx.TypeNot, Text: "go"}}, []string{"c.md", "d.json"}},
		{"case-insensitive glob", []irgx.Term{{Kind: irgx.IGlob, Text: "*.GO"}}, []string{"a.go", "b.go"}},
	} {
		w := openWalk(t, irgx.WalkSpec{Terms: append(slices.Clone(base), c.terms...)})
		if got := eligible(t, root, w); !slices.Equal(got, c.want) {
			t.Errorf("%s: walk = %v, want %v", c.name, got, c.want)
		}
	}
}

// An extra ignore file is a term, which is how a tool ships its own ignore rules
// without writing into the tree it is searching.
func TestAnExtraIgnoreFileIsHonouredAsATerm(t *testing.T) {
	root := corpus(t, map[string]string{"a.txt": "a", "b.txt": "b"})
	rules := filepath.Join(t.TempDir(), "my.ignore")
	if err := os.WriteFile(rules, []byte("b.txt\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	w := openWalk(t, irgx.WalkSpec{Terms: []irgx.Term{
		irgx.RootOf(root), {Kind: irgx.IgnoreFile, Text: rules},
	}})
	if want := []string{"a.txt"}; !slices.Equal(eligible(t, root, w), want) {
		t.Errorf("walk = %v, want %v", eligible(t, root, w), want)
	}
}

func TestMaxDepthCountsDirectoriesBelowTheRoot(t *testing.T) {
	root := corpus(t, map[string]string{
		"top.txt": "0", "one/a.txt": "1", "one/two/b.txt": "2", "one/two/three/c.txt": "3",
	})
	for depth, want := range map[uint64][]string{
		1: {"top.txt"},
		2: {"one/a.txt", "top.txt"},
		3: {"one/a.txt", "one/two/b.txt", "top.txt"},
		0: {"one/a.txt", "one/two/b.txt", "one/two/three/c.txt", "top.txt"}, // 0 = no limit
	} {
		w := openWalk(t, irgx.WalkSpec{Terms: []irgx.Term{irgx.RootOf(root)}, MaxDepth: depth})
		if got := eligible(t, root, w); !slices.Equal(got, want) {
			t.Errorf("MaxDepth %d = %v, want %v", depth, got, want)
		}
	}
}

// Len, All and Next are three views of one set, and Rewind makes the walk
// re-readable - the property that separates a materialized set from a stream.
// Draining one at a time crosses the internal batch boundary repeatedly, which is
// where a refill drops or repeats an entry.
func TestTheSetIsMaterializedRereadableAndAgreesWithItself(t *testing.T) {
	files := map[string]string{}
	for i := range 100 {
		files["f"+itoa(i)+".txt"] = "body " + itoa(i)
	}
	root := corpus(t, files)
	w := openWalk(t, irgx.WalkSpec{Terms: []irgx.Term{irgx.RootOf(root)}})
	if w.Len() != 100 {
		t.Fatalf("Len() = %d, want 100", w.Len())
	}
	first := eligible(t, root, w)
	if len(first) != 100 {
		t.Fatalf("All() gave %d entries, Len() said %d", len(first), w.Len())
	}
	// All drained it; without a Rewind there is nothing left, and with one the
	// same set comes back.
	if _, ok := w.Next(); ok {
		t.Error("Next yielded past the end of a drained walk")
	}
	w.Rewind()
	var again []string
	for e, ok := w.Next(); ok; e, ok = w.Next() {
		rel, _ := filepath.Rel(root, e.Path)
		again = append(again, filepath.ToSlash(rel))
	}
	slices.Sort(again)
	if !slices.Equal(again, first) {
		t.Errorf("the walk read differently the second time: %d vs %d entries", len(again), len(first))
	}
}

// Holds is membership without a scan, so it has to answer exactly what the
// materialized set contains - including a firm no for a path that exists on disk
// but was filtered out.
func TestHoldsAgreesWithTheMaterializedSet(t *testing.T) {
	root := corpus(t, map[string]string{
		".gitignore": "out.txt\n", "in.go": "package a", "out.txt": "x", "other.md": "# m",
	})
	w := openWalk(t, irgx.WalkSpec{
		Terms:        []irgx.Term{irgx.RootOf(root), irgx.TypeOf("go")},
		NoRequireGit: true,
	})
	members := eligible(t, root, w)
	for _, name := range []string{"in.go", "out.txt", "other.md", ".gitignore", "nonexistent.go"} {
		want := slices.Contains(members, name)
		if got := w.Holds(filepath.Join(root, name)); got != want {
			t.Errorf("Holds(%q) = %v, want %v (set is %v)", name, got, want, members)
		}
	}
	// Membership is about the SPELLING, not the file: the set holds the paths the
	// walk produced, so another route to the same bytes is not in it. Worth
	// pinning, because the alternative reading (resolve and compare inodes) is
	// what a caller assumes until it costs them a false negative.
	t.Chdir(root)
	for _, spelling := range []string{"in.go", "./in.go", "sub/../in.go"} {
		if w.Holds(spelling) {
			t.Errorf("Holds(%q) = true; membership is by the walk's own spelling, not by resolving the path", spelling)
		}
	}
	for _, e := range w.All() {
		if !w.Holds(e.Path) {
			t.Errorf("Holds(%q) = false for a path the walk itself produced", e.Path)
		}
	}
}

// Members is the setting that turns an inventory into a work plan: it applies the
// corpus content rules, so a binary blob and an empty file leave the set, and it
// is the only setting that fills in Size. Both halves matter to a Go caller -
// sizing a plain walk from Size would report an empty corpus - so both are
// pinned, with os.Stat as the oracle for the number.
func TestMembersAppliesTheContentRulesAndIsWhatFillsInSize(t *testing.T) {
	root := corpus(t, map[string]string{
		"empty.txt": "", "small.txt": "abc", "big.txt": strings.Repeat("x", 5000),
		"binary.dat": "aa\x00bb",
	})
	plain := openWalk(t, irgx.WalkSpec{Terms: []irgx.Term{irgx.RootOf(root)}})
	if want := []string{"big.txt", "binary.dat", "empty.txt", "small.txt"}; !slices.Equal(eligible(t, root, plain), want) {
		t.Errorf("a plain walk = %v, want every path %v", eligible(t, root, plain), want)
	}
	plain.Rewind()
	for _, e := range plain.All() {
		if e.Size != 0 {
			t.Errorf("%q reports size %d without Members; the field is only filled when files are read", e.Path, e.Size)
		}
	}

	members := openWalk(t, irgx.WalkSpec{Terms: []irgx.Term{irgx.RootOf(root)}, Members: true})
	got := eligible(t, root, members)
	if want := []string{"big.txt", "small.txt"}; !slices.Equal(got, want) {
		t.Errorf("a members walk = %v, want %v - the empty and binary files are not members", got, want)
	}
	members.Rewind()
	for _, e := range members.All() {
		info, err := os.Stat(e.Path)
		if err != nil {
			t.Errorf("the walk offered %q, which does not stat: %v", e.Path, err)
			continue
		}
		if int64(e.Size) != info.Size() {
			t.Errorf("%q: walk says %d bytes, stat says %d", e.Path, e.Size, info.Size())
		}
	}
}

// Genus partitions the corpus by what a file is FOR, and the three are total and
// disjoint: an unfamiliar extension lands in CODE, so a gap shows one file too
// many rather than silently hiding one.
func TestGenusIsTotalAndCodeIsTheLeftover(t *testing.T) {
	for _, c := range []struct {
		path string
		want irgx.Genus
	}{
		{"main.go", irgx.GenusCode}, {"lib.rs", irgx.GenusCode}, {"a.py", irgx.GenusCode},
		{"README.md", irgx.GenusDocs}, {"notes.rst", irgx.GenusDocs}, {"LICENSE", irgx.GenusDocs},
		{"CHANGELOG", irgx.GenusDocs},
		{"pkg.json", irgx.GenusData}, {"conf.yaml", irgx.GenusData}, {"Cargo.toml", irgx.GenusData},
		{"mystery.qqq", irgx.GenusCode}, {"noextension", irgx.GenusCode},
	} {
		if got := irgx.GenusOf(c.path); got != c.want {
			t.Errorf("GenusOf(%q) = %s, want %s", c.path, got, c.want)
		}
	}
	// Every walked entry carries one of the three - never a zero value that means
	// "unclassified", because a renderer partitioning on it would drop those rows.
	root := corpus(t, map[string]string{"a.go": "package a", "b.md": "# b", "c.toml": "k = 1", "d.qqq": "?"})
	w := openWalk(t, irgx.WalkSpec{Terms: []irgx.Term{irgx.RootOf(root)}})
	for _, e := range w.All() {
		if e.Genus != irgx.GenusCode && e.Genus != irgx.GenusDocs && e.Genus != irgx.GenusData {
			t.Errorf("%q has genus %d, which is none of the three", e.Path, e.Genus)
		}
		if want := irgx.GenusOf(e.Path); e.Genus != want {
			t.Errorf("%q: entry says %s, GenusOf says %s", e.Path, e.Genus, want)
		}
	}
}

// IsBinary is the NUL test over a window, which is what decides whether a file is
// searched as text at all. The window is the limit reported by WalkLimits, and a
// NUL past it is invisible by design - so the boundary is the test.
func TestIsBinaryIsTheNulTestOverTheReportedWindow(t *testing.T) {
	window := irgx.WalkLimits().BinaryWindow
	if window <= 0 {
		t.Fatalf("WalkLimits().BinaryWindow = %d, want a positive window", window)
	}
	for _, c := range []struct {
		name string
		body string
		want bool
	}{
		{"empty", "", false},
		{"plain text", "hello\nworld\n", false},
		{"utf-8", "héllo wörld", false},
		{"a NUL at the front", "\x00abc", true},
		{"a NUL mid-window", strings.Repeat("a", 100) + "\x00", true},
		{"a NUL at the last byte of the window", strings.Repeat("a", window-1) + "\x00", true},
		{"a NUL just past the window", strings.Repeat("a", window) + "\x00", false},
		{"high bytes but no NUL", "\xff\xfe\xfd", false},
	} {
		if got := irgx.IsBinaryString(c.body); got != c.want {
			t.Errorf("%s: IsBinary = %v, want %v", c.name, got, c.want)
		}
		if got := irgx.IsBinary([]byte(c.body)); got != c.want {
			t.Errorf("%s: IsBinary([]byte) = %v, want %v", c.name, got, c.want)
		}
	}
}

// The walk and the search have to agree about which files exist, or a caller
// planning work from the walk plans it over a different corpus than the one the
// search reads. Same default policy on both sides, so the eligible set is the
// set of files a match can come from.
func TestTheWalkAndTheSearchAgreeAboutWhichFilesExist(t *testing.T) {
	root := corpus(t, map[string]string{
		".gitignore": "hidden-from-both.txt\n",
		"a.txt":      "token here\n",
		"b/c.txt":    "token there\n",
		".dotfile":   "token in a dotfile\n",

		"hidden-from-both.txt": "token ignored\n",
	})
	w := openWalk(t, irgx.WalkSpec{Terms: []irgx.Term{irgx.RootOf(root)}, NoRequireGit: true})
	walked := eligible(t, root, w)

	tree, err := irgx.OpenCorpus(root)
	if err != nil {
		t.Fatalf("OpenCorpus: %v", err)
	}
	defer tree.Close()
	cur, err := tree.Search(context.Background(), irgx.SearchOpts{Pattern: "token"})
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	defer cur.Close()
	for _, rec := range cur.All() {
		rel, _ := filepath.Rel(root, rec.Path)
		if !slices.Contains(walked, filepath.ToSlash(rel)) {
			t.Errorf("the search read %q, which the walk says is not eligible (%v)", rel, walked)
		}
		if !w.Holds(rec.Path) {
			t.Errorf("the search read %q, which Holds denies", rel)
		}
	}
}

// A spec with no terms at all walks the working directory, and a term with an
// empty text is a refusal rather than a silently-ignored filter.
func TestNoTermsWalksHereAndAnEmptyTermIsRefused(t *testing.T) {
	root := corpus(t, map[string]string{"only.txt": "x"})
	t.Chdir(root)
	w := openWalk(t, irgx.WalkSpec{})
	if got := w.Len(); got != 1 {
		t.Errorf("a bare walk found %d files in its own working directory, want 1", got)
	}
	for _, term := range []irgx.Term{
		{Kind: irgx.Root, Text: ""}, {Kind: irgx.Glob, Text: ""}, {Kind: irgx.Type, Text: ""},
	} {
		if bad, err := irgx.OpenWalk(irgx.WalkSpec{Terms: []irgx.Term{term}}); err == nil {
			bad.Close()
			t.Errorf("OpenWalk with an empty %v term succeeded, want a refusal", term.Kind)
		}
	}
}

// A root that does not exist is an error, not an empty walk: "nothing matched" and
// "you named a directory that isn't there" are different answers, and conflating
// them turns a typo'd path into a search that quietly finds nothing.
func TestAMissingRootIsAnErrorRatherThanAnEmptyWalk(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "no-such-dir")
	if w, err := irgx.OpenWalk(irgx.WalkSpec{Terms: []irgx.Term{irgx.RootOf(missing)}}); err == nil {
		t.Errorf("OpenWalk over a missing root succeeded with %d entries, want an error", w.Len())
		w.Close()
	}
}

// The two brace ceilings are published so a host can size a user's glob before
// sending it. That is only worth doing if the published number is the enforced
// one, so each is driven to its own boundary rather than compared to a constant:
// exactly at the cap opens, one past it refuses. The two axes are independent -
// `{a}{a}{a}…` has a product of ONE, so it clears the first ceiling however long
// it grows, which is the entire reason both numbers exist.
func TestThePublishedBraceCeilingsAreTheOnesEnforced(t *testing.T) {
	root := corpus(t, map[string]string{"keep.a": "x"})
	lim := irgx.WalkLimits()
	if lim.BraceCap <= 0 || lim.BraceGroupCap <= 0 {
		t.Fatalf("WalkLimits() brace ceilings = %d/%d, want both positive",
			lim.BraceCap, lim.BraceGroupCap)
	}

	branches := func(n int) string {
		return "*.{" + strings.Repeat("e,", n-1) + "e}"
	}
	for _, c := range []struct {
		name string
		glob string
		open bool
	}{
		{"branches at the cap", branches(lim.BraceCap), true},
		{"branches one past it", branches(lim.BraceCap + 1), false},
		{"groups at the cap", strings.Repeat("{a}", lim.BraceGroupCap), true},
		{"groups one past it", strings.Repeat("{a}", lim.BraceGroupCap+1), false},
	} {
		t.Run(c.name, func(t *testing.T) {
			w, err := irgx.OpenWalk(irgx.WalkSpec{
				Terms: []irgx.Term{irgx.RootOf(root), irgx.GlobOf(c.glob)},
			})
			if err == nil {
				w.Close()
			}
			if opened := err == nil; opened != c.open {
				t.Errorf("OpenWalk opened = %v, want %v (err %v)", opened, c.open, err)
			}
		})
	}
}

// An unknown type name is a refusal too - `--type qqq` is a typo, and admitting
// every file or none of them are both worse answers than saying so.
func TestAnUnknownTypeNameIsRefused(t *testing.T) {
	root := corpus(t, map[string]string{"a.go": "package a"})
	if w, err := irgx.OpenWalk(irgx.WalkSpec{Terms: []irgx.Term{
		irgx.RootOf(root), irgx.TypeOf("definitely-not-a-type"),
	}}); err == nil {
		t.Errorf("OpenWalk with an unknown type succeeded with %d entries, want a refusal", w.Len())
		w.Close()
	}
}

// Entries are Go strings, so they outlive the walk that produced them - the same
// copy-at-the-boundary rule the tree plane turns on, and the same test for it.
func TestEntriesOutliveTheWalk(t *testing.T) {
	root := corpus(t, map[string]string{"a.txt": "a", "b.txt": "bb"})
	w, err := irgx.OpenWalk(irgx.WalkSpec{Terms: []irgx.Term{irgx.RootOf(root)}})
	if err != nil {
		t.Fatalf("OpenWalk: %v", err)
	}
	kept := w.All()
	before := slices.Clone(kept)
	w.Close()
	w.Close() // idempotent, and the second one is what a deferred Close adds
	for i, e := range kept {
		if e != before[i] {
			t.Fatalf("entry %d changed after Close: %+v was %+v", i, e, before[i])
		}
		if _, err := os.Stat(e.Path); err != nil {
			t.Fatalf("entry %d holds an unreadable path after Close: %v", i, err)
		}
	}
}

// Gapped is how many directories the walk could not read, and TolerateGaps is
// whether that is fatal. A gap has to be REPORTED rather than silently producing
// a smaller corpus, because a search over a partial tree that says nothing is a
// false negative.
func TestGappedCountsTheDirectoriesTheWalkCouldNotRead(t *testing.T) {
	root := corpus(t, map[string]string{"readable/a.txt": "a", "locked/b.txt": "b"})
	locked := filepath.Join(root, "locked")
	if err := os.Chmod(locked, 0o000); err != nil {
		t.Skipf("cannot make a directory unreadable here: %v", err)
	}
	t.Cleanup(func() { _ = os.Chmod(locked, 0o755) })
	if _, err := os.ReadDir(locked); err == nil {
		t.Skip("this filesystem (or this user) reads a 0000 directory anyway")
	}
	w := openWalk(t, irgx.WalkSpec{Terms: []irgx.Term{irgx.RootOf(root)}, TolerateGaps: true})
	if got := w.Gapped(); got == 0 {
		t.Errorf("Gapped() = 0 over a tree with an unreadable directory")
	}
	if got := eligible(t, root, w); !slices.Contains(got, "readable/a.txt") {
		t.Errorf("walk = %v, want the readable half of the tree", got)
	}
}
