Windows was the one platform where "just install it" was not true. The engine
built and passed there, and had for a while - `windows.yml` runs the suite on
real x64 and arm64 kernels - but only Python could actually be installed, and
only on x64. Go rejected Windows at compile time with a named constant, Rust had
no vendored archive to find, and Windows arm64 had nothing anywhere. Three
bindings, and Windows was first class in none of them.

It is now in all three, on both architectures:

- **Go** vendors `libirgx_windows_amd64.a` and `libirgx_windows_arm64.a`
  beside the other four, selected the same way, by the build constraint on a
  `link_windows_*.go` file. `link_unsupported.go` no longer catches Windows.
- **Rust** vendors `x86_64-pc-windows-gnu` and `aarch64-pc-windows-gnullvm`.
  Those are the two names Rust gives the GNU ABI: x86_64 leads with `-gnu`
  (mingw-w64's gcc), and arm64 has no `-gnu` at all, because that toolchain was
  never ported to it. `x86_64-pc-windows-gnullvm` is the same runtime and the
  same COFF reached through clang, so `build.rs` maps it onto the `-gnu`
  directory rather than committing a second copy of three megabytes.
- **Python** adds a `win_arm64` wheel, which is the last hole in a matrix that
  otherwise covered every other platform on both architectures.

Two things had to be true for any of it. The archive has to carry its own C
floor, which `build.zig` already does on COFF by splicing the two floor archives
in with `zig ar qcsL` - COFF has no partial link, so the merged object every
other platform packs is not available there. And the link has to name `ntdll`:
the engine reaches the kernel through sixty `Nt*`/`Ldr*`/`Rtl*` symbols, which
are Zig's std rather than ours, and mingw-w64's default library set stops at
kernel32. Zig's own driver adds ntdll silently, which is exactly why every check
made from a macOS laptop closed for a reason a consumer's link would not have.

So `windows.yml` grew a second job. `native` compiles the engine here and proves
the sources still hold; `bindings` asks the other question - whether what we
ship links and runs under the toolchain a consumer has. On x64 that is
mingw-w64's gcc, linking the committed archive for both Go and
`x86_64-pc-windows-gnu`, exactly the way an install does. On arm64 Go links the
committed archive through `zig cc`, and Rust runs `aarch64-pc-windows-msvc` -
the target nearly every Windows arm64 Rust user is on, and the one rung no
archive can serve, so `build.rs` builds the engine from source against the
Visual Studio already on the runner. Between them, both rungs of that ladder now
run on a real kernel, and until now neither did.

`aarch64-pc-windows-gnullvm` is the one target nothing there links, because
llvm-mingw is not on the image and Zig cannot stand in for it: Zig's mingw is
UCRT-only, and Rust's GNU targets ask the linker for `msvcrt`. Its archive is
not therefore unexercised - it is the same engine build, for the same Zig
triple, that the Go arm64 step links and runs.

Every Windows target pins Windows 10 RS4, which is the floor `build.zig`'s own
`check-windows` drift gate compiles against, so the shipped artifact and the
gate guarding it describe one platform. A wheel tag cannot carry a version the
way `manylinux_2_17` can, so on Python that promise exists in the Zig triple and
nowhere else.

The one Windows ABI still missing a prebuilt is MSVC, and it is missing by
construction rather than by oversight. Zig cross-compiles every target above
from a single host; it cannot cross-compile to `*-pc-windows-msvc`, because the
MSVC C runtime headers are not redistributable and there is nothing to compile
PCRE2 against without Visual Studio on the machine. `build.rs` carries the MSVC
triples for its source rung instead, so a Windows box with Zig installed builds
and links normally, and one without gets a message that says which target it
was, why no archive exists for it, and that `-pc-windows-gnu` is vendored.
