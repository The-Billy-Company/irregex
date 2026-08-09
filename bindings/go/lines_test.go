//go:build cgo

package irgx_test

// The line plane, against an oracle written from the CONTRACT rather than from
// the engine: terminators are '\n' alone, a CRLF's '\r' stays in the content, and
// an unterminated tail is still a line. Those three sentences are the whole
// specification, so they can be implemented independently in Go and compared over
// a grid - which is what makes this a test rather than a mirror.

import (
	"slices"
	"strings"
	"testing"

	irgx "github.com/The-Billy-Company/irregex/bindings/go/v2"
)

// lineTexts covers the grid the off-by-ones live in: no text, no terminator, a
// trailing terminator, a doubled one, CRLF, a lone '\r' (not a terminator), and
// multi-byte content so no offset can be mistaken for a character index.
var lineTexts = []string{
	"", "a", "a\n", "\n", "\n\n", "a\nb", "a\nb\n",
	"a\r\nb\r\n", "a\rb", "héllo\nwörld", "\n\na\n\n",
}

// rows is the contract, implemented from its own sentences.
func rows(s string) []irgx.Line {
	out := []irgx.Line{}
	start, number := 0, 1
	for i := range len(s) {
		if s[i] != '\n' {
			continue
		}
		out = append(out, irgx.Line{Number: number, Start: start, ContentEnd: i, TermEnd: i + 1})
		start, number = i+1, number+1
	}
	if start < len(s) { // the unterminated tail, which is still a line
		out = append(out, irgx.Line{Number: number, Start: start, ContentEnd: len(s), TermEnd: len(s)})
	}
	return out
}

func TestLinesAreTheGridTheContractDescribes(t *testing.T) {
	for _, text := range lineTexts {
		want := rows(text)
		if got := irgx.LinesString(text); !slices.Equal(got, want) {
			t.Errorf("LinesString(%q) = %v, want %v", text, got, want)
		}
		if got := irgx.LineCountString(text); got != len(want) {
			t.Errorf("LineCountString(%q) = %d, want %d", text, got, len(want))
		}
	}
}

// A row's spans have to compose: content is the row a reader sees, TermEnd is
// where the next row starts, and rejoining every row's stored bytes has to
// reproduce the text exactly. A grid that gets the terminator wrong passes a
// per-row check and fails this one.
func TestRowsTileTheTextWithoutGapOrOverlap(t *testing.T) {
	for _, text := range lineTexts {
		var rebuilt strings.Builder
		at := 0
		for i, l := range irgx.LinesString(text) {
			if l.Start != at {
				t.Fatalf("%q row %d starts at %d, want %d", text, i, l.Start, at)
			}
			if l.Start > l.ContentEnd || l.ContentEnd > l.TermEnd {
				t.Fatalf("%q row %d is not ordered: %+v", text, i, l)
			}
			rebuilt.WriteString(text[l.Start:l.TermEnd])
			at = l.TermEnd
		}
		if rebuilt.String() != text {
			t.Errorf("rejoining the rows of %q gave %q", text, rebuilt.String())
		}
	}
}

// The '\r' belongs to the content, which is ripgrep's default and what the
// matching engines in this package see. A binding that stripped it for tidiness
// would put every caret one byte left of where a match is.
func TestCarriageReturnStaysInTheContent(t *testing.T) {
	got := irgx.LinesString("a\r\n")
	if len(got) != 1 {
		t.Fatalf("Lines(\"a\\r\\n\") = %v, want one row", got)
	}
	if want := (irgx.Line{Number: 1, Start: 0, ContentEnd: 2, TermEnd: 3}); got[0] != want {
		t.Errorf("row = %+v, want %+v (content keeps the CR)", got[0], want)
	}
}

// An offset sitting ON a terminator belongs to the line that terminator ENDS,
// not to the line after it. This is the adverse case for the whole plane: get it
// wrong and every band around a line break is off by one row.
func TestAnOffsetOnATerminatorBelongsToTheLineItEnds(t *testing.T) {
	const text = "a\nb\n" // the '\n' at 1 ends row 1; the 'b' at 2 opens row 2
	for _, c := range []struct {
		at   int
		want int
	}{{0, 1}, {1, 1}, {2, 2}, {3, 2}} {
		band, center := irgx.LineContextString(text, c.at, 0, 0)
		if len(band) != 1 || center != 0 {
			t.Fatalf("LineContext(%q, %d, 0, 0) = %v, center %d", text, c.at, band, center)
		}
		if band[0].Number != c.want {
			t.Errorf("byte %d is on line %d, want %d", c.at, band[0].Number, c.want)
		}
	}
}

// The band is -B/-A, and `center` is the number a caret needs: a band clipped at
// the top of the text has fewer rows before the hit than it asked for, so the
// index cannot be derived from len(band).
func TestContextBandClampsWithoutRenumberingAndCenterFollows(t *testing.T) {
	const text = "one\ntwo\nthree\nfour\nfive\n"
	at := strings.Index(text, "three")
	for _, c := range []struct {
		before, after   int
		first, last     int
		wantLen, center int
	}{
		{0, 0, 3, 3, 1, 0},
		{1, 1, 2, 4, 3, 1},
		{9, 0, 1, 3, 3, 2}, // clipped at the top: two rows before, not nine
		{0, 9, 3, 5, 3, 0}, // clipped at the bottom
		{9, 9, 1, 5, 5, 2},
	} {
		band, center := irgx.LineContextString(text, at, c.before, c.after)
		if len(band) != c.wantLen || center != c.center {
			t.Errorf("[-%d,+%d] gave %d rows, center %d; want %d rows, center %d",
				c.before, c.after, len(band), center, c.wantLen, c.center)
			continue
		}
		if band[0].Number != c.first || band[len(band)-1].Number != c.last {
			t.Errorf("[-%d,+%d] spans lines %d..%d, want %d..%d",
				c.before, c.after, band[0].Number, band[len(band)-1].Number, c.first, c.last)
		}
		if band[center].Number != 3 {
			t.Errorf("[-%d,+%d] center row is %d, want the line holding the hit (3)",
				c.before, c.after, band[center].Number)
		}
	}
}

// The end of the text is a legal offset - it is where a match at EOF lands - and
// an offset outside it is caller arithmetic, which panics the way a slice does.
func TestContextAtTheEndIsLegalAndPastItPanics(t *testing.T) {
	const text = "a\nb"
	if band, center := irgx.LineContextString(text, len(text), 0, 0); len(band) != 1 || center != 0 {
		t.Errorf("LineContext at len(text) = %v, center %d; want the tail row", band, center)
	}
	for _, at := range []int{-1, len(text) + 1} {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("LineContext(%q, %d, 0, 0) did not panic", text, at)
				}
			}()
			irgx.LineContextString(text, at, 0, 0)
		}()
	}
}

// The []byte doors have to answer identically to the string ones, or a host that
// avoided a copy got a different grid for its trouble.
func TestByteAndStringDoorsAgree(t *testing.T) {
	for _, text := range lineTexts {
		if got, want := irgx.Lines([]byte(text)), irgx.LinesString(text); !slices.Equal(got, want) {
			t.Errorf("Lines(%q) = %v, LinesString = %v", text, got, want)
		}
		if got, want := irgx.LineCount([]byte(text)), irgx.LineCountString(text); got != want {
			t.Errorf("LineCount(%q) = %d, LineCountString = %d", text, got, want)
		}
	}
}
