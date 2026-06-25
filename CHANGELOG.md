# Changelog

All notable changes to the `gist` kernel are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions track `build.zig.zon`.

## [0.1.0] — unreleased

### Added

- Initial scaffold mirroring `pkg/kernels/core` conventions: `build.zig`
  (static + dynamic libs, header install, `test` + `coverage` steps),
  `build.zig.zon`, flat C-ABI in `include/gist.h`, `src/root.zig`.
- **T0 trigram candidate index** (`src/trigram.zig`): allocation-light,
  container-API-free positional-trigram inverted index over a fixed document
  set. `Index.build` + `Index.queryLiteral` (sound superset of literal matches
  via posting-list AND), queried by hand-rolled binary search. Filter semantics
  (false positives expected, zero false negatives for literals ≥ 3 bytes) and
  the `NeedleTooShort` fallback contract are covered by unit tests.
- `gist_trigram_count` C export — the deterministic cross-language parity oracle.
- **T1 rarest-first query** (`src/trigram.zig`): `queryLiteral` now resolves
  every trigram's posting range up front, seeds the candidate set from the
  *rarest* trigram, and intersects outward (AND is commutative, so results are
  identical — the work is just bounded by the rarest gram instead of the
  lexicographically-first one). Collapsed the `context.Context` tail from ~530µs
  to ~9µs at libs scale.
- **T1 persistence** (`src/trigram.zig`): `serializedSize` / `writeInto` /
  `fromBytes` — IO-free native-endian local-cache serialization (the harness
  does the file IO; the kernel stays filesystem-agnostic). A session builds the
  index once (~6.4s) and warm-starts from disk in ~28ms (227× faster). Round-trip +
  malformed-blob-rejection tests added.
- **T2 regex tier** (`src/regex.zig`): a linear-time **Thompson NFA** over bytes
  (RE2/ripgrep philosophy — no backtracking, no catastrophic blowup) with a
  recursive-descent parser for literals, `.`, `[...]`/`[^...]` ranges, `* + ?`,
  `|`, `()`, and `\d \w \s \D \W \S \t \n \r` + metachar escapes. Includes sound
  required-literal extraction (a conservative slice of Cox's regexp→trigram
  analysis) so a regex reuses the T0 prefilter, falling back to a full scan only
  when no literal is mandatory. Unit-tested incl. the `(a+)+` pathological case.
- **Equality oracle** (`bench/equality.sh`, `bench/bench.zig` `verify` mode):
  gist emits its verified matching-file set per pattern + the exact indexed file
  list; the script runs `rg` (and `rg (?-u)` for regex) over that identical list
  and diffs. Proven over 16,509 files / 125 MiB: 945 adversarial+random literals
  (3 seeds) + 88 regexes → **zero false negatives, zero false positives**.
- **Bench harness** (`bench/bench.zig`): real-corpus build/footprint, on-disk
  persistence timing, and full-pipeline (filter+verify) latency p50/p95/p99 for
  an adversarial slate. gist beats ripgrep on every query over the identical
  corpus (5.7× worst case → ~140,000× for a rare miss).

### Changed — "beat ripgrep, period" perf pass

