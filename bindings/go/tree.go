//go:build cgo

package irgx

// The tree plane: searching a corpus rather than a buffer you already hold.
//
// Everything else in this package takes bytes you read yourself. This takes
// ROOTS, and the engine does the reading: the walk, the ignore rules, the binary
// sniff, the line splitting and the per-file ceilings all happen on the other
// side of one crossing. That is the difference between a grep-shaped program and
// a program that calls a regex library in a loop, and it is not a small one -
// the loop version pays a cgo crossing per file and reimplements gitignore.
//
// Open a [Corpus] once, keep it, and run searches against it. A search
// MATERIALIZES: [Corpus.Search] returns after the work is done and the [Cursor]
// it hands back is a buffer of records to walk, which is why [Cursor.Count] can
// answer before you have pulled anything and why cancelling is a property of the
// search rather than of the walk.
//
// Records are COPIED into Go as they are pulled. The C records borrow the
// cursor's arena and die at close; a Go [Record] holds Go strings and its own
// spans, so it outlives the cursor, the corpus, and the goroutine that read it.

/*
#cgo CFLAGS: -I${SRCDIR}
#include <stdlib.h>
#include "shim.h"

static int32_t go_engine_open(const char *const *roots, size_t nroots,
                              irgx_engine **out, irgx_fault *f) {
  int32_t st = irgx_engine_open(roots, nroots, out);
  capture(st, f);
  return st;
}

static int32_t go_tree_search(irgx_engine *engine, const irgx_tree_request *req,
                              irgx_cursor **out, irgx_fault *f) {
  int32_t st = irgx_tree_search(engine, req, out);
  capture(st, f);
  return st;
}

static int32_t go_matches_next(irgx_cursor *cursor, irgx_match *out,
                               irgx_fault *f) {
  int32_t st = irgx_matches_next(cursor, out);
  capture(st, f);
  return st;
}

static int32_t go_matches_next_batch(irgx_cursor *cursor, irgx_match *out,
                                     size_t cap, size_t *written,
                                     irgx_fault *f) {
  int32_t st = irgx_matches_next_batch(cursor, out, cap, written);
  capture(st, f);
  return st;
}
*/
import "C"

import (
	"context"
	"runtime"
	"strconv"
	"sync"
	"time"
	"unsafe"
)

// batchSize is how many records one crossing pulls.
//
// A cgo call is on the order of a hundred Go calls, so the per-record cost of
// iterating is the crossing rather than the record; 64 amortizes it to noise
// while keeping the transient buffer inside a page or two. Nothing depends on
// the number - it is a rate, not a contract.
const batchSize = 64

// Kind is what a record IS: a line the pattern selected, or a neighbour carried
// along by [SearchOpts.Before] / [SearchOpts.After].
type Kind uint32

const (
	// KindLine is a line the pattern selected.
	KindLine Kind = C.IRGX_MATCH_LINE
	// KindContext is a neighbouring line, carried for display. Its Spans are
	// empty: nothing in it matched, which is the whole reason it is a separate
	// kind rather than a match with no spans.
	KindContext Kind = C.IRGX_MATCH_CONTEXT
)

func (k Kind) String() string {
	switch k {
	case KindLine:
		return "line"
	case KindContext:
		return "context"
	}
	return "kind " + strconv.FormatUint(uint64(k), 10)
}

// Record is one record of a corpus search, owned by Go.
type Record struct {
	// Path is the file the record came from, as the walk spelled it.
	Path string
	// Line is the line's bytes, without its terminator.
	Line string
	// Number is the 1-based line number, as -n prints it.
	Number int
	// Spans are the matches WITHIN Line, as offset pairs into it - the shape
	// [Regexp.FindAllStringIndex] returns, so a caller highlights a corpus hit
	// with the same code it highlights a buffer hit with. Empty for
	// [KindContext].
	Spans [][]int
	// Kind separates a selected line from a neighbour carried along with it.
	Kind Kind
}

