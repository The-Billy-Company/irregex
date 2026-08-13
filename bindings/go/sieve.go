//go:build cgo

package irgx

// The sieve plane: narrowing, so most files are never opened.
//
// EVERY ANSWER HERE IS A SUPERSET. A sieve rules documents OUT; it never rules
// one in. A document this plane admits still has to be read and matched, and a
// document it withholds provably cannot match - that asymmetry is the entire
// contract, and it is why nothing here is named `Match` or returns a hit. The Go
// names say `Candidates`, `MayContain`, `ReadingList`, because that is what they
// are.
//
// The second thing to know is that a declinature is not an empty answer. Below
// the trigram floor - a two-byte needle, say - the tier cannot bound the question
// at all, and returning "no candidates" would be the one catastrophically wrong
// answer this API could give. So every narrowing verb returns a `narrowed bool`
// alongside its documents, and false means READ EVERYTHING. There is no way to
// use these functions correctly while ignoring it, which is deliberate.
//
// Two tiers sit behind this: the trigram index and the crest sieve.
// [Sieve.Describe] says which are present.

/*
#cgo CFLAGS: -I${SRCDIR}
#include "shim.h"

static int32_t go_sieve_open(const uint8_t *dir, size_t dir_len,
                             irgx_sieve **out, irgx_fault *f) {
  int32_t st = irgx_sieve_open(dir, dir_len, out);
  capture(st, f);
  return st;
}

static int32_t go_sieve_describe(const irgx_sieve *s, irgx_sieve_facts *out,
                                 irgx_fault *f) {
  int32_t st = irgx_sieve_describe(s, out);
  capture(st, f);
  return st;
}

static int32_t go_sieve_doc_path(const irgx_sieve *s, uint32_t doc,
                                 irgx_text *out, irgx_fault *f) {
  int32_t st = irgx_sieve_doc_path(s, doc, out);
  capture(st, f);
  return st;
}

static int32_t go_sieve_root(const irgx_sieve *s, uint32_t i, irgx_text *out,
                             irgx_fault *f) {
  int32_t st = irgx_sieve_root(s, i, out);
  capture(st, f);
  return st;
}

static int32_t go_sieve_literal(irgx_sieve *s, const uint8_t *needle, size_t len,
                                uint32_t *out, size_t cap, size_t *written,
                                irgx_fault *f) {
  int32_t st = irgx_sieve_literal(s, needle, len, out, cap, written);
  capture(st, f);
  return st;
}

static int32_t go_sieve_alternation(irgx_sieve *s, const irgx_text *needles,
                                    size_t n, uint32_t *out, size_t cap,
                                    size_t *written, irgx_fault *f) {
  int32_t st = irgx_sieve_alternation(s, needles, n, out, cap, written);
  capture(st, f);
  return st;
}

static int32_t go_sieve_candidates(irgx_sieve *s, const irgx_winnow *w,
                                   uint32_t *out, size_t cap, size_t *written,
                                   irgx_fault *f) {
  int32_t st = irgx_sieve_candidates(s, w, out, cap, written);
  capture(st, f);
  return st;
}

static int32_t go_sieve_reading_list(irgx_sieve *s, const irgx_winnow *w,
                                     uint32_t *out, size_t cap, size_t *written,
                                     irgx_fault *f) {
  int32_t st = irgx_sieve_reading_list(s, w, out, cap, written);
  capture(st, f);
  return st;
}

static int32_t go_sieve_freshness(const irgx_sieve *s, irgx_freshness *out,
                                  irgx_fault *f) {
  int32_t st = irgx_sieve_freshness(s, out);
  capture(st, f);
  return st;
}

static int32_t go_sieve_stale_count(const irgx_sieve *s, size_t *out,
                                    irgx_fault *f) {
  int32_t st = irgx_sieve_stale_count(s, out);
  capture(st, f);
  return st;
}

static int32_t go_winnow_of(irgx_regex *re, irgx_winnow **out, irgx_fault *f) {
  int32_t st = irgx_winnow_of(re, out);
  capture(st, f);
  return st;
}

static int32_t go_winnow_describe(const irgx_winnow *w, irgx_winnow_facts *out,
                                  irgx_fault *f) {
  int32_t st = irgx_winnow_describe(w, out);
  capture(st, f);
  return st;
}
*/
import "C"

