# Changelog

All notable changes to the `irregex` kernel (formerly `gist`; the gist CLI is its flagship face) are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions track `build.zig.zon`.

<!-- towncrier release notes start -->

## [0.1.0] - 2026-07-01

### Added

- **Bench harness** (`bench/bench.zig`): real-corpus build/footprint, on-disk
  persistence timing, and full-pipeline (filter+verify) latency p50/p95/p99 for
  an adversarial slate. gist beats ripgrep on every query over the identical
  corpus (5.7× worst case → ~140,000× for a rare miss).
- **Byte-class DFA — the sole non-Pike engine** (`src/regex_dfa.zig`, tests in
  `src/regex_dfa_test.zig`; supersedes and removes the interim bit-parallel
  Glushkov engine). The Pike VM is O(active-threads)/byte, so on the
  no-prefilter
  scan tail — a *selective but common* first byte (`;$`, `[0-9]{4}`,
  `panic|0x`)
  re-seeds a closure at nearly every byte — it lost to rg's O(1)/byte lazy DFA.
  This determinizes the Thompson NFA (Cox → RE2 / rust-`regex` lineage, an
  eager
  capped variant) into an immutable, scratch-free automaton that spends **one
  table lookup per byte regardless of match density**:
  - **Byte classes** collapse the 256-byte alphabet to the handful of columns
  any
    consuming state actually distinguishes (RE2/rust-`regex` `ByteClasses`),
    shrinking the transition table.
  - **Line anchors without a `.*` hack** — `^` is resolved once in the start
    state's closure (`at_start=true`); `$` by a separate **final** transition
    table closed with `at_end=true` (the single-line analogue of RE2's one-byte
    match delay). Unanchored search re-seeds the NFA start into every
  transition;
    an `^`-anchored program never re-seeds and dead-states to `false` the
  instant
    its thread set drains.
  - **Eager + capped** — built at compile (these patterns are tiny); past
    `max_states=4096` the build bails to null and the Pike VM keeps serving (so
    `{1000}`-style expansion stays linear, only a pathological alternation
  trips
    the cap). One immutable `Dfa` is shared lock-free across all reader
  threads.
  - **Single-pass `docMatch`** — scans the whole file buffer in **one fused
  loop**
    that detects `\n` inline, so each byte is touched exactly once. (The
  per-line
    path memchr-scans for `\n` *and then* re-scans the bytes in the automaton —
    double byte-traffic, the dominant cost of a no-prefilter full scan.)
- **Counted repetition `{n}` / `{n,}` / `{n,m}`** (`src/regex_syntax.zig`):
  parsed
  and desugared into the existing node vocabulary (`min` mandatory copies, then
  `(max-min)` optional copies or a trailing `*` when unbounded) — the `atom`
  pointer is shared across copies (the AST becomes a read-only DAG), so the NFA
  compiler and literal extractor are untouched and `ab{3}c` still prefilters on
  `abbbc`. Expansion is capped at 1000 to bound NFA size. **Mirrors rust-regex
  brace semantics exactly**: an unescaped `{` must begin a valid count or it's
  a
  `BadPattern` (ripgrep errors identically — `interface{}` is rejected, the
  literal is `\{`), while a stray `}` stays literal. Proven byte-identical to
  `rg (?-u)`: the oracle battery adds `[0-9]{4}`, `\w{3,8}`, `x{2,4}`,
  `0x[0-9a-fA-F]{2,}`, `interface\{\}` + a `{0}\w{2,4}` template (0 FN / 0 FP).
- **DFA start-state acceleration** (`src/regex/dfa.zig`,
  `src/regex/powerset.zig`).
  The byte-class DFA's unanchored start state self-loops on most bytes; only a
  few
  "relevant" bytes can begin a match (`trans_in` leaves start) or match at EOL
  (`trans_fin` is a match — the `$`-literal case like `;$`). `powerset`
  collects
  that set and, when ≤ 3 bytes, attaches a SIMD `Prefilter`; the scanner then
  `memchr`/range-skips the dead run to the next relevant byte instead of a
  table
  lookup per byte (the rust-`regex`/RE2 `accel.rs` trick). For unanchored
  patterns
  where `\n` is irrelevant and no empty line matches, the skip **crosses
  newlines** — collapsing `;$` to a single-byte `memchr ;` (rg's exact
  strategy)
  and the prefilter from a two-range scan to one. Sound because a skipped byte
  both
  keeps start in itself *and* can't match under `$`; the byte-at-a-time inner
  loop
  still stops at `\n`, so `$`/line-end resolution is unchanged. **Verified by
  the
  existing doc-level differential fuzz vs the Pike VM** (12k patterns ×
  multi-line
  buffers, *anchors + `$`-literals included*) — **0 divergences**.
  Kernel-level:
  the no-prefilter end-to-end is read-floor-bound (the scan is ~1 % of wall, <
  30 ms
  User vs ~300 ms System), so this makes the automaton optimal without moving
  the
  IO-bound macro number — the lever for that stays the read floor above.
- **DFA transition-table premultiplication** (`src/regex/powerset.zig`,
  `src/regex/dfa.zig`). The dense no-prefilter scan's hot loop is one load-use
  recurrence per byte: `next = trans[state * ncls + class[byte]]`. The `state *
  ncls`
  multiply sat *on* the loop-carried dependency chain — every step had to
  compute
  the row offset before it could issue the load that produces the next state.
  `powerset` now stores every transition target, `start`, and `dead`
  **pre-scaled
  by `ncls`** (a row *offset*, not a state id) and lays `is_match` out
  offset-indexed,
  so the recurrence collapses to a bare `next = trans[state + class[byte]]` —
  the
  `madd` leaves the critical path entirely (the rust-`regex`/RE2
  premultiplied-DFA
  representation). **Correctness:** structural invariants + exhaustive language
  equivalence (`powerset_test.zig`, updated for the offset representation) and
  the
  doc-level DFA↔Pike differential fuzz (12k patterns × multi-line buffers) —
  **0
  divergences** — plus `scan_regress.sh` end-to-end (5 no-prefilter patterns,
  **0
  FN / 0 FP** vs `rg` over the identical 17.5k-file tree). **Measured** (Apple
  Silicon, kperf FIXED_CYCLES/INSTRUCTIONS, min-of-N, real 137 MB corpus,
  `[0-9a-f]{8}-[0-9a-f]{4}`): **6.62 → 3.98 cyc/byte (−40 %, 1.66×)**, ins/byte
  16.89 → 14.99 (−1.9), IPC 2.55 → 3.76. The signature is unambiguously
  latency-bound — instructions fell ~11 % but cycles fell 40 % *and* IPC rose,
  because shortening the recurrence (madd→load ⇒ load) exposed the ILP the
  dependency chain had been hiding. The dense DFA now sits at the scalar-DFA
  hard
  floor (~one L1 load-use per byte), at/ahead of rg's premultiplied lazy DFA.
- **Equality oracle** (`bench/equality.sh`, `bench/bench.zig` `verify` mode):
  gist emits its verified matching-file set per pattern + the exact indexed
  file
  list; the script runs `rg` (and `rg (?-u)` for regex) over that identical
  list
  and diffs. Proven over 16,509 files / 125 MiB: 945 adversarial+random
  literals
  (3 seeds) + 88 regexes → **zero false negatives, zero false positives**.
- **Expanded scenario slates**: the warm/oracle slate (`bench.zig`) grows to 20
  literals (added cross-language keywords `goroutine`/`panic(`/`Result<`/`def`/
  `.unwrap()`) + 30 regexes (added `if\s+err\s*!=\s*nil`, `const\s+\w+\s*=`,
  `\w+\.\w+\(`, `[a-z]+_[a-z]+_[a-z]+`, `[a-z]+[A-Z]\w+`, `[0-9a-f]{8}-…`); the
  cold literal slate adds a guaranteed miss +
  `goroutine`/`SELECT`/`func(`/`})`;
  the cold regex slate grows to 22 tiers (decl, err-idiom, uuid/snake/camel,
  dotted-call). Re-proven sound: **50 literals + 68 regexes, 0 FN / 0 FP** vs
  rg.
- **Latent Pike `.skip` soundness fix** (`src/regex.zig` `eol_empty`). The DFA
  doc-fuzz surfaced it: a nullable prefix flowing into `$` (`\d*$`, `a*`,
  `x|$`)
  matches the zero-width end of **every** line, but skip mode only seeds
  first-byte positions and never evaluated the end-of-line empty match — a real
  false-negative the DFA exposed. `compile` now precomputes whether the start
  epsilon-reaches `match` at `(at_start=false, at_end=true)` and short-circuits
  to
  true (also a fast path for the DFA: no full-line scan for a match-everything
  pattern). `^`-anchored programs correctly stay false.
  - **Verification — two oracles, both fail-closed.** The rg `(?-u)` equality
    battery (135 literals + 64 regexes over 17.1k files / 126 MiB → **0 FN / 0
    FP**) *and* two **differential fuzzes vs the proven Pike VM**, hermetic (no
  rg
    needed): a line-level fuzz (6,000 random patterns — *anchors included* — ×
  10
    inputs) and a **doc-level fuzz** (6,000 patterns × 8 multi-line buffers
  with
    empty lines + trailing newlines) proving the single-pass scan
  byte-identical
    to the per-line path. **Zero divergences** in `zig build test`. The fuzzes
    earned their keep — they caught the Pike `.skip` bug above and a last-byte
    `trans_fin` edge in the single-pass scanner during development.
  - **Measured** (`bench/regex_headtohead.sh` + direct warm-cache query timing,
    17.1k files / 126 MiB, min-of-runs to filter shared-box load): the
    no-prefilter scan tail dropped **7–21%** of query time and now sits **at
  rg's
    own scan floor** (~248–264 ms vs rg ~250–280 ms) — the residual gap is
  purely
    gist's ~27 ms cold-load that rg never pays. The former clear losers flipped
  to
    ties: `[a-z]+_[a-z]+_[a-z]+` 326→258 ms query (355→285 ms total vs rg 278),
    `panic|0x` 313→248 ms. Prefilterable tiers still win outright
  (`pgxpool\.\w+`
    ~3×, `^func\s` ~2.5×, alternations 1.4–1.65×) because the trigram prefilter
    reads a fraction of the corpus while rg re-walks all of it.
- **Line anchors `^` / `$`** (`src/regex_syntax.zig`, `src/regex.zig`):
  zero-width
  assertions resolved during the Pike epsilon-closure from per-position
  (start, end)-of-line flags — `^`/`$` add no NFA bytes, so an anchored
  pattern's
  required literal is unchanged (`^func` ⇒ prefilter "func"). `\^`/`\$` stay
  literal. Fixed `docMatch` to grep's line model (a trailing `\n` *terminates*
  the last line rather than seeding a phantom empty one — otherwise `^$`/`$`
  over-match every newline-terminated file vs rg). Proven byte-identical to
  `rg (?-u)`: the oracle's 52-regex battery now includes 8 anchored shapes +
  `^{0}`/`{0}$`/`^\s*{0}` templates (0 FN / 0 FP), and the cold CLI path
  matches
  rg on `^$` (15,572 files with a real blank line), `^func\s`, `\)$`, `;$`,
  `^}$`.
