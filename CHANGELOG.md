# Changelog

All notable changes to the `gist` kernel are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions track `build.zig.zon`.

## [0.1.0] — unreleased

### Fixed

- **README benchmark prose + `regex/adversarial_test.zig`** — escaped the bare
  `_loaders_` / trailing-underscore emphasis in the cold-loader notes (markdown
  lint), and switched the rg second-oracle differential's temp-path `bufPrint`
  from `catch unreachable` to `try` so a formatting error propagates instead of
  panicking (zig-safety ratchet). No behavior change to the search path.

### Changed

- **Benchmark certify harness (`bench/certify.sh`) reformatted** to the repo
  shell style (2-space indent, one statement per line) and the macroscopic
  probe loop straightened so each class benches `gist` plus every competitor in
  a single pass. No change to the emitted `CERTIFICATE.md`, the macro CSV, or
  the bootstrap-CI / Mann-Whitney stats path.

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
  ties.   The hard floor is `\w{3,8}` — dense matching where `\w` covers most bytes
  so the skip never engages and it's Pike-VM-per-byte vs rg's O(1)/byte lazy DFA;
  closing it is the identified next rung (a lazy DFA / bit-parallel NFA step).
- **Byte-class DFA — the sole non-Pike engine** (`src/regex_dfa.zig`, tests in
  `src/regex_dfa_test.zig`; supersedes and removes the interim bit-parallel
  Glushkov engine). The Pike VM is O(active-threads)/byte, so on the no-prefilter
  scan tail — a *selective but common* first byte (`;$`, `[0-9]{4}`, `panic|0x`)
  re-seeds a closure at nearly every byte — it lost to rg's O(1)/byte lazy DFA.
  This determinizes the Thompson NFA (Cox → RE2 / rust-`regex` lineage, an eager
  capped variant) into an immutable, scratch-free automaton that spends **one
  table lookup per byte regardless of match density**:
  - **Byte classes** collapse the 256-byte alphabet to the handful of columns any
    consuming state actually distinguishes (RE2/rust-`regex` `ByteClasses`),
    shrinking the transition table.
  - **Line anchors without a `.*` hack** — `^` is resolved once in the start
    state's closure (`at_start=true`); `$` by a separate **final** transition
    table closed with `at_end=true` (the single-line analogue of RE2's one-byte
    match delay). Unanchored search re-seeds the NFA start into every transition;
    an `^`-anchored program never re-seeds and dead-states to `false` the instant
    its thread set drains.
  - **Eager + capped** — built at compile (these patterns are tiny); past
    `max_states=4096` the build bails to null and the Pike VM keeps serving (so
    `{1000}`-style expansion stays linear, only a pathological alternation trips
    the cap). One immutable `Dfa` is shared lock-free across all reader threads.
  - **Single-pass `docMatch`** — scans the whole file buffer in **one fused loop**
    that detects `\n` inline, so each byte is touched exactly once. (The per-line
    path memchr-scans for `\n` *and then* re-scans the bytes in the automaton —
    double byte-traffic, the dominant cost of a no-prefilter full scan.)
