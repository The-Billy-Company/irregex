//go:build cgo

package irgx

/*
#include "irgx.h"
#include "shim.h"

static int32_t go_munch_clone_worker(const irgx_munch *source, irgx_munch **out,
                                     irgx_fault *f) {
  int32_t st = irgx_munch_clone_worker(source, out);
  capture(st, f);
  return st;
}

static int32_t go_munch_scan_metered(irgx_munch *m, const uint8_t *text, size_t len,
                                     size_t at, const uint32_t *allow, size_t nallow,
                                     uint32_t pick, irgx_munch_token *tok,
                                     uint32_t *out, size_t cap, size_t *remaining,
                                     irgx_fault *f) {
  int32_t st = irgx_munch_scan_metered(m, text, len, at, allow, nallow, pick,
                                      tok, out, cap, remaining);
  capture(st, f);
  return st;
}

static int32_t go_munch_save(irgx_munch *m, const irgx_munch_image_limits *limits,
                             irgx_munch_image_budget *budget, uint8_t *out,
                             size_t cap, size_t *written, irgx_fault *f) {
  int32_t st = irgx_munch_save(m, limits, budget, out, cap, written);
  capture(st, f);
  return st;
}

static int32_t go_munch_load(const irgx_munch_pattern *expected, size_t count,
                             uint32_t flags, const uint8_t *image, size_t len,
                             const irgx_munch_image_limits *limits,
                             irgx_munch_image_budget *budget, irgx_munch **out,
                             irgx_fault *f) {
  int32_t st = irgx_munch_load(expected, count, flags, image, len, limits, budget, out);
  capture(st, f);
  return st;
}
*/
import "C"

import (
	"runtime"
	"unsafe"
)

// MunchImageLimits are mandatory ceilings for saving or loading an Image1
// machine. Each zero means zero, and every ceiling must admit the image.
// DecodedBytes counts canonical expanded values, while LiveOwnedBytes bounds
// storage owned by the native image operation, including its temporary storage.
// Saving also allocates the returned Go byte slice outside the native budget;
// its length is bounded by EncodedBytes.
type MunchImageLimits struct {
	EncodedBytes      uint64
	DecodedBytes      uint64
	Patterns          uint64
	Voices            uint64
	States            uint64
	TransitionEntries uint64
	AuxiliaryEntries  uint64
	LiveOwnedBytes    uint64
}

// MunchImageBudget is a cumulative, nonrefundable allowance. Save and LoadMunch
// retain native allocation and work debits on failure as well as success.
// A budget shared across goroutines must be synchronized by its caller.
// These allowances are separate from ScanMetered's byte-transition allowance.
type MunchImageBudget struct {
	AllocationLeft uint64
	WorkLeft       uint64
}

func (l MunchImageLimits) native() C.irgx_munch_image_limits {
	return C.irgx_munch_image_limits{
		struct_size:        C.uint32_t(C.sizeof_irgx_munch_image_limits),
		version:            1,
		encoded_bytes:      C.uint64_t(l.EncodedBytes),
		decoded_bytes:      C.uint64_t(l.DecodedBytes),
		patterns:           C.uint64_t(l.Patterns),
		voices:             C.uint64_t(l.Voices),
		states:             C.uint64_t(l.States),
		transition_entries: C.uint64_t(l.TransitionEntries),
		auxiliary_entries:  C.uint64_t(l.AuxiliaryEntries),
		live_owned_bytes:   C.uint64_t(l.LiveOwnedBytes),
	}
}

func (b *MunchImageBudget) native() C.irgx_munch_image_budget {
	return C.irgx_munch_image_budget{
		struct_size:     C.uint32_t(C.sizeof_irgx_munch_image_budget),
		version:         1,
		allocation_left: C.uint64_t(b.AllocationLeft),
		work_left:       C.uint64_t(b.WorkLeft),
	}
}

func (b *MunchImageBudget) update(native *C.irgx_munch_image_budget) {
	b.AllocationLeft = uint64(native.allocation_left)
	b.WorkLeft = uint64(native.work_left)
}

