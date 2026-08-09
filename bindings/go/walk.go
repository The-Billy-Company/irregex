//go:build cgo

package irgx

// The walk plane: which files a search is even allowed to read.
//
// gitignore precedence, the type registry, hidden and binary policy - the half
// of a grep-shaped tool that has nothing to do with matching, and the half that
// is genuinely hard to get right. It is answered here as a set you can hold and
// interrogate rather than as a side effect of searching, so "which files would
// this have looked at?" is a question with an answer instead of a thing you infer
// from output.
//
// The set is MATERIALIZED by [OpenWalk]: the filesystem is read once, and
// [Walk.Len], [Walk.Holds] and [Walk.Rewind] are then all free of it. That is
// what makes a second pass over the same eligibility cost nothing, and why
// [Walk.Gapped] can be a number rather than a stream of warnings.
//
// Two of these verbs are about bytes and paths rather than about a walk -
// [IsBinary] and [GenusOf] - and take no handle. They are the policy the walk
// applies, exposed so a host that already has the bytes can ask the same
// question the same way instead of writing its own sniffer that disagrees.

/*
#cgo CFLAGS: -I${SRCDIR}
#include "shim.h"

static int32_t go_walk_limits(irgx_limits *out, irgx_fault *f) {
  int32_t st = irgx_walk_limits(out);
  capture(st, f);
  return st;
}

static int32_t go_walk_open(const irgx_walk_spec *spec, irgx_walk **out,
                            irgx_fault *f) {
  int32_t st = irgx_walk_open(spec, out);
  capture(st, f);
  return st;
}

static int32_t go_walk_next(irgx_walk *w, irgx_walk_entry *out, irgx_fault *f) {
  int32_t st = irgx_walk_next(w, out);
  capture(st, f);
  return st;
}

static int32_t go_walk_next_batch(irgx_walk *w, irgx_walk_entry *out, size_t cap,
                                  size_t *written, irgx_fault *f) {
  int32_t st = irgx_walk_next_batch(w, out, cap, written);
  capture(st, f);
  return st;
}

static int32_t go_walk_holds(const irgx_walk *w, const uint8_t *path,
                             size_t path_len, irgx_fault *f) {
  int32_t st = irgx_walk_holds(w, path, path_len);
  capture(st, f);
  return st;
}

static int32_t go_walk_binary(const uint8_t *bytes, size_t len, irgx_fault *f) {
  int32_t st = irgx_walk_binary(bytes, len);
  capture(st, f);
  return st;
}

static int32_t go_walk_genus(const uint8_t *path, size_t len, uint32_t *out,
                             irgx_fault *f) {
  int32_t st = irgx_walk_genus(path, len, out);
  capture(st, f);
  return st;
}
*/
import "C"

import (
	"path/filepath"
	"runtime"
	"strconv"
	"unsafe"
)

// Genus is what a path is FOR - a total, disjoint partition, so an unfamiliar
// extension lands in [GenusCode] rather than falling through a gap.
//
// The axis a language filter cannot express: "the paper trail" is markdown and
// man pages and LICENSE, not one language, and "the implementation plus its
// payload" is everything that is not prose.
type Genus uint32

const (
	// GenusCode is implementation - and the LEFTOVER, so an extension nothing
	// recognizes lands here. A gap can therefore only show one file too many,
	// never hide one.
	GenusCode Genus = C.IRGX_GENUS_CODE
	// GenusDocs is the paper trail: markdown, rst, man, org, TeX, LICENSE.
	GenusDocs Genus = C.IRGX_GENUS_DOCS
	// GenusData is configuration: json, yaml, toml, lockfiles.
	GenusData Genus = C.IRGX_GENUS_DATA
)

func (g Genus) String() string {
	switch g {
	case GenusCode:
		return "code"
	case GenusDocs:
		return "docs"
	case GenusData:
		return "data"
	}
	return "genus " + strconv.FormatUint(uint64(g), 10)
}

// TermKind is what one clause of a [WalkSpec] MEANS. A root is a place to walk
// from; every other kind narrows what the walk keeps.
type TermKind uint32

