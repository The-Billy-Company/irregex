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
//
// Windows is the one platform that names a library. The engine reaches the
// kernel through ntdll, which mingw-w64's default library set does not carry,
// and cgo links with the gcc on your PATH rather than with Zig's driver - which
// adds ntdll on its own and would hide the omission from every check made off
// a Windows machine. `scripts/vendor_libraries.py` links its probe under
// exactly this line and refuses to vendor an archive the two disagree about.

// #cgo LDFLAGS: ${SRCDIR}/libirgx_windows_amd64.a -lntdll
import "C"
