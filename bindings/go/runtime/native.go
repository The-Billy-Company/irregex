//go:build cgo && irgx_ffi

package runtime

/*
// Linked against the SHARED libirgx, as the Python and Rust bindings are, not
// the static archive. Product producers (gist_run / relate_run / blast_run) are
// resolved at run time via dlsym, so this package never links a product library
// — a host that wants in-process rank, kinship, or compose links those dylibs
// from the product module that owns them. This tier is opt-in
// (`-tags irgx_ffi`) and already points at a local build tree, so a load path
// into that same tree is what it was always describing.
#cgo CFLAGS:  -I${SRCDIR}/../../../zig-out/include
#cgo LDFLAGS: -L${SRCDIR}/../../../zig-out/lib -lirgx
#cgo LDFLAGS: -Wl,-rpath,${SRCDIR}/../../../zig-out/lib
#include <stdlib.h>
#include <string.h>
#include "producers.h"
*/
import "C"

import (
	"context"
	"errors"
	"fmt"
	goruntime "runtime"
	"sync"
	"unsafe"

	"github.com/The-Billy-Company/irregex/bindings/go/analytic"
)

// hasCGO reports that the in-process transport was compiled in.
const hasCGO = true

// Native is a warm in-process corpus over the pull-cursor ABI. Searches are
// serialized (the resident engine is single-writer); the cursors they return are
// independent and safe to iterate concurrently.
type Native struct {
	mu  sync.Mutex
	ptr *C.irgx_engine
}

// OpenNative stands up the in-process engine over roots (none = the rootless CWD
// walk a bare `gist <pattern>` scans).
func OpenNative(roots ...string) (*Native, error) {
	cRoots := make([]*C.char, len(roots))
	for i, r := range roots {
		cRoots[i] = C.CString(r)
	}
	defer func() {
		for _, p := range cRoots {
			C.free(unsafe.Pointer(p))
		}
	}()
	var head **C.char
	if len(cRoots) > 0 {
		head = (**C.char)(unsafe.Pointer(&cRoots[0]))
	}
	var out *C.irgx_engine
	if st := C.irgx_engine_open(head, C.size_t(len(roots)), &out); st != C.IRGX_OK {
		return nil, statusError(st, "engine open")
	}
	e := &Native{ptr: out}
	goruntime.SetFinalizer(e, (*Native).Close)
	return e, nil
}

// Close frees the warm corpus, index and I/O pool (idempotent). Cursors already
// materialized own their records and stay valid.
func (n *Native) Close() error {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.ptr != nil {
		C.irgx_engine_close(n.ptr)
		n.ptr = nil
		goruntime.SetFinalizer(n, nil)
	}
	return nil
}

// Do runs fn while holding the engine lock, handing it the underlying
// irgx_engine pointer. Product packages that speak a product ABI over this
// corpus (exact search via gist_search_cursor) use this rather than reaching
// into the unexported C handle — C pointer types cannot cross cgo packages.
func (n *Native) Do(fn func(engine unsafe.Pointer) error) error {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.ptr == nil {
		return errors.New("irregex: engine is closed")
	}
	return fn(unsafe.Pointer(n.ptr))
}

func goBytes(p unsafe.Pointer, n C.size_t) string {
	if p == nil || n == 0 {
		return ""
	}
	return C.GoStringN((*C.char)(p), C.int(n))
}

// libraryDigest is the linked library's row-schema digest, "" when this library
// has no analytic plane, or a *DriftError when it has one this decoder was not
// generated from.
func libraryDigest() (string, error) {
	if C.irgx_schema_digest() == nil {
		return "", nil
	}
	return verifyDigest(C.GoString(C.irgx_schema_digest()), namedDrift)
}

// namedDrift walks the library's own schema table against this binding's to name
// the first divergence — a digest alone detects drift; irgx_schema_get says
// WHICH schema moved, which is the difference between a bug report and a mystery.
func namedDrift() string {
	if n := int(C.irgx_schema_count()); n != analytic.SchemaCount() {
		return fmt.Sprintf("library declares %d schemas, this decoder %d", n, analytic.SchemaCount())
	}
	for id := uint32(1); int(id) <= analytic.SchemaCount(); id++ {
		var cs C.irgx_schema
		cs.struct_size = C.uint32_t(unsafe.Sizeof(cs))
		if C.irgx_schema_get(C.uint32_t(id), &cs) != C.IRGX_OK {
			return fmt.Sprintf("library cannot describe schema %d", id)
		}
		mine, _ := analytic.Schema(id)
		if name := C.GoString(cs.name); name != mine.Name {
			return fmt.Sprintf("schema %d is %q in the library, %q here", id, name, mine.Name)
		}
		if int(cs.nfields) != len(mine.Fields) {
			return fmt.Sprintf("schema %q has %d fields in the library, %d here", mine.Name, int(cs.nfields), len(mine.Fields))
		}
		for i, f := range unsafe.Slice(cs.fields, int(cs.nfields)) {
			if got := C.GoString(f.name); got != mine.Fields[i].Name || uint32(f.tag) != mine.Fields[i].Tag {
				return fmt.Sprintf("schema %q field %d is %s:%s in the library, %s:%s here",
					mine.Name, i, got, analytic.Tag(f.tag), mine.Fields[i].Name, analytic.Tag(mine.Fields[i].Tag))
			}
		}
	}
	return "field-level tables agree; the digest covers more than names and tags"
}

// watchCancel allocates a cancellation token and a goroutine that trips it when
// ctx ends. release tears the watcher down before the token frees, so no
// goroutine can touch freed memory.
func watchCancel(ctx context.Context) (*C.irgx_cancel, func(), error) {
	var tok *C.irgx_cancel
	if C.irgx_cancel_new(&tok) != C.IRGX_OK {
		return nil, nil, errors.New("irregex: could not allocate a cancel token")
	}
	stop, watched := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(watched)
		select {
		case <-ctx.Done():
			C.irgx_cancel_request(tok)
		case <-stop:
		}
	}()
	return tok, func() {
		close(stop)
		<-watched
		C.irgx_cancel_free(tok)
	}, nil
}

// statusError maps a fault status onto a typed error, enriched with this thread's
// last fault detail when the library can name the incident.
func statusError(st C.int32_t, what string) error {
	if analytic.Status(st).Declined() {
		return fmt.Errorf("%s: %w (use the gist binary with -P/--engine auto for lookaround)", what, ErrUnsupportedPattern)
	}
	msg := C.GoString(C.irgx_status_message(st))
	if detail := lastFault(); detail != "" {
		return fmt.Errorf("%s: %s (%s)", what, msg, detail)
	}
	return fmt.Errorf("%s: %s", what, msg)
}

func lastFault() string {
	var f C.irgx_fault
	f.struct_size = C.uint32_t(unsafe.Sizeof(f))
	if C.irgx_last_fault(&f) != C.IRGX_MATCH {
		return ""
	}
	out := C.GoString(f.name)
	if f.path != nil {
		out += " at " + goBytes(unsafe.Pointer(f.path), f.path_len)
		// Only a file offset belongs after a path. The engine names the space
		// rather than leaving it to be inferred from `path`, so a pattern offset
		// can no longer be rendered as a position inside a filename.
		if f.at_space == C.IRGX_AT_FILE {
			out += fmt.Sprintf("+%d", uint64(f.at))
		}
	}
	return out
}
