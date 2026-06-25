# gist

A fast, regex-first, **agent-friendly** code locator kernel for the Billy
monorepo (Zig, flat C-ABI — mirrors [`lamina`](../lamina/README.md) /
[`principia`](../principia/README.md)). This is build-time dev tooling for the
coding agents that work _on_ Billy; it is unrelated to Billy-the-product.

## Why it exists

`ripgrep` is near-optimal at _unindexed_ scan (~0.3s warm on Billy's source when
scoped). The agent pain it cannot fix — proven by dogfooding the current tools
against real questions about this repo — is elsewhere:

- **scope**: a naive `rg` from repo root hangs >55s on 99 GB of `target/` +
  caches; scoping is shell-fragile.
- **intent**: finding "rate limiting in the gateway" requires _guessing_ the
  exact word — `rate.?limit` hits, `throttle`/`quota`/`leaky` return nothing.
- **shape**: regex cannot express "functions taking `ctx context.Context`"
  without 3 hand-written variants that still undercount (546 vs 5783).
- **output**: agents pay tokens for flat, unranked lines or 150-line chunks.

gist targets those: a candidate **index** (don't rescan), correct **scope**,
**intent**-aware entry, and **ranked, token-compressed** output — fusing with
Billy's existing graph ([`graphify`](../../../scripts/observe/workspace/graph))
and contracts. The frontier survey + decision trail live in
[`research/dossiers/locator-sota.dossier.toml`](../../../research/dossiers).

## Tiers (staged, each proven before the next)

| Tier                          | State                  | What                                                                                                                                                                                                                              |
| ----------------------------- | ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **T0 trigram index**          | ✅ (`src/trigram.zig`) | positional-trigram candidate filter — sound superset of literal matches, queried by binary search; the proven baseline. Build is parallel (16-core extraction + O(n) counting sort), 1.0 s over 125 MiB                           |
| **T1 rarest-first + persist** | ✅ (`src/trigram.zig`) | resolve every trigram's posting range, seed from the _rarest_, intersect outward (killed the `context.Context` tail 530µs→9µs at libs scale); on-disk serialize/`fromBytes` so a session builds **once** and warm-starts in ~28ms |
| **T2 regex**                  | ✅ (`src/regex.zig`)   | linear-time **Thompson NFA** over bytes (RE2/ripgrep philosophy — no catastrophic backtracking) + sound required-literal extraction so a regex reuses the T0 prefilter — including a **multi-literal cover set** for alternations (`foo\|bar\|baz` prefilters on the UNION of all three, not a scan). The no-literal full-scan path is accelerated to the metal: an **anchored fast path** (`^…` seeds only at line start), a **first-byte skip** (SIMD `memchr`/range scan to the next byte that can _begin_ a match) so the Pike search skips dead spans instead of stepping every byte, and — for the **dense** case the skip can't help (`\w{3,8}`, where `\w` covers most bytes) — a **bit-parallel Glushkov engine** (`src/regex_bitparallel.zig`): the active-position set is one machine word advanced by a handful of bit ops per byte (O(popcount)/byte, no scratch), the structural answer to rg's lazy DFA for small dense programs. It's gated to anchor-free, word-sized programs and dispatched only when the first-byte set is too dense for the skip; everything else stays on the Pike VM, which remains the correctness reference. Proven byte-identical to `rg (?-u)` **and** divergence-free vs the Pike VM across a 40k-case differential fuzz (random grammar × random inputs); cold head-to-head (`bench/regex_headtohead.sh`) wins every prefilterable tier 1.4–3.1× and races on the no-literal tail. The same slate also clocks `ag` (the_silver_searcher, PCRE): gist beats it 15/16 (`ag` trails 1.5–5.2×), the lone exception being the prefilter-less 2-byte mixed alternation `panic\|0x` |
| **T3 freshness overlay**      | ✅ (`bench/fresh.zig`) | keeps a persisted index correct under heavy concurrent commit churn **without rebuilding or consulting git**. Anchor = the build's wall instant; a file is fresh iff `mtime ≥ anchor`, so any changed/new/touched file (incl. a coworker's commit landing via `git checkout`) is folded into the candidate set and re-verified — zero false negatives, read-your-own-writes, and immune to rebases/overlaps that break `git diff`. Parallel stat-walk; **~42 ms cold vs rg ~555 ms** |
| **T4 fusion + rank**          | ✅ (`src/rank.zig`)    | weighted **Reciprocal Rank Fusion** over {lexical density, symbol/definition boost, shallow-path} + an optional external ranking (the graphify graph-centrality hook); `cli -- rank <needle>` emits ranked, token-compressed `path:line [def\|use] ×n  <line>` — a symbol's **definition outranks its call sites** (the win rg can't express). Embeddings stay opt-in only (CoREB: short queries collapse them) |

## Proof (every claim falsifiable, run it yourself)

```bash
bench/equality.sh 150 1      # gist ≡ rg over a byte-exact corpus SNAPSHOT, per needle
bench/headtohead.sh          # gist WARM p50 vs rg + ag (the_silver_searcher) fastest mode, per literal
bench/coldquery.sh           # gist COLD (fresh process, persisted index) vs rg + ag, per literal
bench/regex_headtohead.sh    # gist COLD vs rg (?-u) + ag (PCRE) per REGEX, grouped by feature tier
zig build -Doptimize=ReleaseFast bench   # build cost, footprint, latency p50/p95/p99
```

