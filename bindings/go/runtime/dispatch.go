//go:build cgo && irgx_ffi

package runtime

/*
#include <stdlib.h>
#include "producers.h"
*/
import "C"

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"sync"
	"time"
	"unsafe"

	"github.com/The-Billy-Company/irregex/bindings/go/v2/analytic"
)

// native answers q in-process. A nil cursor with a nil error means this tier
// declined or is absent — the caller answers through the next one, unchanged.
func native(ctx context.Context, q Query) (*Rows, error) {
	if noFFI() {
		return nil, nil
	}
	digest, err := libraryDigest()
	if err != nil {
		return nil, err
	}
	if digest == "" {
		return nil, nil
	}
	eng, warm := openCorpus(q)
	if !warm {
		return nil, nil // the corpus would not stand up in-process; the child re-reads it
	}
	rows, err := dispatch(ctx, eng, q)
	if rows == nil {
		// Nothing took ownership of the engine, so the failure and the release of
		// the corpus it half-opened are one event.
		return nil, errors.Join(err, eng.Close())
	}
	return rows, nil
}

// openCorpus stands the tree up in-process, or reports that it could not — which
// is a declinature rather than a failure, since the child reads the same bytes.
func openCorpus(q Query) (*Native, bool) {
	eng, err := OpenNative(q.scope()...)
	if err != nil {
		return nil, false
	}
	return eng, true
}

// dispatch runs one analytic op against an already-open corpus. A nil cursor and
// nil error is this tier declining; on any return but a live cursor the caller
// still owns eng.
func dispatch(ctx context.Context, eng *Native, q Query) (*Rows, error) {
	params, free := lowerParams(q)
	defer free()
	if params == nil {
		return nil, nil // a params shape this transport cannot lower; the child can
	}
	tok, release, err := watchCancel(ctx)
	if err != nil {
		return nil, err
	}

	run, routed := producer(q.Op)
	if !routed {
		release()
		return nil, nil // this process did not load the library that owns the verb
	}

	var cur *C.irgx_rows
	st := C.irgx_go_produce(run, eng.ptr, C.uint32_t(q.Op), params, tok, &cur)
	release()
	if st != C.IRGX_OK {
		if analytic.Status(st).Declined() || st == C.IRGX_INVALID {
			// A declinature is routine; INVALID means the library that answered
			// predates this op or its params shape. The child answers both.
			return nil, nil
		}
		return nil, statusError(st, q.Op.String())
	}
	return newRows(&nativeRows{engine: eng, ptr: cur}), nil
}

// producer is the function that answers op in THIS process, or a report that
// none does.
//
// The entry symbol comes from the generated verb table rather than the op: op
// numbers stayed ecosystem-wide when the producers split, so `4` means `echoes`
// whether or not librelate is here, and an op-range rule would mis-route the
// next verb appended to a family. The symbol is then resolved against the loaded
// process — the same lookup Python's ctypes and Rust's `sys` do, and the only one
// that can tell "librelate is linked" from "it is not". A missing producer is an
// absence, and the verb answers one tier down, through the child.
func producer(op analytic.Op) (C.irgx_producer, bool) {
	verb, ok := analytic.Verb(op)
	if !ok {
		return nil, false
	}
	found := producers()[verb.Entry]
	return found, found != nil
}

// producers resolves every entry symbol the verb table names, once. Resolution
// is per-process and cannot change under us: a dlopen after this point could
// only ADD a producer, and a verb answered by the child is answered correctly.
var producers = sync.OnceValue(func() map[string]C.irgx_producer {
	found := make(map[string]C.irgx_producer, 3)
	for _, entry := range entries() {
		name := C.CString(entry)
		if fn := C.irgx_go_producer(name); fn != nil {
			found[entry] = fn
		}
		C.free(unsafe.Pointer(name))
	}
	return found
})

// entries are the distinct entry symbols the verb table names, in op order.
func entries() []string {
	var out []string
	for op := 1; op <= analytic.VerbCount(); op++ {
		verb, ok := analytic.Verb(analytic.Op(op))
		if !ok || slices.Contains(out, verb.Entry) {
			continue
		}
		out = append(out, verb.Entry)
	}
	return out
}

