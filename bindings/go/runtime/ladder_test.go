package runtime

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/The-Billy-Company/irregex/bindings/go/analytic"
)

// TestProbeIsCoherent pins the introspection's internal agreement: a build with
// no cgo cannot have an analytic plane, and a plane that IS live must be the one
// this decoder was generated from.
func TestProbeIsCoherent(t *testing.T) {
	tier := Probe()
	if tier.ContractDigest != analytic.Digest {
		t.Fatalf("contract digest = %q, want %q", tier.ContractDigest, analytic.Digest)
	}
	if !tier.CGO && tier.Analytic {
		t.Fatal("a build without cgo reported an in-process analytic plane")
	}
	if tier.Analytic && tier.LibraryDigest != analytic.Digest {
		t.Fatalf("analytic tier accepted digest %q against contract %q", tier.LibraryDigest, analytic.Digest)
	}
	var drift *DriftError
	if errors.As(tier.Err, &drift) && drift.Want == drift.Got {
		t.Fatalf("drift reported with matching digests: %v", drift)
	}
	t.Logf("tier: cgo=%v analytic=%v library=%q err=%v", tier.CGO, tier.Analytic, tier.LibraryDigest, tier.Err)
}

// TestNoFFIForcesCold pins the operator escape hatch: with IRREGEX_NO_FFI set the
// in-process plane is not consulted at all, which is how a host keeps answering
// while a drifted library is rebuilt.
func TestNoFFIForcesCold(t *testing.T) {
	t.Setenv("IRREGEX_NO_FFI", "1")
	if tier := Probe(); tier.Analytic {
		t.Fatal("IRREGEX_NO_FFI=1 still reported a live analytic plane")
	}
	if rows, err := native(t.Context(), Query{Op: analytic.OpDups, Params: analytic.Kinship{}}); rows != nil || err != nil {
		t.Fatalf("native() = (%v, %v) under IRREGEX_NO_FFI, want a clean declinature", rows, err)
	}
}

// TestRunRefusesIncoherentQueries pins the seam checks, which exist so a params
// struct of the wrong family is refused instead of having its bytes reinterpreted
// as another family's layout.
func TestRunRefusesIncoherentQueries(t *testing.T) {
	for name, q := range map[string]Query{
		"unknown op":   {Op: analytic.Op(0), Params: analytic.Kinship{}},
		"no params":    {Op: analytic.OpSimilar},
		"wrong family": {Op: analytic.OpSimilar, Params: analytic.Retrieval{Query: "x"}},
	} {
		if _, err := Run(t.Context(), q); err == nil {
			t.Errorf("%s: Run accepted it", name)
		}
	}
}

// TestRunHonorsCanceledContext pins that cancellation is answered before any tier
// is engaged — no child spawned, no library entered.
func TestRunHonorsCanceledContext(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	_, err := Run(ctx, Query{Op: analytic.OpDups, Params: analytic.Kinship{}, Roots: []string{"."}})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("Run on a canceled context = %v, want context.Canceled", err)
	}
}

// TestDigestPolicy pins the acceptance rule for a library's row-schema table.
// Drift must be a loud, named refusal rather than a fallback, because rows
// decoded against the wrong table are wrong quietly; a library with no analytic
// plane at all is a different fact and must read as an absence.
func TestDigestPolicy(t *testing.T) {
	named := func() string { return "schema 3 is \"kin\" in the library, \"similar\" here" }

	if got, err := verifyDigest("", func() string { t.Error("a library with no plane was described as drifted"); return "" }); got != "" || err != nil {
		t.Errorf("verifyDigest(\"\") = (%q, %v), want a clean absence", got, err)
	}
	if got, err := verifyDigest(analytic.Digest, named); got != analytic.Digest || err != nil {
		t.Errorf("verifyDigest(contract digest) = (%q, %v), want it accepted", got, err)
	}

	got, err := verifyDigest("0123456789abcdef0123456789abcdef", named)
	var drift *DriftError
	if !errors.As(err, &drift) {
		t.Fatalf("a mismatched digest returned %v, want a *DriftError", err)
	}
	if got != "0123456789abcdef0123456789abcdef" {
		t.Errorf("drift reported digest %q, want the library's own", got)
	}
	if drift.Want != analytic.Digest || drift.Got != got {
		t.Errorf("drift = want %q got %q, expected want %q got %q", drift.Want, drift.Got, analytic.Digest, got)
	}
	for _, want := range []string{analytic.Digest, got, named()} {
		if !strings.Contains(drift.Error(), want) {
			t.Errorf("drift message %q omits %q", drift.Error(), want)
		}
	}
}

