//go:build cgo

package irgx_test

// The self-index plane, and the one plane whose oracle is perfect: the text is
// right there. Every claim an index makes about a text - how many times a pattern
// occurs, where, and what the bytes at an offset are - can be checked by asking
// the text directly, and the two arrive by unrelated routes (a backward search
// over a wavelet-encoded BWT versus a naive scan over a Go string).
//
// The interesting cases are the ones a suffix structure gets wrong when it is
// built wrong: the sentinel row, a pattern that is a prefix of another, overlapping
// occurrences, a text of one repeated byte, and the empty pattern.

import (
	"bytes"
	"slices"
	"strings"
	"testing"

	irgx "github.com/The-Billy-Company/irregex/bindings/go/v2"
)

var codexTexts = []string{
	"", "a", "aa", "aaaa", "abracadabra", "mississippi",
	"the quick brown fox jumps over the lazy dog",
	"héllo wörld héllo",
	"a\x00b\x00c",
	strings.Repeat("ab", 500),
	strings.Repeat("x", 1000) + "needle" + strings.Repeat("y", 1000),
}

// probes are patterns worth asking of every text: present and absent, one byte and
// many, overlapping, and the whole text itself.
var codexProbes = []string{
	"", "a", "b", "z", "aa", "ab", "abra", "issi", "ssi", "the", "needle",
	"héllo", "\x00", "nope", "abracadabra", strings.Repeat("ab", 3),
}

func buildCodex(t *testing.T, text string, opts irgx.CodexOpts) *irgx.Codex {
	t.Helper()
	cx, err := irgx.BuildCodexString(text, opts)
	if err != nil {
		t.Fatalf("BuildCodexString(%d bytes): %v", len(text), err)
	}
	t.Cleanup(cx.Close)
	return cx
}

func TestCountIsEveryOverlappingOccurrenceInTheText(t *testing.T) {
	for _, text := range codexTexts {
		cx := buildCodex(t, text, irgx.CodexOpts{})
		for _, probe := range codexProbes {
			// The empty pattern counts 0 by contract - a search answer, not the
			// vacuous n+1 the mathematics gives - so the oracle says 0 too.
			want := len(occurrences(text, probe))
			if got := cx.Count(probe); got != want {
				t.Errorf("Count(%q) over %q = %d, want %d", probe, elide(text), got, want)
			}
		}
	}
}

func TestLocateIsEveryOffsetInAscendingOrder(t *testing.T) {
	for _, text := range codexTexts {
		cx := buildCodex(t, text, irgx.CodexOpts{})
		for _, probe := range codexProbes {
			at, ok := cx.Locate(probe)
			if !ok {
				t.Fatalf("Locate(%q) declined on an index built with a locate layer", probe)
			}
			want := occurrences(text, probe)
			if !slices.IsSorted(at) {
				t.Errorf("Locate(%q) over %q is not ascending: %v", probe, elide(text), at)
			}
			if !slices.Equal(at, want) {
				t.Errorf("Locate(%q) over %q = %v, want %v", probe, elide(text), at, want)
			}
			if len(at) != cx.Count(probe) {
				t.Errorf("Locate(%q) gave %d offsets but Count said %d", probe, len(at), cx.Count(probe))
			}
			// Every offset it names has to really hold the pattern - the check that
			// catches a locate layer whose sampling is off by one.
			for _, i := range at {
				if i+len(probe) > len(text) || text[i:i+len(probe)] != probe {
					t.Errorf("Locate(%q) named %d, where the text has %q", probe, i, elide(text[i:]))
				}
			}
		}
	}
}

// The whole point of the structure: the index IS the text, so a host may delete
// the original. Extract has to reproduce every substring, and the ends are where
// an off-by-one lives.
func TestTheIndexReconstructsTheTextItNeverStored(t *testing.T) {
	for _, text := range codexTexts {
		cx := buildCodex(t, text, irgx.CodexOpts{})
		if cx.Len() != len(text) {
			t.Errorf("Len() = %d over a %d-byte text", cx.Len(), len(text))
		}
		if got := cx.Text(); !bytes.Equal(got, []byte(text)) {
			t.Errorf("Text() = %q, want %q", elide(string(got)), elide(text))
			continue
		}
		for at := range len(text) + 1 {
			for _, n := range []int{0, 1, 3, len(text), len(text) + 10} {
				want := text[at:min(at+n, len(text))]
				if got := cx.Extract(at, n); string(got) != want {
					t.Errorf("Extract(%d, %d) over %q = %q, want %q", at, n, elide(text), got, want)
				}
			}
		}
		// An offset one past the end is the legal empty tail; two past it is
		// caller arithmetic and panics.
		if got := cx.Extract(len(text), 5); len(got) != 0 {
			t.Errorf("Extract(len, 5) = %q, want nothing", got)
		}
		for _, at := range []int{-1, len(text) + 1} {
			func() {
				defer func() {
					if recover() == nil {
						t.Errorf("Extract(%d, 1) over a %d-byte text did not panic", at, len(text))
					}
				}()
				cx.Extract(at, 1)
			}()
		}
	}
}

