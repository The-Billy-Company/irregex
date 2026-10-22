//go:build cgo

package irgx

import (
	"bytes"
	"errors"
	"reflect"
	"runtime"
	"strings"
	"sync"
	"testing"
)

func imageTestLimits() MunchImageLimits {
	return MunchImageLimits{
		EncodedBytes: 1 << 20, DecodedBytes: 1 << 20, Patterns: 16, Voices: 64,
		States: 1 << 16, TransitionEntries: 1 << 20, AuxiliaryEntries: 1 << 20,
		LiveOwnedBytes: 1 << 24,
	}
}

func imageTestBudget() *MunchImageBudget {
	return &MunchImageBudget{AllocationLeft: 1 << 24, WorkLeft: 1 << 24}
}

func discardMunchPool(m *Munch) {
	for {
		pooled := m.pool.Get()
		if pooled == nil {
			return
		}
		pooled.(*lexer).release()
	}
}

func TestCompileLimitedRetainsCeilingsAcrossPoolMisses(t *testing.T) {
	limits := CompileLimits{MatchSteps: 32, Depth: 256, HeapBytes: 1 << 20}
	re, err := (CompileOpts{PCRE: true}).CompileLimited(`(?:(a+)+)$`, limits)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := re.MarshalText(); err == nil {
		t.Fatal("text serialization dropped execution ceilings")
	}
	for attempt := range 2 {
		if attempt == 1 {
			for {
				pooled := re.pool.Get()
				if pooled == nil {
					break
				}
				pooled.(*handle).release()
			}
		}
		ok, err := re.TryMatchString(strings.Repeat("a", 30) + "!")
		var native *Error
		if ok || !errors.As(err, &native) || native.Status >= 0 {
			t.Fatalf("attempt %d: exhausted search = %v, %v", attempt, ok, err)
		}
	}
	if err := re.UnmarshalText([]byte("b+")); err != nil {
		t.Fatal(err)
	}
	if re.limits != nil || !re.MatchString("bbb") {
		t.Fatal("text replacement retained the old ceilings or workers")
	}
}

func TestCompileLimitedInertLinearAndLazyPCRECaptures(t *testing.T) {
	re, err := CompileLimited("a+", CompileLimits{})
	if err != nil || !re.MatchString("aaa") {
		t.Fatalf("linear engine with zero ceilings: %v", err)
	}
	limits := CompileLimits{MatchSteps: 100_000, Depth: 256, HeapBytes: 1 << 20}
	re, err = (CompileOpts{PCRE: true}).CompileLimited(`(a+)`, limits)
	if err != nil {
		t.Fatal(err)
	}
	if got := re.FindStringSubmatch("aaa"); !reflect.DeepEqual(got, []string{"aaa", "aaa"}) {
		t.Fatalf("lazy bounded captures = %q", got)
	}
	limits.Depth = uint64(1) << 32
	if _, err := (CompileOpts{PCRE: true}).CompileLimited("a+", limits); err == nil {
		t.Fatal("out-of-range native depth accepted")
	}
	defaults := CompileLimits{UnspecifiedLimit, UnspecifiedLimit, UnspecifiedLimit}
	if _, err := (CompileOpts{PCRE: true}).CompileLimited("a+", defaults); err != nil {
		t.Fatalf("unspecified native ceilings: %v", err)
	}
}

func TestMunchMeteredDebitsAndGuards(t *testing.T) {
	m := MustCompileMunch("a+", "ab", "a*")
	left := uint64(0)
	if tok, ok, err := m.ScanMetered("aaa", 0, nil, &left); err == nil || ok || tok.Length != 0 || len(tok.Patterns) != 0 || left != 0 {
		t.Fatalf("zero-budget scan = %+v, %v, %v, remaining %d", tok, ok, err, left)
	}
	left = 100
	tok, ok, err := m.ScanMetered("aaa", 0, nil, &left)
	if err != nil || !ok || tok.Length != 3 || !reflect.DeepEqual(tok.Patterns, []int{0, 2}) || left >= 100 {
		t.Fatalf("metered scan = %+v, %v, %v, remaining %d", tok, ok, err, left)
	}
	before := left
	if _, _, err := m.ScanMetered("ab", 0, []int{1}, &left); err != nil || left >= before {
		t.Fatalf("second scan did not retain cumulative debits: %d -> %d, %v", before, left, err)
	}
	left = 100
	short, ok, err := m.ScanShortestMetered("aaa", 0, []int{0, 2}, &left)
	if err != nil || !ok || short.Length != 1 {
		t.Fatalf("shortest metered scan = %+v, %v, %v", short, ok, err)
	}
	left = 0
	if _, ok, err := m.ScanMetered("aaa", 0, []int{}, &left); err != nil || ok || left != 0 {
		t.Fatalf("empty permission set spent work: %v %v %d", ok, err, left)
	}
	if tok, ok, err := m.ScanMetered("", 0, []int{2}, &left); err != nil || !ok || tok.Length != 0 || left != 0 {
		t.Fatalf("free empty acceptance = %+v %v %v %d", tok, ok, err, left)
	}
	for _, allow := range [][]int{{-1}, {3}, {int(^uint32(0)) + 1}} {
		left = 100
		if _, _, err := m.ScanMetered("aaa", 0, allow, &left); err == nil || left != 100 {
			t.Fatalf("invalid ordinals %v accepted or debited: %v, %d", allow, err, left)
		}
	}
	if _, _, err := m.ScanMetered("a", -1, nil, &left); err == nil {
		t.Fatal("negative cursor accepted")
	}
	if _, _, err := m.ScanMetered("a", 2, nil, &left); err == nil {
		t.Fatal("past-end cursor accepted")
	}
	if _, _, err := m.ScanMetered("a", 0, nil, nil); err == nil {
		t.Fatal("missing transition allowance accepted")
	}
}