// TestTiersAgree is the cross-tier oracle: whichever tiers this machine has must
// answer a verb with the same rows. A declinature is a fact about speed, so a
// difference here would mean one tier is lying.
func TestTiersAgree(t *testing.T) {
	root := corpus(t)
	q := Query{
		Op:     analytic.OpDups,
		Params: analytic.Kinship{MaxDistance: ptr(0.6), Top: 10, NoIndex: true},
		Roots:  []string{root},
		Dir:    root,
	}

	// The only skip left in this package, and it is deliberately not the kind
	// TestMain abolished. That kind asked the filesystem whether a binary
	// happened to be lying around; this one asks how this very test binary was
	// compiled. The default build is pure Go, because the in-process analytic
	// tier is opt-in behind `-tags irregex_ffi` so a `go get` consumer never
	// tries to link a libirregex that cannot exist in the module cache. A
	// cross-tier oracle with one tier present has nothing to compare, and no
	// amount of building or installing changes that — only rebuilding this test
	// binary with the tag does.
	warm := Probe()
	if !warm.Analytic {
		t.Skipf("this test binary has no in-process analytic tier to compare the cold one against; rebuild with `-tags irregex_ffi` (cgo=%v, err=%v)", warm.CGO, warm.Err)
	}
	native := render(t, q)
	if len(native) == 0 {
		t.Fatal("the fixture corpus produced no duplicate pair, so this oracle proves nothing")
	}
	t.Setenv("IRREGEX_NO_FFI", "1")
	cold := render(t, q)
	if len(native) != len(cold) {
		t.Fatalf("tiers disagree on row count: native %d, cold %d\nnative=%v\ncold=%v", len(native), len(cold), native, cold)
	}
	for i := range native {
		if native[i] != cold[i] {
			t.Errorf("row %d: native %s, cold %s", i, native[i], cold[i])
		}
	}
}

// TestColdSurfacesStats pins that the subprocess tier reports the answer-level
// counters rather than dropping them: a retrieval answer must be able to say the
// query was foreign to the corpus instead of merely empty.
func TestColdSurfacesStats(t *testing.T) {
	t.Setenv("IRREGEX_NO_FFI", "1")
	root := corpus(t)
	rows, err := Run(t.Context(), Query{
		Op:     analytic.OpRecall,
		Params: analytic.Retrieval{Query: "kinship sketch of a duplicated helper", Top: 3},
		Roots:  []string{root},
		Dir:    root,
	})
	if err != nil {
		t.Fatalf("recall: %v", err)
	}
	defer rows.Close()
	found, err := rows.Collect()
	if err != nil {
		t.Fatalf("collect: %v", err)
	}
	stats := rows.Stats()
	if stats.Elapsed <= 0 {
		t.Errorf("stats reported no elapsed time: %+v", stats)
	}
	if stats.Rows != uint64(len(found)) {
		t.Errorf("stats.Rows = %d, decoded %d", stats.Rows, len(found))
	}
	if stats.SourceName() == "" {
		t.Error("stats named no tier")
	}
}

func render(t *testing.T, q Query) []string {
	t.Helper()
	rows, err := Run(t.Context(), q)
	if err != nil {
		t.Fatalf("run %s: %v", q.Op, err)
	}
	defer rows.Close()
	found, err := rows.Collect()
	if err != nil {
		t.Fatalf("collect %s: %v", q.Op, err)
	}
	out := make([]string, 0, len(found))
	for _, row := range found {
		out = append(out, row.String())
	}
	return out
}

// corpus writes a small tree with one deliberate near-duplicate pair and one
// unrelated file, so a kinship verb has something true to find without depending
// on the repository around it. The files are deliberately substantial: a sketch of
// a three-line file carries too few phrases for the candidate stage to band, so a
// toy corpus produces a vacuous answer rather than a wrong one.
func corpus(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	var body strings.Builder
	body.WriteString("package sample\n\n")
	for i := 1; i <= 11; i++ {
		fmt.Fprintf(&body, "// Stanza %d: the reticulation of splines, a matter of some delicacy.\n"+
			"func Reticulate%d(splines []int) int {\n\ttotal := 0\n\tfor _, s := range splines {\n\t\ttotal += s * %d\n\t}\n\treturn total\n}\n\n", i, i, i)
	}
	files := map[string]string{
		"alpha.go": body.String(),
		"beta.go":  body.String() + "// a trailing remark, so the pair is near rather than exact\n",
		"gamma.go": "package sample\n\n" + strings.Repeat("// Wholly unrelated prose about tunnels, weather, and the price of tin.\n", 30),
	}
	for name, text := range files {
		if err := os.WriteFile(filepath.Join(root, name), []byte(text), 0o600); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	return root
}

// ptr is the address of a literal, for the optional knobs that read "absent" as
// nil. Go 1.26 spells this `new(0.6)`; keeping the helper keeps this module's
// floor at the version its production code actually needs, so a consumer on an
// older toolchain is not locked out by a convenience in a test.
func ptr[T any](v T) *T { return &v }
