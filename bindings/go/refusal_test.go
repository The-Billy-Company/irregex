package irgx_test

import (
	"errors"
	"io"
	"reflect"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"testing"

	irgx "github.com/The-Billy-Company/irregex/bindings/go"
)

// The two halves of a refused compile. The engine decides which is which by
// handing the pattern to PCRE2, so these rows are the two sides of that
// question: constructs PCRE2 has and the linear grammar does not, and text
// PCRE2 rejects as well.

// declined is a construct outside the linear grammar, with what it finds once
// the PCRE flag is set. Every row must be rescuable, or ErrNeedsPCRE is a lie.
var declined = []struct {
	pattern string
	text    string
	want    []int
}{
	{`(?=x)`, "ax", []int{1, 1}},
	{`(?<=x)y`, "xy", []int{1, 2}},
	{`(a)\1`, "aa", []int{0, 2}},
	{`(?>ab)`, "ab", []int{0, 2}},
}

// malformed is text no grammar here accepts, with the byte offset the engine
// reports. The offsets are pinned rather than merely bounded: they are what a
// caller points at, so a shift in them is a change worth being told about.
var malformed = []struct {
	pattern string
	at      int
}{
	{`(unclosed`, 9},
	{`a{2,1}`, 5},
	{`[z-a]`, 4},
	{`*x`, 1},
	{`[abc`, 4},
}

func TestDeclinedPatternRetriesWithPCRE(t *testing.T) {
	for _, tc := range declined {
		t.Run(tc.pattern, func(t *testing.T) {
			re, err := irgx.Compile(tc.pattern)
			if err == nil {
				t.Fatalf("Compile(%q) succeeded under the linear grammar", tc.pattern)
			}
			if re != nil {
				t.Errorf("Compile returned %v alongside the error; a declinature writes no handle", re)
			}
			if !errors.Is(err, irgx.ErrNeedsPCRE) {
				t.Fatalf("error %q does not match ErrNeedsPCRE", err)
			}
			// A construct the other grammar has is not a defect in the text, so
			// there is no offset to report and no SyntaxError to report it in.
			var bad *irgx.SyntaxError
			if errors.As(err, &bad) {
				t.Errorf("declined pattern came back as %T (%v), want the sentinel only", bad, bad)
			}
			if !strings.Contains(err.Error(), strconv.Quote(tc.pattern)) {
				t.Errorf("error %q does not name the pattern", err)
			}

			// The retry the sentinel exists to authorize.
			re, err = irgx.CompileOpts{PCRE: true}.Compile(tc.pattern)
			if err != nil {
				t.Fatalf("PCRE compile: %v", err)
			}
			if got := re.FindStringIndex(tc.text); !reflect.DeepEqual(got, tc.want) {
				t.Errorf("over %q found %v, want %v", tc.text, got, tc.want)
			}
			if !re.MatchString(tc.text) {
				t.Errorf("MatchString(%q) = false", tc.text)
			}
		})
	}
}

