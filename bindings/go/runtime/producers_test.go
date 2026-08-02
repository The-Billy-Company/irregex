//go:build cgo && irgx_ffi

package runtime

import (
	"testing"

	"github.com/The-Billy-Company/irregex/bindings/go/analytic"
)

// TestEveryVerbNamesAnEntry pins routing to the contract rather than to the op
// number. Ops stayed ecosystem-wide when the producers split, so nothing about a
// verb's NUMBER says which library answers it — only its entry symbol does, and a
// verb without one could not be routed at all.
func TestEveryVerbNamesAnEntry(t *testing.T) {
	for op := 1; op <= analytic.VerbCount(); op++ {
		verb, ok := analytic.Verb(analytic.Op(op))
		if !ok {
			t.Fatalf("op %d is inside VerbCount but Verb() does not resolve it", op)
		}
		if verb.Entry == "" {
			t.Errorf("verb %q (op %d) names no entry symbol", verb.Name, op)
		}
	}
}

// TestRoutingFollowsReachability pins the producer lookup: a verb is routed
// in-process exactly when its entry symbol resolves to an image that shares this
// engine (see the guard in producers.h).
//
// Read the two columns it logs before trusting it. This module links only the
// substrate, so unless the host has loaded a product library both sides are
// false and the assertion holds vacuously — it can catch routing that claims a
// producer nobody loaded, but it cannot by itself prove the guard admits a
// legitimate one or refuses a private-copy one. Proving that pair needs a second
// dylib this suite cannot link; the C probe that does it is the "Proving the
// engine-sharing guard" recipe in this package's README.
func TestRoutingFollowsReachability(t *testing.T) {
	routed := producers()
	for _, entry := range entries() {
		_, isRouted := routed[entry]
		present := reachable(entry)
		if isRouted != present {
			t.Errorf("entry %q: routed=%v but reachable=%v", entry, isRouted, present)
		}
		t.Logf("%-12s reachable=%-5v routed=%v", entry, present, isRouted)
	}
}
