# scripts

Two maintainer tools. Neither runs during a build or a test; both produce
committed artifacts, so a user of the crate never needs them.

## `vendor_libraries.py`

Cross-compiles `libirgx.a` for every target the crate vendors and writes them
to `vendor/<rust-target-triple>/`. Zig cross-compiles, so one machine produces
the whole set.

```bash
python3 scripts/vendor_libraries.py                          # all targets
python3 scripts/vendor_libraries.py --only x86_64-apple-darwin
python3 scripts/vendor_libraries.py --list
```

Needs `zig` on PATH and an engine checkout above this directory. For each target
it builds with an explicit minimum platform version, strips debug info with
`llvm-strip --strip-debug`, verifies the PCRE2 C floor is actually present in the
archive rather than folding it in itself, and then link-tests the result with a
small C program that compiles a pattern and runs a search. A target that fails
either check is not written, because an archive that only fails at the
consumer's link step is worse than a missing one.

It also checks, before compiling anything, that every system library a target
declares is one `build.rs` actually emits. The link-test proves an archive
closes under some set of libraries, and a consumer's link is emitted by
`build.rs` rather than by this script - if the two sets disagree, the proof is
about a build nobody performs. Only Windows has an entry, `-lntdll`.

The pinned minimum platform versions are what make the archives portable:
macOS 11.0, glibc 2.17 on Linux so the archives work on anything from CentOS 7
forward, and Windows 10 RS4.

**MSVC is absent by construction, not by oversight.** Zig cannot cross-compile
to `*-pc-windows-msvc`: the MSVC C runtime headers are not redistributable, so
there is nothing to compile the PCRE2 floor against without Visual Studio on the
machine. An archive that could only be produced on one operating system is not
one this script can promise, so `build.rs` carries the MSVC triples for its
source rung instead - which is where a machine that can build them already is.

## `python_oracle.py`

Drives the reference Python binding over a corpus of pattern / flag / text
triples and writes what it reports to `testdata/python_oracle.json`, which
`tests/oracle.rs` asserts against.

```bash
IRGX_LIB=/path/to/libirgx.dylib python3 scripts/python_oracle.py
```

`IRGX_LIB` is only needed when the Python package was installed without its
bundled shared library, which is the case in a source checkout. Add a case by
appending to `CASES` and re-running; the JSON is committed so the Rust test suite
needs no Python.

Everything is recorded in bytes. The Python binding reports codepoint indices for
a `str` pattern and byte offsets for a `bytes` one, and the generator asks in
bytes because that is the coordinate system Rust `str` uses.