- **Parallel build + counting sort** (`src/trigram.zig`): `Index.build` now fans
  trigram extraction across all cores (byte-balanced contiguous doc shards, each
  thread filling a private region — no contention) and replaces the O(n log n)
  comparison sort over ~22.8M postings with an O(n) **counting sort** on the
  24-bit trigram key. The count is stable and the concatenated postings are
  doc-major, so each bucket lands doc-ascending — **byte-identical** to the old
  index. Small corpora keep the single-threaded comparison sort (the 64 MiB
  histogram isn't worth it below 4 MiB). **6.5 s → 1.0 s (6.4×), 124 MiB/s**;
  re-proven sound by the equality oracle on the new path. Degrades gracefully to
  the serial path on any spawn/alloc failure.
- **Data-parallel verify** (`bench/bench.zig`): candidate verification and the
  <3-byte full-scan fallback fan out across 16 threads with **byte-balanced**
  sharding (equal bytes per thread, not equal file count — a few large files
  can't stall one worker while the rest idle). `func(` 14.9 ms → 3.1 ms, `func`
  12.0 ms → 3.7 ms, `})` full scan 59 ms → 7.2 ms.
- **Race-free oracle** (`bench/equality.sh`, `verify` mode): the corpus is
  regenerated live by coworker agents, so reading a file once for gist's index
  and again for rg could see two versions (it did — a transient `\w+Request`
  "mismatch" on a file regenerated mid-run). `verify` now dumps a **byte-exact
  snapshot** of the indexed bytes and points rg at the snapshot, so any diff is a
  real semantic disagreement. Re-proven: **660 literals + 176 regexes across 4
  seeds, 0 FN / 0 FP**.
- **Head-to-head harness** (`bench/headtohead.sh`): gist warm p50 vs `rg`'s
  *fastest* mode (native parallel walk, warmed, hyperfine median-of-8) per query.
  gist wins **every** query **47.6×–58,000×** (worst case the 2-byte `})`
  full-scan fallback at 47.6×).
- **Cold / first-query win** (`bench/cli.zig`, `bench/coldquery.sh`): a one-shot
  CLI — `cli -- index` builds + persists the index (postings + a doc→path
  table) once; `cli -- query <needle>` is a **fresh process** that cold-loads the
  index (~30 ms) and reads & verifies **only the candidate files**. rg has no
  index, so every invocation re-walks the tree and reads every byte. Measured
  fresh-process via hyperfine (spawn included, warm cache): `queryLiteral`
  39ms→290ms (**7.4×**, 7 files read), `pgxpool` 47ms→274ms (**5.9×**, 399),
  `rate_limit` 46ms→293ms (**6.4×**), `func` 140ms→252ms (**1.8×**), `import`
  212ms→376ms (**1.8×**). rg now wins only the one-time build (~1.3 s) and a bare
  <3-byte needle (full read ⇒ tie). gist wins **every query after the first
  build — warm and cold.**
- **Parallel cold read** (`bench/cli.zig`): the cold path is IO-bound (read every
  candidate's bytes), and it was the one place a heavy cold query could lose —
  rg reads multi-threaded, gist read single-threaded. Fanned the candidate
  read+verify across one `std.Thread` per core, each shard doing **blocking
  `std.posix` reads** into a reused `per_file_cap` scratch buffer (no per-file
  alloc; same cap as the indexer ⇒ byte-identical corpus). Cold head-to-head now:
  `import` 212→**155 ms** (1.9×), `func` 140→**109 ms** (2.4×), `context.Context`
  **58 ms** (4.9×), selective queries 40–44 ms (6.6–7.5×). gist wins **every**
  cold query 1.9×–7.5×. Posix read path proven faithful: `queryLiteral` (7) and
  `pgxpool` (401) match the index-based counts exactly.
  - **Negative result (recorded, not hidden):** the first cut fanned this out via
    `std.Io.Group.concurrent`. Measured on the macOS io backend it was **~6×
    slower** (`pgxpool` 43→252 ms, `import` 212→1305 ms) — fiber/scheduling
    overhead dwarfed the reads and the concurrent file IO didn't parallelize.
    Raw `std.Thread` + blocking syscalls (what `search.zig` already uses) is the
    proven-fast path; the io event loop is bypassed for the worker reads.
- **SIMD substring scan** (`bench/simd.zig`): reading `std/mem.zig::findPos`
  shows `std.mem.indexOf` is SIMD only for a 1-byte needle — lengths **2–4** fall
  to `findPosLinear` (a naive byte loop) and 5+ to scalar Boyer-Moore-Horspool.
  Code search is dominated by 2–4 byte needles (`})`, `ctx`, `func`, `=>`, `::`,
  `fn`), so that naive path was the hot loss. `simd.contains` runs the memchr
  "generic SIMD": splat the needle's first + last byte, vector-compare both lanes
  across a V-wide window, AND the masks, and `eql`-verify only survivors.
  **Isolated single-thread full-corpus scan (125 MiB), std → SIMD MiB/s:** `})`
  2233→41051 (**18.4×**), `ctx` 2093→37735 (**18.0×**), `func` 2274→40713
  (**17.9×**), `=>` 1866→32019 (**17.2×**), `import` 6085→40757 (**6.7×**),
  `context.Context` 3560→19525 (**5.5×**) — std's ~2.2 GB/s naive path vs SIMD's
  ~40 GB/s. Wired into the parallel verify (`search.zig`) and the cold CLI
  (`cli.zig`). Byte-exact with `std.mem.indexOf`, proven by a 5000-case
  differential fuzz (`zig build test`, now wired) **and** the rg equality oracle
  (135 literals + 44 regexes, 0 FN / 0 FP, re-proven on the SIMD verify path).
- **Shape refactor**: extracted corpus loading into `bench/corpus.zig` and the
  parallel verify into `bench/search.zig`; the cold CLI lives in `bench/cli.zig`.
  Every file stays under the 500-line cap.
