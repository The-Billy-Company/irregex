# vendor

Prebuilt static archives of the engine, one directory per Rust target triple.
`build.rs` picks the one matching `TARGET` and links it. This is why the crate
installs with no Zig toolchain on the machine.

| Target | Built against |
|---|---|
| `aarch64-apple-darwin` | macOS 11.0 |
| `x86_64-apple-darwin` | macOS 11.0 |
| `x86_64-unknown-linux-gnu` | glibc 2.17 |
| `aarch64-unknown-linux-gnu` | glibc 2.17 |

Each archive is 1.3 to 1.8 MiB, stripped of debug info, and self-contained: the
PCRE2 C floor is merged in, so linking needs nothing but a C runtime. The glibc
floor is 2.17 so the Linux archives work on anything from CentOS 7 forward.

Regenerate with `python3 ../scripts/vendor_libraries.py`, which cross-compiles
all four from one machine and link-tests each before writing it.

A target that is not here still builds, two ways: point `IRREGEX_LIB_DIR` at your
own library, or have `zig` on PATH beside an engine checkout. A target with
neither fails at build time with a message naming the target and both fixes.