import (
	"runtime"
	"strconv"
	"time"
	"unsafe"
)

// Doc is a document id in a [Sieve]'s artifacts. Resolve one to a path with
// [Sieve.Path]; it means nothing outside the sieve that issued it.
type Doc uint32

// SieveFacts is what a set of artifacts contains, and which tiers are present at
// all.
type SieveFacts struct {
	// Docs, Paths and Postings are what was indexed.
	Docs, Paths, Postings int
	// Roots is how many roots it was built over; read them with [Sieve.Root].
	Roots int
	// HasCrest is whether the crest tier is present; HasCodicil, the sidecar.
	// A narrowing verb can only use a tier that is here.
	HasCrest, HasCodicil bool
}

// FreshState is which freshness posture is in force. A switch rather than a
// conjunction over other fields, because "may I trust read elision" is one
// question and deriving it from three booleans is how a host gets it wrong.
type FreshState int32

const (
	// Anchored means the artifacts carry a build instant that dates THIS tree,
	// so freshness is decidable and elision is trustworthy.
	Anchored FreshState = 1
	// Unanchored means there is no recorded build instant, so nothing can be
	// dated. Not an error - just no basis for eliding a read.
	Unanchored FreshState = 2
	// Foreign means the anchor exists and dates somebody ELSE'S tree: artifacts
	// from another checkout, pointed at by the artifact-home env knob. They are
	// inert rather than wrong, and [Freshness.Anchor] is non-zero, which is how
	// a host recognizes this rather than guessing.
	Foreign FreshState = 3
)

func (s FreshState) String() string {
	switch s {
	case Anchored:
		return "anchored"
	case Unanchored:
		return "unanchored"
	case Foreign:
		return "foreign"
	}
	return "state " + strconv.FormatInt(int64(s), 10)
}

// Freshness is whether the artifacts still describe the tree.
type Freshness struct {
	// State is the posture. Read it before trusting a narrowing answer to
	// justify NOT reading a file.
	State FreshState
	// Anchor is the recorded build instant, or the zero Time when there is
	// none. Non-zero under [Foreign]: the instant exists, it just dates another
	// tree.
	Anchor time.Time
}

// WinnowFacts is what a narrowing plan is made of, and whether it can narrow at
// all.
type WinnowFacts struct {
	// Clauses, Atoms, Literals and Alternatives are the plan's shape.
	Clauses, Atoms, Literals, Alternatives int
	// SieveActive is whether the crest tier participates in this plan.
	SieveActive bool
	// Idle is the honest answer that this pattern rules NOTHING out - `.*`, or
	// anything with no bindable literal. An empty candidate list would have been
	// a lie, so the plan says it is idle instead and the host reads everything.
	Idle bool
}

// Sieve is a corpus's persisted narrowing tier.
//
// It is NOT safe for concurrent use by multiple goroutines: the narrowing verbs
// take it mutably (they memoize folded forms), so two goroutines sharing one
// corrupt that cache. Open one per goroutine, or guard it - the artifacts are
// memory-mapped, so a second open is cheap.
type Sieve struct{ ptr *C.irgx_sieve }

// OpenSieve opens the persisted artifacts in dir, or the artifact home (the
// `<prefix>DIR` env knob, else the default artifact directory) when dir is
// empty. Any other directory is a deliberate override and costs freshness: see
// [Foreign].
//
// It returns [ErrNoIndex] when nothing has been indexed - a declinature, not a
// failure, and not an empty index. Artifacts built over a different tree open
// INERT rather than wrong, which is a successful open whose [Sieve.Freshness]
// reports [Foreign].
func OpenSieve(dir string) (*Sieve, error) {
	var (
		ptr   *C.irgx_sieve
		fault C.irgx_fault
	)
	st := C.go_sieve_open(bytePtr(dir), C.size_t(len(dir)), &ptr, &fault)
	runtime.KeepAlive(dir)
	switch {
	case st == C.IRGX_STALE:
		// A declinature installs no fault, so there is nothing to read here and
		// nothing to report but the fact itself.
		return nil, ErrNoIndex
	case st < 0:
		where := "the artifact home"
		if dir != "" {
			where = strconv.Quote(dir)
		}
		return nil, newError(st, &fault, "open the narrowing index in "+where)
	}
	s := &Sieve{ptr: ptr}
	runtime.SetFinalizer(s, (*Sieve).Close)
	return s, nil
}