// reachable reports that entry resolves to an image sharing this engine — the
// routing condition, not merely "the symbol is loaded". Exported for the
// producers test — a _test.go file cannot call dlsym through cgo itself.
func reachable(entry string) bool {
	name := C.CString(entry)
	defer C.free(unsafe.Pointer(name))
	return C.irgx_go_producer(name) != nil
}

// lowerParams builds the C params struct for q's family, plus the release for
// every buffer it borrowed. A nil pointer means "this transport cannot express
// these params" — a declinature, since the child answers the same query.
//
// The struct is Go memory holding only C pointers, which cgo passes as-is; the
// buffers behind those pointers are C-allocated because the callee may hold them
// for the length of the call and Go memory may not contain Go pointers here.
func lowerParams(q Query) (unsafe.Pointer, func()) {
	var owned []unsafe.Pointer
	free := func() {
		for _, p := range owned {
			C.free(p)
		}
	}
	span := func(s string) (*C.uint8_t, C.size_t) {
		if s == "" {
			return nil, 0
		}
		p := C.CBytes([]byte(s))
		owned = append(owned, p)
		return (*C.uint8_t)(p), C.size_t(len(s))
	}
	spans := func(ss []string) (*C.irgx_text, C.size_t) {
		if len(ss) == 0 {
			return nil, 0
		}
		arr := C.calloc(C.size_t(len(ss)), C.size_t(unsafe.Sizeof(C.irgx_text{})))
		if arr == nil {
			return nil, 0
		}
		owned = append(owned, arr)
		view := unsafe.Slice((*C.irgx_text)(arr), len(ss))
		for i, s := range ss {
			view[i].ptr, view[i].len = span(s)
		}
		return (*C.irgx_text)(arr), C.size_t(len(ss))
	}

	switch p := q.Params.(type) {
	case analytic.Kinship:
		c := C.relate_kinship_params{
			flags:     C.uint32_t(p.Flags()),
			channel:   C.uint32_t(p.Channel),
			unit:      C.uint32_t(p.Unit),
			min_grade: C.uint32_t(p.MinGrade),
			min_size:  count(p.MinSize),
			min_lines: count(p.MinLines),
			top:       count(p.Top),
		}
		c.struct_size = C.uint32_t(unsafe.Sizeof(c))
		if q.Op == analytic.OpDistinct {
			c.flags |= C.uint32_t(analytic.AnDistinct) // the polarity is the op, not a caller field
		}
		c.target, c.target_len = span(p.Target)
		if p.MaxDistance != nil {
			c.max_distance = C.double(*p.MaxDistance)
		}
		if p.MinEcho != nil {
			c.min_echo = C.double(*p.MinEcho)
		}
		return unsafe.Pointer(&c), free

	case analytic.Retrieval:
		c := C.relate_retrieval_params{flags: C.uint32_t(p.Flags()), top: count(p.Top)}
		c.struct_size = C.uint32_t(unsafe.Sizeof(c))
		c.query, c.query_len = span(p.Query)
		return unsafe.Pointer(&c), free

	case analytic.Sweep:
		c := C.relate_sweep_params{flags: C.uint32_t(p.Flags()), top: count(p.Top)}
		c.struct_size = C.uint32_t(unsafe.Sizeof(c))
		c.patterns, c.npatterns = spans(p.Patterns)
		c.under, c.under_len = span(p.Under)
		return unsafe.Pointer(&c), free

	case analytic.Compose:
		c := C.blast_compose_params{
			flags:  C.uint32_t(p.Flags()),
			budget: count(p.Budget),
			top:    count(p.Top),
		}
		c.struct_size = C.uint32_t(unsafe.Sizeof(c))
		c.text, c.text_len = span(p.Text)
		c.patterns, c.npatterns = spans(p.Patterns)
		if p.MaxDistance != nil {
			c.max_distance = C.double(*p.MaxDistance)
		}
		if p.MinEcho != nil {
			c.min_echo = C.double(*p.MinEcho)
		}
		return unsafe.Pointer(&c), free

	case analytic.Rank:
		c := C.gist_rank_params{flags: C.uint32_t(p.Flags()), top: count(p.Top)}
		c.struct_size = C.uint32_t(unsafe.Sizeof(c))
		c.pattern, c.pattern_len = span(p.Pattern)
		return unsafe.Pointer(&c), free
	}
	return nil, free
}

