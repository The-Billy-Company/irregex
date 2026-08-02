//go:build cgo && !irgx_syslib

package irgx

// The vendored archive for this platform. One of these files exists per
// supported platform, each carrying the same directive against a different
// path, because cgo resolves LDFLAGS at build time and has no way to compute a
// directory - the build constraint on the file is the selection mechanism.
//
// ${SRCDIR} is cgo's own expansion, and it is what makes the archive findable
// from a module cache directory whose path nobody can predict.
//
// The archives sit beside the source rather than in a subdirectory because
// `go mod vendor` copies a package's own files and nothing else; an archive one
// directory down would be silently dropped and the vendored build would fail at
// the linker.

// #cgo LDFLAGS: ${SRCDIR}/libirgx_darwin_arm64.a
import "C"
