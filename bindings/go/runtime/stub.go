//go:build !cgo || !irregex_ffi

package runtime

import (
	"context"
	"unsafe"
)

// This build has no in-process tier: there is no library to link and no
// analytic plane to probe. That is an absence, not a failure — every verb still
// answers through the subprocess transport, byte for byte, so this file exists
// to make the ladder's first rung a no-op rather than to reimplement it.
//
// It is also the DEFAULT, which is the point. The in-process tier links a
// libirregex that only a `zig build` produces, and a module fetched by
// `go get` has no such artifact anywhere near it — keying the tier on cgo alone
// meant the ordinary CGO_ENABLED=1 build tried to link a file that could not
// exist and failed at the linker rather than answering. The tier is therefore
// opt-in: build with `-tags irregex_ffi` once zig-out/ is populated.

const hasCGO = false

// Native is the in-process engine, which this build does not have.
type Native struct{}

// OpenNative always reports [ErrNoCGO] here; callers fall through to the child.
func OpenNative(...string) (*Native, error) { return nil, ErrNoCGO }

// Close is a no-op on a handle that was never opened.
func (*Native) Close() error { return nil }

// Do always reports [ErrNoCGO] here.
func (*Native) Do(func(unsafe.Pointer) error) error { return ErrNoCGO }

func native(context.Context, Query) (*Rows, error) { return nil, nil }

func libraryDigest() (string, error) { return "", nil }
