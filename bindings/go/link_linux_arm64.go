//go:build cgo && !irgx_syslib

// Copyright (c) 2026 The Billy Company

package irgx

// #cgo LDFLAGS: ${SRCDIR}/libirgx_linux_arm64.a -lm
import "C"