`equality.sh` has gist emit its verified matching-file set per pattern **plus a
byte-exact snapshot of the files it indexed** (the corpus is regenerated live by
coworker agents — the snapshot freezes the bytes so the diff can't race), then
runs `rg` over that identical snapshot and diffs. A file in rg's set but not
gist's = a trigram-filter false negative (the one unforgivable bug); a file in
gist's but not rg's = an unsound verify. Both must be zero.

**Measured (≈16.5k files · 125 MiB · `services libs clients contracts scripts quality`):**

- **Correctness:** 660 random+adversarial literals + 176 regexes across 4 seeds
  → **0 false negatives, 0 false positives** vs ripgrep over the byte-identical
  snapshot (re-proven on the parallel/counting-sort build path).
- **Build once, query forever:** parallel extraction (16 cores) + an O(n)
  **counting sort** on the 24-bit trigram key (stable ⇒ byte-identical to the
  comparison-sorted index) → **1.0 s build (6.4× faster than the old 6.5 s),
  124 MiB/s** · 174 MiB index (1.39× corpus) · serialize 83 ms · **cold-load
  31 ms (32× faster than even the now-faster rebuild)**.
- **Beats `rg` at its _best_** — vs `rg`'s fastest mode (native parallel walk,
  warmed, hyperfine median-of-8), gist's warm full-pipeline p50 wins **every
  query, 47.6×–58,000×**: `queryLiteral` 0.73ms→340ms (**466×**),
  `context.Context` 1.1ms→352ms (**311×**), `pgxpool` 1.7ms→339ms (**194×**),
  `import` 2.7ms→316ms (**116×**), `func(` 3.1ms→271ms (**88×**), a literal
  _miss_ `zzqxv` 5µs→293ms (**~58,000×**), and even the 2-byte `})` full-scan
  fallback 7.2ms→344ms (**47.6×**).
- **The verify scales with cores.** Candidate verification (and the <3-byte
  full-scan fallback) fans out across 16 threads with **byte-balanced** sharding
  (equal bytes/thread, not equal file count — a few large files can't stall one
  worker): `func(` 14.9ms→3.1ms, `func` 12.0ms→3.7ms, `})` 59ms→7.2ms.
- **Wins the *cold / first* query too** (`bench/coldquery.sh`). Build the index
  once (persisted), then each query is a **fresh process** that cold-loads the
  index (~30 ms) and reads only the *candidate* files — across one `std.Thread`
  per core, blocking-`posix` reads — vs rg, which re-walks the whole tree and
  reads every byte on every invocation. Measured fresh-process via hyperfine
  (process spawn included, warm cache): `queryLiteral` 40ms→297ms (**7.5×**, read
  8/16.7k files), `pgxpool` 44ms→293ms (**6.6×**, 401 files), `rate_limit`
  42ms→291ms (**7.0×**), and even common tokens that touch thousands of
  candidates win — `func` 109ms→264ms (**2.4×**), `import` 155ms→290ms
  (**1.9×**). rg only ever wins the **one-time** initial build (~1.0 s) and a
  bare <3-byte needle (no trigram filter ⇒ full read ⇒ a tie).
- **Raced against `ag` (the_silver_searcher) too**, on its honest fastest path —
  handed `--path-to-ignore .gitignore`, the root ignore set `rg` reads for free
  (without it `ag`'s walk has no repo-root gitignore and grinds through the
  gitignored ~99 GB: 0.46 s scoped vs minutes unscoped). Across the 37 measured
  queries `gist` wins all but one and `rg` beats `ag` on **36/37**: `ag` trails
  `rg` by ~1.6–2.1× on every literal (warm + cold) and on 15/16 regexes. The
  **one** query `ag` wins is the no-prefilter mixed alternation `panic|0x` —
  `ag` 483 ms vs `rg` 675 ms (**1.40×**) — the very pattern where `gist`'s Pike
  VM is weakest (1173 ms), since a 2-byte branch denies every engine a literal
  prefilter. The `rg≷ag` column + per-script tally in the bench scripts surface
  this directly.

The win is **architectural and raw**: gist is a resident (or instantly
cold-loaded) index behind a rarest-first trigram prefilter, then a parallel
SIMD-class verify that touches only candidate bytes; `rg` and `ag` are both
unindexed scanners that pay per-invocation spawn + a full FS-walk + a full scan
_every time_ (`ag` strictly slower than `rg` here, save the one alternation).
Build once — gist wins every query after, warm (47×–58,000×) or cold (1.8×–7.4×).

## Build

```bash
cd pkg/kernels/gist
zig build test        # unit tests (T0 index · T1 persist · T2 regex NFA)
zig build             # emit libgist.{a,dylib} + include/gist.h into zig-out/
zig build bench       # corpus build/footprint + full-pipeline latency percentiles
zig build verify -- 150 1   # emit gist match sets + corpus snapshot for the rg oracle
zig build cli -- index            # build + persist the index once
zig build cli -- query <needle>   # fresh-process cold literal query (candidate-only IO)
zig build cli -- regex <pattern>  # cold regex query: NFA verify, `(?-u)` byte semantics
zig build cli -- rank <needle>    # ranked, token-compressed output (def outranks call sites)
zig build coverage    # tests under kcov → .local/coverage/ (needs kcov on PATH)
```

## C ABI (`include/gist.h`)

- `gist_abi_version() -> u32`
- `gist_trigram_count(text, len, out) -> usize` — distinct ascending trigrams (parity oracle)

The `Index` (build/query) is Zig-native this cut; the cgo/cffi bindings land
with T1 alongside the `tests/parity_gen.zig` corpus oracle.