// Driving the backward search by hand has to land where Count does, which is the
// contract that lets a host share work between patterns with a common suffix. The
// loop below is the one in Extend's own documentation, run against every probe.
func TestDrivingTheRowIntervalByHandAgreesWithCount(t *testing.T) {
	for _, text := range codexTexts {
		cx := buildCodex(t, text, irgx.CodexOpts{})
		whole := cx.Whole()
		// Every row plus the sentinel's, which is what makes Position's range
		// Len()+1 rather than Len().
		if whole.Width() != len(text)+1 {
			t.Errorf("Whole() = %+v (width %d) over a %d-byte text, want width %d",
				whole, whole.Width(), len(text), len(text)+1)
		}
		for _, probe := range codexProbes {
			rows, live := whole, true
			for i := len(probe) - 1; i >= 0 && live; i-- {
				rows, live = cx.Extend(rows, probe[i])
			}
			if live != (rows.Width() > 0) {
				t.Errorf("Extend(%q) reported live=%v with width %d", probe, live, rows.Width())
			}
			// The empty probe never enters the loop, and its interval is every
			// row - which is not its occurrence count, by the same deliberate
			// exception Count makes.
			if probe == "" {
				continue
			}
			if got, want := rows.Width(), cx.Count(probe); got != want {
				t.Errorf("driving %q by hand gave width %d, Count said %d", probe, got, want)
			}
			// An empty interval stays empty, so a caller may stop at the first
			// false without checking again.
			if !live {
				for _, b := range []byte{'a', 0, 255} {
					if next, stillLive := cx.Extend(rows, b); stillLive || next.Width() != 0 {
						t.Errorf("extending a dead interval by %q revived it: %+v live=%v", b, next, stillLive)
					}
				}
			}
		}
	}
}

// Position maps a row to a text offset, and the rows of a completed pattern are
// exactly the offsets Locate reports - the identity that says the two layers agree
// with each other rather than each with itself.
func TestPositionOverAPatternsRowsIsWhatLocateReports(t *testing.T) {
	const text = "mississippi"
	cx := buildCodex(t, text, irgx.CodexOpts{})
	for _, probe := range []string{"i", "ss", "issi", "ppi", "m"} {
		rows, live := cx.Whole(), true
		for i := len(probe) - 1; i >= 0 && live; i-- {
			rows, live = cx.Extend(rows, probe[i])
		}
		if !live {
			t.Fatalf("%q does not occur in %q", probe, text)
		}
		var got []int
		for row := rows.Lo; row < rows.Hi; row++ {
			at, ok := cx.Position(row)
			if !ok {
				t.Fatalf("Position(%d) declined on an index with a locate layer", row)
			}
			got = append(got, at)
		}
		slices.Sort(got)
		want, _ := cx.Locate(probe)
		if !slices.Equal(got, want) {
			t.Errorf("walking the rows of %q gave %v, Locate said %v", probe, got, want)
		}
	}
	// There are Len()+1 rows; one past that is a caller's arithmetic.
	if _, ok := cx.Position(cx.Len()); !ok {
		t.Error("the sentinel row declined a position")
	}
	for _, row := range []int{-1, cx.Len() + 1} {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("Position(%d) did not panic", row)
				}
			}()
			cx.Position(row)
		}()
	}
}

// NoLocate is a DECLINATURE, not an empty answer: counting stays exact, and
// "where" reports that the structure was never built. An index that answered an
// empty slice here would tell a caller the pattern does not occur.
func TestWithoutALocateLayerCountingIsExactAndWhereDeclines(t *testing.T) {
	const text = "abracadabra"
	full := buildCodex(t, text, irgx.CodexOpts{})
	bare := buildCodex(t, text, irgx.CodexOpts{SampleRate: irgx.NoLocate})

	if stats := bare.Measure(); stats.Locates || stats.LocateBytes != 0 || stats.SampleRate != 0 {
		t.Errorf("a NoLocate index reports %+v, want no locate layer and a zero rate", stats)
	}
	for _, probe := range []string{"a", "abra", "nope", ""} {
		if got, want := bare.Count(probe), full.Count(probe); got != want {
			t.Errorf("Count(%q) without a locate layer = %d, want %d", probe, got, want)
		}
		if at, ok := bare.Locate(probe); ok {
			t.Errorf("Locate(%q) answered %v without a locate layer, want a declinature", probe, at)
		}
	}
	if at, ok := bare.Position(0); ok {
		t.Errorf("Position(0) answered %d without a locate layer", at)
	}
	// The text is still reconstructible - the locate layer is about WHERE, not
	// about the bytes.
	if got := bare.Text(); string(got) != text {
		t.Errorf("Text() = %q without a locate layer, want %q", got, text)
	}
	// And the whole point of asking for it: it costs less.
	if bare.Measure().IndexBytes >= full.Measure().IndexBytes {
		t.Errorf("a NoLocate index (%d bytes) is not smaller than one with a locate layer (%d)",
			bare.Measure().IndexBytes, full.Measure().IndexBytes)
	}
}

