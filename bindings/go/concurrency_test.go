package irregex_test

import (
	"fmt"
	"reflect"
	"runtime"
	"strings"
	"sync"
	"testing"

	irregex "github.com/The-Billy-Company/irregex/bindings/go"
)

// The package-level var is the shape every Go programmer writes, and it is the
// reason a *Regexp has to be safe for concurrent use.
var shared = irregex.MustCompile(`(?P<key>\w+)=(\d+)`)

// Many goroutines, one Regexp, a different input each, every answer checked
// against one computed serially beforehand. Run under -race this also covers the
// pool itself; the C handle's own single-thread rule is covered separately, in
// TestPoolLendsEachHandleOnce, because the race detector cannot see inside C.
func TestConcurrentFinds(t *testing.T) {
	const workers = 32
	const rounds = 40

	texts := make([]string, workers)
	for i := range texts {
		// Different lengths and different match counts, so two goroutines are
		// never doing the same work at the same offsets.
		var b strings.Builder
		for j := 0; j <= i; j++ {
			fmt.Fprintf(&b, "k%d=%d ", j, j*7)
		}
		texts[i] = b.String()
	}

	// The expected answers, computed one at a time before any goroutine starts.
	wantIndex := make([][][]int, workers)
	wantGroups := make([][][]int, workers)
	wantStrings := make([][]string, workers)
	wantReplaced := make([]string, workers)
	for i, text := range texts {
		wantIndex[i] = shared.FindAllStringIndex(text, -1)
		wantGroups[i] = shared.FindAllStringSubmatchIndex(text, -1)
		wantStrings[i] = shared.FindAllString(text, -1)
		wantReplaced[i] = shared.ReplaceAllString(text, "${key}")
	}

	var wg sync.WaitGroup
	wg.Add(workers)
	for i := range workers {
		go func() {
			defer wg.Done()
			text := texts[i]
			for round := range rounds {
				if got := shared.FindAllStringIndex(text, -1); !reflect.DeepEqual(got, wantIndex[i]) {
					t.Errorf("worker %d round %d: FindAllStringIndex = %v, want %v", i, round, got, wantIndex[i])
					return
				}
				if got := shared.FindAllStringSubmatchIndex(text, -1); !reflect.DeepEqual(got, wantGroups[i]) {
					t.Errorf("worker %d round %d: submatch index = %v, want %v", i, round, got, wantGroups[i])
					return
				}
				if got := shared.FindAllString(text, -1); !reflect.DeepEqual(got, wantStrings[i]) {
					t.Errorf("worker %d round %d: FindAllString = %q, want %q", i, round, got, wantStrings[i])
					return
				}
				if got := shared.ReplaceAllString(text, "${key}"); got != wantReplaced[i] {
					t.Errorf("worker %d round %d: ReplaceAllString = %q, want %q", i, round, got, wantReplaced[i])
					return
				}
				if !shared.MatchString(text) {
					t.Errorf("worker %d round %d: MatchString = false", i, round)
					return
				}
			}
		}()
	}
	wg.Wait()
}

// Compiling from many goroutines at once, which is the other half: a Regexp
// built while another one is being built must still be correct.
func TestConcurrentCompiles(t *testing.T) {
	var wg sync.WaitGroup
	for i := range 32 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			pattern := fmt.Sprintf(`a{%d}`, i%5+1)
			re, err := irregex.Compile(pattern)
			if err != nil {
				t.Errorf("compile %q: %v", pattern, err)
				return
			}
			if got, want := re.FindString(strings.Repeat("a", 5)), strings.Repeat("a", i%5+1); got != want {
				t.Errorf("%q found %q, want %q", pattern, got, want)
			}
		}()
	}
	wg.Wait()
}

// The pool grows under load and sync.Pool drops what it holds on a GC cycle, so
// the handles it dropped have to be freed by their finalizers. This does not
// assert a number - there is nothing to observe from Go - but it does prove that
// churning the pool through several GC cycles leaves the Regexp working and does
// not free a handle that is still in use, which is the failure that would
// otherwise show up as a crash here.
func TestPoolSurvivesGC(t *testing.T) {
	re := irregex.MustCompile(`\d+`)
	for range 5 {
		var wg sync.WaitGroup
		for i := range 16 {
			wg.Add(1)
			go func() {
				defer wg.Done()
				text := strings.Repeat(fmt.Sprint(i), 3)
				if got := re.FindString(text); got != text {
					t.Errorf("FindString(%q) = %q", text, got)
				}
			}()
		}
		wg.Wait()
		runtime.GC()
	}
	if got := re.FindString("abc 123"); got != "123" {
		t.Errorf("after GC churn, FindString = %q, want 123", got)
	}
}