// Limit makes an optional ceiling present. Use it for [SearchOpts.MaxCount],
// where zero is a legal ceiling ("select nothing from any file") and therefore
// cannot double as "no ceiling":
//
//	irgx.SearchOpts{Pattern: "TODO", MaxCount: irgx.Limit(3)}
func Limit(n uint64) *uint64 { return &n }

// SearchOpts is one complete corpus-search question. The zero value plus a
// Pattern is an unbudgeted, contextless search for every match in every eligible
// file.
//
// The flag set is a SUBSET of [CompileOpts] on purpose, and the gap is the point:
// a warm corpus search has nowhere for PCRE, MultiLine or DotAll to travel, and
// asking for one is refused rather than ignored. Existence is spelled
// MaxResults: 1, not by a second flag that means the same thing.
type SearchOpts struct {
	// Pattern is the expression to search for. Required.
	Pattern string
	// Fixed, IgnoreCase, Word, SmartCase and ASCII mean what they mean on
	// [CompileOpts].
	Fixed      bool
	IgnoreCase bool
	Word       bool
	SmartCase  bool
	ASCII      bool
	// Invert selects the lines that do NOT match - grep's -v. The records that
	// come back have no spans, because nothing in them matched.
	Invert bool
	// MaxCount is the per-file ceiling, absent by default. Set it with [Limit].
	MaxCount *uint64
	// Before and After carry neighbouring lines along with each selected line -
	// grep's -B and -A. They arrive as [KindContext] records in reading order.
	Before, After int
	// MaxResults caps the whole search rather than each file: 0 is unbounded,
	// and 1 is the existence question, which lets the engine stop at the first
	// hit instead of walking the rest of the tree.
	MaxResults int
	// Timeout budgets the search; zero is unbudgeted. A search that runs out
	// returns what it had, so a budget is a way to bound latency rather than a
	// way to fail.
	Timeout time.Duration
}

func (o SearchOpts) bits() uint32 {
	flags := bit(o.Fixed, flagFixed) |
		bit(o.IgnoreCase, flagIgnoreCase) |
		bit(o.Word, flagWord) |
		bit(o.SmartCase, flagSmartCase) |
		bit(o.ASCII, flagNoUnicode) |
		bit(o.Invert, flagInvert)
	if o.MaxCount != nil {
		flags |= flagMaxCount
	}
	return flags
}

// Corpus is a warm tree: the walk, the ignore rules and the I/O pool, stood up
// once and spent across many searches.
//
// Searches on one Corpus are SERIALIZED. The ABI permits concurrent queries
// against one engine, but the engine is handed to the search as a mutable
// pointer and the sibling in-process runtime treats it as single-writer, so this
// takes the conservative reading: goroutines may call [Corpus.Search]
// concurrently and will queue. Cursors are independent of each other and of the
// lock once returned, so the parallelism worth having - reading N result sets -
// is unaffected.
type Corpus struct {
	mu  sync.Mutex
	ptr *C.irgx_engine
}

// OpenCorpus stands a corpus up over roots. No roots walks the working
// directory, which is what a bare command-line search does and is not an error.
//
// Close it when done. The corpus outlives its cursors on purpose - a cursor
// copies its records into Go as it goes - so the two can be closed in either
// order.
func OpenCorpus(roots ...string) (*Corpus, error) {
	paths := make([]*C.char, len(roots))
	for i, r := range roots {
		paths[i] = C.CString(r)
	}
	// C memory holding C strings, so there is no Go pointer in the array C is
	// about to read and no pinning question to get wrong. The paths are the
	// engine's to copy during the open; ours to free the moment it returns.
	defer func() {
		for _, p := range paths {
			C.free(unsafe.Pointer(p))
		}
	}()
	var (
		ptr   *C.irgx_engine
		fault C.irgx_fault
	)
	st := C.go_engine_open((**C.char)(unsafe.Pointer(head(paths))),
		C.size_t(len(roots)), &ptr, &fault)
	if st != C.IRGX_OK {
		return nil, newError(st, &fault, "open a corpus over "+strconv.Itoa(len(roots))+" root(s)")
	}
	c := &Corpus{ptr: ptr}
	runtime.SetFinalizer(c, (*Corpus).Close)
	return c, nil
}

