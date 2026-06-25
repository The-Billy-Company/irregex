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
| **T2 regex**                  | ✅ (`src/regex.zig`)   | linear-time **Thompson NFA** over bytes (RE2/ripgrep philosophy — no catastrophic backtracking) + sound required-literal extraction so a regex reuses the T0 prefilter — including a **multi-literal cover set** for alternations (`foo\|bar\|baz` prefilters on the UNION of all three, not a scan). The no-literal full-scan path is accelerated to the metal: an **anchored fast path** (`^…` seeds only at line start), a **first-byte skip** (SIMD `memchr`/range scan to the next byte that can _begin_ a match) so the Pike search skips dead spans instead of stepping every byte, and — for the **dense** case the skip can't help (`\w{3,8}`, where `\w` covers most bytes) — a **bit-parallel Glushkov engine** (`src/regex_bitparallel.zig`): the active-position set is one machine word advanced by a handful of bit ops per byte (O(popcount)/byte, no scratch), the structural answer to rg's lazy DFA for small dense programs. It's gated to anchor-free, word-sized programs and dispatched only when the first-byte set is too dense for the skip; everything else stays on the Pike VM, which remains the correctness reference. Proven byte-identical to `rg (?-u)` **and** divergence-free vs the Pike VM across a 40k-case differential fuzz (random grammar × random inputs). Cold head-to-head over a 22-pattern slate (`bench/regex_headtohead.sh`) vs the **seven-tool field**: gist lands **≈ csearch and faster than zoekt** (the two indexed RE2 engines), **≥ rg**, and 2–5.5× over ugrep/ag/GNU-grep — the formerly-losing dense floor `\w{3,8}` now beats both indexed rivals (csearch 1.1×, zoekt 2.1×). See the Proof section |
| **T3 freshness overlay**      | ✅ (`bench/fresh.zig`) | keeps a persisted index correct under heavy concurrent commit churn **without rebuilding or consulting git**. Anchor = the build's wall instant; a file is fresh iff `mtime ≥ anchor`, so any changed/new/touched file (incl. a coworker's commit landing via `git checkout`) is folded into the candidate set and re-verified — zero false negatives, read-your-own-writes, and immune to rebases/overlaps that break `git diff`. Parallel stat-walk; **~42 ms cold vs rg ~555 ms** |
| **T4 fusion + rank**          | ✅ (`src/rank.zig`)    | weighted **Reciprocal Rank Fusion** over {lexical density, symbol/definition boost, shallow-path} + an optional external ranking (the graphify graph-centrality hook); `cli -- rank <needle>` emits ranked, token-compressed `path:line [def\|use] ×n  <line>` — a symbol's **definition outranks its call sites** (the win rg can't express). Embeddings stay opt-in only (CoREB: short queries collapse them) |

## Proof (every claim falsifiable, run it yourself)