- **Measured competitive standing (17,112 files · 126.5 MiB, shared dev box,
  hyperfine geomeans):** WARM resident gist beats every scanner
  **1,028×–5,992×**
  (15/15; up to 270,000× on a miss) — uncontested, the indexed rivals have no
  resident CLI. COLD one-shot gist beats every *unindexed* tool **1.9×–9.2×**
  (10–11/11). COLD regex gist lands **≈ csearch (0.9×, 14/22 wins) and faster
  than
  zoekt (1.4×, 13/22)**, **≥ rg (1.3×)** — the old dense floor `\w{3,8}` now
  beats
  both indexed rivals. The **one honest loss**: COLD *literal* one-shot vs the
  indexed rivals (csearch 0.3×, zoekt 0.5× geomean), because gist deserializes
  a
  177 MiB index (30 ms) where csearch mmaps 28 MiB, and runs a corpus-wide T3
  freshness stat-walk they skip — both causes recorded as the next rung, not
  hidden. gist still beats csearch on the dense / 2-byte needles (`})` 1.5×).
- **Multi-literal alternation prefilter** (`src/regex_syntax.zig`
  `requiredAny`,
  `src/trigram.zig` `Index.queryAny`): an alternation has no single mandatory
  literal, so it used to full-scan. Now a cover set is extracted — a set of ≥3
  B
  literals such that *every* match contains one (`foo|bar|baz` ⇒ {foo, bar,
  baz})
  — and the candidate set is the UNION of each literal's trigram candidates.
  Sound
  by construction: the union is a superset of every match, so no true match is
  dropped; the existing verify pass still gates false positives. It's admitted
  only when **every** branch yields a ≥3 B literal (a `<3` or unfilterable
  branch
  ⇒ no cover ⇒ full scan, e.g. `panic|0x`), a single mandatory literal still
  wins
  over a union, and the set is capped at 32 branches. Wired through the cold
  CLI
  (`fresh.candidates` now takes a filter *set*) and the oracle. Proven
  byte-identical to `rg (?-u)`: the battery adds `return|continue|break`,
  `func|struct|enum`, `TODO|FIXME|XXX`, `import\s+\(|^package`,
  `context|errors`,
  `panic|0x` + the `({0}|{1})` template (0 FN / 0 FP over 17,028 files); the
  cold
  CLI on `panic|throttle|leaky` reads only 1,071/17,029 files (union prefilter,
  not a scan) and returns rg's exact 694-file set.
- **No-prefilter regex → direct live-tree scan** (`bench/scan.zig`, dispatched
  from `bench/cli.zig` `runRegex`). A regex with no usable trigram prefilter —
  no
  ≥3 B required literal and no all-≥3 alternation cover (`[0-9]{4}`,
  `panic|0x`,
  `[a-f0-9]{2,}`, `\w{3,8}`, `[a-z]+_[a-z]+_[a-z]+`) — makes the index filter
  *nothing*: every doc is a candidate. The cold index path then paid **two**
  full
  tree traversals — a corpus-wide T3 freshness `statFile` walk **and** a
  candidate
  read of all ~17 k files — where rg pays one (walk + read). The tier is
  IO-bound
  (profiled: System time dwarfs the automaton's User time — the scan engine was
  never the bottleneck, the redundant traversal was), and the freshness
  stat-walk
  is the dominant tax: measured **255 ms → 187 ms** (~67 ms) by toggling the
  anchor on a `panic|0x` full scan. So for that case gist now **skips the index
  entirely** and walks the LIVE tree once, reading + DFA-scanning each file
  like
  rg. This is strictly **more** correct than the index+freshness path — it
  reads
  current bytes, sees files created since the build, honors deletions, with no
  staleness window — so no freshness walk is needed at all. Same skip-dirs /
  NUL-binary / 4 MiB cap as the indexed corpus.
  - **Fused work-stealing pipeline (a tie was never the floor).** The first cut
    was phased — a parallel walk to collect every path, *then* a sharded
  read+scan
    — and profiling (process-internal clock, build-wrapper-independent) caught
  it
    leaking two ways: a **~63 ms walk barrier** overlapping nothing, and **~169
  ms
    of straggler idle** (static file-count sharding stranded the big files on
  one
    core — fastest core done in 158 ms, slowest 327 ms). Rewritten so walkers
    stream discovered paths into a shared MPMC queue while a core-sized pool
  steals
    files in batches and reads+scans *as the walk still runs*: **worker-span
    Δ 169 ms → 2.5 ms** (near-perfect byte-balance) and the walk folded under
  the
    scan — **~1.7× internal speedup**. Oversubscription was *measured, not
    assumed*: warm-cache the tier is CPU/syscall-bound (~190 µs/file
    open+read+close, the DFA pass a rounding error), so ×1 worker/logical-core
  beat
    ×2/×3 on both wall-clock and balance.
  - **Correctness:** byte-identical to `rg (?-u) -l` over the same logical
  corpus
    (rg run with `--no-ignore --hidden` + gist's dir-excludes so both scan the
    same file set): **0 FN / 0 FP** across `[0-9]{4}`, `panic|0x`,
  `[a-f0-9]{2,}`,
    `[0-9a-f]{8}-…`, `[a-z]+_[a-z]+_[a-z]+`, `\w{3,8}`, `x{2,4}` — the only
    residual diffs being 3 multi-MB data blobs (`train_text.txt` 2.2 GB,
    `val_text.txt` 22 MB) whose first match sits past the **pre-existing 4 MiB
    `per_file_cap`** the indexed corpus caps identically.
  - **Measured** (ReleaseFast, release-vs-release vs `rg (?-u) -l` on its
  fastest
    gitignore-respecting path, min-of-N back-to-back, shared dev box; gist
  scans a
    gitignore-*superset*, so it wins while reading **more** bytes): `\w{3,8}`
    **1.3–3.0×** · `[a-f0-9]{2,}` **1.3–1.4×** · `[a-z]+_[a-z]+_[a-z]+`
  **1.2×** ·
    `[0-9]{4}` **1.1×** · `panic|0x` **win-or-tie (~1.0×)** — **0 FN / 0 FP**
  vs rg
    throughout (one `[0-9]{4}` `rg_only` file: a >4 MiB blob past the shared
    `per_file_cap`). gist wins or ties all five. (The earlier Debug-build
  numbers
    understated gist — release-vs-release is the honest race.)
  - **Permanent regression** (`bench/scan_regress.sh`): the scan path is a
    different code path than the index path `bench/equality.sh` proves, so it
  gets
    its own permanent oracle — asserts each pattern still **routes** to the
  scan
    path, diffs gist's scan set vs `rg (?-u)` over the identical corpus and
  **exits
    1 on any FN/FP** (cap-skips excepted by size), and prints the worker-span Δ
  as a
    **straggler canary** so a future regression of the work-stealing balance
  fails
    loudly. Keeps the win honest and the floor measured for the next
  exploration.
  - **Why the verdict is structural (off the data, not vibes):** gist's time is
    **pattern-independent** (~240 ms across all five — it sits at the per-file
    syscall floor, the DFA being a single early-exiting pass), whereas rg's
  swings
    **2–373 ms with match density** (floor + per-byte scan). gist therefore
  wins
    every scan-expensive pattern and ties only the cheapest sparse-literal
    (`panic|0x`), where rg's scan is near-free and both rest on the same read
  floor.
  - **Named next rung (recorded, not hidden):** beating rg on the
  sparse-literal
    tie means dropping *below* the read floor — batch the per-file
    `openat`+`read`+`close` (io_uring / `readv`), since at ~190 µs/file the
    syscalls, not the scanned bytes, are the wall. A prefilter can't help a
  tier
    already at its IO floor.
