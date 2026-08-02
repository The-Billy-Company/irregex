//go:build cgo && irgx_syslib

package irgx

// The escape hatch, for a platform not vendored here or a library you built
// yourself. Build with -tags irgx_syslib and point the toolchain at your
// library:
//
//	IRGX_LIB_DIR=/path/to/zig-out \
//	CGO_CFLAGS="-I$IRGX_LIB_DIR/include" \
//	CGO_LDFLAGS="-L$IRGX_LIB_DIR/lib" \
//	go build -tags irgx_syslib ./...
//
// cgo expands nothing but ${SRCDIR} in a #cgo line, so an environment variable
// cannot be read from here; CGO_CFLAGS and CGO_LDFLAGS are the toolchain's own
// way in, and they are appended to what this file declares.
//
// The library you supply is checked against this binding's ABI version at
// package init, so a mismatched one fails at the first Compile with a sentence
// naming both numbers rather than corrupting a search.

// #cgo LDFLAGS: -lirgx
import "C"