func TestMalformedPatternCarriesItsOffset(t *testing.T) {
	for _, tc := range malformed {
		t.Run(tc.pattern, func(t *testing.T) {
			re, err := irgx.Compile(tc.pattern)
			if err == nil {
				t.Fatalf("Compile(%q) = %v, want an error", tc.pattern, re)
			}
			var bad *irgx.SyntaxError
			if !errors.As(err, &bad) {
				t.Fatalf("error is %T (%v), want *irgx.SyntaxError", err, err)
			}
			if bad.Expr != tc.pattern {
				t.Errorf("Expr = %q, want %q", bad.Expr, tc.pattern)
			}
			// An offset outside the pattern cannot be pointed at, which is the
			// only thing a caller wants it for. len is inside: it is the
			// position one past the last byte, where an unclosed group ends.
			if bad.At < 0 || bad.At > len(tc.pattern) {
				t.Fatalf("At = %d, outside %q (len %d)", bad.At, tc.pattern, len(tc.pattern))
			}
			if bad.At != tc.at {
				t.Errorf("At = %d, want %d", bad.At, tc.at)
			}
			if bad.Reason == "" {
				t.Error("Reason is empty; the engine's word for the defect was dropped")
			}
			for _, want := range []string{strconv.Quote(tc.pattern), strconv.Itoa(bad.At), bad.Reason} {
				if !strings.Contains(bad.Error(), want) {
					t.Errorf("message %q does not carry %q", bad, want)
				}
			}
			// Nothing accepts it, so the flag that rescues a declinature does
			// not rescue this - and it must not start looking rescuable.
			pcre, err := irgx.CompileOpts{PCRE: true}.Compile(tc.pattern)
			if err == nil {
				t.Fatalf("with PCRE, Compile(%q) = %v, want an error", tc.pattern, pcre)
			}
			if errors.Is(err, irgx.ErrNeedsPCRE) {
				t.Errorf("with PCRE, error %q still asks for PCRE", err)
			}
			if !errors.As(err, &bad) {
				t.Errorf("with PCRE, error is %T (%v), want *irgx.SyntaxError", err, err)
			}
		})
	}
}

// The engine measures its offset in one of two rulers and says which. Nothing
// in this plane opens a file, so the only ruler it can name is the pattern, and
// this is where that is load-bearing: a reader that got the space wrong either
// drops the position - leaving a plain error with no caret to print - or hands
// back an index into a string the caller never passed. Both halves are checked,
// because SyntaxError.At and the seam error underneath it are filled separately
// and a caller may reach for either.
func TestARefusalIsPositionedInThePattern(t *testing.T) {
	for _, tc := range malformed {
		t.Run(tc.pattern, func(t *testing.T) {
			for _, pcre := range []bool{false, true} {
				_, err := irgx.CompileOpts{PCRE: pcre}.Compile(tc.pattern)
				var bad *irgx.SyntaxError
				if !errors.As(err, &bad) {
					t.Fatalf("pcre=%v: error is %T (%v), want *irgx.SyntaxError", pcre, err, err)
				}
				if bad.At < 0 || bad.At > len(bad.Expr) {
					t.Fatalf("pcre=%v: At = %d, which is no position in %q", pcre, bad.At, bad.Expr)
				}
				// The caret a caller prints sits under Expr[At], so the offset
				// has to slice the pattern rather than merely be a number.
				_ = bad.Expr[:bad.At]
				var seam *irgx.Error
				if !errors.As(err, &seam) {
					t.Fatalf("pcre=%v: no *irgx.Error underneath", pcre)
				}
				if seam.At != int64(bad.At) {
					t.Errorf("pcre=%v: the seam reports byte %d, the class reports %d", pcre, seam.At, bad.At)
				}
			}
		})
	}
}

// The two classes have to be told apart from each other and from anything else
// a caller might be matching in the same errors.Is chain.
func TestRefusalClassesAreDistinguishable(t *testing.T) {
	_, declinature := irgx.Compile(declined[0].pattern)
	_, defect := irgx.Compile(malformed[0].pattern)
	if declinature == nil || defect == nil {
		t.Fatal("both patterns were supposed to be refused")
	}

	var bad *irgx.SyntaxError
	if errors.As(declinature, &bad) {
		t.Error("the declinature is also a *SyntaxError")
	}
	if errors.Is(defect, irgx.ErrNeedsPCRE) {
		t.Error("the malformed pattern also matches ErrNeedsPCRE")
	}
	if !errors.As(defect, &bad) || !errors.Is(declinature, irgx.ErrNeedsPCRE) {
		t.Fatal("a class stopped matching itself")
	}
	// An unrelated sentinel must not be swallowed by either one.
	unrelated := errors.New("something else entirely")
	for name, err := range map[string]error{"declinature": declinature, "defect": defect} {
		if errors.Is(err, io.EOF) || errors.Is(err, unrelated) {
			t.Errorf("%s matches an unrelated error", name)
		}
	}
	// And the generic seam error is still reachable under the defect, which is
	// where its status code and fault plane live.
	var seam *irgx.Error
	if !errors.As(defect, &seam) {
		t.Fatal("the defect does not unwrap to an *irgx.Error")
	}
	if seam.Status >= 0 {
		t.Errorf("Status = %d, want a negative status", seam.Status)
	}
	// The declinature is not a failure, so it carries no seam error to unwrap.
	if errors.As(declinature, &seam) {
		t.Error("the declinature unwraps to an *irgx.Error; it is a routing fact, not a fault")
	}
}

