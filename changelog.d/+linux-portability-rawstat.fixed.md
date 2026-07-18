Linux targets build again. Zig 0.16's `std.c` declares no `fstat`/`fstatat` on
Linux and `std.posix.close` is gone, which had silently rotted every
comptime-pruned Linux leg (`--one-file-system` device ids, `--sort created`
birth times, stdin classification, the mmap fast path's sizing stat, the
session reconciler's lstat, and the inotify watcher's fd closes) — invisible
from the macOS dev boxes. Raw stat now lives behind one portable shim
(`grepfile.RawStat` + `statPath`/`lstatPath`/`statFd`): `statx(2)` on Linux,
the exact libc `fstatat`/`fstat` calls it replaced everywhere else, so macOS
behavior is byte-identical while Linux additionally gains real `statx` BTIME
birth times for `--sort created`. Watcher closes use `std.os.linux.close`
directly in their comptime-Linux branches. A `zig build check-linux` drift
gate (folded into `zig build test`) cross-compiles the full CLI module for
x86_64-linux as a no-link object — full Sema + codegen over every
Linux-reachable line in ~1 s warm — proven to fail on exactly this class of
breakage; x86_64-gnu, x86_64-musl, and aarch64-gnu full builds all verified
green.