gist is raced against a **seven-tool field** — two other *indexed* searchers
(`csearch`, Russ Cox's Google Code Search, gist's direct trigram ancestor;
`zoekt`, Sourcegraph's production indexed search) and five unindexed scanners
(`rg`, `ugrep`, `ag`, GNU `grep`, `git grep`), each on its honest fastest path.
The field, the fairness scoping, and the per-tool invocations all live in
[`bench/_compete.sh`](bench/_compete.sh).

```bash
bench/equality.sh 150 1      # gist ≡ rg over a byte-exact corpus SNAPSHOT, per needle
bench/headtohead.sh          # WARM: gist resident p50 vs the unindexed scanners
bench/coldquery.sh           # COLD literal: gist vs csearch/zoekt + rg/ugrep/ag/ggrep/git-grep
bench/regex_headtohead.sh    # COLD regex: same field, per feature tier
zig build -Doptimize=ReleaseFast bench   # build cost, footprint, latency p50/p95/p99
```

`equality.sh` has gist emit its verified matching-file set per pattern **plus a
byte-exact snapshot of the files it indexed** (the corpus is regenerated live by
coworker agents — the snapshot freezes the bytes so the diff can't race), then
runs `rg` over that identical snapshot and diffs. A file in rg's set but not
gist's = a trigram-filter false negative (the one unforgivable bug); a file in
gist's but not rg's = an unsound verify. Both must be zero. Ratios below are
`hyperfine` geomeans over the slate — robust to this shared dev box's load,
since each query's tools run back-to-back under identical conditions.

**Measured (17,112 files · 126.5 MiB · `services libs clients contracts scripts quality`):**

- **Correctness:** the expanded oracle (50 literals + 68 regexes at battery 30;
  hundreds more across seeds) is **0 false negatives / 0 false positives** vs
  ripgrep over the byte-identical snapshot. `csearch`, indexing gist's *exact*
  16,696-file corpus, returns the same sets (it is the faithful indexed twin).
- **Index economics — gist builds fastest, indexes leanest of the trigram pair:**
  gist **1.2 s build · 177 MiB index**; csearch **8.2 s · 28 MiB** (over gist's
  exact file list); zoekt **5.6 s · 346 MiB / 6 shards** (it embeds file content
  + ctags symbols). gist's index is the heavyweight of the three — the lever
  behind the one race it loses, below.
- **WARM resident — gist's home turf, uncontested.** In a long-lived agent
  session gist answers from a RAM-resident index; the scanners re-walk + re-read
  every time. Geomean speedup over 15 needles: **rg 1,395× · ag 2,194× · git grep
  1,028× · GNU grep 4,764× · ugrep 5,992×** (all 15/15), up to **270,000×** on a
  guaranteed miss (`zzqxv`, gist 1µs). The indexed rivals have **no resident
  CLI** — csearch/zoekt reload their whole index on every invocation — so in a
  session gist's sub-ms query is ~25–800× faster per query than even them.
- **COLD one-shot vs every unindexed scanner — gist wins all.** Each query is a
  fresh process: gist cold-loads its index (~30 ms) and reads only the
  *candidate* files; rg/ugrep/ag/grep re-walk the whole tree. Geomean: **ugrep
  9.2× · GNU grep 7.1× · ag 3.5× · rg 2.3× · git grep 1.9×** (gist wins 10–11/11).
- **COLD one-shot literal vs the indexed rivals — gist currently trails, and we
  say why (no vibes).** csearch is ~3× faster on selective needles (`pgxpool`
  17 ms vs gist 106 ms), zoekt ~2× across the board — geomean csearch **0.3×**,
  zoekt **0.5×**. Two honest causes: gist (a) **deserializes its 177 MiB index**
  (30 ms) where csearch *mmaps* 28 MiB, and (b) runs a **corpus-wide T3 freshness
  stat-walk** for read-your-writes correctness under concurrent commit churn —
  work csearch/zoekt skip entirely (they go stale until re-indexed). Even so gist
  *beats* csearch on the dense / 2-byte needles its prefilter can't help (`})`
  **1.5×**, `import` ties), where csearch's grep-verify over a huge candidate set
  costs more. **Next rung (recorded, not hidden):** mmap the index to kill the
  30 ms deserialize, and make the freshness walk incremental.
- **COLD regex — gist is competitive-to-winning against the indexed rivals.** The
  required-literal / alternation-cover prefilter + the first-byte skip + the
  bit-parallel Glushkov engine put gist **≈ csearch (0.9× geomean, ahead on
  14/22 patterns)** and **faster than zoekt (1.4×, 13/22)** across 22 tiers; the
  old dense floor `\w{3,8}` now **beats csearch (1.1×) and zoekt (2.1×)**, and
  gist crushes zoekt on anchored shapes (`^func\s` 2.4×). Vs unindexed: **≥ rg
  (1.3×, 15/22) · ag 2.0× · GNU grep 3.1× · ugrep 5.5×**, tying git grep.

The shape of the result is honest and architectural: **gist owns the
agent-session workload it was built for** — a resident index answering in
microseconds (1,000–6,000× over every scanner), or a cold one-shot that beats
every unindexed tool by reading only candidate bytes instead of re-walking the
tree. Against the two mature *indexed* engines it splits: gist matches/beats them
on **regex** (prefilter + bit-parallel automaton) but trails them on the **cold
literal one-shot**, the price of a richer index (2× smaller than zoekt's, but
fully deserialized) and a freshness guarantee neither csearch nor zoekt offers.
Build once — gist wins every query after, warm always, cold against every
unindexed grep, with the indexed cold-load gap mapped to its two fixable causes.

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