// Close releases the sieve and unmaps its artifacts. Idempotent.
//
// Safe as a finalizer: [Sieve.Path] and [Sieve.Root] copy their bytes out, and
// document ids are numbers, so nothing a caller holds points into the mapping.
func (s *Sieve) Close() {
	if s.ptr != nil {
		C.irgx_sieve_close(s.ptr)
		s.ptr = nil
		runtime.SetFinalizer(s, nil)
	}
}

// Describe reports what this artifact set contains.
func (s *Sieve) Describe() SieveFacts {
	var (
		raw   C.irgx_sieve_facts
		fault C.irgx_fault
	)
	raw.struct_size = C.uint32_t(unsafe.Sizeof(raw))
	if st := C.go_sieve_describe(s.ptr, &raw, &fault); st < 0 {
		panic(newError(st, &fault, "describe a narrowing index"))
	}
	return SieveFacts{
		Docs:       int(raw.doc_count),
		Paths:      int(raw.path_count),
		Postings:   int(raw.posting_count),
		Roots:      int(raw.root_count),
		HasCrest:   raw.has_crest != 0,
		HasCodicil: raw.has_codicil != 0,
	}
}

// Path is the file a document id names.
//
// It panics for an id this sieve did not issue, the way indexing a slice out of
// range panics: a document id is only meaningful inside the sieve that produced
// it, and one from somewhere else is a bug rather than a lookup miss.
func (s *Sieve) Path(doc Doc) string {
	var (
		out   C.irgx_text
		fault C.irgx_fault
	)
	st := C.go_sieve_doc_path(s.ptr, C.uint32_t(doc), &out, &fault)
	if st < 0 {
		panic(newError(st, &fault, "read the path of document "+strconv.FormatUint(uint64(doc), 10)))
	}
	return goString(out)
}

// Root is the i-th root the artifacts were built over - the scope any freshness
// walk covers, and the only honest answer to "what corpus is this?". It panics
// for an i past [SieveFacts.Roots].
func (s *Sieve) Root(i int) string {
	var (
		out   C.irgx_text
		fault C.irgx_fault
	)
	st := C.go_sieve_root(s.ptr, C.uint32_t(i), &out, &fault)
	if st < 0 {
		panic(newError(st, &fault, "read root "+strconv.Itoa(i)+" of a narrowing index"))
	}
	return goString(out)
}

// Roots is every root the artifacts were built over.
func (s *Sieve) Roots() []string {
	n := s.Describe().Roots
	out := make([]string, n)
	for i := range out {
		out[i] = s.Root(i)
	}
	return out
}

// MayContain is the documents that could hold needle, ascending, and whether the
// tier could bound the question at all.
//
// A raw literal probe for a host that already knows the exact bytes it is
// hunting: no parse, no plan, nothing to get wrong. narrowed is false when the
// needle is below the trigram floor and no crest tier covers it - READ
// EVERYTHING then. It is a separate return rather than an empty slice because
// those two answers are opposites and must not share a spelling.
func (s *Sieve) MayContain(needle string) (docs []Doc, narrowed bool) {
	if needle == "" {
		panic("irregex: Sieve.MayContain: the empty needle is in every document")
	}
	var fault C.irgx_fault
	ids, st := drain(sieveGuess, func(buf []C.uint32_t) (int, int32) {
		var written C.size_t
		st := C.go_sieve_literal(s.ptr, bytePtr(needle), C.size_t(len(needle)),
			head(buf), C.size_t(len(buf)), &written, &fault)
		return int(written), int32(st)
	})
	runtime.KeepAlive(needle)
	return s.docs(ids, st, &fault, "narrow a corpus to the documents holding "+strconv.Quote(needle))
}

