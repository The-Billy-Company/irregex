Generalized the warm session's data-parallelism from the invert emit to EVERY
positive warm face, so a common token no longer loses to cold purely on core
count. The invert-only `renderLinesInvertParallel` became the shared
`render.renderLinesParallel`, and its floor/shard gate was lifted into one
`math/parallel.zig::shardBounds` primitive that all faces now cross into
parallelism through: (1) `queryLines` positive emit shards the candidate doc
slice byte-balanced and renders each shard through the cold `Emitter` into its
own buffer, concatenated in doc order; (2) the `-l`/`-c` fold (`query`) splits
its candidate walk into `eachBase` (sharded, per-thread scratch + `Accumulator`
over the immutable mirror — `-c` sums, `-l` concatenates then sorts once) and
`eachOverlay` (the bounded mutation set, always serial); (3) the FFI `search`
record stream collects each shard's per-line spans into its own buffer, then
feeds the sink SERIALLY in doc order honoring early `halt`, so the stream stays
byte-identical and stops at the same record. All share the 256 KiB byte floor —
below it (or on one core) each face falls straight through to its serial core, so
tiny queries never pay thread-spawn. Every shard is read-only over the mirror
under the held session lock with its own arena, and the fail-closed per-hit
existence check is preserved per shard.

Measured on the live 20k-file / 193 MiB repo corpus (warm files-mode p50,
serial → sharded): `import` (13838 files) 10.5 → 5.9 ms, `})` (7780) 12.7 → 5.0 ms
(2.5×), `def ` (4908) 6.4 → 3.0 ms (2.1×), `func ` (3690) 5.1 → 2.5 ms (2.0×),
`context.Context` (1756) 2.8 → 1.4 ms (2.0×); small/rare needles stay on the
serial core, unchanged. Byte-parity proven `warm == --no-index == rg` (with
`--uncap` past the soft output budget) on a controlled 400-file fixture crossing
the floor (8/8 cases: `-l`/`-c`/bare/`-n`, large + rare set) and the live tree
(16/16), plus a resident-suite test over a >256 KiB tree asserting the sharded
`-l`/`-c`/emit/stream against ground truth (path-sorted `-l`, exact `-c` sum,
ascending record stream). The committed session gate is unregressed (armed
geomean 474×). The now-orphaned invert-only render helper was removed.
