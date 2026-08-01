//go:build cgo && !irregex_syslib

package irregex

// #cgo LDFLAGS: ${SRCDIR}/libirregex_darwin_amd64.a
import "C"