// count clamps a caller's budget into the ABI's unsigned slot; a negative budget
// is the same request as none.
func count(n int) C.uint32_t {
	if n <= 0 {
		return 0
	}
	return C.uint32_t(n)
}

// nativeRows pulls decoded rows straight out of the cursor arena.
type nativeRows struct {
	engine *Native
	ptr    *C.irgx_rows
	views  []C.irgx_row
	done   bool
}

func (n *nativeRows) fill(dst []Row) (int, error) {
	if n.ptr == nil || n.done || len(dst) == 0 {
		return 0, nil
	}
	if len(n.views) < len(dst) {
		n.views = make([]C.irgx_row, len(dst))
	}
	var written C.size_t
	st := C.irgx_rows_next_batch(n.ptr, &n.views[0], C.size_t(len(dst)), &written)
	switch st {
	case C.IRGX_MATCH:
		for i := range int(written) {
			row, err := goRow(&n.views[i])
			if err != nil {
				return i, err
			}
			dst[i] = row
		}
		return int(written), nil
	case C.IRGX_OK:
		n.done = true
		return 0, nil
	default:
		return 0, statusError(st, "rows batch")
	}
}

func (n *nativeRows) stats() Stats {
	if n.ptr == nil {
		return Stats{}
	}
	var cs C.irgx_stats
	cs.struct_size = C.uint32_t(unsafe.Sizeof(cs))
	if C.irgx_rows_stats(n.ptr, &cs) != C.IRGX_OK {
		return Stats{}
	}
	return Stats{
		Source:          uint32(cs.source),
		Elapsed:         time.Duration(cs.elapsed_ns),
		FilesConsidered: uint64(cs.files_considered),
		Refreshed:       uint64(cs.refreshed),
		Foreign:         uint64(cs.foreign),
		Omitted:         uint64(cs.omitted),
		Rows:            uint64(cs.rows),
	}
}

func (n *nativeRows) close() error {
	if n.ptr != nil {
		C.irgx_rows_close(n.ptr)
		n.ptr = nil
	}
	return n.engine.Close()
}

// goRow decodes one borrowed native row, copying every text out of the arena so
// the result outlives the cursor.
func goRow(cr *C.irgx_row) (Row, error) {
	schema, ok := analytic.Schema(uint32(cr.schema_id))
	if !ok {
		return Row{}, fmt.Errorf("irregex: library returned unknown schema id %d", uint32(cr.schema_id))
	}
	n := int(cr.nvalues)
	values := make([]Value, n)
	if n > 0 && cr.values != nil {
		for i, cv := range unsafe.Slice(cr.values, n) {
			var nested uint32
			if i < len(schema.Fields) {
				nested = schema.Fields[i].Nested
			}
			v, err := goValue(cv, nested)
			if err != nil {
				return Row{}, err
			}
			values[i] = v
		}
	}
	return Assemble(uint32(cr.schema_id), values, uint64(cr.present))
}

func goValue(cv C.irgx_value, nested uint32) (Value, error) {
	switch analytic.Tag(cv.tag) {
	case analytic.TagText:
		return Text(goBytes(cv.ptr, cv.len)), nil
	case analytic.TagInt:
		return Int(int64(cv.integer)), nil
	case analytic.TagFloat:
		return Float(float64(cv.real)), nil
	case analytic.TagBool:
		return Bool(cv.integer != 0), nil
	case analytic.TagEnum:
		return EnumOf(nested, int64(cv.integer)), nil
	case analytic.TagTexts:
		n := int(cv.len)
		out := make([]string, n)
		if n > 0 && cv.ptr != nil {
			for i, t := range unsafe.Slice((*C.irgx_text)(cv.ptr), n) {
				out[i] = goBytes(unsafe.Pointer(t.ptr), t.len)
			}
		}
		return Texts(out), nil
	case analytic.TagRows:
		n := int(cv.len)
		out := make([]Row, n)
		if n > 0 && cv.ptr != nil {
			for i, cr := range unsafe.Slice((*C.irgx_row)(cv.ptr), n) {
				child, err := goRow(&cr)
				if err != nil {
					return Value{}, err
				}
				out[i] = child
			}
		}
		return Nested(out), nil
	default:
		return Value{}, fmt.Errorf("irregex: library returned unknown value tag %d", uint32(cv.tag))
	}
}
