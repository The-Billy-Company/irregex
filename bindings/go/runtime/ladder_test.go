package runtime

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/The-Billy-Company/irregex/bindings/go/v2/analytic"
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

// TestNoFFIForcesCold pins the operator escape hatch: with IRGX_NO_FFI set the
// in-process plane is not consulted at all, which is how a host keeps answering
// while a drifted library is rebuilt.
func TestNoFFIForcesCold(t *testing.T) {
	t.Setenv("IRGX_NO_FFI", "1")
	if tier := Probe(); tier.Analytic {
		t.Fatal("IRGX_NO_FFI=1 still reported a live analytic plane")
	}
	if rows, err := native(t.Context(), Query{Op: analytic.OpDups, Params: analytic.Kinship{}}); rows != nil || err != nil {
		t.Fatalf("native() = (%v, %v) under IRGX_NO_FFI, want a clean declinature", rows, err)
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

// The cold tier's own counters are pinned where a producer is built: gist's
// `exact` package drives this package's `Run` through `rank` and asserts the
// stats come back (`gist/bindings/go/exact/ladder_test.go`). Nothing in this
// file spawns a child, which is why this package's tests need no binary at all.