- **Latent Pike `.skip` soundness fix** (`src/regex.zig` `eol_empty`). The DFA
  doc-fuzz surfaced it: a nullable prefix flowing into `$` (`\d*$`, `a*`, `x|$`)
  matches the zero-width end of **every** line, but skip mode only seeds
  first-byte positions and never evaluated the end-of-line empty match — a real
  false-negative the DFA exposed. `compile` now precomputes whether the start
  epsilon-reaches `match` at `(at_start=false, at_end=true)` and short-circuits to
  true (also a fast path for the DFA: no full-line scan for a match-everything
  pattern). `^`-anchored programs correctly stay false.
  - **Verification — two oracles, both fail-closed.** The rg `(?-u)` equality
    battery (135 literals + 64 regexes over 17.1k files / 126 MiB → **0 FN / 0
    FP**) *and* two **differential fuzzes vs the proven Pike VM**, hermetic (no rg
    needed): a line-level fuzz (6,000 random patterns — *anchors included* — × 10
    inputs) and a **doc-level fuzz** (6,000 patterns × 8 multi-line buffers with
    empty lines + trailing newlines) proving the single-pass scan byte-identical
    to the per-line path. **Zero divergences** in `zig build test`. The fuzzes
    earned their keep — they caught the Pike `.skip` bug above and a last-byte
    `trans_fin` edge in the single-pass scanner during development.
  - **Measured** (`bench/regex_headtohead.sh` + direct warm-cache query timing,
    17.1k files / 126 MiB, min-of-runs to filter shared-box load): the
    no-prefilter scan tail dropped **7–21%** of query time and now sits **at rg's
    own scan floor** (~248–264 ms vs rg ~250–280 ms) — the residual gap is purely
    gist's ~27 ms cold-load that rg never pays. The former clear losers flipped to
    ties: `[a-z]+_[a-z]+_[a-z]+` 326→258 ms query (355→285 ms total vs rg 278),
    `panic|0x` 313→248 ms. Prefilterable tiers still win outright (`pgxpool\.\w+`
    ~3×, `^func\s` ~2.5×, alternations 1.4–1.65×) because the trigram prefilter
    reads a fraction of the corpus while rg re-walks all of it.
- **No-prefilter regex → direct live-tree scan** (`bench/scan.zig`, dispatched
  from `bench/cli.zig` `runRegex`). A regex with no usable trigram prefilter — no
  ≥3 B required literal and no all-≥3 alternation cover (`[0-9]{4}`, `panic|0x`,
  `[a-f0-9]{2,}`, `\w{3,8}`, `[a-z]+_[a-z]+_[a-z]+`) — makes the index filter
  *nothing*: every doc is a candidate. The cold index path then paid **two** full
  tree traversals — a corpus-wide T3 freshness `statFile` walk **and** a candidate
  read of all ~17 k files — where rg pays one (walk + read). The tier is IO-bound
  (profiled: System time dwarfs the automaton's User time — the scan engine was
  never the bottleneck, the redundant traversal was), and the freshness stat-walk
  is the dominant tax: measured **255 ms → 187 ms** (~67 ms) by toggling the
  anchor on a `panic|0x` full scan. So for that case gist now **skips the index
  entirely** and walks the LIVE tree once, reading + DFA-scanning each file like
  rg. This is strictly **more** correct than the index+freshness path — it reads
  current bytes, sees files created since the build, honors deletions, with no
  staleness window — so no freshness walk is needed at all. Same skip-dirs /
  NUL-binary / 4 MiB cap as the indexed corpus.
  - **Fused work-stealing pipeline (a tie was never the floor).** The first cut
    was phased — a parallel walk to collect every path, *then* a sharded read+scan
    — and profiling (process-internal clock, build-wrapper-independent) caught it
    leaking two ways: a **~63 ms walk barrier** overlapping nothing, and **~169 ms
    of straggler idle** (static file-count sharding stranded the big files on one
    core — fastest core done in 158 ms, slowest 327 ms). Rewritten so walkers
    stream discovered paths into a shared MPMC queue while a core-sized pool steals
    files in batches and reads+scans *as the walk still runs*: **worker-span
    Δ 169 ms → 2.5 ms** (near-perfect byte-balance) and the walk folded under the
    scan — **~1.7× internal speedup**. Oversubscription was *measured, not
    assumed*: warm-cache the tier is CPU/syscall-bound (~190 µs/file
    open+read+close, the DFA pass a rounding error), so ×1 worker/logical-core beat
    ×2/×3 on both wall-clock and balance.
  - **Correctness:** byte-identical to `rg (?-u) -l` over the same logical corpus
    (rg run with `--no-ignore --hidden` + gist's dir-excludes so both scan the
    same file set): **0 FN / 0 FP** across `[0-9]{4}`, `panic|0x`, `[a-f0-9]{2,}`,
    `[0-9a-f]{8}-…`, `[a-z]+_[a-z]+_[a-z]+`, `\w{3,8}`, `x{2,4}` — the only
    residual diffs being 3 multi-MB data blobs (`train_text.txt` 2.2 GB,
    `val_text.txt` 22 MB) whose first match sits past the **pre-existing 4 MiB
    `per_file_cap`** the indexed corpus caps identically.
  - **Measured** (ReleaseFast, release-vs-release vs `rg (?-u) -l` on its fastest
    gitignore-respecting path, min-of-N back-to-back, shared dev box; gist scans a
    gitignore-*superset*, so it wins while reading **more** bytes): `\w{3,8}`
    **1.3–3.0×** · `[a-f0-9]{2,}` **1.3–1.4×** · `[a-z]+_[a-z]+_[a-z]+` **1.2×** ·
    `[0-9]{4}` **1.1×** · `panic|0x` **win-or-tie (~1.0×)** — **0 FN / 0 FP** vs rg
    throughout (one `[0-9]{4}` `rg_only` file: a >4 MiB blob past the shared
    `per_file_cap`). gist wins or ties all five. (The earlier Debug-build numbers
    understated gist — release-vs-release is the honest race.)
  - **Permanent regression** (`bench/scan_regress.sh`): the scan path is a
    different code path than the index path `bench/equality.sh` proves, so it gets
    its own permanent oracle — asserts each pattern still **routes** to the scan
    path, diffs gist's scan set vs `rg (?-u)` over the identical corpus and **exits
    1 on any FN/FP** (cap-skips excepted by size), and prints the worker-span Δ as a
    **straggler canary** so a future regression of the work-stealing balance fails
    loudly. Keeps the win honest and the floor measured for the next exploration.
  - **Why the verdict is structural (off the data, not vibes):** gist's time is
    **pattern-independent** (~240 ms across all five — it sits at the per-file
    syscall floor, the DFA being a single early-exiting pass), whereas rg's swings
    **2–373 ms with match density** (floor + per-byte scan). gist therefore wins
    every scan-expensive pattern and ties only the cheapest sparse-literal
    (`panic|0x`), where rg's scan is near-free and both rest on the same read floor.
  - **Named next rung (recorded, not hidden):** beating rg on the sparse-literal
    tie means dropping *below* the read floor — batch the per-file
    `openat`+`read`+`close` (io_uring / `readv`), since at ~190 µs/file the
    syscalls, not the scanned bytes, are the wall. A prefilter can't help a tier
    already at its IO floor.
