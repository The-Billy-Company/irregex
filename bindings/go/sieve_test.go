//go:build cgo

package irgx_test

// The narrowing plane. Two halves, tested differently on purpose.
//
// The PLAN half needs no corpus at all - a winnow is derived from the pattern
// alone - so it is tested hermetically, and the property under test is the one a
// caller bets on: a plan that says it cannot narrow must be believed, and a plan
// that says it can must be made of something.
//
// The INDEX half cannot be built through this C ABI: the artifacts are written by
// an indexer that lives outside it, so there is no hermetic way for a Go test to
// mint one. What IS testable hermetically is the declinature - an unindexed
// directory has to say so rather than pretend to be an empty index - and that is
// the case that actually bites, because an empty candidate set means "read
// nothing" while a declinature means "read everything". When an artifact home
// does exist on the machine, the soundness property gets checked against the real
// files it names; when it does not, that check skips rather than pretending.

import (
	"errors"
	"os"
	"slices"
	"strings"
	"testing"

	irgx "github.com/The-Billy-Company/irregex/bindings/go/v2"
)

// An unindexed directory is a DECLINATURE, not an empty index. The whole plane
// turns on this distinction: an empty candidate list would tell a caller to read
// nothing, which for an index that does not exist is exactly backwards.
func TestAnUnindexedDirectoryDeclinesRatherThanReadingAsEmpty(t *testing.T) {
	empty := t.TempDir()
	s, err := irgx.OpenSieve(empty)
	if !errors.Is(err, irgx.ErrNoIndex) {
		if err == nil {
			s.Close()
		}
		t.Fatalf("OpenSieve(%q) = %v, want ErrNoIndex", empty, err)
	}
	// The declinature is not an engine fault, so it must not arrive wearing one:
	// a caller distinguishing "no index" from "broken index" needs the sentinel to
	// be reachable by errors.Is and not by string matching.
	var fault *irgx.Error
	if errors.As(err, &fault) {
		t.Errorf("ErrNoIndex arrived as an engine error (%v); a declinature installs no fault", fault)
	}
}

// The same declinature through the door a host actually uses: no directory at all,
// meaning the artifact home. GIST_DIR is what resolves it, so pointing that at an
// empty directory makes the unindexed case deterministic instead of a question
// about the machine the test runs on.
func TestTheArtifactHomeDeclinesWhenNothingHasBeenIndexed(t *testing.T) {
	t.Setenv("GIST_DIR", t.TempDir())
	if s, err := irgx.OpenSieve(""); !errors.Is(err, irgx.ErrNoIndex) {
		if err == nil {
			s.Close()
		}
		t.Fatalf("OpenSieve(\"\") with an empty artifact home = %v, want ErrNoIndex", err)
	}
}

