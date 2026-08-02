//go:build cgo && !irgx_syslib

package irgx

// #cgo LDFLAGS: ${SRCDIR}/libirgx_linux_arm64.a -lm
import "C"