- **DFA transition-table premultiplication** (`src/regex/powerset.zig`,
  `src/regex/dfa.zig`). The dense no-prefilter scan's hot loop is one load-use
  recurrence per byte: `next = trans[state * ncls + class[byte]]`. The `state * ncls`
  multiply sat *on* the loop-carried dependency chain — every step had to compute
  the row offset before it could issue the load that produces the next state.
  `powerset` now stores every transition target, `start`, and `dead` **pre-scaled
  by `ncls`** (a row *offset*, not a state id) and lays `is_match` out offset-indexed,
  so the recurrence collapses to a bare `next = trans[state + class[byte]]` — the
  `madd` leaves the critical path entirely (the rust-`regex`/RE2 premultiplied-DFA
  representation). **Correctness:** structural invariants + exhaustive language
  equivalence (`powerset_test.zig`, updated for the offset representation) and the
  doc-level DFA↔Pike differential fuzz (12k patterns × multi-line buffers) — **0
  divergences** — plus `scan_regress.sh` end-to-end (5 no-prefilter patterns, **0
  FN / 0 FP** vs `rg` over the identical 17.5k-file tree). **Measured** (Apple
  Silicon, kperf FIXED_CYCLES/INSTRUCTIONS, min-of-N, real 137 MB corpus,
  `[0-9a-f]{8}-[0-9a-f]{4}`): **6.62 → 3.98 cyc/byte (−40 %, 1.66×)**, ins/byte
  16.89 → 14.99 (−1.9), IPC 2.55 → 3.76. The signature is unambiguously
  latency-bound — instructions fell ~11 % but cycles fell 40 % *and* IPC rose,
  because shortening the recurrence (madd→load ⇒ load) exposed the ILP the
  dependency chain had been hiding. The dense DFA now sits at the scalar-DFA hard
  floor (~one L1 load-use per byte), at/ahead of rg's premultiplied lazy DFA.