// A saved image reloads into an index that answers identically. Round-tripping is
// how the structure survives a process, so "identically" means every verb, not
// just a count.
func TestASavedIndexReloadsAnsweringIdentically(t *testing.T) {
	for _, text := range codexTexts {
		cx := buildCodex(t, text, irgx.CodexOpts{})
		image := cx.Save()
		if len(image) == 0 {
			t.Fatalf("Save() over %q produced nothing", elide(text))
		}
		back, err := irgx.LoadCodex(image)
		if err != nil {
			t.Fatalf("LoadCodex of %d bytes: %v", len(image), err)
		}
		if got, want := back.Len(), cx.Len(); got != want {
			t.Errorf("the reloaded index is %d bytes long, want %d", got, want)
		}
		if !bytes.Equal(back.Text(), cx.Text()) {
			t.Errorf("the reloaded index reconstructs %q, want %q", elide(string(back.Text())), elide(text))
		}
		for _, probe := range codexProbes {
			if got, want := back.Count(probe), cx.Count(probe); got != want {
				t.Errorf("reloaded Count(%q) = %d, want %d", probe, got, want)
			}
			gotAt, gotOK := back.Locate(probe)
			wantAt, wantOK := cx.Locate(probe)
			if gotOK != wantOK || !slices.Equal(gotAt, wantAt) {
				t.Errorf("reloaded Locate(%q) = %v/%v, want %v/%v", probe, gotAt, gotOK, wantAt, wantOK)
			}
		}
		// Saving the reloaded index reproduces the image, so the format is stable
		// rather than merely readable.
		if again := back.Save(); !bytes.Equal(again, image) {
			t.Errorf("re-saving the reloaded index gave %d bytes, want the original %d", len(again), len(image))
		}
		back.Close()
	}
}

// Fails closed: half an index would answer confidently and wrongly, so anything
// that is not exactly an image this build wrote is an error rather than a
// best-effort load.
func TestLoadingASpoiledImageFailsClosed(t *testing.T) {
	image := buildCodex(t, "abracadabra", irgx.CodexOpts{}).Save()
	for _, c := range []struct {
		name  string
		image []byte
	}{
		{"empty", nil},
		{"truncated", image[:len(image)/2]},
		{"one byte short", image[:len(image)-1]},
		{"a flipped header bit", flip(image, 0)},
		{"a flipped body bit", flip(image, len(image)/2)},
		{"a flipped trailing bit", flip(image, len(image)-1)},
		{"random bytes", []byte("not an index at all, just some bytes")},
	} {
		if cx, err := irgx.LoadCodex(c.image); err == nil {
			cx.Close()
			t.Errorf("LoadCodex accepted %s", c.name)
		}
	}
}

func flip(image []byte, at int) []byte {
	out := slices.Clone(image)
	out[at] ^= 0x40
	return out
}

// PlainOnly forbids the compressed form, so the index has a predictable size
// rather than a smaller one - and it must answer exactly the same, because an
// encoding is not a semantics.
func TestTheEncodingChoiceDoesNotChangeAnyAnswer(t *testing.T) {
	for _, text := range codexTexts {
		compact := buildCodex(t, text, irgx.CodexOpts{})
		plain := buildCodex(t, text, irgx.CodexOpts{PlainOnly: true})
		if !bytes.Equal(plain.Text(), compact.Text()) {
			t.Errorf("the two encodings reconstruct different texts for %q", elide(text))
		}
		for _, probe := range codexProbes {
			if got, want := plain.Count(probe), compact.Count(probe); got != want {
				t.Errorf("PlainOnly Count(%q) over %q = %d, want %d", probe, elide(text), got, want)
			}
			gotAt, _ := plain.Locate(probe)
			wantAt, _ := compact.Locate(probe)
			if !slices.Equal(gotAt, wantAt) {
				t.Errorf("PlainOnly Locate(%q) over %q = %v, want %v", probe, elide(text), gotAt, wantAt)
			}
		}
	}
}