const (
	// Root is a place to walk from. A spec with no root walks the working
	// directory.
	Root TermKind = C.IRGX_TERM_ROOT
	// Glob keeps paths matching a glob; GlobNot drops them; IGlob is Glob,
	// case-insensitively.
	Glob    TermKind = C.IRGX_TERM_GLOB
	GlobNot TermKind = C.IRGX_TERM_GLOB_NOT
	IGlob   TermKind = C.IRGX_TERM_IGLOB
	// Type keeps a registered type by name ("zig", "docs"); TypeNot drops it.
	Type    TermKind = C.IRGX_TERM_TYPE
	TypeNot TermKind = C.IRGX_TERM_TYPE_NOT
	// IgnoreFile names an extra ignore file to honor, on top of the ones the
	// policy already reads.
	IgnoreFile TermKind = C.IRGX_TERM_IGNORE_FILE
)

// Term is one clause of a walk spec: a kind and the text it applies to.
type Term struct {
	Kind TermKind
	Text string
}

// RootOf, GlobOf and TypeOf spell the three common terms without a struct
// literal, because a spec is usually a list of roots and a couple of filters and
// `irgx.RootOf(".")` reads better than the field names at that density.
func RootOf(path string) Term { return Term{Kind: Root, Text: path} }
func GlobOf(pat string) Term  { return Term{Kind: Glob, Text: pat} }
func TypeOf(name string) Term { return Term{Kind: Type, Text: name} }

// WalkSpec is one complete eligibility question. The zero value plus a root is
// the default policy: honor every ignore file, skip hidden entries, skip
// binaries, files only.
//
// Every flag here is a DECLINATURE of something the walk would otherwise do,
// which is why they read as absences - the safe spelling is the zero value, and
// a host that sets nothing gets the policy a command-line search gets.
type WalkSpec struct {
	// Terms are the roots and the filters, in the order they were written.
	Terms []Term
	// MaxDepth bounds descent; 0 is unbounded.
	MaxDepth uint64
	// Hidden descends into dotfiles.
	Hidden bool
	// NoIgnore turns off every ignore file at once. The six that follow turn off
	// one source each, and are the ones to reach for: NoIgnore is a blunt
	// instrument that also drops the ones you did want.
	NoIgnore bool
	// NoIgnoreVCS stops reading .gitignore.
	NoIgnoreVCS bool
	// NoIgnoreDot stops reading .ignore.
	NoIgnoreDot bool
	// NoIgnoreParent stops reading ignore files above the root.
	NoIgnoreParent bool
	// NoIgnoreExclude stops reading .git/info/exclude.
	NoIgnoreExclude bool
	// NoIgnoreGlobal stops reading the user's global ignore file.
	NoIgnoreGlobal bool
	// NoIgnoreFiles stops reading the ignore files named by [IgnoreFile] terms.
	NoIgnoreFiles bool
	// NoRequireGit applies VCS ignore rules outside a repository, where they
	// would otherwise be inert.
	NoRequireGit bool
	// IgnoreFileICase matches ignore-file patterns case-insensitively.
	IgnoreFileICase bool
	// Follow follows symlinks. OneFileSystem refuses to cross a mount point.
	Follow        bool
	OneFileSystem bool
	// GlobICase matches every glob term case-insensitively, which is [IGlob]
	// applied to the whole spec.
	GlobICase bool
	// Members narrows the eligible set to what a SEARCH would actually read, by
	// additionally applying the corpus content rules - the binary sniff, the
	// per-file ceiling, and the empty file - and populating [Entry.Size] with
	// each survivor's length.
	//
	// This is the only setting that opens files, so it is the only one that costs
	// a read per candidate, and it is what to ask for when the walk is a work
	// PLAN rather than an inventory: without it a binary blob and an empty file
	// are both eligible paths that no match can ever come from.
	Members bool
	// TolerateGaps turns an unreadable directory into a count ([Walk.Gapped])
	// instead of a refusal. Without it an unreadable directory fails the walk,
	// which is the honest default: "nothing matched" and "we never looked there"
	// are different answers, and a host that wants the second one has to say so.
	TolerateGaps bool
}

