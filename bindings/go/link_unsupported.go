//go:build cgo && !irgx_syslib && !(darwin && (amd64 || arm64)) && !(linux && (amd64 || arm64))

package irgx

// No archive is vendored for this platform, so there is nothing to link and the
// build stops here rather than at a linker error about a missing symbol.
//
// Two ways forward: regenerate the vendored set with this platform added (see
// scripts/vendor_libraries.py), or build the engine yourself and link it with
// -tags irgx_syslib.
const _ = irregex_has_no_vendored_archive_for_this_platform