func (l *lexer) clone() (*lexer, error) {
	var (
		ptr   *C.irgx_munch
		fault C.irgx_fault
	)
	st := C.go_munch_clone_worker(l.ptr, &ptr, &fault)
	runtime.KeepAlive(l)
	if st != C.IRGX_OK {
		return nil, newError(st, &fault, "clone a munch worker")
	}
	out := &lexer{ptr: ptr}
	runtime.SetFinalizer(out, (*lexer).release)
	return out, nil
}

// Clone shares m's immutable machine with a new Munch and independent worker
// scratch. It performs no compilation or image decoding. The clone remains
// usable after m is collected and is safe for concurrent use.
func (m *Munch) Clone() (*Munch, error) {
	worker, err := m.acquireError()
	if err != nil {
		return nil, err
	}
	defer m.release(worker)
	seed, err := worker.clone()
	if err != nil {
		return nil, err
	}
	return &Munch{
		exprs: append([]string(nil), m.exprs...), flags: m.flags, seated: m.seated,
		declined: append([]Refusal(nil), m.declined...), seed: seed,
	}, nil
}

// Save encodes m as an Image1 machine under explicit ceilings and a mandatory
// cumulative budget. Sizing and copying use the same worker and allowance;
// budget debits are retained even when either phase fails.
func (m *Munch) Save(limits MunchImageLimits, budget *MunchImageBudget) ([]byte, error) {
	if budget == nil {
		return nil, refuse("save a munch without an image budget")
	}
	worker, err := m.acquireError()
	if err != nil {
		return nil, err
	}
	defer func() {
		if worker.ptr != nil {
			m.release(worker)
		}
	}()
	bounds, quota := limits.native(), budget.native()
	defer budget.update(&quota)
	var (
		written C.size_t
		fault   C.irgx_fault
	)
	st := C.go_munch_save(worker.ptr, &bounds, &quota, nil, 0, &written, &fault)
	runtime.KeepAlive(worker)
	if st != C.IRGX_MATCH {
		return nil, newError(st, &fault, "size a munch image")
	}
	if uint64(written) > uint64(^uint(0)>>1) || written == 0 {
		// Discard the worker to release its pending image before returning.
		worker.release()
		return nil, refuse("represent a munch image length as a Go slice")
	}
	image := make([]byte, int(written))
	st = C.go_munch_save(worker.ptr, &bounds, &quota, (*C.uint8_t)(unsafe.Pointer(&image[0])),
		C.size_t(len(image)), &written, &fault)
	runtime.KeepAlive(worker)
	if st != C.IRGX_MATCH {
		return nil, newError(st, &fault, "save a munch image")
	}
	if uint64(written) != uint64(len(image)) {
		return nil, refuse("copy the complete munch image")
	}
	return image, nil
}

// LoadMunch validates and owns image against the exact ordered expressions,
// using default pattern flags. It never recompiles a rejected image.
func LoadMunch(image []byte, exprs []string, limits MunchImageLimits, budget *MunchImageBudget) (*Munch, error) {
	return CompileOpts{}.LoadMunch(image, exprs, limits, budget)
}