// Close releases the corpus. Idempotent, and it cannot fail.
func (c *Corpus) Close() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ptr != nil {
		C.irgx_engine_close(c.ptr)
		c.ptr = nil
		runtime.SetFinalizer(c, nil)
	}
}

// Search runs one search over the corpus and returns a cursor over its records.
//
// ctx cancels the SEARCH, which is where the time goes: by the time this returns
// the records are materialized and walking them touches no filesystem. A
// cancelled search returns ctx.Err() rather than a partial cursor.
//
// Close the cursor. A search that found nothing still returns one, because "no
// matches" is an answer and not a reason to have nothing to release.
func (c *Corpus) Search(ctx context.Context, opts SearchOpts) (*Cursor, error) {
	if opts.Pattern == "" {
		return nil, refuse("search a corpus for the empty pattern")
	}
	if opts.Before < 0 || opts.After < 0 || opts.MaxResults < 0 || opts.Timeout < 0 {
		return nil, refuse("search a corpus with a negative bound")
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ptr == nil {
		return nil, refuse("search a closed corpus")
	}

	var pin runtime.Pinner
	defer pin.Unpin()
	body := bytePtr(opts.Pattern)
	pin.Pin(body)

	req := C.irgx_tree_request{
		flags:          C.uint32_t(opts.bits()),
		pattern:        body,
		pattern_len:    C.size_t(len(opts.Pattern)),
		before_context: C.uint64_t(opts.Before),
		after_context:  C.uint64_t(opts.After),
		max_results:    C.size_t(opts.MaxResults),
		timeout_ns:     C.uint64_t(opts.Timeout.Nanoseconds()),
	}
	req.struct_size = C.uint32_t(unsafe.Sizeof(req))
	if opts.MaxCount != nil {
		req.max_count = C.uint64_t(*opts.MaxCount)
	}

	// The token is the one handle another thread may touch while a query runs,
	// which is exactly what a ctx watcher is. It is torn down before the free,
	// so no goroutine can trip a token that has already been released - and
	// because the search is synchronous, both happen before Search returns and
	// the cursor never depends on either.
	stop, err := watch(ctx, &req)
	if err != nil {
		return nil, err
	}
	var (
		ptr   *C.irgx_cursor
		fault C.irgx_fault
	)
	st := C.go_tree_search(c.ptr, &req, &ptr, &fault)
	stop()
	runtime.KeepAlive(opts.Pattern)
	if st < 0 {
		// A cancelled search is the context's answer, not the engine's: a caller
		// that cancelled wants errors.Is(err, context.Canceled) to hold.
		if err := ctx.Err(); err != nil {
			if ptr != nil {
				C.irgx_matches_close(ptr)
			}
			return nil, err
		}
		return nil, newError(st, &fault, "search a corpus for "+strconv.Quote(opts.Pattern))
	}
	cur := &Cursor{ptr: ptr, left: int(C.irgx_matches_count(ptr))}
	cur.total = cur.left
	runtime.SetFinalizer(cur, (*Cursor).Close)
	return cur, nil
}

// watch installs a cancel token on req that trips when ctx ends, and returns the
// teardown that must run before req is forgotten.
//
// A ctx with no deadline and no cancel still gets a token: Done() is nil then, so
// the watcher blocks forever on a channel that is never closed and costs one
// parked goroutine for the length of one search. Skipping the token in that case
// would save it, at the price of two paths through here.
func watch(ctx context.Context, req *C.irgx_tree_request) (func(), error) {
	var token *C.irgx_cancel
	if st := C.irgx_cancel_new(&token); st != C.IRGX_OK {
		var none C.irgx_fault
		return nil, newError(st, &none, "allocate a cancellation token")
	}
	req.cancel = token
	stop, done := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(done)
		select {
		case <-ctx.Done():
			C.irgx_cancel_request(token)
		case <-stop:
		}
	}()
	return func() {
		close(stop)
		<-done
		req.cancel = nil
		C.irgx_cancel_free(token)
	}, nil
}

