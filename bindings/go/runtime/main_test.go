package runtime

import (
	"flag"
	"fmt"
	"os"
	"testing"
)

// tools are the engines this package's tests drive.
//
// gist, and deliberately only gist. What this package owns is the ladder — the
// dispatch, the tiers, the row decode — not any particular verb, so it needs
// *a* producer rather than a specific one, and which producer it picks decides
// who can run these tests. gist is public; relate is not. Certifying relate
// here made a public package's suite require a clone of a private one, which is
// a suite the public cannot run.
//
// gist produces exactly one analytic verb (`rank`), and one is all a ladder
// test needs. The oracle that genuinely has to be relate's — the cross-tier row
// comparison over a kinship verb — moved to relate's own Go bindings, where the
// binary it judges is the repository's own artifact rather than a sibling's.
var tools = []string{ToolGist}

// engines names the binary TestMain certified for each of [tools], so a failing
// run can close by saying which build produced it. The store that makes every
// later call agree is [Binary]'s own cache, which TestMain primes: resolving
// here fixes the answer for the whole process, so a test that chdirs into a
// temp dir cannot re-walk from a different anchor and judge something else.
var engines = map[string]string{}

// TestMain hands the harness its binaries once, and refuses to run the package
// without them.
//
// A test knows something the library cannot: which build it is judging.
// [Binary] staying a *discovering* affordance is right for a library consumer,
// who genuinely has no other way to find the engine. But a missing binary
// during a test run is a broken environment rather than an optional
// capability, and failing the whole package is the honest severity for that.
//
// The per-test `t.Skipf("no relate binary")` guards this replaces are exactly
// what hid a dead rung in the resolver: discovery quietly returned nothing,
// every test that needed a child skipped, and the package reported ok over a
// seam nothing had exercised. A skip is a claim that the thing was optional,
// and it was never optional here.
//
// One skip survives in this package — TestTiersAgree's — and it is a fact about
// the build tags rather than about the filesystem. Its comment says so.
func TestMain(m *testing.M) {
	flag.Parse()
	for _, tool := range tools {
		bin, err := Binary(tool)
		if err != nil {
			fmt.Fprintf(os.Stderr, "this package's tests drive the real %s engine, and none was found.\n%v\n", tool, err)
			os.Exit(1)
		}
		engines[tool] = bin
		if testing.Verbose() {
			fmt.Fprintf(os.Stderr, "judging %s: %s\n", tool, bin)
		}
	}
	code := m.Run()
	if code != 0 {
		for _, tool := range tools {
			fmt.Fprintf(os.Stderr, "judged %s: %s\n", tool, engines[tool])
		}
	}
	os.Exit(code)
}