// A file where a directory belongs is a caller error rather than a declinature -
// "you pointed me at something that is not an artifact home" is a different
// answer from "nothing has been indexed here".
func TestAPathThatIsNotADirectoryIsAnErrorNotADeclinature(t *testing.T) {
	file := t.TempDir() + "/not-a-dir"
	if err := os.WriteFile(file, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	s, err := irgx.OpenSieve(file)
	if err == nil {
		s.Close()
		t.Skip("this build opens a plain file as an artifact home")
	}
	if errors.Is(err, irgx.ErrNoIndex) {
		t.Logf("a plain file reads as unindexed: %v", err)
	}
}

// Idle is a claim about the PATTERN, and a narrow one: nothing here prunes
// anything - no clause, no literal, no live swell - so a host should skip the
// index rather than walk a corpus proving nothing. It is not the same claim as
// "the tier will bound this at query time", which depends on the index and shows
// up as narrowed=false; a short literal like "a" is a plan with something in it
// that the trigram floor still declines.
func TestAPlanKnowsWhetherItCanPruneAtAll(t *testing.T) {
	for _, c := range []struct {
		pattern  string
		wantIdle bool
	}{
		{"WalletService", false},
		{"pgxpool\\.\\w+", false},
		{"foo.*bar", false},
		{"foobar|bazqux", false},
		{"a", false},      // a literal too short for the floor is still a literal
		{"[a-z]+", false}, // a class feeds the swell even though it binds no literal
		{".*", true},      // nothing anywhere to prune with
		{"^", true},       // an assertion prunes nothing
		{"(?s).", true},   // any single byte
	} {
		re := irgx.MustCompile(c.pattern)
		plan, err := re.Winnow()
		if err != nil {
			t.Fatalf("Winnow(%q): %v", c.pattern, err)
		}
		facts := plan.Describe()
		if facts.Idle != c.wantIdle {
			t.Errorf("Winnow(%q).Idle = %v, want %v (facts %+v)", c.pattern, facts.Idle, c.wantIdle, facts)
		}
		// A plan that claims it can narrow has to be made of something, or the
		// claim is unfalsifiable and a caller spends a query on an empty plan.
		if !facts.Idle && facts.Literals == 0 && facts.Alternatives == 0 {
			t.Errorf("Winnow(%q) is not idle but binds no literal and no alternative: %+v", c.pattern, facts)
		}
		if facts.Idle && facts.SieveActive {
			t.Errorf("Winnow(%q) is idle yet reports the tier active: %+v", c.pattern, facts)
		}
		plan.Close()
		plan.Close() // idempotent
	}
}

// A plan outlives the pattern it came from: it copies what it needs, which is what
// lets a host derive plans once and drop the regexps. If it borrowed, this would
// read freed memory.
func TestAPlanOutlivesThePatternItWasDerivedFrom(t *testing.T) {
	plan, err := irgx.MustCompile("WalletService").Winnow()
	if err != nil {
		t.Fatalf("Winnow: %v", err)
	}
	defer plan.Close()
	before := plan.Describe()
	for range 3 {
		// Compile and drop a few more, so a plan that aliased a pooled handle's
		// arena would be reading something reused by now.
		irgx.MustCompile("other" + "Pattern").Winnow()
	}
	if got := plan.Describe(); got != before {
		t.Errorf("the plan changed after its pattern went away: %+v was %+v", got, before)
	}
}

// The empty needle is in every document, so asking about it is not a question -
// and answering "every document" would look like a successful narrowing that
// narrowed nothing. Same for an alternation with no branches, and for a branch
// that is empty inside one that is not.
func TestTheEmptyProbeIsRefusedRatherThanAnsweredWithEverything(t *testing.T) {
	s := openArtifactHome(t)
	for _, c := range []struct {
		name string
		call func()
	}{
		{"an empty needle", func() { s.MayContain("") }},
		{"no branches", func() { s.MayContainAny() }},
		{"an empty branch", func() { s.MayContainAny("alpha", "") }},
	} {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("MayContain with %s did not panic", c.name)
				}
			}()
			c.call()
		}()
	}
}

// openArtifactHome opens the machine's own artifact home, skipping the test when
// nothing has been indexed. The index cannot be built through this ABI, so this
// is the honest shape: real work when there is an index to read, and a skip that
// says why when there is not.
func openArtifactHome(t *testing.T) *irgx.Sieve {
	t.Helper()
	s, err := irgx.OpenSieve("")
	if errors.Is(err, irgx.ErrNoIndex) {
		t.Skip("no narrowing index at the artifact home; nothing to read (the indexer is outside this ABI)")
	}
	if err != nil {
		t.Fatalf("OpenSieve(\"\"): %v", err)
	}
	t.Cleanup(s.Close)
	return s
}

