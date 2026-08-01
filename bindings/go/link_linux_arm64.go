//go:build cgo && !irregex_syslib

package irregex

// #cgo LDFLAGS: ${SRCDIR}/libirregex_linux_arm64.a -lm
import "C"
