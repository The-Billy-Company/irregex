# vendor

Prebuilt static archives of the engine, one directory per Rust target triple.
`build.rs` picks the one matching `TARGET` and links it. This is why the crate
installs with no Zig toolchain on the machine.

| Target | Built against | Also serves |
|---|---|---|
| `aarch64-apple-darwin` | macOS 11.0 | |
| `x86_64-apple-darwin` | macOS 11.0 | |
| `x86_64-unknown-linux-gnu` | glibc 2.17 | |
| `aarch64-unknown-linux-gnu` | glibc 2.17 | |
| `x86_64-pc-windows-gnu` | Windows 10 RS4 | `x86_64-pc-windows-gnullvm` |
| `aarch64-pc-windows-gnullvm` | Windows 10 RS4 | |

Each archive is stripped of debug info and self-contained: the PCRE2 C floor is
merged in, so linking needs nothing but a C runtime. The glibc floor is 2.17 so
the Linux archives work on anything from CentOS 7 forward.

The two Windows rows are the GNU ABI under the names Rust gives it. `x86_64`
leads with `-gnu` (mingw-w64's gcc) and `-gnullvm` (llvm-mingw) is the same
runtime and the same COFF reached through clang, so one archive serves both and
`build.rs` maps the alias rather than committing a second copy. `aarch64` has no
`-gnu` at all, because mingw-w64's gcc was never ported to it. Both Windows
archives need `ntdll`, which `build.rs` emits.

Regenerate with `python3 ../scripts/vendor_libraries.py`, which cross-compiles
every one of them from one machine and link-tests each before writing it.

**No MSVC archive is here, and none can be.** Zig cross-compiles to everything
above from a single host, but the MSVC C runtime headers are not
redistributable, so it has nothing to compile the PCRE2 floor against unless
Visual Studio is on the machine - which would make `*-pc-windows-msvc` the one
target whose archive could not come off the same build as the rest. `build.rs`
knows the MSVC triples anyway and builds the engine from source for them, so a
Windows machine with Zig installed builds and links normally.

A target that is not here still builds, two ways: point `IRGX_LIB_DIR` at your
own library, or have `zig` on PATH beside an engine checkout. A target with
neither fails at build time with a message naming the target and both fixes.