// Cursor is a walk over one search's records.
//
// It is NOT safe for concurrent use by multiple goroutines - it is a position -
// but two cursors are independent, so fanning out over several searches is fine.
type Cursor struct {
	ptr   *C.irgx_cursor
	buf   []Record
	at    int
	left  int
	total int
}

// Count is how many records the search found, answerable before any are pulled
// and unchanged by pulling them.
func (c *Cursor) Count() int { return c.total }

// Next returns the next record, or false when the stream is drained.
//
// Records arrive in batches of [batchSize] behind this, because a cgo crossing
// costs about what a hundred Go calls cost and one per record would make
// iteration the expensive part of a search. The one-record verb still earns its
// place: when exactly one record remains there is no batch to amortize and no
// buffer worth allocating, so the tail of every stream is pulled singly.
func (c *Cursor) Next() (Record, bool) {
	if c.at < len(c.buf) {
		m := c.buf[c.at]
		c.at++
		return m, true
	}
	if c.ptr == nil || c.left <= 0 {
		return Record{}, false
	}
	if c.left == 1 {
		return c.one()
	}
	return c.refill()
}

// one pulls a single record: the tail case, and the existence case.
func (c *Cursor) one() (Record, bool) {
	var (
		raw   C.irgx_match
		fault C.irgx_fault
	)
	st := C.go_matches_next(c.ptr, &raw, &fault)
	if st < 0 {
		panic(newError(st, &fault, "pull a record from a corpus search"))
	}
	if st != C.IRGX_MATCH {
		c.left = 0
		return Record{}, false
	}
	c.left--
	return goRecord(raw), true
}

// refill pulls a batch and hands back its first record.
func (c *Cursor) refill() (Record, bool) {
	n := min(batchSize, c.left)
	raw := make([]C.irgx_match, n)
	var (
		written C.size_t
		fault   C.irgx_fault
	)
	// Deliberately not routed through drain: this verb reports what the call
	// CONSUMED rather than how many records exist, so a short buffer is a
	// partial pull to resume rather than a retry to re-run.
	st := C.go_matches_next_batch(c.ptr, head(raw), C.size_t(n), &written, &fault)
	if st < 0 {
		panic(newError(st, &fault, "pull records from a corpus search"))
	}
	took := int(written)
	if took == 0 {
		c.left = 0
		return Record{}, false
	}
	c.left -= took
	c.buf = c.buf[:0]
	for _, r := range raw[:took] {
		c.buf = append(c.buf, goRecord(r))
	}
	c.at = 1
	return c.buf[0], true
}

// All collects every remaining record. Convenience over [Cursor.Next] for a
// caller that wants the result set rather than a stream; it still crosses once
// per batch.
func (c *Cursor) All() []Record {
	out := make([]Record, 0, c.left)
	for {
		m, ok := c.Next()
		if !ok {
			return out
		}
		out = append(out, m)
	}
}

// Close releases the cursor and every byte its records borrowed. Idempotent.
//
// Safe to call while holding [Record] values, and safe as a finalizer, because a
// Record is Go memory: [goRecord] copies the path, the line and the spans out at
// the moment the record is pulled. That is the whole reason it copies.
func (c *Cursor) Close() {
	if c.ptr != nil {
		C.irgx_matches_close(c.ptr)
		c.ptr = nil
		c.left = 0
		runtime.SetFinalizer(c, nil)
	}
}

// goRecord copies one C record into Go.
//
// path, line and spans all point into the cursor's arena and die at
// irgx_matches_close. Handing a caller a string over those bytes would be a
// use-after-free waiting for a Close - and worse, a finalizer could spring it
// with no call in sight. The copy is what makes a Record an ordinary Go value.
func goRecord(raw C.irgx_match) Record {
	m := Record{
		Path:   goString(raw.path),
		Line:   goString(raw.line),
		Number: int(raw.line_number),
		Kind:   Kind(raw.kind),
	}
	if raw.spans != nil && raw.nspans != 0 {
		m.Spans = make([][]int, 0, int(raw.nspans))
		for _, s := range unsafe.Slice(raw.spans, int(raw.nspans)) {
			m.Spans = append(m.Spans, []int{int(s.start), int(s.end)})
		}
	}
	return m
}