// LoadMunch validates an Image1 machine against the exact ordered expressions
// and o's flags, under mandatory ceilings and a cumulative budget. No compile
// fallback is permitted, including when its worker pool empties after a GC.
// The input bytes and expression slice may be reused after this call returns.
func (o CompileOpts) LoadMunch(image []byte, exprs []string, limits MunchImageLimits, budget *MunchImageBudget) (*Munch, error) {
	if abiMismatch != nil {
		return nil, abiMismatch
	}
	if budget == nil {
		return nil, refuse("load a munch without an image budget")
	}
	var pin runtime.Pinner
	defer pin.Unpin()
	pats := make([]C.irgx_munch_pattern, len(exprs))
	for i, expr := range exprs {
		body := bytePtr(expr)
		if len(expr) != 0 {
			pin.Pin(body)
		}
		pats[i] = C.irgx_munch_pattern{pattern: body, len: C.size_t(len(expr))}
	}
	var expected *C.irgx_munch_pattern
	if len(pats) != 0 {
		expected = &pats[0]
	}
	bounds, quota := limits.native(), budget.native()
	defer budget.update(&quota)
	var (
		ptr   *C.irgx_munch
		fault C.irgx_fault
	)
	st := C.go_munch_load(expected, C.size_t(len(pats)), C.uint32_t(o.bits()),
		(*C.uint8_t)(unsafe.Pointer(unsafe.SliceData(image))), C.size_t(len(image)),
		&bounds, &quota, &ptr, &fault)
	runtime.KeepAlive(image)
	runtime.KeepAlive(exprs)
	if st != C.IRGX_OK {
		return nil, newError(st, &fault, "load a munch image")
	}
	seed := &lexer{ptr: ptr}
	runtime.SetFinalizer(seed, (*lexer).release)
	return &Munch{
		exprs: append([]string(nil), exprs...), flags: o.bits(), seated: seed.seated(),
		declined: seed.refusals(len(exprs)), seed: seed,
	}, nil
}

// ScanMetered is ScanAmong under a cumulative DFA byte-transition allowance.
// Every internal voice shares remaining; zero refuses required transitions.
// No partial token is returned on exhaustion, and debits survive errors. A nil
// allow permits every seated pattern; an empty allow is a free non-match.
// The caller must synchronize a remaining pointer shared across goroutines.
func (m *Munch) ScanMetered(text string, at int, allow []int, remaining *uint64) (Token, bool, error) {
	return m.scanMetered(text, at, allow, pickLongest, remaining)
}

// ScanShortestMetered is ScanShortestAmong under the same cumulative allowance
// as ScanMetered. Empty matches are skipped.
func (m *Munch) ScanShortestMetered(text string, at int, allow []int, remaining *uint64) (Token, bool, error) {
	return m.scanMetered(text, at, allow, pickShortest, remaining)
}

func (m *Munch) scanMetered(text string, at int, allow []int, pick uint32, remaining *uint64) (Token, bool, error) {
	if remaining == nil || uint64(C.size_t(*remaining)) != *remaining {
		return Token{}, false, refuse("represent a munch transition allowance")
	}
	if at < 0 || at > len(text) {
		return Token{}, false, refuse("scan a munch outside the text")
	}
	for _, id := range allow {
		if id < 0 || id >= len(m.exprs) || uint64(id) > uint64(^uint32(0)) {
			return Token{}, false, refuse("scan with an out-of-range terminal ordinal")
		}
	}
	if (allow != nil && len(allow) == 0) || m.seated == 0 {
		return Token{}, false, nil
	}
	worker, err := m.acquireError()
	if err != nil {
		return Token{}, false, err
	}
	defer m.release(worker)
	row := make([]C.uint32_t, len(allow))
	for i, id := range allow {
		row[i] = C.uint32_t(id)
	}
	var permitted *C.uint32_t
	if len(row) != 0 {
		permitted = &row[0]
	}
	ids := make([]C.uint32_t, m.seated)
	var (
		tok   C.irgx_munch_token
		fault C.irgx_fault
	)
	left := C.size_t(*remaining)
	st := C.go_munch_scan_metered(worker.ptr, bytePtr(text), C.size_t(len(text)), C.size_t(at),
		permitted, C.size_t(len(row)), C.uint32_t(pick),
		&tok, (*C.uint32_t)(unsafe.Pointer(unsafe.SliceData(ids))), C.size_t(len(ids)), &left, &fault)
	runtime.KeepAlive(text)
	runtime.KeepAlive(worker)
	*remaining = uint64(left)
	if st < 0 {
		return Token{}, false, newError(st, &fault, "scan a munch with a transition allowance")
	}
	if st != C.IRGX_MATCH {
		return Token{}, false, nil
	}
	out := make([]int, int(tok.count))
	for i := range out {
		out[i] = int(ids[i])
	}
	return Token{Length: int(tok.len), Patterns: out}, true, nil
}
