Layer H — the executed portability matrix. `bench/portable/` cross-compiles gist
for every triple ripgrep declares in its own release workflow, plus targets it
publishes nothing for, **from one machine with no cross toolchains installed**,
and grades each by what was actually proven rather than by what links:

- `builds` — an artifact exists _and_ its own ELF/Mach-O/PE header reports the
  promised format, architecture, width, and endianness, so a build that silently
  fell back to the host fails here instead of passing;
- `runs` — that artifact executed on a machine of that architecture (native,
  Rosetta, or a foreign-arch container) and answered a real query, including a
  PCRE2 lookbehind the linear engine cannot represent — so serving it proves the
  vendored C cross-compiled too;
- `conforms` — all twelve of `bench/harness/probes.zig`'s query classes came back
  byte-identical, exit codes included, to a native oracle that is itself pinned
  byte-for-byte to a real `rg` on the same corpus, in **both** the live-scan and
  the indexed pass.

The indexed pass on a big-endian target is what caught the bug this harness was
worth building for: `@bitCast`ing a `@Vector(16, bool)` compare to a movemask
follows target endianness, so on s390x lane 0 landed in the high bit and `@ctz`
reported every match fifteen bytes from where it was. `primitives/bits.zig`'s
`laneMask` now owns that conversion behind a `comptime` endian branch — 25 call
sites across the scanner, class-run scanner, and regex prefilter — and
little-endian builds lower to exactly the bare `@bitCast` they did before.

Sweeps are hermetic against the coworker agents editing this tree: the package
and its path dependencies are frozen once, compile-checked for the host's own
triple, and every target is built from that recorded digest, so all rows describe
one identical set of bytes. A build failure whose diagnostics also break the host
is scored `tree-broken` rather than mistaken for a port gap.

`bench/certify/certify_portable_report.py` splices the layer and is fail-closed:
it refuses to publish unless every POSIX triple ripgrep declares is covered, the
Windows gap is disclosed, the oracle was pinned to a real `rg`, and at least one
_cross_ target conformed.
