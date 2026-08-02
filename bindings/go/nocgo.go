//go:build !cgo

package irgx

// The engine is a native library, and there is no pure-Go implementation behind
// this package to fall back to, so CGO_ENABLED=0 cannot produce a working
// build. Saying that here, at compile time, beats shipping a package whose
// every call panics.
//
// If you need a pure-Go regex, the standard library's regexp is one.
const _ = irregex_requires_cgo_build_with_CGO_ENABLED_1