func (s WalkSpec) bits() uint32 {
	return bit(s.Hidden, C.IRGX_WALK_HIDDEN) |
		bit(s.NoIgnore, C.IRGX_WALK_NO_IGNORE) |
		bit(s.NoIgnoreVCS, C.IRGX_WALK_NO_IGNORE_VCS) |
		bit(s.NoIgnoreDot, C.IRGX_WALK_NO_IGNORE_DOT) |
		bit(s.NoIgnoreParent, C.IRGX_WALK_NO_IGNORE_PARENT) |
		bit(s.NoIgnoreExclude, C.IRGX_WALK_NO_IGNORE_EXCLUDE) |
		bit(s.NoIgnoreGlobal, C.IRGX_WALK_NO_IGNORE_GLOBAL) |
		bit(s.NoIgnoreFiles, C.IRGX_WALK_NO_IGNORE_FILES) |
		bit(s.NoRequireGit, C.IRGX_WALK_NO_REQUIRE_GIT) |
		bit(s.IgnoreFileICase, C.IRGX_WALK_IGNORE_FILE_ICASE) |
		bit(s.Follow, C.IRGX_WALK_FOLLOW) |
		bit(s.OneFileSystem, C.IRGX_WALK_ONE_FILE_SYSTEM) |
		bit(s.GlobICase, C.IRGX_WALK_GLOB_ICASE) |
		bit(s.Members, C.IRGX_WALK_MEMBERS) |
		bit(s.TolerateGaps, C.IRGX_WALK_TOLERATE_GAPS)
}

// Entry is one eligible file, owned by Go.
type Entry struct {
	// Path is the file, as the walk spelled it - rooted the way the [Root] term
	// was, so a relative root yields relative paths. It is also the only spelling
	// [Walk.Holds] recognizes.
	Path string
	// Size is the file's length in bytes, and it is ZERO unless the spec asked
	// for [WalkSpec.Members] - the only setting that reads files. Sizing an
	// inventory walk from this field would report an empty corpus.
	Size uint64
	// Genus is what it is FOR.
	Genus Genus
}

// Limits are the ceilings this build enforces, so a host sizes a request against
// the truth instead of against a constant it copied out of a header once.
type Limits struct {
	// BinaryWindow is how many leading bytes the binary verdict sniffs - the
	// same window [IsBinary] applies.
	BinaryWindow int
	// FileCap is the most files one walk may materialize.
	FileCap uint64
	// TypeRows is how many rows the type registry holds; TypeNames is how many
	// distinct names it answers to (an alias is a name without a row).
	TypeRows, TypeNames int
	// BraceCap and BraceGroupCap are the two ceilings a `{a,b}` glob term is
	// expanded under; exceeding either refuses the open rather than allocating.
	// They bound different things and a host validating a user's glob needs
	// both: BraceCap bounds the PRODUCT, which `{a}{a}{a}...` slips past at a
	// product of one while still recursing once per group, and BraceGroupCap
	// bounds that.
	BraceCap, BraceGroupCap int
}

// WalkLimits reports the ceilings this build enforces.
func WalkLimits() Limits {
	var (
		raw   C.irgx_limits
		fault C.irgx_fault
	)
	raw.struct_size = C.uint32_t(unsafe.Sizeof(raw))
	if st := C.go_walk_limits(&raw, &fault); st < 0 {
		panic(newError(st, &fault, "read the walk limits"))
	}
	return Limits{
		BinaryWindow:  int(raw.binary_window),
		FileCap:       uint64(raw.file_cap),
		TypeRows:      int(raw.type_rows),
		TypeNames:     int(raw.type_names),
		BraceCap:      int(raw.brace_cap),
		BraceGroupCap: int(raw.brace_group_cap),
	}
}

// Walk is the materialized set of files a search may read.
//
// It is NOT safe for concurrent use by multiple goroutines: iteration is a
// position, and [Walk.Rewind] moves it. The set itself never changes after
// [OpenWalk] returns, so a host that wants concurrent readers can hold the
// entries - [Walk.All] hands back Go values that outlive the handle.
type Walk struct {
	ptr   *C.irgx_walk
	buf   []Entry
	at    int
	left  int
	total int
}