- **Regex engine gains AST-level ASCII case-folding, so `-i` / `(?i)` matches
  caseless across every backend** (`src/regex/syntax.zig`). Case-insensitivity
  used
  to be handled ad-hoc at the grep layer; it now lives in the engine where the
  NFA, lazy DFA, and Pike capture VM all inherit it from one place.

  - **`ByteSet.foldCase`** admits the opposite-case twin of every letter
  present in
    a consuming class (`a`⇄`A`), and **`foldCaseAst`** walks the AST applying
  it to
    every class (zero-width assertions and structure untouched, `capture` nodes
    recursed transparently). It's idempotent, so re-visiting a shared `{n,m}`
  atom
    in the DAG is harmless.
  - **Trigram soundness preserved**: a folded literal byte becomes a 2-member
  set,
    which the `only`/`required` literal extraction reports as non-singleton —
  so a
    caseless pattern yields an empty required-literal and the query soundly
  falls
    back to a full scan (gist's trigram index is case-sensitive). No false
    negatives from a case-folded search.

  Proven against real ripgrep as the oracle: `-i` cases (ASCII caseless literal
  and
  class) diff to **0 bytes** vs `rg`, with the engine's existing differential
  and
  prefilter-soundness tests still green.
- **Regex parser expands the control + hex escape set (`\f \v \a \0 \xNN
  \x{H..H}`)** (`src/regex/syntax.zig`). ripgrep patterns reach for these
  byte escapes routinely; gist previously only decoded `\t \n \r`, so a legal
  pattern like `\x7F` or `\0` was mis-parsed as a literal `x`/`0`.

  - **Control escapes**: `\f`→`0x0C`, `\v`→`0x0B`, `\a`→`0x07`, `\0`→NUL (rg's
    `\0`), alongside the existing `\t \n \r`.
  - **Hex escapes**: `\xNN` (two hex digits) and the braced codepoint form
    `\x{H..H}` (`hexByte`/`hexVal`). gist is a byte engine, so a value `> 0xFF`
    is a hard `BadPattern` (rg's `(?-u)` byte-mode behavior) rather than a
  silent
    truncation — fail-loud beats a wrong match.

  Proven against real ripgrep as the oracle: the escape cases (`\x` byte,
  braced
  codepoint, `\0`/control) diff to **0 bytes** vs `rg`; over-`0xFF` `\x{…}`
  errors
  loud as designed. The regex engine's differential tests stay green.
- **Regex scan accelerators** (`src/regex.zig`, split into
  `src/regex_test.zig`):
  the verify-time Pike search that used to re-seed the start thread at *every*
  byte — wasted closure work — now compiles three position invariants and
  dispatches `lineMatch` to the cheapest sound strategy (semantics unchanged,
  proven by the rg oracle + an overlapping-start unit battery):
  - **Anchored fast path** — `startsAnchored` (every alternation branch begins
    with `^`) seeds only at line position 0 and bails the instant the thread
  list
    drains, so a non-matching line for `^}$` / `^$` is ~O(1) instead of O(len).
  - **First-byte skip** — `analyzeFirst` walks the NFA for the byte set that
  can
    *begin* a match mid-line (traversing `^`, blocking `$`; the
  over-approximation
    is sound — a mid-line seed of an `^`-only branch dies on the failed
  assertion).
    When the thread list empties the scanner jumps to the next viable start
    instead of stepping dead bytes: SIMD `indexOfScalar` for a singleton set
    (`;$`, `0x…`), a **SIMD range scan** (`lo ≤ b ≤ hi` per `@Vector` window,
  OR'd
    over ≤6 contiguous ranges) for `[0-9]{4}` / `[a-f0-9]{2,}` / `\w{3,8}`,
  else a
    scalar byteset probe. The earlier blocking-`^` version dropped 408
  `^package`
    matches in `import\s+\(|^package` — caught by the oracle, now a regression
  test.
  - **Plain path** — unchanged re-seed-every-byte loop for an empty first set
    (a bare `$`), which the skip can't drive.
  Measured cold head-to-head vs `rg (?-u) -l` at its fastest
  gitignore-respecting
  walk (`bench/regex_headtohead.sh`, hyperfine p-mean, warm cache, 17.1k
  files):
  gist wins **every prefilterable tier robustly** (stable run-to-run) —
  `pgxpool\.\w+` **≈3.0×**, `^func\s` **≈2.5×**, `func\s+\w+\(` **≈1.9×**,
  `func|struct|enum`/`error|panic|fatal` **≈1.5–1.65×**,
  `return|continue|break`
  **≈1.5×** — because the prefilter reads a fraction of the corpus while rg
  re-walks all of it. The **no-literal full-scan tail oscillates around
  parity**
  (≈0.8–1.1×, noise-dominated): with no prefilter for *either* tool both read
  the
  whole 126 MiB, so it's a straight scan race sensitive to the shared dev box's
  load. The skip turned the old clear losses (`^}$` 0.54×, `;$` 0.77×) into
  ties.   The hard floor is `\w{3,8}` — dense matching where `\w` covers most
  bytes
  so the skip never engages and it's Pike-VM-per-byte vs rg's O(1)/byte lazy
  DFA;
  closing it is the identified next rung (a lazy DFA / bit-parallel NFA step).
- **Second baseline: `ag` (the_silver_searcher)** in all three race scripts
  (`bench/headtohead.sh`, `coldquery.sh`, `regex_headtohead.sh`) — a new
  `ag … column`, an `rg≷ag` direct-matchup column, and an "ag faster than rg on
  N/M" tally. `ag` runs on its honest fastest path: `--path-to-ignore
  .gitignore`
  hands it the root ignore set `rg` reads for free (its own walk reads ignore
  files only *inside* the search paths, so without it `ag` grinds through the
  gitignored ~99 GB — 0.46 s scoped vs minutes unscoped). Columns auto-skip if
  `ag` is not installed. Measured over 37 queries (17.1k files): `gist` wins
  all
  but one; `rg` beats `ag` on **36/37** (`ag` ~1.6–2.1× behind on every
  literal,
  warm + cold, and 15/16 regexes). `ag`'s lone win is the prefilter-less 2-byte
  mixed alternation `panic|0x` — `ag` 483 ms vs `rg` 675 ms (**1.40×**), the
  same
  pattern where gist's Pike VM is weakest (1173 ms).
- **Seven-tool competitive field + indexed rivals** (`bench/_compete.sh`,
  rewritten `coldquery.sh` / `regex_headtohead.sh` / `headtohead.sh`): the race
  now spans every level. Beyond the unindexed scanners (`rg`, `ag`, plus new
  `ugrep`, GNU `grep`, `git grep`) gist is benched against the two mature
  *indexed* searchers — **csearch** (Russ Cox's Google Code Search, gist's
  direct
  trigram ancestor) and **zoekt** (Sourcegraph's production indexed search). A
  shared `_compete.sh` registry defines the field, the per-tool fastest-honest
  invocations, and the index builds; csearch indexes gist's **exact** corpus
  file
  list (`paths.list`) for an apples-to-apples trigram-vs-trigram race, zoekt
  the
  roots tree under the heavy ignore set. Output adds geomean-speedup + win-rate
  summaries (split indexed/unindexed) and per-race CSVs. Two correctness fixes
  in
  the harness: every command's output is drained (`… | wc -l`) so ugrep's lazy
  multithreaded `-l` actually scans (it short-circuits when stdout is
  discarded)
  and a needle miss (grep exits 1) no longer aborts hyperfine.
- **Sub-trigram literals → the same live-tree scan** (`bench/scan.zig`
  generalized to verify a literal via `simd.contains` as well as a regex via
  `docMatch`; `bench/cli.zig` `runQuery` routes `needle.len < 3` there). A `<3
  B`
  literal (`})`, `=>`) has no trigram filter, so the index path seeded every
  doc
  **and** ran the corpus-wide freshness `statFile` walk on top of the read —
  the
  same two-traversals-vs-rg's-one tax the no-prefilter *regex* path already
  escaped. Short literals now skip the index and walk the live tree once
  through
  the proven work-stealing pipeline. **Correctness:** the literal scan is
  byte-identical to the trusted DFA scan over the identical tree (`} )` literal
  vs
  `/\}\)/` regex → same 5,610-file set, 0 diff), and `scan_regress.sh` stays
  green
  (0 FN / 0 FP). The ≥ 3 B indexed path is untouched (`pgxpool` still reads
  409/17,513 files, ~1.7 ms cold-load).
- **T0 trigram candidate index** (`src/trigram.zig`): allocation-light,
  container-API-free positional-trigram inverted index over a fixed document
  set. `Index.build` + `Index.queryLiteral` (sound superset of literal matches
  via posting-list AND), queried by hand-rolled binary search. Filter semantics
  (false positives expected, zero false negatives for literals ≥ 3 bytes) and
  the `NeedleTooShort` fallback contract are covered by unit tests.
- **T1 persistence** (`src/trigram.zig`): `serializedSize` / `writeInto` /
  `fromBytes` — IO-free native-endian local-cache serialization (the harness
  does the file IO; the kernel stays filesystem-agnostic). A session builds the
  index once (~6.4s) and warm-starts from disk in ~28ms (227× faster).
  Round-trip +
  malformed-blob-rejection tests added.
- **T1 rarest-first query** (`src/trigram.zig`): `queryLiteral` now resolves
  every trigram's posting range up front, seeds the candidate set from the
  *rarest* trigram, and intersects outward (AND is commutative, so results are
  identical — the work is just bounded by the rarest gram instead of the
  lexicographically-first one). Collapsed the `context.Context` tail from
  ~530µs
  to ~9µs at libs scale.
- **T2 regex tier** (`src/regex.zig`): a linear-time **Thompson NFA** over
  bytes
  (RE2/ripgrep philosophy — no backtracking, no catastrophic blowup) with a
  recursive-descent parser for literals, `.`, `[...]`/`[^...]` ranges, `* + ?`,
  `|`, `()`, and `\d \w \s \D \W \S \t \n \r` + metachar escapes. Includes
  sound
  required-literal extraction (a conservative slice of Cox's regexp→trigram
  analysis) so a regex reuses the T0 prefilter, falling back to a full scan
  only
  when no literal is mandatory. Unit-tested incl. the `(a+)+` pathological
  case.
- **`-g`/`--glob` supports `{a,b,c}` brace alternation** (`bench/rgargs.zig`).
  ripgrep's glob dialect expands `{…}` groups; gist treated the braces
  literally, so
  `--glob '*.{js,py,go}'` matched nothing.

  - **`braceExpand`** lowers a glob into the cartesian product of every brace
  group
    (nesting-aware, unbalanced `{` left literal) at registration time, so
    `*.{js,py}` becomes the include set `*.js`, `*.py` and
    `!{.git,node_modules}/**` becomes the excludes `!.git/**`,
  `!node_modules/**`.
    `addGlob` expands, then routes each variant through `addGlobOne` (the prior
    include/exclude/iglob logic) — one glob dialect across `-g`, `--iglob`, and
    `--type-add`.

  Proven against real ripgrep as the oracle: `r391` (a real editor's
  `!{.git,node_modules,plugged}/**` + `*.{js,json,…,py,…}` glob combo) now
  diffs to
  **0 bytes** vs `rg`.
- **`grep` accepts the reflexive ripgrep surface an agent's muscle memory
  types**
  (`bench/grepargs.zig`, extracted from `bench/lines.zig`;
  `bench/pathfilter.zig`).
  Found by dogfooding gist _as the agent_ against `rg` on real repo questions:
  the
  goal is to _never reach for ripgrep_, but three reflexive invocations still
  broke
  — one of them silently, the worst failure mode. All three are closed,
  byte-exact
  vs `rg` (9/9 head-to-head, `.local/gist-dogfood/prove.sh`):

  - **Positional PATH args now scope the search** — `grep WalletService
  services/`
    used to search the _whole repo_ while the agent believed it scoped (a
    wrong-but-confident result). Every non-flag token after the pattern is now
  a
    path root AND-ed into the `PathFilter` and **pruned before any read** —
  gist's
    structural edge, not just parity: `grep WalletService services/backend/api`
    reads **28 candidates** (vs 86 unscoped, vs rg's whole-subtree walk) and
  runs
    **1.14× faster than rg at ~⅕ the syscall time** (112 ms vs 590 ms system,
    hyperfine 15-run), output byte-identical.
  - **Bundled short flags** — `-ln`, `-in`, `-nw`, `-nC3` used to fail loud as
    "unknown flag". A `-xyz` cluster is now decomposed left-to-right; the first
    _value_ flag consumes the cluster remainder (`-nC3` ⇒ `-n -C 3`, `-tgo` ⇒
    `-t go`) or the next token.
  - **Harmless rg flags** — `-n` (line numbers, always on), `-H`, `-r`/`-R`,
    `--no-heading`, `--color[=X]`, `--with-filename` are accepted as **no-ops**
    under gist's fixed `path:line:text` model (they used to fail loud); `-N` /
    `--no-line-number` drops the line column for real, and `-S` /
  `--smart-case`
    folds iff the pattern carries no uppercase (rg's rule). Every existing flag
    also gained its rg **long spelling** (`--ignore-case`, `--context=N`,
    `--type=<lang>`, `--glob=<glob>`, `--max-count=N`, …).

  Fail-loud is preserved for genuinely unknown flags (a silent empty result is
  the
  worst agent failure) — the diagnostic now prints the full supported surface.
  The
  parser moved to its own module so `lines.zig` (line emit/verify) drops from
  479 →
  344 lines and the larger compatibility table lives on its own (both under the
  500-line shape cap). New adversarial tests (`bench/grepargs_test.zig`, 12
  cases)
  pin bundling, no-ops, long-flag `=`/next-token values, smart-case, `-e`/`--`
  leading-dash safety, and the fail-loud contract; `bench/pathfilter_test.zig`
  gains positional-root coverage (dir-prefix `/`-boundary, exact file, `.`
  whole-corpus, `normalizeRoot`). The `gist ≡ rg` set oracle is unchanged.
- **`grep` closes three reflexive-invocation gaps found by dogfooding gist _as
  the
  agent_ against `rg`** (`bench/grepargs.zig`, `bench/lines.zig`,
  `bench/pathfilter.zig`). Racing the two tools on real repo questions surfaced
  one
  silent-wrong landmine, one fail-loud on a legal pattern, and a robustness win
  rg
  lacks — each of which broke a call an agent's muscle memory actually types:

  - **`-r` / `--replace` was a silent-wrong landmine — now a real value flag.**
  rg's
    `-r` _consumes_ the replacement, but gist had it mis-listed among the
  boolean
    no-ops, so `grep -r X pat` parsed `X` as the pattern and `pat` as a path
  root — a
    wrong-but-confident empty result (the worst agent failure). It now stores
    `opts.replace` and rewrites each match before emit: `$0`/`${0}`/`$&` expand
  to
    the whole match, `$$` is a literal `$`. A capture-group ref (`$1`, `${2}`)
  is
    rejected **at parse time** — gist's span engine tracks the whole-match
  extent,
    not per-group captures, so failing loud beats a silently-dropped
  substitution.
    Proven byte-identical to `rg -o -r`/`rg -r` over the shared `-t go` corpus.
  - **Leading inline flag groups `(?i)` / `(?-u)` / `(?m)` are now honored.**
  An agent
    pastes rg patterns carrying a global flag group reflexively; gist used to
  reject
    the whole (legal-to-rg) pattern. Now `i`→ASCII caseless
  (`(?i)walletservice` is
    byte-identical to `-i`), `m`/`u`/`U`/any `-…` form → no-op (gist is
  per-line,
    byte-oriented — exactly rg `(?-u)`), while `s` (dotall across newlines) and
  `x`
    (extended) still fail **loud** rather than silently mismatch. `-F` keeps
  `(?i)`
    a literal; a non-capturing `(?:…)`/lookahead `(?=…)` is left for the
  compiler.
  - **`-t tsx/jsx/vue/svelte/rego/mdc/cedar` resolve.** Convenience rows for
  types an
    agent types that even `rg` lacks (`tsx`/`jsx`) or that are repo-native
  (`rego`,
    Cursor `.mdc`, Cedar policy), so a reflexive `-t tsx useState` scopes
  instead of
    erroring.

  Also documented but _not_ a gist change — the decisive reason to prefer gist
  in an
  agent loop: in a harness where stdin is a non-tty pipe (how Cursor/Claude
  Code/
  Codex spawn shells), a bare `rg PATTERN` with no path arg **blocks forever
  reading
  stdin**; gist always searches its indexed roots and never has this failure
  mode
  (`rg PATTERN </dev/null` returns instantly with the same result).

  Correctness unchanged: the `gist ≡ rg` set oracle still proves 0 FN / 0 FP
  (80
  literals + 94 regexes), the parser carries 4 new adversarial tests (value
  consumption, inline-flag map, `-F` literal, group-ref reject), and all five
  new
  behaviors diff to **0 lines** vs `rg` on the shared scope.
- **`grep` gains `--files` (file discovery) and `-o`/`--only-matching` (span
  extraction)** — the two reflexive ripgrep invocations dogfooding surfaced as
  the
  next holes in the "never reach for `rg`" goal. Both fail-loud gaps before
  this
  (`unknown flag`), so an agent's `rg --files -g …` / `rg -o …` muscle memory
  hit a
  wall mid-loop.

  - **`--files [PATH…]`** lists every corpus file the `-t`/`-g`/PATH filter
  admits
    — and does it with **zero file reads and zero tree walk**. gist already
  holds
    the whole path list in the mmap'd index, so discovery is a pure in-memory
    filter + sort where `rg --files` must walk the entire tree. On this repo
  that's
    the difference between an instant answer and a walk that, from the
  _uncurated_
    root, stalls on the 106 GB of build/vendor mass gist's corpus policy
  already
    excludes (measured: `rg` content-search from repo root **hangs >20 s**, `rg
  --files` 93 ms; gist projects the index in a few ms). Read-your-own-writes is
    preserved — the freshness overlay folds in files created since the build (a
    stat-only walk, no reads) so a coworker's just-written file still appears;
  a
    file _deleted_ since the last `index` may still list (no read to verify it
  away)
    and self-heals on rebuild, the same tolerated false-positive the trigram
  filter
    carries. The projection is intentionally the curated code set: no build
  caches
    (`.zig-cache/`, `dist-types/`, `.local/`), no binaries, no >4 MiB blobs —
  arguably
    a _better_ discovery list for an agent than rg's raw walk.

  - **`-o`/`--only-matching`** emits each non-overlapping match's TEXT alone
  (not
    the whole line), one `path:line:text` row per match — extraction of idents,
    symbols, URLs, hex, etc. The DFA is match/no-match only, so spans run the
  Pike
    VM with a per-state start-offset side-channel added to the ε-closure
  (`starts`
    in `Closure`, null on the hot boolean path — no cost to
  `lineMatch`/`docMatch`).
    Semantics are rg's `(?-u)` exactly: **leftmost start, then the
  highest-priority
    thread wins the end** — earlier alternation branches and greedy quantifiers
    extend maximally (empirically fixed against `rg -o`: `a|ab`→`a`,
  `a+`→greedy,
    `[0-9]{2,}`→longest run). After a match at `[s,e)` the next search resumes
  at
    `e` (non-overlapping); a zero-width match steps one byte so a nullable
  pattern
    can't loop.

  **Proof (byte-exact vs `rg -o` on the shared corpus):** an 11-pattern
  differential battery (`func \w+`, `[A-Z]\w+Error`, `return|continue|break`,
  `\bfunc\b`, `[a-z]+[A-Z]\w+`, `a|ab`, `[0-9]{2,}`, …) over
  `services/backend/gateway`
  diffs to **0 lines** against `rg -o -n --no-heading --no-ignore --hidden
  --no-unicode` (`.local/gist-dogfood/o_battery.sh`); every residual divergence
  across the wider tree is a `.gitignore`/hidden/`isSkipDir` file — gist's
  documented corpus policy, not a match bug. Permanent regression coverage:
  `matchSpan` leftmost-first/greedy/anchor/boundary cases in `core_test.zig`,
  and
  `-o`/`--files` argv parsing (bundling, pattern-optional, roots) in
  `grepargs_test.zig`.
- **`grep` gains the agent's full ripgrep flag surface** (`bench/lines.zig`,
  `bench/pathfilter.zig`). Found by dogfooding gist _as the agent_, racing
  every
  query against `rg`: the three flags an agent reaches for after `-n` were
  missing,
  and an unknown flag was silently swallowed as the pattern — the worst failure
  mode (a wrong-but-confident empty result). Now:

  - **`-A/-B/-C N` context lines** — read the code _around_ a hit without a
  second
    file round-trip (the #1 affordance after `-n`). Byte-exact `:`/`-`/`--`
  framing:
    a 17-line `-C2` block and an asymmetric `-A1 -B1` block both diff to **0
  lines**
    against `rg -n --no-heading -C`, group separators and all.
  - **`-t <lang>` / `-g <glob>` path scoping** (`pathfilter.zig`) — confine to
  one
    language or subtree. The type table is **codebase-agnostic** (~75 languages
  with
    rg-compatible names — `java kotlin ruby php c cpp cs haskell elixir
  terraform
  dockerfile …`, not just the monorepo's seven), so `-t <name>` accepts the
  same
    name an agent already types at rg, and a row may carry a bare filename
    (`Makefile`, `Dockerfile`, `go.mod`) as well as an extension. This is also
  the
    one place gist _beats_ rg structurally instead of merely matching it: rg
  applies
    the filter while walking the whole tree, but gist already holds the path
  list,
    so it **prunes candidate ids before touching disk**. `-t go pgxpool.Pool`
  reads 234 of 18 608 files and runs **1.44× faster
    than `rg -t go`** (55 ms vs 79 ms, hyperfine 20-run, byte-identical
  output); the
    pre-fix `-t go` swallowed the flag and degenerated to reading all 18 608
  (459 ms).
    Globs are gitignore/rg-shaped (`*` per-segment, `**` across `/`, `?`,
  `[a-z]`
    classes, `!`-exclude), basename-matched when slash-free.
  - **`-w` word-boundary** (wraps `\b(…)\b`), **`-F` fixed-string** (escapes
  regex
    metachars), **`-l` files-with-matches**, **`-c` per-file count**, **`-v`
  invert**
    (seeds all docs — an inverted match can occur in a file lacking the
  literal).
  - **Fail-loud parsing** — an unrecognized `-x` now errors with the
  supported-flag
    list (use `-e <pat>` or `-- <pat>` for a leading-dash literal) instead of
    searching for it.

  Correctness is unchanged and re-proven: the new `pathfilter` glob matcher
  carries
  its own adversarial tests (segment vs `/` boundaries, `**` zero-dir, class
  negation, pathological star backtracking, exclude veto); a 7-feature
  line-output
  battery (`-w`, `-F`, `^`-anchor, `$`-eol, alternation, class, counted) diffs
  to
  **0 lines** vs `rg` on the shared scope; and the `gist ≡ rg` set oracle still
  proves 0 false negatives / 0 false positives. The grep line loop also adopts
  rg's
  `\n`-terminates semantics (a trailing newline yields no phantom empty final
  line),
  so `$`/`^$` match exactly as rg does. Path scoping respects the same
  documented
  corpus policy as the rest of gist (skips `vendor`/`dist-types`/build output)
  — the
  only residual deltas vs a raw `rg` path-arg run, all in skipped subtrees.
- **`rg --json` emits ripgrep's JSON Lines record stream — was a fail-loud
  gap**
  (`bench/rgjson.zig` (new), `bench/rgcompat.zig`, `bench/rgemit.zig`,
  `bench/rgsuite/run.py`). `--json` is how tools consume ripgrep structurally,
  so
  the drop-in has to speak it, not decline it.

  - **Exact message sequence** (`rgjson.zig`): one JSON object per line — a
  `begin`
    per matched file, a `match`/`context` per emitted line with byte-accurate
    `submatches` (and, under `-r`, per-match `replacement`), an `end` carrying
  that
    file's stats, then a trailing `summary`. It rides the _one_ regex engine
    (`matchSpan` for spans, the capture VM for `-r`) and reuses
  `rgemit.expandInto`
    for template expansion, so there's no second matcher or replacer to drift.
  - **`-A/-B/-C` context, `-v` invert, `-m` cap, `--crlf`** are all reflected
  in the
    record stream and the aggregated `stats` (`matches`, `matched_lines`,
    `searches`, `bytes_searched`); `--quiet` still tallies stats while
  suppressing
    the record body.
  - **Deterministic-only fields are real; wall-clock/printer-internal ones are
    normalized.** `elapsed`/`elapsed_total`/`bytes_printed` are inherently
    non-reproducible, so both sides emit placeholders that `rgsuite/run.py`
    normalizes (mirroring what it already does for `--stats` seconds); every
    correctness field is emitted for real.
  - **Strings use rg's escaping** — `\"` `\\`, `\n`/`\r`/`\t` short forms,
  other C0
    as `\u00XX` (all harness fixtures are UTF-8).

  Proven against real ripgrep as the oracle: the `--json` cases diff to **0
  bytes**
  after the shared timing/`bytes_printed` normalization, and `--json` is
  removed
  from the fail-loud deferral list.
- **`rg --type-add` defines and composes custom file types**
  (`bench/rgargs.zig`).
  The type surface already resolved built-in names (`-t go`); ripgrep also lets
  a
  caller _mint_ a type on the command line, and its tests exercise both forms —
  so
  the parser now accepts them instead of erroring on an unknown type.

  - **`--type-add 'name:glob'`** registers a user type from one or more globs
    (`--type-add web:*.html --type-add web:*.css`, accumulated in order),
  usable
    immediately via `-t name`/`-T name`. Bare extensions are lifted to `*.ext`.
  - **`--type-add 'name:include:t1,t2'`** composes an existing set of types
  into a
    new alias, resolving each member (custom-first, then the built-in table)
    recursively.
  - **Resolution order fixed**: `-t <name>` checks `--type-add` definitions
  before
    the built-in `pathfilter` table, so a redefinition wins. (Along the way
  this
    fixed a Zig control-flow bug where an `else die` bound to a `for`'s `else`
    clause mis-reported valid built-in types like `py` as "unrecognized".)

  Proven against real ripgrep as the oracle: the `--type-add` single-glob and
  `:include:` composition cases (`file_type_add`, `file_type_add_compose`) diff
  to
  **0 bytes** vs `rg`. `--type-list` itself stays a documented NA (gist's type
  table
  is a distinct catalogue, not rg's exact list).
- **`rg` auto-detects a UTF-16 BOM and transcodes to UTF-8**
  (`bench/rgcompat.zig`).
  ripgrep's default (`--encoding auto`) sniffs a byte-order mark and decodes;
  gist
  read raw bytes, so a UTF-16 file's (UTF-8) pattern never matched and its NUL
  bytes tripped binary detection into skipping the file entirely.

  - **`decodeBom`** runs once per file at ingest: a UTF-8 BOM is stripped, a
    UTF-16 LE (`FF FE`) / BE (`FE FF`) BOM transcodes the whole file to UTF-8
  via
    **`utf16ToUtf8`** (surrogate pairs resolved; a lone/invalid surrogate or a
    trailing odd byte becomes U+FFFD, matching rust-encoding's lossy decode).
  It's
    applied at every read site (walk, symlink target, explicit path arg), so
  the
    transcoded UTF-8 flows through matching _and_ binary detection uniformly.
  - **Scope stays honest**: only _BOM-marked_ UTF-16 is auto-detected. BOM-less
    UTF-16 and other charsets still require explicit `-E`/`--encoding`, which
    remains a fail-loud NA (gist is a UTF-8/byte engine).

  Proven against real ripgrep as the oracle: `f1_utf16_auto` (a BOM'd UTF-16
  file
  searched for a Cyrillic literal) now diffs to **0 bytes** vs `rg`.
- **`rg` gains `--color` support and match highlighting — the one CLI feature
  demo'd against real ripgrep that gist visibly lacked** (`color.zig` (new),
  `output.zig`, `run.zig`, `args.zig`, `cli/main.zig`). `--color=always`/`ansi`
  previously failed loud (`unsupported by design — gist emits no ANSI`); the
  default `auto` mode silently emitted nothing. Both are now real, resolved
  once
  per run in the new `color.zig`.

  - **`--color auto|always|never|ansi`**, matching ripgrep's own resolution
    rules: `auto` (the default) colorizes iff stdout is a real terminal *and*
    the environment doesn't opt out (`NO_COLOR` — any value,
  <https://no-color.org>
    — or an absent/`dumb` `TERM`) *and* no flag that implies plain text
    (`--json`, `--vimgrep`) is active; `always`/`ansi` force it on regardless
  of
    destination or environment (rg's own override rule — an explicit request
    beats `NO_COLOR`); `never` forces it off.
  - **Match highlighting tuned to beat ripgrep's own default on legibility, not
    just parity**: rg's `fg:red,style:bold` is the "normal" red (SGR `31`),
    which reads muddy against a lot of terminal palettes. gist paints a match
    bold + underlined *bright* red (`1;4;91`) — still coloring the letters, no
    filled background block — so it reads at a glance without inventing a new
    visual language. Path (bold magenta) and line-number (green) keep rg's own
    hues; separators are dimmed one notch so the match is the only thing
    competing for the eye. Wired through every text-emitting path: the default
    `path:line:text` frame, `-o`/`--only-matching`, `--vimgrep`, `--passthru`,
    and `-w` word-bounded spans (an `-r`/`--replace` line is left unpainted —
    the substituted text isn't "the match" any more).

  **Proof:** piped/non-tty output — the common agent-loop case, and the whole
  point of the earlier stdin-parity work — is untouched: `color.enabled`
  resolves to `false` whenever stdout isn't a real terminal, so `make | gist
  "pat"` stays byte-identical to `make | rg "pat"`. `--color=always` verified
  against real `rg --color=always` on the same fixture (`-n`, `-o`, `-w`): the
  path/line-number/match ANSI runs decode correctly and non-tty parity holds
  with color forced off.
- **`rg` gains a capture-group engine — `-r $1`/named-group replacement and
  JSON
  submatches, no longer a fail-loud gap** (`src/regex/captures.zig` (new),
  `src/regex/syntax.zig`, `src/regex/analysis.zig`, `src/regex/compile.zig`,
  `src/root.zig`, `bench/rgemit.zig`). The prior `-r` handled only whole-match
  `$0`/`$$` and _rejected_ a group ref at parse time; ripgrep's own test suite
  leans on `$1`/`${name}` substitution, so the drop-in couldn't reach those
  cases.

  - **Group parsing** (`syntax.zig`): `(…)` and named `(?P<n>…)`/`(?<n>…)` now
    capture (1-based index in opening-paren order, names recorded only when a
  sink
    is given so the hot main-engine parse allocates nothing); `(?:…)` is
    non-capturing; lookaround (`(?=`,`(?!`,`(?<=`,`(?<!`) fails loud as
    `BadPattern` (gist's linear engine can't backtrack).
  - **A dedicated capture VM** (`captures.zig`) compiles the same `syntax.zig`
  AST
    into a Pike VM that threads per-group slot vectors, so a leftmost-first
  match
    now yields each group's `[start,end)` — without touching the hot
  boolean/span
    matcher (the new `.capture` AST node the analysis/compile/prefilter passes
    recurse through transparently, so trigram prefilters and anchoring are
    unchanged). Slot count is capped to keep the closure stack bounded.
  - **`-r` expands real templates** — `$1`, `${2}`, `$name`, `${name}`, `$0`,
    `$$` — with rust-regex `Replacer` semantics (unknown/out-of-range group →
    empty). The expander is a shared free function (`rgemit.expandInto`) so the
    text printer and the JSON stream replace identically.
  - **Two `-r` × `--max-columns` edge cases now match rg byte-for-byte.** A
    replaced over-long line reports match granularity
    (`[Omitted long line with N matches]`, and `--max-columns-preview`'s
    `[... N more matches]`) instead of the granular-less
    `[Omitted long matching line]`; and an empty match whose
    start coincides with the previous match's end is skipped (rust-regex
    `find_iter` progress rule), so `-r '${0}f'` over `.*` yields `af`, not
  `aff`.

  Proven against real ripgrep as the oracle: the `-r`/replacement and
  max-columns-granularity cases (`f129_replace`,
  `r1739_replacement_lineterm_match`,
  `f1078_max_columns_preview2`) all diff to **0 bytes** vs `rg`, and the regex
  engine's adversarial differential/prefilter tests still pass with the new
  node.
- **`rg` honors a linked git worktree's shared `info/exclude`**
  (`bench/rgignore.zig`,
  `bench/rgcompat.zig`). The ignore engine only read `.git/info/exclude` at CWD
  via
  a shallow `.git`-dir check, so searching a _worktree_ path (whose `.git` is a
  gitfile pointing elsewhere) missed the repo's excludes and surfaced ignored
  files.

  - **`Ignore.init` now takes the search's positional roots** and probes each
  for
    its own `.git`, so `rg <flags> some-repo` honors that repo's VCS ignores
  even
    when CWD isn't a repo (`anyRootRepo`).
  - **`resolveGitDir`** mirrors ripgrep's `resolve_git_commondir`: a `.git`
    directory is the git dir; a `.git` **file** is followed through `gitdir: …`
  →
    its `commondir` (relative commondir joined to the worktree git dir,
  absolute
    used as-is), and `<commondir>/info/exclude` is loaded anchored to the
  worktree
    root. `isGitRepo` was refactored onto the shared `hasDotGit` probe so a CWD
    worktree gitfile is now detected too.

  Proven against real ripgrep as the oracle:
  `r1446_respect_excludes_in_worktree`
  (a worktree whose commondir exclude ignores one file) now diffs to **0
  bytes**
  vs `rg`.
- **`rg` honors ancestor ignore files and finds the git repo by ascent**
  (`bench/rgignore.zig`). ripgrep reads `.gitignore`/`.ignore` from every
  directory
  _above_ the search root and discovers `.git` at any ancestor; gist only read
  CWD-and-below, so searching from a repo subdirectory ignored the wrong set.

  - **`gitRootDepth`** ascends from CWD looking for `.git` (dir or worktree
  file),
    replacing the CWD-only `isGitRepo` — so a search run inside `repo/sub/` now
    enables VCS ignores from `repo/`'s `.gitignore` (`no_parent_ignore_git`).
  - **`loadParents`** walks each ancestor shallow→deep (deeper wins), reading
  its
    `.gitignore` (bounded to the git root) and `.ignore`/`.rgignore` (to `/`),
    skipped under `--no-ignore-parent`. An **anchored ancestor rule is
  re-anchored**
    onto the search subtree: `readFile`/`addLine` take a `strip` prefix (CWD's
  path
    relative to that ancestor) — a rule like `/parent/*.txt` seen from
  `parent/`
    becomes `*.txt`, and a rule targeting a sibling of CWD is dropped.
  Slash-less
    ancestor rules match a basename at any depth unchanged.

  Proven against real ripgrep as the oracle: `no_parent_ignore_git`,
  `r829_2778`,
  `r3173_hidden_whitelist_only_dot`, and `f1757` (a `.ignore` above the search
  root
  excluding `target/`) now diff to **0 bytes** vs `rg`.
- **`rg` now honors the `.gitignore` boundary — the single biggest drop-in gap
  closed** (`bench/rgignore.zig` (new), `bench/rgargs.zig`,
  `bench/rgcompat.zig`).
  gist was deliberately ignore-agnostic, so any ripgrep scenario with a
  `.gitignore`/`.ignore` searched a superset and diverged. The walk now applies
  the
  same "what's tracked" filter rg does, as a proper per-directory rule model
  rather
  than a bolt-on path test.

  - **Full gitignore dialect** (`rgignore.zig`, reusing `pathfilter.globMatch`
  so
    there's one glob dialect): leading/embedded `/` anchors to the ignore
  file's
    dir, a slash-less pattern matches a basename at any depth, a trailing `/`
    restricts to directories, `!pat` re-includes, and **last matching rule
  wins**
    with deeper dirs + `.ignore`/`.rgignore`/`--ignore-file` outranking a
  shallower
    `.gitignore`. Rules accumulate as the walk descends (loaded once per dir),
  and
    an ignored directory is _pruned_ — so `/*` + `!/dir` re-includes `dir`
  while
    keeping its siblings excluded, exactly like git.
  - **Hidden-file interaction**: a `!`-whitelisted dotfile is un-hidden
  (overrides
    the default dotfile skip), and `.git` is never walked.
  - **The `--no-ignore*` / `-u` control surface is now real**, not a no-op:
    `--no-ignore`, `--no-ignore-vcs` (VCS sources only), `--no-ignore-dot`,
    `--no-ignore-exclude`, `--no-ignore-files`, `--no-require-git` (honor
    `.gitignore` outside a repo), `--ignore-file <path>` (ordered, later wins),
    `--ignore-file-case-insensitive`; `-u`→`--no-ignore`, `-uu`→`+--hidden`.
  VCS
    rules (`.gitignore`, `.git/info/exclude`) apply only inside a git repo
  unless
    `--no-require-git`.

  Proven against real ripgrep as the oracle: this converts **~30 previously
  divergent cases to byte-exact PASS** (anchoring, negation/whitelist,
  precedence,
  `--ignore-file`, `--no-ignore-vcs`, per-dir `.ignore`, hidden whitelist),
  lifting
  supported-surface parity to 98.9% with no regression elsewhere.
- Initial scaffold mirroring `pkg/kernels/core` conventions: `build.zig`
  (static + dynamic libs, header install, `test` + `coverage` steps),
  `build.zig.zon`, flat C-ABI in `include/gist.h`, `src/root.zig`.
- `gist_trigram_count` C export — the deterministic cross-language parity
  oracle.

### Changed

- **Benchmark certify harness (`bench/certify.sh`) reformatted** to the repo
  shell style (2-space indent, one statement per line) and the macroscopic
  probe loop straightened so each class benches `gist` plus every competitor in
  a single pass. No change to the emitted `CERTIFICATE.md`, the macro CSV, or
  the bootstrap-CI / Mann-Whitney stats path.
- **CLI collapses six competitor-shaped verbs into three real ones, on a native
  flag vocabulary with a separated legacy alias layer**
  (`src/commands/search/`,
  `src/commands/status/`, `src/commands/cli/{main,schema}.zig`). The old
  surface
  (`index` · `query` · `regex` · `rank` · `grep` · `rg`) named _which
  competitor's
  argv it aped_, not what gist does — and `query`/`regex`/`rank`/`grep` were
  four
  verbs answering one question (_what matches, and how do you want it shaped_)
  over
  one engine. The new surface says what gist actually does:

  - **`gist search <pattern> [PATH…]`** — the one search verb. Pattern is
    auto-detected literal-or-regex (a literal is its own required literal, so
  it
    rides the same trigram prefilter — no second code path). Output shape is a
    **flag, not a verb**: `--show lines` (default, the byte-exact `rg -n`
    drop-in) / `--show files` (was `query`/`regex`) / `--show count` /
    `--rank [=N]` (was `rank`, top-K default 20). The dispatcher
    (`search/run.zig`) still routes each request to its fastest backend — the
    `drivers` fast paths for `--show files`/`--rank`, the full line engine
    (`emit.zig`) for the feature flags.
  - **`gist status`** — new, read-only introspection: whether an index exists,
    file / distinct-trigram / posting counts, on-disk size, build age vs the
    freshness anchor, and corpus roots. Answers "am I ready to search fast"
    before an agent commits to a query, with zero search work.
  - **`gist index`** — unchanged, the mutating build/refresh lifecycle action.

  **Two flag sets, one behavior each.** Set B (native) is the primary,
  documented
  vocabulary — `--show`, `--rank`, `--lang`, `--glob`, `--word`, `--fixed`,
  `--ignore-case`, `--smart-case`, `--invert`, `--before/--after/--context`,
  `--limit`, `--spans`, `--replace`, `--only-matching`, `--pattern`, plus two
  genuinely new capabilities: **`--live`** (skip the index, scan the live tree
  —
  the capability `gist rg` carried, without keeping a competitor-shaped verb)
  and
  **`--json`** (structured records, the one thing rgsuite marked NA against
  `rg --json`). Set A (legacy) is every `rg`/`grep` spelling an agent's muscle
  memory types — `-A/-B/-C -i -w -F -l -c -v -o -n -N -S -m -e -t -g -r`, the
  long
  forms, short-flag bundling, the no-op set, the fail-loud set — each an
  **alias
  onto exactly one native option**, split into its own module
  (`search/compat.zig`) so the ergonomic surface reads clean.

  **Agent discovery.** `gist --schema` emits a JSON capability manifest (verbs
  →
  flags → `{native_name, type, default, legacy_aliases, description}` + exit
  codes)
  so the two-set model is machine-checkable, not just prose — the seed for
  wiring
  gist into `services/ai/tools`.

  Dead-code shake per the refactoring rule: `src/commands/grep/` and
  `src/commands/cli/drivers.zig` are **deleted**, not deprecated-and-kept;
  their
  logic lives in `search/`. The `ripgrep/` differential-parity engine stays
  wired
  but **undocumented** (dropped from `--help`/`--schema`) — it's the `rgsuite`
  441-test harness plumbing, not a public verb. Every bench script
  (`_compete.sh`, `streams.sh`, `scan_regress.sh`) and the README are rewritten
  around `search`; `bench/rgsuite/run.py` still targets the internal `rg` path,
  so
  the parity certificate is unaffected. Native + legacy parsing is guarded by
  the
  superset test suite `search/args_test.zig`.
- **Cold / first-query win** (`bench/cli.zig`, `bench/coldquery.sh`): a
  one-shot
  CLI — `cli -- index` builds + persists the index (postings + a doc→path
  table) once; `cli -- query <needle>` is a **fresh process** that cold-loads
  the
  index (~30 ms) and reads & verifies **only the candidate files**. rg has no
  index, so every invocation re-walks the tree and reads every byte. Measured
  fresh-process via hyperfine (spawn included, warm cache): `queryLiteral`
  39ms→290ms (**7.4×**, 7 files read), `pgxpool` 47ms→274ms (**5.9×**, 399),
  `rate_limit` 46ms→293ms (**6.4×**), `func` 140ms→252ms (**1.8×**), `import`
  212ms→376ms (**1.8×**). rg now wins only the one-time build (~1.3 s) and a
  bare
  <3-byte needle (full read ⇒ tie). gist wins **every query after the first
  build — warm and cold.**
- **Cold regex query** (`bench/cli.zig`): `cli -- regex <pattern>` runs the T2
  Thompson NFA on the cold path — prefiltered on the regex's required literal
  (sound, so no true match is dropped), `docMatch`-verified per candidate with
  a
  per-thread `Sim` over the existing parallel read fan-out (the `Regex` is
  shared
  immutably; only the `Sim` scratch is per-thread). The literal `query` path is
  unchanged (its benchmark contract is preserved). Proven e2e: 11 regex shapes
  (incl. `[a-z]+_[a-z]+` at 12,803 files and `//\s*TODO` at 16)
  **byte-identical
  to `rg (?-u) -l`** over gist's exact indexed file list, 0 FN / 0 FP.
  Refactored
  the shared cold-load / candidate-resolve / emit into `loadPersisted` /
  `candidateIds` / `emitMatches` so literal + regex share one path.
- **Data-parallel verify** (`bench/bench.zig`): candidate verification and the
  <3-byte full-scan fallback fan out across 16 threads with **byte-balanced**
  sharding (equal bytes per thread, not equal file count — a few large files
  can't stall one worker while the rest idle). `func(` 14.9 ms → 3.1 ms, `func`
  12.0 ms → 3.7 ms, `})` full scan 59 ms → 7.2 ms.
- **Head-to-head harness** (`bench/headtohead.sh`): gist warm p50 vs `rg`'s
  *fastest* mode (native parallel walk, warmed, hyperfine median-of-8) per
  query.
  gist wins **every** query **47.6×–58,000×** (worst case the 2-byte `})`
  full-scan fallback at 47.6×).
- **Parallel build + counting sort** (`src/trigram.zig`): `Index.build` now
  fans
  trigram extraction across all cores (byte-balanced contiguous doc shards,
  each
  thread filling a private region — no contention) and replaces the O(n log n)
  comparison sort over ~22.8M postings with an O(n) **counting sort** on the
  24-bit trigram key. The count is stable and the concatenated postings are
  doc-major, so each bucket lands doc-ascending — **byte-identical** to the old
  index. Small corpora keep the single-threaded comparison sort (the 64 MiB
  histogram isn't worth it below 4 MiB). **6.5 s → 1.0 s (6.4×), 124 MiB/s**;
  re-proven sound by the equality oracle on the new path. Degrades gracefully
  to
  the serial path on any spawn/alloc failure.
- **Parallel cold read** (`bench/cli.zig`): the cold path is IO-bound (read
  every
  candidate's bytes), and it was the one place a heavy cold query could lose —
  rg reads multi-threaded, gist read single-threaded. Fanned the candidate
  read+verify across one `std.Thread` per core, each shard doing **blocking
  `std.posix` reads** into a reused `per_file_cap` scratch buffer (no per-file
  alloc; same cap as the indexer ⇒ byte-identical corpus). Cold head-to-head
  now:
  `import` 212→**155 ms** (1.9×), `func` 140→**109 ms** (2.4×),
  `context.Context`
  **58 ms** (4.9×), selective queries 40–44 ms (6.6–7.5×). gist wins **every**
  cold query 1.9×–7.5×. Posix read path proven faithful: `queryLiteral` (7) and
  `pgxpool` (401) match the index-based counts exactly.
  - **Negative result (recorded, not hidden):** the first cut fanned this out
  via
    `std.Io.Group.concurrent`. Measured on the macOS io backend it was **~6×
    slower** (`pgxpool` 43→252 ms, `import` 212→1305 ms) — fiber/scheduling
    overhead dwarfed the reads and the concurrent file IO didn't parallelize.
    Raw `std.Thread` + blocking syscalls (what `search.zig` already uses) is
  the
    proven-fast path; the io event loop is bypassed for the worker reads.
- **Race-free oracle** (`bench/equality.sh`, `verify` mode): the corpus is
  regenerated live by coworker agents, so reading a file once for gist's index
  and again for rg could see two versions (it did — a transient `\w+Request`
  "mismatch" on a file regenerated mid-run). `verify` now dumps a **byte-exact
  snapshot** of the indexed bytes and points rg at the snapshot, so any diff is
  a
  real semantic disagreement. Re-proven: **660 literals + 176 regexes across 4
  seeds, 0 FN / 0 FP**.
- **Ranking signals are now language-agnostic** (`bench/signals.zig`, extracted
  from
  `bench/cli.zig`). The two byte-level heuristics the T4 ranker consumes — the
  **definition boost** (`definesNeedle`) and **codegen demotion**
  (`isGenerated`) —
  hardcoded only the monorepo's seven languages, so on any other codebase the
  def-boost stayed flat (a search for a Ruby/Kotlin/C# symbol never recognized
  its
  declaration) and generated files weren't demoted. Now:

  - `definesNeedle` knows the declaration keywords of the **mainstream
  ecosystem**
    (Kotlin `fun`, Elixir `defmodule`/`defp`, Perl `sub`, Scala `object`, Swift
    `protocol`/`actor`/`extension`, `record`/`namespace`/`trait`/`impl`/…
  alongside
    the original `fn`/`func`/`def`/`class`/`struct`/…), so the def-first
  ordering
    fires on any repo.
  - `isGenerated` leans first on the **universal** first-line markers
  (`@generated`,
    `Code generated`, `DO NOT EDIT`, `AUTO-GENERATED`, … — language-independent
  and
    far more reliable than any suffix list) and broadens the suffix fast-path
  across
    ecosystems (`.pb.cc`, `.pb.h`, `_pb2_grpc.py`, `.g.dart`, `.designer.cs`,
    `.min.js`, …).

  Dogfooding the extraction caught a **real latent bug**: `definesNeedle` only
  checked the identifier boundary _before_ the needle, so searching `Wallet`
  treated
  `type WalletService struct` as its _definition_ (a prefix hit). It now
  requires a
  whole-word match on **both** sides. The signal still only ever reorders
  (never
  drops) a match, so it stays sound; the fix only sharpens the def-first order.
  New
  adversarial tests (`bench/signals_test.zig`) pin definition detection across
  ten
  languages, the use-vs-decl discriminators, and generated detection by suffix
  and
  by marker. Extracting the module also returns `bench/cli.zig` under the
  500-line
  shape cap (it had drifted to 554 with no `MONOLITHIC` marker).
- **SIMD substring scan** (`bench/simd.zig`): reading `std/mem.zig::findPos`
  shows `std.mem.indexOf` is SIMD only for a 1-byte needle — lengths **2–4**
  fall
  to `findPosLinear` (a naive byte loop) and 5+ to scalar Boyer-Moore-Horspool.
  Code search is dominated by 2–4 byte needles (`})`, `ctx`, `func`, `=>`,
  `::`,
  `fn`), so that naive path was the hot loss. `simd.contains` runs the memchr
  "generic SIMD": splat the needle's first + last byte, vector-compare both
  lanes
  across a V-wide window, AND the masks, and `eql`-verify only survivors.
  **Isolated single-thread full-corpus scan (125 MiB), std → SIMD MiB/s:** `})`
  2233→41051 (**18.4×**), `ctx` 2093→37735 (**18.0×**), `func` 2274→40713
  (**17.9×**), `=>` 1866→32019 (**17.2×**), `import` 6085→40757 (**6.7×**),
  `context.Context` 3560→19525 (**5.5×**) — std's ~2.2 GB/s naive path vs
  SIMD's
  ~40 GB/s. Wired into the parallel verify (`search.zig`) and the cold CLI
  (`cli.zig`). Byte-exact with `std.mem.indexOf`, proven by a 5000-case
  differential fuzz (`zig build test`, now wired) **and** the rg equality
  oracle
  (135 literals + 44 regexes, 0 FN / 0 FP, re-proven on the SIMD verify path).
- **Shape refactor**: extracted corpus loading into `bench/corpus.zig` and the
  parallel verify into `bench/search.zig`; the cold CLI lives in
  `bench/cli.zig`.
  Every file stays under the 500-line cap.
- **T3 freshness overlay** (`bench/fresh.zig`): keeps a persisted index correct
  against a working tree many agents rewrite many times a minute, without
  rebuilding and without consulting git history (the fragile part under heavy,
  overlapping, rebased commit churn). Insight: the cold query already reads &
  *verifies* every candidate against live bytes, so a stale/edited/deleted
  match
  is never a false **positive** — the only gap is a false **negative** (a file
  that now matches but wasn't a trigram candidate). So freshness only *widens*
  the candidate set with files touched since build; the existing verify does
  the
  rest. Anchor = the build's wall-clock instant (a `real` Io.Clock timestamp,
  same UTC-ns domain as file mtime); a file is fresh iff `mtime ≥ anchor`.
  Immune
  to commit chaos — rebases/overlaps/races never undo the fact that writing a
  file's bytes (incl. a `git checkout`/merge/pull landing a coworker's commit)
  advances its mtime — so it has no false negatives and cannot break, where
  `git diff HEAD` is *unsound* (a coworker commit already in HEAD shows no diff
  yet differs from our pre-commit index). The discovery stat-walk fans across
  the
  roots in parallel (private page-backed arenas, no shared-allocator
  contention).
  Proven end-to-end on a single probe file: a **new** file, a **modified** file
  whose new trigrams the index never saw, and a **deleted** file (stale posting
  reads-fails gracefully → no match, no crash) are each handled. Cold process
  wall **~42 ms vs ripgrep's ~555 ms (13×)**; worst-case cold-cache walk ~95 ms
  still ~6×. Backward compatible: no anchor file ⇒ freshness is skipped,
  behavior
  byte-identical to the pre-T3 cold path. `widen` dedup carries a unit test.
- **T4 fusion + rank** (`src/rank.zig`, `cli -- rank`): the lexical tiers
  return
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
  token-compressed `path:line [def|use] ×n  <line>`. Proven on real symbols:
  the
  `pub fn` definition of `queryLiteral` / `parallelVerify` /
  `extractSortedUnique`
  ranks **#1** above every call site, ~25–42 ms cold. rrf + signals carry 4
  unit
  tests (definition beats a 25×-hotter usage; external graph drives + is
  weight-controlled). Kernel suite 28/28.
- **T4 ranking now demotes codegen output** (`src/rank.zig`). A fourth RRF
  signal,
  `authored`, sinks generated files (`*_grpc.pb.go`, `*_pb2.py`,
  `*.connect.go`, …)
  below hand-written code. Found by dogfooding: `rank context.Context` returned
  a
  head of `*_grpc.pb.go` stubs because a generated file wins _both_ the lexical
  signal (most occurrences) and the definition boost (its boilerplate `func (c
  *…)`
  parses as a decl) — yet it is never an agent's edit target. The class split
  is
  fused tie-aware (authored docs share rank 0, generated docs share rank
  `n_authored`), so it is neutral _within_ a class and never re-votes the
  density/def order among real files; when a symbol lives only in generated
  files
  the demotion is uniform and the def-first order is untouched. Detection
  mirrors
  the repo shape gates (generated filename suffixes + first-line `// Code
  generated` / `@generated` markers). Match sets are unchanged — the gist ≡ rg
  oracle still proves 0 false negatives / 0 false positives. `rank` output
  gains a
  `[gen]` tag.
- **The engine now lives entirely under `src/`, split into concern-scoped
  tiers;
  `bench/` is the benchmark/verify harness only** — a clean separation of the
  product from the tooling that measures it. Engine logic had accreted inside
  `bench/` next to the latency harness; it moved out into six tiers, each a
  subfolder with its own `README.md`:

  - `src/index/` (**T0** trigram candidate index —
  `ngram`/`trigram`/`persist`),
    `src/regex/` (Thompson NFA + byte-class DFA + Pike VM), `src/rank/` (**T4**
  RRF
    fusion + language-agnostic signals), `src/scan/` (no-prefilter parallel
  verify
    — `simd`/`sweep`/`verify`), `src/corpus/` (loading + mtime freshness
  overlay),
    `src/commands/` (the CLI driver surfaces that compose the tiers).
  - The `rg` drop-in was **renamed off ripgrep's source layout onto its
  features**:
    the one `rgcompat` monolith became
  `src/commands/ripgrep/{args,ignore,output,
  json,run}.zig`, `rgemit` became `output.zig`, and `pathfilter` split into
    `src/commands/scope/{glob,types}.zig`. Each module is now named for what it
  _is_.
  - `build.zig` builds two artifacts on the shared kernel — the production
  `gist`
    CLI (`src/commands/cli/main.zig`) and a separate `gist-bench` harness
    (`bench/bench.zig`); they no longer share a binary.

  Pure structural move — every `*_test.zig` rides `src/root.zig` and the full
  suite
  (177 tests, incl. the differential Pike-VM fuzz oracle) stays green.
  Rule-of-Five
  registry entries record the `src/` tier fan-out and the harness-only
  `bench/`.

### Fixed

- **A `./root` positional no longer breaks anchored ignore matching**
  (`bench/rgignore.zig`). When the search root was given as `./some_dir`, gist
  prefixed every walked path with `./`, so an anchored rule (or a whitelist
  like
  `!/some_dir/build/`) failed to match and the path was mis-ignored.

  - **`match` normalizes a leading `./`** (new `stripDot`) on both the
  candidate
    path and the rule's `base` before comparing, so `./some_dir/build/foo` is
    matched identically to `some_dir/build/foo` — the anchored/negated rules
  now
    fire regardless of how the root was spelled. Output still keeps the `./`
  prefix
    ripgrep prints.

  Proven against real ripgrep as the oracle: `r829_2731` (`-l string
  ./some_dir`
  with a `build/` ignore + `!/some_dir/build/` whitelist) and `f1757`'s
  `./rust1`
  invocation now diff to **0 bytes** vs `rg`.
- **DFA compilation no longer churns the allocator on every subset-map probe,
  so
  compiling a pathological pattern is ~9× faster** (`src/regex/powerset.zig`).
  The
  determinizer interns each transition target into the subset map
  ~`states×ncls×2`
  times; a genuine blow-up probes it ≈86k times before bailing at `max_states`.

  - **`intern` now probes with a reusable scratch key** and heap-allocates a
    permanent key **only when the state proves genuinely new** — one alloc per
    interned state, not one alloc+free per probe. On a real fuzzer-surfaced
    cap-busting pattern this drops allocations from ≈86k to **4184** (≈
  `nstates`),
    and per-compile time from **~175ms → ~19ms** ReleaseFast (~5s → ~0.37s
  Debug).
  - Because interning duplicates is the common case in _any_ determinization,
  the
    win applies to every DFA compile, not just the pathological bail path.

  Proven with a before/after timing harness and pinned by a new deterministic
  regression guard (`powerset_test.zig`): a counting allocator asserts a
  cap-busting compile allocates `< 2×max_states` — it would jump ~20× if
  alloc-per-probe ever returns. Full regex suite (177 tests, incl. the
  differential
  Pike-VM fuzz oracle) stays green — no correctness change.
- **Query results now go to stdout, diagnostics to stderr** (`bench/cli.zig`,
  `bench/scan.zig`, `bench/corpus.zig`). The `query` / `regex` / `rank` paths
  printed _everything_ — match paths, ranked rows, and the timing summary —
  through `std.debug.print`, which writes to **stderr**. Found by dogfooding
  gist
  as an agent: `gist query Foo > files.txt` captured an **empty file** and
  `gist query Foo | head` mixed the `—` summary line into the paths — the
  opposite
  of the `rg` convention every agent and shell pipeline assumes. The match list
  (literal `query`), the ranked rows (`rank`), and the live-tree scan match set
  (`regex` / sub-trigram `query`) now emit on **stdout** via a raw
  `posix.write`
  loop (`corpus.emitStdout`, EPIPE-safe so `| head` exiting early can't crash
  the
  query); the human-facing `—` summary, the `[pipeline]` straggler canary, and
  the
  `no index` / `bad pattern` guidance stay on **stderr**. Match sets are
  byte-for-
  byte unchanged — the `gist ≡ rg` equality oracle (50 literals + 68 regexes)
  and
  the no-prefilter `scan_regress.sh` gate both still prove 0 false negatives /
  0 false positives, and every bench harness (which captures `2>&1` and splits
  by
  content shape) is unaffected. New permanent guard: `bench/streams.sh` asserts
  the results→stdout / diagnostics→stderr split across the literal, rank, and
  scan
  paths and reproduces the original empty-file bug as a falsifiable regression.
- **README benchmark prose + `regex/adversarial_test.zig`** — escaped the bare
  `_loaders_` / trailing-underscore emphasis in the cold-loader notes (markdown
  lint), and switched the rg second-oracle differential's temp-path `bufPrint`
  from `catch unreachable` to `try` so a formatting error propagates instead of
  panicking (zig-safety ratchet). No behavior change to the search path.
- **`--ignore-file` precedence + `-u`/`--require-git` semantics match ripgrep**
  (`bench/rgignore.zig`, `bench/rgargs.zig`). Three ignore-source ordering
  bugs:

  - **`--ignore-file` is now lowest precedence** — added _before_ the in-tree
    `.ignore`/`.gitignore` (not after), so a repo `.ignore` `!imp.log`
  correctly
    overrides an `--ignore-file` `*.log` (`f45_precedence_with_others`).
  - **`-u`/`--no-ignore` no longer disables `--ignore-file`** — the explicit
    `--ignore-file` sources are loaded before the `no_ignore` early-return,
  matching
    rg (an explicit ignore file is honored even unrestricted); only
    `--no-ignore-files` drops them, and **`--ignore-files`** re-enables them
    (`f1466_no_ignore_files`).
  - **`--require-git` now undoes `--no-require-git`** (last flag wins) instead
  of
    being a no-op, so `--no-require-git --require-git` again requires a real
  `.git`
    before honoring `.gitignore` (`f1414_no_require_git`).

  Proven against real ripgrep as the oracle: all three regressions diff to **0
  bytes** vs `rg`.
- **`.skip` search no longer drops a zero-width match at a bare boundary /
  EOL**
  (`src/regex/analysis.zig`, `src/regex/core.zig`). The first-byte `.skip`
  search
  seeds a start only at line position 0 and immediately _before_ a byte in the
  first-set — never at a bare word-boundary gap or at end-of-line. That is
  sound
  for a match that must consume a first byte, but a **conditionally-nullable**
  branch can match with no consumed byte at a position the skip never visits.
  So a
  pattern like `zzz|\b{4,6}$` or `q|\B{2}` — where one branch supplies a
  first-set
  (forcing `.skip`) while another matches zero-width via a word boundary —
  silently
  missed the zero-width branch. `reachesMatchEol` couldn't rescue it: it
  deliberately won't cross a `\b`/`\B`, so its `eol_empty` shortcut stays false
  for
  these _content-dependent_ EOL matches.

  Surfaced by the regex engine's own adversarial differential fuzzer against
  the
  `rg` oracle: `MATCH-DIVERGENCE pat=/^\S\w{2}|\b{4,6}$/` and
  `DOC-DIVERGENCE pat=/…|\B+\B{4,6}$/` (gist returned `false` where `rg`
  matched).

  Fix: a new conservative analysis predicate `reachesMatchZeroWidth` — does the
  start ε-reach `match` through a zero-width path that may cross _any_
  assertion
  (`^ $ \b \B`)? — sets a `Regex.nullable` flag, and `lineMatchPike` routes
  nullable
  patterns to the `.plain` search (which re-seeds every position, EOL included)
  instead of `.skip`. Sound by construction: a false "nullable" only forgoes
  the
  skip optimization, never a match, and genuinely consuming patterns
  (`func\s+\w+`, `pgxpool`, …) stay non-nullable on the fast `.skip` path. The
  full
  differential fuzz suite is green again; permanent regression coverage lands
  in
  `src/regex/core_test.zig` (the `z|\b{4,6}$` / `z|\B{2}` / `z|\b{2,}$`
  skip-mode
  cases, expectations cross-checked against `rg`).
- **`grep` closes four more reflexive-invocation gaps found by dogfooding gist
  _as
  the agent_ against `rg`** (`bench/grepargs.zig`, `bench/lines.zig`). Racing
  the
  two on real repo questions surfaced one silent-wrong landmine and three
  fail-loud-on-a-legal-call breaks — each of which an agent's muscle memory
  hits:

  - **`--count-matches` was a silent-wrong landmine — now a true match count.**
  It
    aliased to `-c`/`--count`, so it counted matching _lines_ where rg counts
    individual match _spans_ — on `e` in one file gist said `165` (lines) while
  rg
    said `988` (matches), a wrong-but-confident number (the worst agent
  failure).
    It now counts non-overlapping leftmost-first spans via the same span engine
    `-o` rides (a per-shard `SpanSim`, allocated only when the flag is set),
  while
    `-c`/`--count` stays line-count. `-m N` caps the total; `--count-matches
  -v`
    falls back to counting non-matching lines (rg's behavior — invert has no
  span
    to count). **Proven byte-identical to `rg --count-matches`** across 11
    literal + regex patterns over the shared `-g '*.go' services/backend` scope
    (up to 2 591 files each, 0 mismatches).
  - **Corpus-policy no-ops gist already satisfies are accepted, not
  fail-loud.**
    `--hidden`, `--no-ignore[-vcs/-parent/-dot/-global]`, `-u`/`-uu`/
    `--unrestricted`, `--one-file-system` all ask rg to widen its corpus toward
    what gist's index **already** searches (it ignores `.gitignore` and
  includes
    hidden dotfiles — README "Scope vs ripgrep"), so they're no-ops here, not
    errors. Proven to leave output byte-identical to the bare query.
  - **`--sort`/`--sortr` swallow their value (gist emits path-ascending
  already).**
    gist's `grep` output is sorted by path (a stable, deterministic order),
  which
    _is_ `--sort path` — the overwhelmingly common agent request — so the flag
  is
    a no-op that consumes its value instead of erroring.
  - **Recognized-but-unsupportable flags fail LOUD with the reason + `rg`
    fallback, not the generic "unknown flag" dump.** `-P`/`--pcre2` (PCRE
    backreferences/lookaround — gist runs a linear-time RE2-style engine),
    `-U`/`--multiline[-dotall]` (gist matches per line), and
    `--json`/`--vimgrep`/`--column` (gist emits fixed `path:line:text`) now
  print
    a one-line "why + use `rg …`" instead of leaving the agent to guess whether
  it
    typo'd or hit a real limit. Crucially still fail loud — never silently
  ignored
    (which would give a wrong result on a genuinely PCRE/multiline pattern).

  Correctness unchanged: the `gist ≡ rg` set oracle still proves **0 FN / 0
  FP**
  (140 literals + 70 regexes over the byte-identical snapshot), and the parser
  carries 4 new adversarial tests (count-matches ≠ count, the corpus no-op
  family,
  `--sort` value-swallow, the fail-loud contract for `-P`/`-U`/`--json`/…).
- **`rg -o` emits zero-width matches for a nullable pattern, matching rg's
  `find_iter`** (`bench/rgemit.zig`). gist's only-matching span loop
  unconditionally
  skipped empty spans, so `-o ''` (and other nullable patterns) produced
  nothing
  where ripgrep prints an empty `-o` line per zero-width match.

  - **`emitMatches`** now emits a zero-width match when the regex is
  **nullable**
    (`re.nullable`), following rg's progress rule — an empty match adjacent to
  the
    previous match's end is skipped, empties advance one byte — and honoring
  `-w`
    (word-boundary check on the empty span). A **non-nullable** pattern never
    produces an empty span, so its output is byte-identical to before: **zero
    regression risk** for every previously-passing `-o`/`-w` case (verified: no
    passing test regressed).

  Proven against real ripgrep as the oracle: `r1891` (`-won ''` over `"\n##\n"`
  →
  one empty match on the blank line, three on `##`) now diffs to **0 bytes** vs
  `rg`, taking the drop-in to **100% supported-surface parity (265/265)**.
- **`rg` drop-in matches ripgrep's stdin heuristic exactly — the socket fd type
  is
  no longer a silent divergence** (`bench/rgcompat.zig`). ripgrep decides to
  search
  stdin (vs. walking `./`) with `!is_terminal(fd0) && (is_file || is_fifo ||
  is_socket)` (grep/cli `is_readable_stdin`). gist's `readableStdin`
  whitelisted
  only regular files and FIFOs, so `sock_producer | gist rg pat` — and, more
  commonly, any exec API that wires fd0 to a `socketpair` — fell through to a
  directory walk while real `rg` searched the stream. Added `S.IFSOCK` to the
  whitelist; the three-type set still excludes a tty and `/dev/null` (a char
  device), so bare `rg pat` and `rg pat </dev/null` keep walking `./`.

  **Proven byte-identical to `rg` across all four fd types** (socket, pipe,
  regular-file, `/dev/null`) via a `socketpair`-backed differential probe:
  socket
  and pipe search the stream (`match here`, rc 0), `/dev/null` and a bare tty
  walk
  the CWD, a redirected regular file searches that one source.
  Supported-surface
  parity over the 330 mined ripgrep tests stays **61/61 = 100%**.

  Note: the "`rg foo` appears to hang" failure mode in exec-spawned shells (a
  pipe/socket wired to fd0 that never sends data or EOF) is ripgrep's own
  documented, unmitigable heuristic — its source calls it "a terrible failure
  mode, but there really is no good way to mitigate it" (core/flags/hiargs.rs).
  gist now reproduces it faithfully; non-interactive callers should redirect
  `</dev/null` exactly as they would for `rg`.
