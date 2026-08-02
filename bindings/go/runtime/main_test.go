package runtime

import (
	"flag"
	"os"
	"testing"
)

// TestMain exists to parse flags, and deliberately to do nothing else.
//
// It used to resolve a producer binary and refuse to run the package without
// one, because the cold tier's tests spawned a child. That made a public
// library's suite require a clone of a consumer: this repository builds no
// binary of its own, so the only producer available was gist's.
//
// The tests that genuinely needed a child moved to the repositories that build
// one — the row-and-stats comparison to gist's `exact`, the kinship oracle to
// relate's own bindings — and what remains here is the ladder's own reasoning:
// tier introspection, the FFI escape hatch, seam refusals, cancellation, and
// the digest policy. None of that spawns anything, so there is nothing left to
// certify up front, and the package now runs from a clone of this repository
// alone.
//
// It stays rather than being deleted because a `t.Skipf` in its place is how the
// dead rung hid the first time: discovery quietly returned nothing, every test
// needing a child skipped, and the package reported ok over a seam nothing had
// exercised. Anything reintroduced here that needs a producer should fail the
// package, not skip it.
func TestMain(m *testing.M) {
	flag.Parse()
	os.Exit(m.Run())
}