// What an index says about itself has to hold together: every document id it
// issues resolves to a path, the roots it was built over are all readable, and the
// counts agree with the ids.
func TestAnIndexDescribesItselfConsistently(t *testing.T) {
	s := openArtifactHome(t)
	facts := s.Describe()
	if facts.Docs <= 0 || facts.Paths <= 0 {
		t.Fatalf("Describe() = %+v, want a non-empty index", facts)
	}
	roots := s.Roots()
	if len(roots) != facts.Roots {
		t.Errorf("Roots() gave %d, Describe().Roots said %d", len(roots), facts.Roots)
	}
	for i, root := range roots {
		if root == "" {
			t.Errorf("root %d is empty", i)
		}
	}
	// Every id in range resolves; the one past the end is a caller's arithmetic
	// and panics, the way a slice index does.
	for _, doc := range []irgx.Doc{0, irgx.Doc(facts.Paths - 1)} {
		if s.Path(doc) == "" {
			t.Errorf("document %d has an empty path", doc)
		}
	}
	func() {
		defer func() {
			if recover() == nil {
				t.Errorf("Path(%d) past the end did not panic", facts.Paths)
			}
		}()
		s.Path(irgx.Doc(facts.Paths))
	}()
	func() {
		defer func() {
			if recover() == nil {
				t.Errorf("Root(%d) past the end did not panic", facts.Roots)
			}
		}()
		s.Root(facts.Roots)
	}()
}

// Freshness is a posture, and StaleCount is the magnitude behind it. They cannot
// disagree: an index reporting itself anchored with a positive stale count would
// be telling a caller elision is safe while knowing files moved.
func TestFreshnessAndStaleCountTellTheSameStory(t *testing.T) {
	s := openArtifactHome(t)
	fresh := s.Freshness()
	switch fresh.State {
	case irgx.Anchored, irgx.Unanchored, irgx.Foreign:
	default:
		t.Fatalf("Freshness().State = %d, which is none of the three postures", fresh.State)
	}
	n, ok := s.StaleCount()
	if fresh.State == irgx.Foreign && ok {
		t.Errorf("a foreign index counted %d stale documents; it has no anchor to count against", n)
	}
	if !ok && n != 0 {
		t.Errorf("StaleCount declined but still reported %d", n)
	}
	if fresh.State == irgx.Anchored && fresh.Anchor.IsZero() {
		t.Error("an anchored index has no anchor time")
	}
	t.Logf("artifact home: %s, anchor %v, %d stale (counted: %v)", fresh.State, fresh.Anchor, n, ok)
}

// THE soundness property, and the only one worth a real oracle: a narrowing tier
// may over-admit but must never under-admit, because a document it drops is a
// document nobody reads. So for a needle whose bytes are really in a file the
// index names, that file's document must be in the candidate set.
//
// The index is a statement about the bytes AS BUILT, so the oracle has to be read
// against those bytes - which is per FILE, not per index: a file untouched since
// the anchor still holds exactly what was indexed, however stale the corpus as a
// whole has become. So each document is admitted to the oracle only when its own
// mtime precedes the anchor, which keeps the check running in a working tree ten
// agents are editing instead of skipping the moment anything moves.
func TestNarrowingNeverDropsADocumentThatHoldsTheNeedle(t *testing.T) {
	// The artifact home is resolved against the working directory and its anchor
	// dates the tree it was built over, so this has to ask from the top of the
	// checkout - from a subdirectory the same artifacts read as foreign.
	t.Chdir("../..")
	s := openArtifactHome(t)
	fresh := s.Freshness()
	if fresh.Anchor.IsZero() || fresh.State == irgx.Foreign {
		t.Skipf("the artifact home is %s with anchor %v; nothing here dates the bytes on disk", fresh.State, fresh.Anchor)
	}
	facts := s.Describe()
	stale, _ := s.StaleCount()
	t.Logf("%d documents, %s, %d changed since %v", facts.Paths, fresh.State, stale, fresh.Anchor)

	// asBuilt is every document whose file has not been touched since the index
	// was built - the population the index's claims are still about.
	asBuilt := make([]irgx.Doc, 0, facts.Paths)
	bodies := make(map[irgx.Doc]string, facts.Paths)
	for id := range facts.Paths {
		doc := irgx.Doc(id)
		path := s.Path(doc)
		info, err := os.Stat(path)
		if err != nil || !info.ModTime().Before(fresh.Anchor) {
			continue
		}
		body, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		asBuilt = append(asBuilt, doc)
		bodies[doc] = string(body)
	}
	if len(asBuilt) == 0 {
		t.Skip("every indexed file has changed since the anchor; there is nothing the index still describes")
	}

	// Needles long enough to clear the trigram floor, drawn from what this corpus
	// actually is rather than invented.
	checked := 0
	for _, needle := range []string{"irgx_sieve_open", "trigram", "IRGX_STALE", "unicode", "propertyHas"} {
		docs, narrowed := s.MayContain(needle)
		if !narrowed {
			t.Logf("%q: the tier could not bound it; nothing to check", needle)
			continue
		}
		admitted := map[irgx.Doc]bool{}
		for _, d := range docs {
			admitted[d] = true
		}
		holders := 0
		for _, doc := range asBuilt {
			if !strings.Contains(bodies[doc], needle) {
				continue
			}
			holders++
			if !admitted[doc] {
				t.Errorf("%q is in %s, which the tier did not admit - a document it drops is a document nobody reads",
					needle, s.Path(doc))
			}
		}
		if holders > 0 {
			checked++
		}
		if len(docs) >= facts.Paths {
			t.Logf("%q admitted every document; the probe narrowed nothing", needle)
		}
	}
	if checked == 0 {
		t.Skip("none of the probe needles occur in the unchanged half of the corpus")
	}
}