// MayContainAny is the documents that could hold ANY of needles, merged inside
// the index rather than by one crossing per needle stitched together outside it.
//
// Sound only because it is a UNION: one branch nothing can bound leaves the whole
// answer unbounded, so narrowed is false unless every branch could be bounded.
// The tier declines rather than hand back the branches it happened to manage,
// which would look like a narrower answer than it is.
func (s *Sieve) MayContainAny(needles ...string) (docs []Doc, narrowed bool) {
	if len(needles) == 0 {
		panic("irregex: Sieve.MayContainAny: an empty alternation is not a question")
	}
	var pin runtime.Pinner
	defer pin.Unpin()
	set := make([]C.irgx_text, len(needles))
	for i, n := range needles {
		if n == "" {
			panic("irregex: Sieve.MayContainAny: branch " + strconv.Itoa(i) +
				" is empty, and the empty branch admits every document")
		}
		p := bytePtr(n)
		pin.Pin(p)
		set[i] = C.irgx_text{ptr: p, len: C.size_t(len(n))}
	}
	var fault C.irgx_fault
	ids, st := drain(sieveGuess, func(buf []C.uint32_t) (int, int32) {
		var written C.size_t
		st := C.go_sieve_alternation(s.ptr, head(set), C.size_t(len(set)), head(buf),
			C.size_t(len(buf)), &written, &fault)
		return int(written), int32(st)
	})
	runtime.KeepAlive(needles)
	runtime.KeepAlive(set)
	return s.docs(ids, st, &fault, "narrow a corpus to the documents holding any of "+
		strconv.Itoa(len(needles))+" needles")
}

// Candidates is what a whole plan admits, in document-id order.
//
// AS BUILT, NOT AS NOW: both prunings read artifacts written at index time, so a
// file changed since then may be missing. That is the raw index answer, which is
// what you want when intersecting it with another set of your own. When the
// answer has to be sound against the bytes on disk right now, use
// [Sieve.ReadingList].
func (s *Sieve) Candidates(w *Winnow) (docs []Doc, narrowed bool) {
	var fault C.irgx_fault
	ids, st := drain(sieveGuess, func(buf []C.uint32_t) (int, int32) {
		var written C.size_t
		st := C.go_sieve_candidates(s.ptr, w.ptr, head(buf), C.size_t(len(buf)),
			&written, &fault)
		return int(written), int32(st)
	})
	return s.docs(ids, st, &fault, "narrow a corpus to a pattern's candidates")
}

// ReadingList is the same set as [Sieve.Candidates], sequenced by what is
// cheapest to read and sound against live bytes: a file that changed since the
// index was built is folded back in rather than silently dropped.
//
// This is the one to hand a reader. narrowed is false only when the plan cannot
// narrow at all; with no usable anchor it returns every document rather than
// declining, because "read everything in a sensible order" is still an answer.
func (s *Sieve) ReadingList(w *Winnow) (docs []Doc, narrowed bool) {
	var fault C.irgx_fault
	ids, st := drain(sieveGuess, func(buf []C.uint32_t) (int, int32) {
		var written C.size_t
		st := C.go_sieve_reading_list(s.ptr, w.ptr, head(buf), C.size_t(len(buf)),
			&written, &fault)
		return int(written), int32(st)
	})
	return s.docs(ids, st, &fault, "order a corpus into a reading list")
}

// sieveGuess is the first buffer a narrowing query tries. A candidate set is
// usually a small fraction of the corpus, and the engine reports the count that
// EXISTS, so a wider answer measures its own single retry.
const sieveGuess = 256

// docs is the shared tail of the four narrowing verbs: the STALE-is-a-declinature
// rule, in one place, so no verb can forget it.
func (s *Sieve) docs(ids []C.uint32_t, st int32, fault *C.irgx_fault, op string) ([]Doc, bool) {
	if st == C.IRGX_STALE {
		// *written was never touched, which is precisely why this cannot be
		// reported as an empty candidate set: nobody wrote a zero, the tier
		// declined to answer, and the caller has to read everything.
		return nil, false
	}
	if st < 0 {
		panic(newError(C.int32_t(st), fault, op))
	}
	if len(ids) == 0 {
		return nil, true
	}
	out := make([]Doc, len(ids))
	for i, d := range ids {
		out[i] = Doc(d)
	}
	return out, true
}