// OpenWalk answers one eligibility question, reading the filesystem once.
//
// Close it when done, or let the garbage collector: every [Entry] is copied into
// Go when it is pulled, so a free can never invalidate one a caller still holds.
func OpenWalk(spec WalkSpec) (*Walk, error) {
	var pin runtime.Pinner
	defer pin.Unpin()
	terms := make([]C.irgx_walk_term, len(spec.Terms))
	for i, t := range spec.Terms {
		if t.Text == "" {
			return nil, refuse("walk with an empty " + strconv.Itoa(i) + "th term")
		}
		text := bytePtr(t.Text)
		// Go memory holding a Go pointer that C is about to read, which the cgo
		// rules forbid unless it is pinned. Pinning rather than copying: the
		// header says a term's text is borrowed for the length of this call
		// only, so it has to survive exactly the crossing.
		pin.Pin(text)
		terms[i] = C.irgx_walk_term{
			kind:     C.uint32_t(t.Kind),
			text:     text,
			text_len: C.size_t(len(t.Text)),
		}
	}
	// The spec is passed BY POINTER, so the array it names is a Go pointer inside
	// Go memory C dereferences - the same rule as the texts above, one level out.
	// The texts are reachable from a struct C reads; the struct's own array has to
	// be pinned for exactly the same reason, and forgetting it is a panic rather
	// than a silent corruption because cgocheck walks one level down.
	if head(terms) != nil {
		pin.Pin(head(terms))
	}
	raw := C.irgx_walk_spec{
		flags:      C.uint32_t(spec.bits()),
		max_depth:  C.uint64_t(spec.MaxDepth),
		terms:      head(terms),
		term_count: C.size_t(len(terms)),
	}
	raw.struct_size = C.uint32_t(unsafe.Sizeof(raw))
	var (
		ptr   *C.irgx_walk
		fault C.irgx_fault
	)
	st := C.go_walk_open(&raw, &ptr, &fault)
	runtime.KeepAlive(spec.Terms)
	runtime.KeepAlive(terms)
	// MATCH means files were admitted and OK means none were, and BOTH wrote a
	// handle - the status reports the answer, not whether there is something to
	// release. So the test is the sign, and an empty walk is a walk.
	if st < 0 {
		return nil, newError(st, &fault, "walk a tree under "+strconv.Itoa(len(terms))+" term(s)")
	}
	w := &Walk{ptr: ptr}
	w.total = int(C.irgx_walk_count(ptr))
	w.left = w.total
	runtime.SetFinalizer(w, (*Walk).Close)
	return w, nil
}

// Len is how many files are eligible, answerable without iterating.
func (w *Walk) Len() int { return w.total }

// Gapped is how many directories were unreadable but tolerated - the number that
// separates "nothing matched" from "we never looked there". Always 0 unless
// [WalkSpec.TolerateGaps] was set, because without it an unreadable directory
// fails the walk instead of being counted.
func (w *Walk) Gapped() int { return int(C.irgx_walk_gapped(w.ptr)) }

// Holds reports whether this exact path is in the set - membership without
// iterating, and without disturbing the iteration position.
//
// EXACT is the operative word: the comparison is against the path as the walk
// spelled it, which is rooted the way the [Root] term was. Native Windows
// separators are converted to the ABI's canonical `/`; nothing else is
// normalized. It does not resolve `.`, `..`, a symlink, or a relative path
// against the working directory - "in.go" and "/abs/in.go" are two spellings and
// only the walk's own answers yes. Ask it with an [Entry.Path], or with a path
// built from the same root you handed in.
func (w *Walk) Holds(path string) bool {
	path = filepath.ToSlash(path)
	var fault C.irgx_fault
	st := C.go_walk_holds(w.ptr, bytePtr(path), C.size_t(len(path)), &fault)
	runtime.KeepAlive(path)
	if st < 0 {
		panic(newError(st, &fault, "ask whether a walk holds "+strconv.Quote(path)))
	}
	return st == C.IRGX_MATCH
}

// Rewind restarts iteration. The set is already materialized, so this re-reads
// nothing from the filesystem - a second pass is free.
func (w *Walk) Rewind() {
	C.irgx_walk_rewind(w.ptr)
	w.buf, w.at, w.left = w.buf[:0], 0, w.total
}

