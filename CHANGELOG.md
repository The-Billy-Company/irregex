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
- **Line anchors `^` / `$`** (`src/regex_syntax.zig`, `src/regex.zig`): zero-width
  assertions resolved during the Pike epsilon-closure from per-position
  (start, end)-of-line flags — `^`/`$` add no NFA bytes, so an anchored pattern's
  required literal is unchanged (`^func` ⇒ prefilter "func"). `\^`/`\$` stay
  literal. Fixed `docMatch` to grep's line model (a trailing `\n` *terminates*
  the last line rather than seeding a phantom empty one — otherwise `^$`/`$`
  over-match every newline-terminated file vs rg). Proven byte-identical to
  `rg (?-u)`: the oracle's 52-regex battery now includes 8 anchored shapes +
  `^{0}`/`{0}$`/`^\s*{0}` templates (0 FN / 0 FP), and the cold CLI path matches
  rg on `^$` (15,572 files with a real blank line), `^func\s`, `\)$`, `;$`, `^}$`.
- **Counted repetition `{n}` / `{n,}` / `{n,m}`** (`src/regex_syntax.zig`): parsed
  and desugared into the existing node vocabulary (`min` mandatory copies, then
  `(max-min)` optional copies or a trailing `*` when unbounded) — the `atom`
  pointer is shared across copies (the AST becomes a read-only DAG), so the NFA
  compiler and literal extractor are untouched and `ab{3}c` still prefilters on
  `abbbc`. Expansion is capped at 1000 to bound NFA size. **Mirrors rust-regex
  brace semantics exactly**: an unescaped `{` must begin a valid count or it's a
  `BadPattern` (ripgrep errors identically — `interface{}` is rejected, the
  literal is `\{`), while a stray `}` stays literal. Proven byte-identical to
  `rg (?-u)`: the oracle battery adds `[0-9]{4}`, `\w{3,8}`, `x{2,4}`,
  `0x[0-9a-fA-F]{2,}`, `interface\{\}` + a `{0}\w{2,4}` template (0 FN / 0 FP).
- **Multi-literal alternation prefilter** (`src/regex_syntax.zig` `requiredAny`,
  `src/trigram.zig` `Index.queryAny`): an alternation has no single mandatory
  literal, so it used to full-scan. Now a cover set is extracted — a set of ≥3 B
  literals such that *every* match contains one (`foo|bar|baz` ⇒ {foo, bar, baz})
  — and the candidate set is the UNION of each literal's trigram candidates. Sound
  by construction: the union is a superset of every match, so no true match is
  dropped; the existing verify pass still gates false positives. It's admitted
  only when **every** branch yields a ≥3 B literal (a `<3` or unfilterable branch
  ⇒ no cover ⇒ full scan, e.g. `panic|0x`), a single mandatory literal still wins
  over a union, and the set is capped at 32 branches. Wired through the cold CLI
  (`fresh.candidates` now takes a filter *set*) and the oracle. Proven
  byte-identical to `rg (?-u)`: the battery adds `return|continue|break`,
  `func|struct|enum`, `TODO|FIXME|XXX`, `import\s+\(|^package`, `context|errors`,
  `panic|0x` + the `({0}|{1})` template (0 FN / 0 FP over 17,028 files); the cold
  CLI on `panic|throttle|leaky` reads only 1,071/17,029 files (union prefilter,
  not a scan) and returns rg's exact 694-file set.
