The unit suite went from **~17.7 minutes to ~70 seconds** on the edit loop,
without weakening a single assertion. (Wall clocks are an idle 16-core box; this
tree is shared by ~10 agents, so a busy machine stretches all of them.)

The suite was never slow — it was **serial**. Zig's stock runner walks
`builtin.test_functions` start to finish in one process, so 991 tests ran on one
core of sixteen at `user/real = 0.64`. The chassis now compiles the test binary
once and hangs _n_ independent `Run` steps off it, each owning the residues of
`BRIGADE_SHARD=i/n`; the parallelism is the build runner's own scheduler, which
already spreads independent steps across cores and gives each its own output
pipe. No thread, no fork, nothing to make thread-safe — a shard is just another
process. Per-test semantics (fresh allocator and `Io`, leak detection, skips,
error-return traces, logged-error counting) are byte-identical to the stock
runner, so sharding is invisible to test authors. The default is 2× the core
count, deliberately over-decomposed so the runner's `cores - 1` in-flight limit
behaves as a work queue: 16 shards 86 s, 32 shards 71 s, 64 shards 74 s.

Sharding cannot split one test, so the floor becomes the slowest single one.
`BRIGADE_TIMES=1` (per-test `<ms>\t<name>`) found four compile-bound
differentials — the word-boundary Unicode quit path at 320 s, its ASCII
counterpart at 160 s, and the two symbolic differentials at 101 s and 88 s —
costing 669 s of the suite's 1059 s. They carry explicit coverage floors, so
their sweeps stay exactly as they were; `build.zig` names them as `deep_tests`
and `zig build test-quick` (`zig build test-quick`) runs everything else. Full
`zig build test` is unchanged and remains what a push is judged by; the quick
tier is a deliberately weaker proof and says so. A `deep_tests` entry that stops
matching is reported by name and only ever makes the quick tier slower.

`-Dtest-filter=` / `-Dtest-skip=` narrow by name substring, so the actual answer
to "did the test I just touched break?" is now ~0.1 s rather than a coffee break.