// Next returns the next eligible file, or false when the set is exhausted.
//
// Entries arrive in batches, for the reason [Cursor.Next] gives: a crossing costs
// about what a hundred Go calls cost, and a tree has a lot of files in it. The
// one-entry verb pulls the tail, where there is no batch left to amortize.
func (w *Walk) Next() (Entry, bool) {
	if w.at < len(w.buf) {
		e := w.buf[w.at]
		w.at++
		return e, true
	}
	if w.ptr == nil || w.left <= 0 {
		return Entry{}, false
	}
	if w.left == 1 {
		return w.one()
	}
	return w.refill()
}

func (w *Walk) one() (Entry, bool) {
	var (
		raw   C.irgx_walk_entry
		fault C.irgx_fault
	)
	st := C.go_walk_next(w.ptr, &raw, &fault)
	if st < 0 {
		panic(newError(st, &fault, "pull an entry from a walk"))
	}
	if st != C.IRGX_MATCH {
		w.left = 0
		return Entry{}, false
	}
	w.left--
	return goEntry(raw), true
}

func (w *Walk) refill() (Entry, bool) {
	n := min(batchSize, w.left)
	raw := make([]C.irgx_walk_entry, n)
	var (
		written C.size_t
		fault   C.irgx_fault
	)
	// Not drain's protocol: *written is what this call CONSUMED, so a partial
	// pull resumes rather than retries.
	st := C.go_walk_next_batch(w.ptr, head(raw), C.size_t(n), &written, &fault)
	if st < 0 {
		panic(newError(st, &fault, "pull entries from a walk"))
	}
	took := int(written)
	if took == 0 {
		w.left = 0
		return Entry{}, false
	}
	w.left -= took
	w.buf = w.buf[:0]
	for _, r := range raw[:took] {
		w.buf = append(w.buf, goEntry(r))
	}
	w.at = 1
	return w.buf[0], true
}

// All collects every remaining entry. The result is Go memory and outlives the
// walk, which is what makes a materialized set worth handing around.
func (w *Walk) All() []Entry {
	out := make([]Entry, 0, w.left)
	for {
		e, ok := w.Next()
		if !ok {
			return out
		}
		out = append(out, e)
	}
}

// Close releases the walk and every byte it lent out. Idempotent.
func (w *Walk) Close() {
	if w.ptr != nil {
		C.irgx_walk_close(w.ptr)
		w.ptr = nil
		w.left = 0
		runtime.SetFinalizer(w, nil)
	}
}

// goEntry copies one entry into Go. The path borrows the walk's arena and dies at
// irgx_walk_close; a Go string over it would be a use-after-free the finalizer
// could spring with no call in sight.
func goEntry(raw C.irgx_walk_entry) Entry {
	return Entry{
		Path:  goString(raw.path),
		Size:  uint64(raw.size),
		Genus: Genus(raw.genus),
	}
}

// IsBinary reports whether these bytes read as binary under the same window the
// walk applies - the policy, not a reimplementation of it. [Limits.BinaryWindow]
// is how much of a long buffer it will actually look at.
func IsBinary(b []byte) bool { return isBinary(borrow(b)) }

// IsBinaryString is [IsBinary] over a string.
func IsBinaryString(s string) bool { return isBinary(s) }

func isBinary(s string) bool {
	var fault C.irgx_fault
	st := C.go_walk_binary(bytePtr(s), C.size_t(len(s)), &fault)
	runtime.KeepAlive(s)
	if st < 0 {
		panic(newError(st, &fault, "sniff "+strconv.Itoa(len(s))+" bytes for binary content"))
	}
	return st == C.IRGX_MATCH
}

// GenusOf reports what a path is FOR, by the same registry the walk consults.
//
// It reads the path and nothing else, so it answers for a file that does not
// exist - which is the point when you are classifying names out of an index
// rather than off a disk.
func GenusOf(path string) Genus {
	var (
		out   C.uint32_t
		fault C.irgx_fault
	)
	st := C.go_walk_genus(bytePtr(path), C.size_t(len(path)), &out, &fault)
	runtime.KeepAlive(path)
	if st < 0 {
		panic(newError(st, &fault, "classify the path "+strconv.Quote(path)))
	}
	return Genus(out)
}
