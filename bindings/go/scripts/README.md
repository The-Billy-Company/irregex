# Maintenance scripts

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

| Target | Zig triple | Archive |
|---|---|---|
| darwin/arm64 | `aarch64-macos.11.0` | `libirgx_darwin_arm64.a` |
| darwin/amd64 | `x86_64-macos.11.0` | `libirgx_darwin_amd64.a` |
| linux/amd64 | `x86_64-linux-gnu.2.17` | `libirgx_linux_amd64.a` |
| linux/arm64 | `aarch64-linux-gnu.2.17` | `libirgx_linux_arm64.a` |

Archives land beside the Go source, with `irgx.h` next to them. That is not
cosmetic: `go mod vendor` copies a package's own files and skips a subdirectory
holding no Go package, so an archive kept one level down would be missing from
every vendored consumer.

The triples carry an explicit minimum platform version. Inheriting the host SDK
would produce an archive that refuses to link or load on a machine older than
the one that built it.

**Rerun this whenever the engine changes.** The archives are committed build
output. A source change that is not followed by a run of this script ships an
engine older than the repository it came from.

Three things happen per target beyond `zig build`:

- **The C floor is folded in where the build leaves it out.** On macOS the
  installed archive already carries PCRE2; on ELF it holds the Zig objects only,
  so a cgo link fails on `pcre2_compile_8` and friends. The script probes the
  archive for that symbol and merges the floor in only when it is genuinely
  absent, so the day the Zig build folds it in everywhere, this keeps working
  with nothing to edit.
- **Debug info is stripped.** DWARF is most of an unstripped archive and nothing
  links against it. Stripping takes the vendored set from about 26 MB to under
  7 MB. `llvm-strip` does the work; `--keep-debug` skips it.
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
