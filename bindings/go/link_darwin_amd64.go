//go:build cgo && !irgx_syslib

package irgx

// #cgo LDFLAGS: ${SRCDIR}/libirgx_darwin_amd64.a
import "C"