func TestMunchImageRoundTripCloneAndWorkerOwnership(t *testing.T) {
	exprs := []string{"a+", "ab", `\Aunseated`}
	opts := CompileOpts{IgnoreCase: true}
	original, err := opts.CompileMunch(exprs...)
	if err != nil {
		t.Fatal(err)
	}
	budget := imageTestBudget()
	image, err := original.Save(imageTestLimits(), budget)
	if err != nil || len(image) == 0 || budget.AllocationLeft == 1<<24 || budget.WorkLeft == 1<<24 {
		t.Fatalf("save = %d bytes, %+v, %v", len(image), budget, err)
	}
	loaded, err := opts.LoadMunch(image, exprs, imageTestLimits(), budget)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(loaded.Declined(), original.Declined()) || loaded.Len() != original.Len() {
		t.Fatal("loaded slate lost admission metadata")
	}
	clone, err := loaded.Clone()
	if err != nil {
		t.Fatal(err)
	}
	// The returned machine owns its input; destroy every caller-owned buffer.
	clear(image)
	exprs[0] = "invalid("
	runtime.GC()
	runtime.GC()
	discardMunchPool(clone)
	// Make recompilation impossible to prove a pool miss uses the retained
	// native program. This changes private test state, not a caller's slice.
	savedExprs := clone.exprs
	clone.exprs = []string{"invalid("}
	worker, err := clone.acquireError()
	clone.exprs = savedExprs
	if err != nil {
		t.Fatalf("image worker pool miss recompiled: %v", err)
	}
	clone.release(worker)
	var done sync.WaitGroup
	for range 8 {
		done.Add(1)
		go func() {
			defer done.Done()
			for range 20 {
				tok, ok := clone.Scan("AAA", 0)
				if !ok || tok.Length != 3 || !reflect.DeepEqual(tok.Patterns, []int{0}) {
					t.Errorf("cloned worker = %+v %v", tok, ok)
					return
				}
			}
		}()
	}
	done.Wait()
	again, err := clone.Save(imageTestLimits(), imageTestBudget())
	if err != nil || len(again) == 0 {
		t.Fatalf("saving a clone: %v", err)
	}
}

func TestMunchImageRefusesMismatchedInputsAndBudgets(t *testing.T) {
	m := MustCompileMunch("a+", "ab")
	limits := imageTestLimits()
	image, err := m.Save(limits, imageTestBudget())
	if err != nil {
		t.Fatal(err)
	}
	corrupt := bytes.Clone(image)
	corrupt[0] ^= 0xff
	for _, tc := range []struct {
		name  string
		image []byte
		exprs []string
		opts  CompileOpts
	}{
		{"different", image, []string{"b+", "ab"}, CompileOpts{}},
		{"reordered", image, []string{"ab", "a+"}, CompileOpts{}},
		{"flags", image, []string{"a+", "ab"}, CompileOpts{IgnoreCase: true}},
		{"corrupt", corrupt, []string{"a+", "ab"}, CompileOpts{}},
		{"truncated", image[:len(image)-1], []string{"a+", "ab"}, CompileOpts{}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			loaded, err := tc.opts.LoadMunch(tc.image, tc.exprs, limits, imageTestBudget())
			if loaded != nil || err == nil {
				t.Fatalf("mismatched image loaded or recompiled: %v, %v", loaded, err)
			}
		})
	}
	if _, err := m.Save(limits, nil); err == nil {
		t.Fatal("save without mandatory budget accepted")
	}
	if _, err := LoadMunch(image, []string{"a+", "ab"}, limits, nil); err == nil {
		t.Fatal("load without mandatory budget accepted")
	}
	tooSmall := limits
	tooSmall.EncodedBytes = uint64(len(image) - 1)
	if _, err := m.Save(tooSmall, imageTestBudget()); err == nil {
		t.Fatal("encoded-byte ceiling ignored by save")
	}
	if _, err := LoadMunch(image, []string{"a+", "ab"}, tooSmall, imageTestBudget()); err == nil {
		t.Fatal("encoded-byte ceiling ignored by load")
	}
	for _, budget := range []*MunchImageBudget{
		{AllocationLeft: 0, WorkLeft: 1 << 24},
		{AllocationLeft: 1 << 24, WorkLeft: 0},
	} {
		before := *budget
		if _, err := m.Save(limits, budget); err == nil {
			t.Fatal("save exceeded a zero quota")
		}
		if budget.AllocationLeft > before.AllocationLeft || budget.WorkLeft > before.WorkLeft {
			t.Fatal("failed save refunded budget")
		}
	}
	// Loading fails after parsing starts; retain the work debits on failure.
	budget := imageTestBudget()
	budget.AllocationLeft = 0
	before := budget.WorkLeft
	if _, err := LoadMunch(image, []string{"a+", "ab"}, limits, budget); err == nil || budget.WorkLeft >= before {
		t.Fatalf("failed load lost debits: %+v, %v", budget, err)
	}
	// A failed save must not leave its pooled worker poisoned or pending.
	if _, err := m.Save(limits, imageTestBudget()); err != nil {
		t.Fatalf("save after a refused save: %v", err)
	}
}