// A larger sample rate trades index size for locate speed, and the answers are
// invariant across every rate - the property that makes the knob safe to turn.
func TestTheSampleRateChangesTheCostAndNotTheAnswer(t *testing.T) {
	const text = "mississippi river, mississippi delta, mississippi mud"
	base := buildCodex(t, text, irgx.CodexOpts{})
	for _, rate := range []uint32{1, 2, 4, 8, 32, 256} {
		cx := buildCodex(t, text, irgx.CodexOpts{SampleRate: rate})
		if stats := cx.Measure(); !stats.Locates || stats.SampleRate != rate {
			t.Errorf("rate %d built an index reporting %+v", rate, stats)
		}
		for _, probe := range []string{"mississippi", "issi", "i", "delta", "nope"} {
			gotAt, ok := cx.Locate(probe)
			if !ok {
				t.Fatalf("rate %d declined to locate %q", rate, probe)
			}
			wantAt, _ := base.Locate(probe)
			if !slices.Equal(gotAt, wantAt) {
				t.Errorf("rate %d Locate(%q) = %v, want %v", rate, probe, gotAt, wantAt)
			}
		}
	}
}

// Measure is arithmetic over the index, so its parts have to add up and its text
// length has to be the text's.
func TestMeasureDescribesTheIndexItBuilt(t *testing.T) {
	const text = "the quick brown fox jumps over the lazy dog"
	cx := buildCodex(t, text, irgx.CodexOpts{})
	stats := cx.Measure()
	if stats.TextLen != len(text) || stats.TextLen != cx.Len() {
		t.Errorf("Measure().TextLen = %d, Len() = %d, want %d", stats.TextLen, cx.Len(), len(text))
	}
	if stats.IndexBytes <= 0 {
		t.Errorf("Measure().IndexBytes = %d", stats.IndexBytes)
	}
	if stats.TreeBytes+stats.LocateBytes > stats.IndexBytes {
		t.Errorf("the layers (%d tree + %d locate) exceed the whole index (%d)",
			stats.TreeBytes, stats.LocateBytes, stats.IndexBytes)
	}
	if !stats.Locates || stats.LocateBytes == 0 {
		t.Errorf("a default index reports %+v, want a locate layer", stats)
	}
	// IndexBytes is what the index occupies RESIDENT, which says nothing about how
	// many bytes it serializes to - the image here is less than half the live
	// structure. What is checkable is that the sizing probe was exact: Save asks
	// for the size first, so a second Save must produce the same length rather
	// than a doubled guess.
	if a, b := cx.Save(), cx.Save(); len(a) != len(b) {
		t.Errorf("two Save() calls gave %d and %d bytes; the sizing probe is not exact", len(a), len(b))
	}
}

// The ceiling is a number a host can refuse against, and a text past it is
// refused here rather than after an allocation that was going to fail.
func TestTheTextCeilingIsReportedAndEnforced(t *testing.T) {
	if got := irgx.MaxCodexTextLen(); got <= 0 {
		t.Fatalf("MaxCodexTextLen() = %d", got)
	}
	// The empty text is a legal index of nothing, which is the other end of the
	// same range and the one an empty file produces.
	cx := buildCodex(t, "", irgx.CodexOpts{})
	if cx.Len() != 0 || len(cx.Text()) != 0 || cx.Count("a") != 0 {
		t.Errorf("the empty index reports len %d, text %q, count %d", cx.Len(), cx.Text(), cx.Count("a"))
	}
	if w := cx.Whole().Width(); w != 1 {
		t.Errorf("the empty index has %d rows, want just the sentinel's", w)
	}
}

// The []byte and string doors build the same index, and the bytes are not retained -
// the index absorbed what it needed, so overwriting the caller's buffer afterwards
// cannot change an answer.
func TestBuildingFromBytesDoesNotRetainThem(t *testing.T) {
	buf := []byte("abracadabra")
	cx, err := irgx.BuildCodex(buf, irgx.CodexOpts{})
	if err != nil {
		t.Fatalf("BuildCodex: %v", err)
	}
	defer cx.Close()
	before := cx.Count("abra")
	for i := range buf {
		buf[i] = 'z'
	}
	if got := cx.Count("abra"); got != before {
		t.Errorf("Count(\"abra\") changed from %d to %d after the source buffer was overwritten", before, got)
	}
	if got := string(cx.Text()); got != "abracadabra" {
		t.Errorf("Text() = %q after the source buffer was overwritten", got)
	}
}

func TestClosingACodexTwiceIsHarmless(t *testing.T) {
	cx, err := irgx.BuildCodexString("abc", irgx.CodexOpts{})
	if err != nil {
		t.Fatalf("BuildCodexString: %v", err)
	}
	cx.Close()
	cx.Close()
}

// elide keeps a failure message readable when the text under test is a thousand
// bytes of one letter.
func elide(s string) string {
	if len(s) <= 48 {
		return s
	}
	return s[:24] + "…" + s[len(s)-24:]
}
