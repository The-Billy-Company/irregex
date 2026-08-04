# Maintenance Scripts

Neither script runs at install time or at test time. They produce two things
that are committed to the module: the vendored archives, and the cross-check
table the tests assert against.

## `vendor_libraries.py`

Rebuilds the static archive matrix from one machine. Go has no `build.rs`, so a
consumer cannot compile Zig at install time; what makes `go get` followed by
`go build` work on a machine with no toolchain is that the module carries one
archive per platform and lets a cgo build constraint pick the matching one. Zig
cross-compiles, so the whole set comes off a single host.

```bash
python3 scripts/vendor_libraries.py               # every target
python3 scripts/vendor_libraries.py --only linux/amd64
python3 scripts/vendor_libraries.py --list        # what the matrix covers
```

- **darwin/arm64** cross-compiles via the Zig triple `aarch64-macos.11.0` into
  `libirgx_darwin_arm64.a`.
- **darwin/amd64** cross-compiles via `x86_64-macos.11.0` into
  `libirgx_darwin_amd64.a`.
- **linux/amd64** cross-compiles via `x86_64-linux-gnu.2.17` into
  `libirgx_linux_amd64.a`.
- **linux/arm64** cross-compiles via `aarch64-linux-gnu.2.17` into
  `libirgx_linux_arm64.a`.
- **windows/amd64** cross-compiles via `x86_64-windows.win10_rs4-gnu` into
  `libirgx_windows_amd64.a`.
- **windows/arm64** cross-compiles via `aarch64-windows.win10_rs4-gnu` into
  `libirgx_windows_arm64.a`.

Archives land beside the Go source, with `irgx.h` next to them. That is not
cosmetic: `go mod vendor` copies a package's own files and skips a subdirectory
holding no Go package, so an archive kept one level down would be missing from
every vendored consumer.

The triples carry an explicit minimum platform version. Inheriting the host SDK
would produce an archive that refuses to link or load on a machine older than
the one that built it. Each target also pins a `-Dcpu` floor - `x86_64_v2` for
both amd64 targets, Zig's `baseline` for both arm64 ones - so a vendored
archive never assumes an instruction the target's oldest supported CPU lacks.

**Rerun this whenever the engine changes.** The archives are committed build
output. A source change that is not followed by a run of this script ships an
engine older than the repository it came from.

Four things happen per target beyond `zig build`:

- **The link file is held to the matrix.** A consumer's cgo link is driven by
  the `#cgo LDFLAGS` line in `link_<goos>_<goarch>.go`, not by anything in this
  script, so that line is checked against the libraries the matrix declares
  before a byte is compiled - as is `link_unsupported.go`'s build constraint,
  which has to exclude every target the matrix now serves. It matters on
  exactly one platform: Windows needs `-lntdll`, and Zig's driver adds ntdll on
  its own while the gcc cgo actually uses does not, so a probe linked here
  would close for a reason a consumer's link would not have.

- **The C floor is verified present, not folded in.** `build.zig` now packs
  `libirgx.a` from a partially-linked object on every target, so PCRE2 and
  libsais ride inside the archive it installs there. This script used to merge
  them in itself on ELF, back when the build shipped the Zig objects alone and
  a cgo link died on `pcre2_compile_8`; what is left of that era is the check,
  kept as a precondition. An archive that reaches here without the floor is a
  regression in the build, and vendoring it would push the failure out to
  somebody's `go build` a week later.
- **Debug info is stripped.** DWARF dominates an unstripped archive and nothing
  links against it, so stripping is most of the difference between a reasonable
  module and a rude one; the four vendored archives currently total about
  9 MB stripped. `llvm-strip` does the work; `--keep-debug` skips it.
- **Every archive is proved to link before it is committed.** A probe program
  that compiles a pattern, searches, reads captures and frees the handle is
  linked against the fresh archive. A missing symbol becomes a failure here
  rather than in somebody's `go build` a week later.

## `python_oracle.py`

Regenerates `testdata/python_oracle.json`, which is what `oracle_test.go`
asserts against.

```bash
python3 scripts/python_oracle.py
# or, from a source checkout where the package has no bundled library:
IRGX_LIB=/path/to/libirgx.dylib python3 scripts/python_oracle.py
```

The engine's Python binding was written against the same C ABI first, is
independently verified, and its test suite pins the exact match semantics. This
script asks it for the spans of a shared corpus of patterns, flags and texts and
records them, so the Go tests have an oracle that this package did not compute.

Everything in the table is expressed in bytes. The Python binding reports
codepoint indices for a `str` pattern and byte offsets for a `bytes` one; Go
strings are indexed by byte, so the bytes half is the like-for-like comparison,
and it is what proves the Go binding needs no offset translation.

Regenerate it when the engine's match semantics change on purpose. Do not edit
it by hand; a hand-edited oracle is not an oracle.
