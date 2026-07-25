The fused work-stealing engine is now the `swarm` package — seven modules split
by **lifetime** rather than by flag: what is decided once per run (`swarm.zig`:
eligibility, pool sizing, the oracle race, spawn/join), what every worker shares
(`queue` the work-stealing spine, `sink` the single writer), what one worker owns
(`crew`: arena, scratch, held fragments, the ordered `--sort` replay), and what
happens per directory (`descent`) and per file (`sift`). `roster` keeps the
callable file-set walk the resident session reconciles against as a peer entry
point, not a search with its output suppressed. The published surface is two
functions, `eligible` and `run`.

The read-elision oracle moved out from under the parallel engine to
`cold/quarry/elide.zig`, where both cold engines admit the same one — the first
half of the tier's single-owner-per-policy restructure, and the seam the serial
engine's `IndexSkip` folds into next. Its three private early exits ("no anchor",
"no index", "the path table would not pay for itself") are now a declared
file-private error set converted to a typed declinature at the module boundary,
so an early exit can no longer read as a fault.

Five worker helpers became `Worker` methods, and the pool spawn/join is written
once for both the search walk and the file-set walk. No behavior change: the
whole supported flag surface is byte-identical against real ripgrep on **both**
engines, and the parallel path's per-worker ordering, coalescing, and budget
contracts are unchanged.
