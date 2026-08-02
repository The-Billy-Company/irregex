The Linux shared object was 79% debug info - 9.24 MB of DWARF sitting on
1.51 MB of `.text` - and the only lever against it was `-Dstrip`, which answers
the size question by destroying the answer to every other one. There is a rung
between the poles, it is now a named option, and on a released ELF target it is
already on. `-Ddebug-compress` puts each `.debug_*` section behind a
`SHF_COMPRESSED` header the debugger inflates on demand: 11.72 MB becomes
4.83 MB with every DWARF byte still readable.

The default is `zlib` and `zstd` is the ask, which inverts how the two codecs
rank on the merits. `ELFCOMPRESS_ZSTD` has been in the generic ABI since 2022
and is better than zlib on ratio, compression speed, and decompression speed at
once, which is the finding it was standardised on - and it loses here on the
only axis a default is decided by, which is who can read it. An older reader
does not degrade on a zstd section, it refuses it, and the floor is gdb 13.2,
binutils 2.40, elfutils 0.189, LLVM 16. So the default takes the 59% of the win
nobody can be broken by and `-Ddebug-compress=zstd` takes the rest, at 4.57 MB.

It is honest about where it does not reach: ELF only, link-time only, and
release only. Link-time only means `libirgx.a` is the same bytes either way,
because an archive is never linked. Release only is not a policy - LLD's
compressor walks the output sections through a `parallelForEach`, and on the
29 MB of DWARF `-ODebug` emits for this library it faults in a worker thread,
`SIGSEGV`, no diagnostic, nothing written. ReleaseSafe (4.90 MB), ReleaseFast
(4.83 MB), and ReleaseSmall (1.37 MB) all compress cleanly, so the default
stands itself down at `-ODebug` and an explicit flag there is refused with the
reason rather than left to crash the linker.

`-Dstrip` gains the thing it always needed. A stripped artifact has no DWARF and
therefore no identity - two builds of different commits are the same anonymous
bytes, and a crash in a `pip install`ed wheel cannot be traced to what produced
it. It now carries a `sha1` build ID note, the 20-byte shape `debuginfod`, the
distro debug-file splitters, and the symbolizers were all built around, for
36 bytes of section. `-Dbuild-id=` overrides in either direction.

Both are refusals rather than degradations when they cannot work, joining the
one `-Dlto` already had, because a link-time flag that does nothing still exits
zero: an operator who asked for a 4.57 MB library and silently got an 11.72 MB
one has no way to find out. `-Ddebug-compress` off ELF says so, `-Ddebug-compress`
next to `-Dstrip=true` says the two contradict, `-Ddebug-compress` at `-ODebug`
names the crash it would otherwise hand you, and either flag now also asks for
LLD explicitly - Zig's own ELF linker takes the compression flag and emits
uncompressed sections without comment.

One thing that was never a flag stops pretending to be. The vendored C floor was
built with a raw `-fno-sanitize=undefined` cflag countermanding the UBSan Zig
had just turned on for it; the same decision is now `.sanitize_c = .off` on the
two C modules, stated where Zig owns it. PCRE2's pointer and shift idioms and
libsais's negative sentinel indices are deliberate and well-defined in practice,
and both must fail as a clean Zig error rather than a sanitizer abort inside C.