- **Regex scan accelerators** (`src/regex.zig`, split into `src/regex_test.zig`):
  the verify-time Pike search that used to re-seed the start thread at *every*
  byte — wasted closure work — now compiles three position invariants and
  dispatches `lineMatch` to the cheapest sound strategy (semantics unchanged,
  proven by the rg oracle + an overlapping-start unit battery):
  - **Anchored fast path** — `startsAnchored` (every alternation branch begins
    with `^`) seeds only at line position 0 and bails the instant the thread list
    drains, so a non-matching line for `^}$` / `^$` is ~O(1) instead of O(len).
  - **First-byte skip** — `analyzeFirst` walks the NFA for the byte set that can
    *begin* a match mid-line (traversing `^`, blocking `$`; the over-approximation
    is sound — a mid-line seed of an `^`-only branch dies on the failed assertion).
    When the thread list empties the scanner jumps to the next viable start
    instead of stepping dead bytes: SIMD `indexOfScalar` for a singleton set
    (`;$`, `0x…`), a **SIMD range scan** (`lo ≤ b ≤ hi` per `@Vector` window, OR'd
    over ≤6 contiguous ranges) for `[0-9]{4}` / `[a-f0-9]{2,}` / `\w{3,8}`, else a
    scalar byteset probe. The earlier blocking-`^` version dropped 408 `^package`
    matches in `import\s+\(|^package` — caught by the oracle, now a regression test.
  - **Plain path** — unchanged re-seed-every-byte loop for an empty first set
    (a bare `$`), which the skip can't drive.
  Measured cold head-to-head vs `rg (?-u) -l` at its fastest gitignore-respecting
  walk (`bench/regex_headtohead.sh`, hyperfine p-mean, warm cache, 17.1k files):
  gist wins **every prefilterable tier robustly** (stable run-to-run) —
  `pgxpool\.\w+` **≈3.0×**, `^func\s` **≈2.5×**, `func\s+\w+\(` **≈1.9×**,
  `func|struct|enum`/`error|panic|fatal` **≈1.5–1.65×**, `return|continue|break`
  **≈1.5×** — because the prefilter reads a fraction of the corpus while rg
  re-walks all of it. The **no-literal full-scan tail oscillates around parity**
  (≈0.8–1.1×, noise-dominated): with no prefilter for *either* tool both read the
  whole 126 MiB, so it's a straight scan race sensitive to the shared dev box's
  load. The skip turned the old clear losses (`^}$` 0.54×, `;$` 0.77×) into
  ties. The hard floor is `\w{3,8}` — dense matching where `\w` covers most bytes
  so the skip never engages and it's Pike-VM-per-byte vs rg's O(1)/byte lazy DFA;
  closing it is the identified next rung (a lazy DFA / bit-parallel NFA step).
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
- **Cold regex query** (`bench/cli.zig`): `cli -- regex <pattern>` runs the T2
  Thompson NFA on the cold path — prefiltered on the regex's required literal
  (sound, so no true match is dropped), `docMatch`-verified per candidate with a
  per-thread `Sim` over the existing parallel read fan-out (the `Regex` is shared
  immutably; only the `Sim` scratch is per-thread). The literal `query` path is
  unchanged (its benchmark contract is preserved). Proven e2e: 11 regex shapes
  (incl. `[a-z]+_[a-z]+` at 12,803 files and `//\s*TODO` at 16) **byte-identical
  to `rg (?-u) -l`** over gist's exact indexed file list, 0 FN / 0 FP. Refactored
  the shared cold-load / candidate-resolve / emit into `loadPersisted` /
  `candidateIds` / `emitMatches` so literal + regex share one path.
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
- **T4 fusion + rank** (`src/rank.zig`, `cli -- rank`): the lexical tiers return
  an unordered match *set*; an agent wants the one line that answers first — a
  symbol's **definition**, not its 200 call sites — and pays tokens for every
  line below. Ranking via **weighted Reciprocal Rank Fusion** (Cormack 2009):
  score(d) = Σ wᵢ/(k+rankᵢ) over three rank-based signals — lexical density,
  symbol/definition boost (weight 2), shallow-path — plus an optional external
  ranking (the graphify graph-centrality hook; null until wired). RRF needs no
  per-signal normalization and admits new signals for free; embeddings stay out
  (CoREB: short keyword queries collapse them). The harness extracts per-file
  features in a parallel posix read pass (matching-line count, a cross-language
  definition-line detector, the representative best line) and prints ranked,
  token-compressed `path:line [def|use] ×n  <line>`. Proven on real symbols: the
  `pub fn` definition of `queryLiteral` / `parallelVerify` / `extractSortedUnique`
  ranks **#1** above every call site, ~25–42 ms cold. rrf + signals carry 4 unit
  tests (definition beats a 25×-hotter usage; external graph drives + is
  weight-controlled). Kernel suite 28/28.
- **T3 freshness overlay** (`bench/fresh.zig`): keeps a persisted index correct
  against a working tree many agents rewrite many times a minute, without
  rebuilding and without consulting git history (the fragile part under heavy,
  overlapping, rebased commit churn). Insight: the cold query already reads &
  *verifies* every candidate against live bytes, so a stale/edited/deleted match
  is never a false **positive** — the only gap is a false **negative** (a file
  that now matches but wasn't a trigram candidate). So freshness only *widens*
  the candidate set with files touched since build; the existing verify does the
  rest. Anchor = the build's wall-clock instant (a `real` Io.Clock timestamp,
  same UTC-ns domain as file mtime); a file is fresh iff `mtime ≥ anchor`. Immune
  to commit chaos — rebases/overlaps/races never undo the fact that writing a
  file's bytes (incl. a `git checkout`/merge/pull landing a coworker's commit)
  advances its mtime — so it has no false negatives and cannot break, where
  `git diff HEAD` is *unsound* (a coworker commit already in HEAD shows no diff
  yet differs from our pre-commit index). The discovery stat-walk fans across the
  roots in parallel (private page-backed arenas, no shared-allocator contention).
  Proven end-to-end on a single probe file: a **new** file, a **modified** file
  whose new trigrams the index never saw, and a **deleted** file (stale posting
  reads-fails gracefully → no match, no crash) are each handled. Cold process
  wall **~42 ms vs ripgrep's ~555 ms (13×)**; worst-case cold-cache walk ~95 ms
  still ~6×. Backward compatible: no anchor file ⇒ freshness is skipped, behavior
  byte-identical to the pre-T3 cold path. `widen` dedup carries a unit test.
- **Shape refactor**: extracted corpus loading into `bench/corpus.zig` and the
  parallel verify into `bench/search.zig`; the cold CLI lives in `bench/cli.zig`.
  Every file stays under the 500-line cap.
