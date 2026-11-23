//go:build cgo && !irgx_syslib

// Copyright (c) 2026 The Billy Company

package irgx

// #cgo LDFLAGS: ${SRCDIR}/libirgx_darwin_amd64.a
import "C"
