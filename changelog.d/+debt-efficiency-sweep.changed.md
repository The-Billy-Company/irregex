Structural-debt and efficiency sweep across the search planes. The serial
engine's index-freshness stat-walk now overlaps the gather walk on its own
thread (mirroring the parallel engine's lazy elide loader) — ~10% faster
serial runs on a warm indexed corpus. `Emitter` gained a caller-threaded
reusable `Matcher.Sim` slot (per-worker in the pipeline, per-run in the serial
engine), replacing three allocations per file; `queryAny` branches share one
lazy `doc_count`-sized decode scratch instead of alloc/freeing per needle. The
last ASCII case-fold twins (`args.lowerDup` / `ignore.lower`) collapsed into
`paths.lowerDup`. Four >500-line files (`syntax.zig`, `regex/core.zig`,
`encoding.zig`, `grepfile.zig`) got MONOLITHIC markers + registry rows.
Byte-parity verified before/after on literals, alternations, and regex
queries; the rg line-parity, equality, and freshness gates all pass.