// Freshness is whether the artifacts still describe the tree. Cheap: it reads
// the anchor and asks whether that anchor dates this tree, without walking the
// corpus.
func (s *Sieve) Freshness() Freshness {
	var (
		raw   C.irgx_freshness
		fault C.irgx_fault
	)
	raw.struct_size = C.uint32_t(unsafe.Sizeof(raw))
	if st := C.go_sieve_freshness(s.ptr, &raw, &fault); st < 0 {
		panic(newError(st, &fault, "read the freshness of a narrowing index"))
	}
	f := Freshness{State: FreshState(raw.state)}
	if raw.anchor_ns != 0 {
		f.Anchor = time.Unix(0, int64(raw.anchor_ns))
	}
	return f
}

// StaleCount is HOW MANY documents changed since the anchor - the magnitude that
// [Sieve.Freshness] reduces to a posture, for a host deciding whether a rebuild
// is worth it.
//
// ok is false when there is no usable anchor: with nothing to date against, the
// honest answer is not zero. Its own verb rather than a Freshness field because
// it costs a corpus walk, and a host asking only "may I trust elision" should not
// have to pay for one.
func (s *Sieve) StaleCount() (n int, ok bool) {
	var (
		out   C.size_t
		fault C.irgx_fault
	)
	st := C.go_sieve_stale_count(s.ptr, &out, &fault)
	if st == C.IRGX_STALE {
		return 0, false
	}
	if st < 0 {
		panic(newError(st, &fault, "count the documents that changed since a narrowing index was built"))
	}
	return int(out), true
}

// Winnow is one pattern's narrowing plan, derived once and spent across many
// queries against many sieves.
//
// It is derived from the pattern alone and borrows nothing from the [Regexp] or
// from any [Sieve], so it outlives both. NOT safe for concurrent use: the
// narrowing verbs that consume it are not, so sharing one buys nothing.
type Winnow struct{ ptr *C.irgx_winnow }

// Winnow derives this pattern's narrowing plan.
//
// Derive it once and reuse it: the plan is where the pattern is taken apart into
// bindable literals, which is work that does not depend on the corpus. Ask
// [Winnow.Describe] whether it can narrow at all before spending a query on it -
// [WinnowFacts.Idle] means it cannot, and there is no point.
func (re *Regexp) Winnow() (*Winnow, error) {
	h := re.acquire()
	defer re.release(h)
	var (
		ptr   *C.irgx_winnow
		fault C.irgx_fault
	)
	if st := C.go_winnow_of(h.ptr, &ptr, &fault); st != C.IRGX_OK {
		return nil, newError(st, &fault, "derive a narrowing plan for "+strconv.Quote(re.expr))
	}
	w := &Winnow{ptr: ptr}
	runtime.SetFinalizer(w, (*Winnow).Close)
	return w, nil
}

// Close releases the plan. Idempotent, and it cannot fail.
func (w *Winnow) Close() {
	if w.ptr != nil {
		C.irgx_winnow_free(w.ptr)
		w.ptr = nil
		runtime.SetFinalizer(w, nil)
	}
}

// Describe is what the plan is made of, and whether it can narrow at all.
func (w *Winnow) Describe() WinnowFacts {
	var (
		raw   C.irgx_winnow_facts
		fault C.irgx_fault
	)
	raw.struct_size = C.uint32_t(unsafe.Sizeof(raw))
	if st := C.go_winnow_describe(w.ptr, &raw, &fault); st < 0 {
		panic(newError(st, &fault, "describe a narrowing plan"))
	}
	return WinnowFacts{
		Clauses:      int(raw.clauses),
		Atoms:        int(raw.atoms),
		Literals:     int(raw.literals),
		Alternatives: int(raw.alternatives),
		SieveActive:  raw.sieve_active != 0,
		Idle:         raw.idle != 0,
	}
}