- **DFA start-state acceleration** (`src/regex/dfa.zig`, `src/regex/powerset.zig`).
  The byte-class DFA's unanchored start state self-loops on most bytes; only a few
  "relevant" bytes can begin a match (`trans_in` leaves start) or match at EOL
  (`trans_fin` is a match — the `$`-literal case like `;$`). `powerset` collects
  that set and, when ≤ 3 bytes, attaches a SIMD `Prefilter`; the scanner then
  `memchr`/range-skips the dead run to the next relevant byte instead of a table
  lookup per byte (the rust-`regex`/RE2 `accel.rs` trick). For unanchored patterns
  where `\n` is irrelevant and no empty line matches, the skip **crosses
  newlines** — collapsing `;$` to a single-byte `memchr ;` (rg's exact strategy)
  and the prefilter from a two-range scan to one. Sound because a skipped byte both
  keeps start in itself *and* can't match under `$`; the byte-at-a-time inner loop
  still stops at `\n`, so `$`/line-end resolution is unchanged. **Verified by the
  existing doc-level differential fuzz vs the Pike VM** (12k patterns × multi-line
  buffers, *anchors + `$`-literals included*) — **0 divergences**. Kernel-level:
  the no-prefilter end-to-end is read-floor-bound (the scan is ~1 % of wall, < 30 ms
  User vs ~300 ms System), so this makes the automaton optimal without moving the
  IO-bound macro number — the lever for that stays the read floor above.
- **Sub-trigram literals → the same live-tree scan** (`bench/scan.zig`
  generalized to verify a literal via `simd.contains` as well as a regex via
  `docMatch`; `bench/cli.zig` `runQuery` routes `needle.len < 3` there). A `<3 B`
  literal (`})`, `=>`) has no trigram filter, so the index path seeded every doc
  **and** ran the corpus-wide freshness `statFile` walk on top of the read — the
  same two-traversals-vs-rg's-one tax the no-prefilter *regex* path already
  escaped. Short literals now skip the index and walk the live tree once through
  the proven work-stealing pipeline. **Correctness:** the literal scan is
  byte-identical to the trusted DFA scan over the identical tree (`} )` literal vs
  `/\}\)/` regex → same 5,610-file set, 0 diff), and `scan_regress.sh` stays green
  (0 FN / 0 FP). The ≥ 3 B indexed path is untouched (`pgxpool` still reads
  409/17,513 files, ~1.7 ms cold-load).
- **Equality oracle** (`bench/equality.sh`, `bench/bench.zig` `verify` mode):
  gist emits its verified matching-file set per pattern + the exact indexed file
  list; the script runs `rg` (and `rg (?-u)` for regex) over that identical list
  and diffs. Proven over 16,509 files / 125 MiB: 945 adversarial+random literals
  (3 seeds) + 88 regexes → **zero false negatives, zero false positives**.
- **Bench harness** (`bench/bench.zig`): real-corpus build/footprint, on-disk
  persistence timing, and full-pipeline (filter+verify) latency p50/p95/p99 for
  an adversarial slate. gist beats ripgrep on every query over the identical
  corpus (5.7× worst case → ~140,000× for a rare miss).
- **Second baseline: `ag` (the_silver_searcher)** in all three race scripts
  (`bench/headtohead.sh`, `coldquery.sh`, `regex_headtohead.sh`) — a new
  `ag … column`, an `rg≷ag` direct-matchup column, and an "ag faster than rg on
  N/M" tally. `ag` runs on its honest fastest path: `--path-to-ignore .gitignore`
  hands it the root ignore set `rg` reads for free (its own walk reads ignore
  files only *inside* the search paths, so without it `ag` grinds through the
  gitignored ~99 GB — 0.46 s scoped vs minutes unscoped). Columns auto-skip if
  `ag` is not installed. Measured over 37 queries (17.1k files): `gist` wins all
  but one; `rg` beats `ag` on **36/37** (`ag` ~1.6–2.1× behind on every literal,
  warm + cold, and 15/16 regexes). `ag`'s lone win is the prefilter-less 2-byte
  mixed alternation `panic|0x` — `ag` 483 ms vs `rg` 675 ms (**1.40×**), the same
  pattern where gist's Pike VM is weakest (1173 ms).

- **Seven-tool competitive field + indexed rivals** (`bench/_compete.sh`,
  rewritten `coldquery.sh` / `regex_headtohead.sh` / `headtohead.sh`): the race
  now spans every level. Beyond the unindexed scanners (`rg`, `ag`, plus new
  `ugrep`, GNU `grep`, `git grep`) gist is benched against the two mature
  *indexed* searchers — **csearch** (Russ Cox's Google Code Search, gist's direct
  trigram ancestor) and **zoekt** (Sourcegraph's production indexed search). A
  shared `_compete.sh` registry defines the field, the per-tool fastest-honest
  invocations, and the index builds; csearch indexes gist's **exact** corpus file
  list (`paths.list`) for an apples-to-apples trigram-vs-trigram race, zoekt the
  roots tree under the heavy ignore set. Output adds geomean-speedup + win-rate
  summaries (split indexed/unindexed) and per-race CSVs. Two correctness fixes in
  the harness: every command's output is drained (`… | wc -l`) so ugrep's lazy
  multithreaded `-l` actually scans (it short-circuits when stdout is discarded)
  and a needle miss (grep exits 1) no longer aborts hyperfine.
- **Expanded scenario slates**: the warm/oracle slate (`bench.zig`) grows to 20
  literals (added cross-language keywords `goroutine`/`panic(`/`Result<`/`def`/
  `.unwrap()`) + 30 regexes (added `if\s+err\s*!=\s*nil`, `const\s+\w+\s*=`,
  `\w+\.\w+\(`, `[a-z]+_[a-z]+_[a-z]+`, `[a-z]+[A-Z]\w+`, `[0-9a-f]{8}-…`); the
  cold literal slate adds a guaranteed miss + `goroutine`/`SELECT`/`func(`/`})`;
  the cold regex slate grows to 22 tiers (decl, err-idiom, uuid/snake/camel,
  dotted-call). Re-proven sound: **50 literals + 68 regexes, 0 FN / 0 FP** vs rg.
- **Measured competitive standing (17,112 files · 126.5 MiB, shared dev box,
  hyperfine geomeans):** WARM resident gist beats every scanner **1,028×–5,992×**
  (15/15; up to 270,000× on a miss) — uncontested, the indexed rivals have no
  resident CLI. COLD one-shot gist beats every *unindexed* tool **1.9×–9.2×**
  (10–11/11). COLD regex gist lands **≈ csearch (0.9×, 14/22 wins) and faster than
  zoekt (1.4×, 13/22)**, **≥ rg (1.3×)** — the old dense floor `\w{3,8}` now beats
  both indexed rivals. The **one honest loss**: COLD *literal* one-shot vs the
  indexed rivals (csearch 0.3×, zoekt 0.5× geomean), because gist deserializes a
  177 MiB index (30 ms) where csearch mmaps 28 MiB, and runs a corpus-wide T3
  freshness stat-walk they skip — both causes recorded as the next rung, not
  hidden. gist still beats csearch on the dense / 2-byte needles (`})` 1.5×).

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
  ranking (a graph-centrality hook; null until wired). RRF needs no
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
