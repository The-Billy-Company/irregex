//go:build cgo && !irgx_syslib

package irgx

// -lm is the only system dependency: the archive is otherwise self-contained,
// carrying its own C floors rather than expecting the host to have them.

// #cgo LDFLAGS: ${SRCDIR}/libirgx_linux_amd64.a -lm
import "C"