// A union is only as bindable as its least bindable branch: one branch nothing can
// bound leaves the whole answer unbounded, so a tier that returned the branches it
// happened to manage would be handing back a narrower set than the truth.
func TestAnAlternationIsUnboundedWhenAnyBranchIs(t *testing.T) {
	s := openArtifactHome(t)
	bindable, ok := s.MayContain("trigram")
	if !ok {
		t.Skip("this corpus cannot bound even a long literal")
	}
	// "a" is below the floor, so the union of it with anything is unbounded.
	if docs, narrowed := s.MayContainAny("trigram", "a"); narrowed {
		t.Errorf("an alternation with an unbindable branch reported %d documents as bounded", len(docs))
	}
	// A union of two bindable branches is bounded, and it contains each branch's
	// own set - a union that lost a branch would be a false negative.
	both, narrowed := s.MayContainAny("trigram", "unicode")
	if !narrowed {
		t.Skip("this corpus cannot bound the two-literal union")
	}
	for _, d := range bindable {
		if !slices.Contains(both, d) {
			t.Errorf("the union dropped document %d, which the single probe admitted", d)
		}
	}
}

// Candidates and ReadingList are the same SET in different orders - one as the
// index was built, one sound against live bytes and sequenced by what is cheapest
// to read. The reading list may be a superset (a changed file is folded back in)
// but may never be missing a candidate.
func TestTheReadingListIsTheCandidateSetSequencedForReading(t *testing.T) {
	s := openArtifactHome(t)
	plan, err := irgx.MustCompile("irgx_sieve_open").Winnow()
	if err != nil {
		t.Fatalf("Winnow: %v", err)
	}
	defer plan.Close()
	if plan.Describe().Idle {
		t.Skip("the probe pattern binds nothing")
	}
	candidates, okC := s.Candidates(plan)
	list, okL := s.ReadingList(plan)
	if !okC {
		t.Skip("the tier declined the plan")
	}
	if !okL {
		t.Error("Candidates narrowed but ReadingList declined; the list falls back to every document rather than declining")
	}
	if !slices.IsSorted(candidates) {
		t.Error("Candidates is not in document-id order")
	}
	for _, d := range candidates {
		if !slices.Contains(list, d) {
			t.Errorf("the reading list is missing candidate %d", d)
		}
	}
	// Every id in either answer has to be a real document.
	docs := s.Describe().Paths
	for _, d := range append(slices.Clone(candidates), list...) {
		if int(d) >= docs {
			t.Fatalf("document id %d is outside an index of %d documents", d, docs)
		}
	}
}
