Windows is now **compiled on every push and executed on every PR**, which is the
difference between a port that was proven once and a port that stays proven. The
previous sweep established that all four triples build and that three of them
conform under Wine; nothing then stopped the next commit from breaking the Win32
arm, because no gate on any machine compiled it.

**`zig build check-windows` is the floor, and it is folded into `zig build test`.**
It runs Sema plus codegen with no link over the CLI for `x86_64-windows-gnu`,
`aarch64-windows-gnu`, and `x86-windows-gnu`, so a Windows-only compile error now
fails a Linux and a macOS run. `the Windows CI lane (`zig build check-windows`)` is the same step
standalone, which is the most a POSIX laptop can honestly claim about Windows.
All three triples are there because they disagree: **x86 is the only one that
caught two real bugs.** The lazy-DFA churn statistic divided a `usize` by a `u64`
counter and assigned the `u64` quotient back, which only fails to compile where
`usize` is 32 bits; and the executable-identity memo was a `std.atomic.Value(u64)`,
which 32-bit x86 has no lock-free load for. That second one is now a plain `u64`
published behind a `bool` flag with acquire/release ordering, so the full 64-bit
stamp survives on every target instead of being narrowed to fit the narrowest one.

**The runtime proof is native, on both architectures.**
`.github/workflows/gist-windows.yml` runs the sharded suite, the ReleaseFast
build, `index_elision_parity.sh`, and a CLI smoke that pins rg's exit-code
contract through a real console, on `windows-2025` and `windows-11-arm`. Dagger
runs inside a Linux container and cannot reach a Windows executor, which is the
same argument `apple.yml` already makes for macOS, so this lane is registered
against its `.github` path directly rather than mirrored from Forgejo. Both
architectures run because arm64 is weakly ordered: the acquire/release pair above
is decoration on x86's total store order and load-bearing there, and a matrix
that only ran x64 would never say so.

The gate that ports is the self-oracling one. `index_elision_parity.sh` diffs the
index-accelerated answer against gist's own `--no-index` full read, so it needs no
ripgrep on PATH and asserts a contract rather than a count; it is also the one
conformance gate the Linux leg runs, so Windows clears the same bar rather than a
taller one. It resolves `gist.exe` itself now, and honors the `${GIST}` override
the three sibling gates already had.