// The fault slot reports the last failure on THIS THREAD, and a declinature
// installs none. So a declinature that follows a real failure on the same
// thread must not borrow its detail - no offset, no fault name, no SyntaxError.
func TestDeclinatureIgnoresAnEarlierFault(t *testing.T) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	for _, prior := range malformed {
		if _, err := irgx.Compile(prior.pattern); err == nil {
			t.Fatalf("Compile(%q) was supposed to fail and leave a fault", prior.pattern)
		}
		_, err := irgx.Compile(declined[0].pattern)
		if !errors.Is(err, irgx.ErrNeedsPCRE) {
			t.Fatalf("after %q failed, the declinature came back as %v", prior.pattern, err)
		}
		var bad *irgx.SyntaxError
		if errors.As(err, &bad) {
			t.Errorf("after %q failed, the declinature picked up %v", prior.pattern, bad)
		}
		if strings.Contains(err.Error(), "at byte") || strings.Contains(err.Error(), prior.pattern) {
			t.Errorf("after %q failed, the declinature says %q", prior.pattern, err)
		}
	}
}

// A declinature never writes *out, so there is nothing to store and nothing to
// free. Run enough of them, from enough goroutines, that a handle leaked or a
// handle freed twice would show up - as a crash, or as a Regexp that stops
// answering afterwards. Under -race this also covers the compile path itself.
func TestDeclinatureRepeatsCleanly(t *testing.T) {
	const workers = 16
	const rounds = 400

	canary := irgx.MustCompile(`\d+`)
	var wg sync.WaitGroup
	wg.Add(workers)
	for w := range workers {
		go func() {
			defer wg.Done()
			for round := range rounds {
				tc := declined[(w+round)%len(declined)]
				re, err := irgx.Compile(tc.pattern)
				if re != nil {
					t.Errorf("worker %d round %d: %q returned a handle", w, round, tc.pattern)
					return
				}
				if !errors.Is(err, irgx.ErrNeedsPCRE) {
					t.Errorf("worker %d round %d: %q = %v", w, round, tc.pattern, err)
					return
				}
				if round%64 == 0 {
					runtime.GC()
				}
			}
		}()
	}
	wg.Wait()

	// Nothing degraded: a Regexp built before the churn still answers, and a
	// fresh compile of a declined pattern still succeeds with the flag.
	if got := canary.FindString("abc 123"); got != "123" {
		t.Errorf("after the churn, FindString = %q, want 123", got)
	}
	re, err := irgx.CompileOpts{PCRE: true}.Compile(declined[0].pattern)
	if err != nil {
		t.Fatalf("after the churn, PCRE compile: %v", err)
	}
	if !re.MatchString(declined[0].text) {
		t.Errorf("after the churn, %q does not match %q", declined[0].pattern, declined[0].text)
	}
}

// MustCompile has no error channel, so the panic is the only place the remedy
// can be named.
func TestMustCompilePanicNamesTheRemedy(t *testing.T) {
	defer func() {
		recovered := recover()
		msg, ok := recovered.(string)
		if !ok {
			t.Fatalf("panic value %v is %T, want a string", recovered, recovered)
		}
		for _, want := range []string{declined[0].pattern, "PCRE"} {
			if !strings.Contains(msg, want) {
				t.Errorf("panic %q does not mention %q", msg, want)
			}
		}
	}()
	irgx.MustCompile(declined[0].pattern)
}
