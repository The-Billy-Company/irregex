# gist

A fast, regex-first, **agent-friendly** code locator kernel for the Billy
monorepo (Zig, flat C-ABI — mirrors [`lamina`](../lamina/README.md) /
[`principia`](../principia/README.md)).

> **Scope:** this is build-time dev tooling for the coding agents that work _on_
> Billy. It has nothing to do with Billy-the-product.

## What it is

`gist` is a persistent code-search engine built for the way an agent actually
searches a large repo: ask many small questions over a long session, against a
tree that other agents are concurrently editing, and pay tokens for every line
of output. It builds a trigram **index once**, then answers each query by
touching only the files that can possibly match — instead of re-walking and
re-reading the whole tree like `grep`/`ripgrep` do on every invocation.

It is a kernel, not a binary you install: a Zig library with a flat C-ABI and a
thin reference CLI (`zig build cli`). The intended consumer is Billy's agent
tooling, which embeds the library and fuses gist's output with an external code
graph and the contract registries.

## Why it exists

`ripgrep` is near-optimal at _unindexed_ scan (~0.3 s warm on Billy's source
when scoped). The agent pain it can't fix — proven by dogfooding the existing
tools against real questions about this repo — is everywhere else:

- **scope** — a naive `rg` from repo root crawls >55 s over 99 GB of `target/`
  + caches; getting the scope right is shell-fragile and easy to get wrong.
- **re-work** — an agent runs dozens of searches per session; every one pays the
  full walk-and-read cost again. There's no memory between queries.
- **freshness** — coworker agents land commits mid-session. A stale index lies;
  `git diff`-based invalidation breaks under rebases and overlapping edits.
- **ranking** — agents don't want an unordered set of files, they want the *one*
  line that answers the question first (a symbol's **definition**, not its 200
  call sites) and pay tokens for everything below it. `grep` can't express that.

`gist` targets exactly those: a persistent **index** (don't rescan), a
zero-false-negative **freshness** guarantee (read-your-own-writes under churn),
and **ranked, token-compressed** output. The frontier survey and decision trail
live in
[`research/dossiers/locator-sota.dossier.toml`](../../../research/dossiers).

## How it works

The pipeline is four cooperating pieces, each a sibling file under `src/`:

**Trigram candidate index** (`src/trigram.zig`). Any file containing a literal
must contain every trigram of that literal, so the AND of the per-trigram
posting lists is a *sound* candidate set — a superset of the true matches,
computed by binary search with no scanning. It's a **filter, not a matcher**:
false positives are expected and verified away; false negatives (the one
unforgivable bug) are impossible for literals ≥ 3 bytes. The build fans
extraction across all cores into private regions, then orders postings with an
O(n) counting sort on the 24-bit key (~1.2 s over 126 MiB). Queries resolve each
trigram's posting range, **seed from the rarest** gram, and intersect outward —
which collapses dense tails (e.g. `context.Context` went 530 µs → 9 µs at libs
scale).

**Zero-copy persistence.** The index serializes to a flat, native-endian blob
and loads back via `mmap` — the posting table aliases the mapped pages directly,
so a cold first query faults in only the handful of pages the binary search
probes (~0.4 ms) instead of reading + allocating + copying the 100+ MiB table.
Build once per session, warm-start every process after.

**Regex** (`src/regex/`). A linear-time **Thompson NFA** over bytes (the
RE2/ripgrep philosophy — no catastrophic backtracking) with sound
required-literal extraction, so a regex reuses the trigram prefilter, including a
**multi-literal cover set** for alternations (`foo|bar|baz` prefilters on the
union of all three). When a pattern has no usable literal, the full-scan path
runs on an immutable **byte-class DFA** (`src/regex/dfa.zig`) that spends one
table lookup per byte regardless of match density — anchors and all — in a
single fused pass that detects newlines inline. The Pike VM stays the capped
fallback and the differential-fuzz correctness reference. See
[`src/regex/README.md`](src/regex/README.md).

**Freshness overlay** (`bench/fresh.zig`). Keeps a persisted index correct under
heavy concurrent commit churn **without rebuilding or consulting git**. The
build stamps a wall-clock anchor; a file is fresh iff `mtime ≥ anchor`, so any
changed, new, or touched file — including a coworker's commit landing via `git
checkout` — is folded into the candidate set and re-verified. Zero false
negatives, read-your-own-writes, immune to the rebases and overlapping edits that
defeat `git diff` (parallel stat-walk, ~42 ms cold).

**Ranking** (`src/rank.zig`). Turns the verified match set into the list an agent
wants via weighted **Reciprocal Rank Fusion** (Cormack et al. 2009) over three
intrinsic signals — lexical density, a **definition boost** (a match on a decl
line outranks its call sites — the win `grep` can't express), and shallow-path
centrality — plus an optional external ranking (a graph-centrality hook).
`rank` emits token-compressed `path:line [def|use] ×n  <line>`.

## Quickstart

```bash
cd pkg/kernels/gist

zig build cli -- index            # build + persist the index once (~1.2 s)
zig build cli -- query <needle>   # cold literal query — reads only candidate files
zig build cli -- regex <pattern>  # cold regex query (`(?-u)` byte semantics)
zig build cli -- rank <needle>    # ranked, token-compressed output (def first)
```

`index` writes the index, the doc→path table, and the freshness anchor. Every
later `query`/`regex`/`rank` is a fresh process that `mmap`s the index, resolves
candidates in RAM, then touches disk for only the candidate files — dozens of
small reads for a selective query instead of ~16.5k. A `<3-byte` needle has no
trigram filter and degenerates to a full read (the one case gist merely matches
`rg`).

Supported regex syntax: literals `.` `[]` `[^]` `a-z` `*` `+` `?` `{n,m}` `|`
`()` `^` `$` and the classes `\d \w \s \t \n \r` — see `src/regex/syntax.zig`.

## Build & test

```bash
zig build test                    # unit tests (index · persist · regex NFA + DFA · RRF)
zig build                         # emit libgist.{a,dylib} + include/gist.h into zig-out/
zig build bench                   # corpus build/footprint + full-pipeline latency p50/p95/p99
zig build verify -- 150 1         # emit gist match sets + corpus snapshot for the rg oracle
zig build coverage                # tests under kcov → .local/coverage/ (needs kcov on PATH)
```

## Proof (every claim falsifiable — run it yourself)

gist is raced against a **seven-tool field**: two other *indexed* searchers
(`csearch`, Russ Cox's Google Code Search, gist's direct trigram ancestor;
`zoekt`, Sourcegraph's production indexed search) and five unindexed scanners
(`rg`, `ugrep`, `ag`, GNU `grep`, `git grep`), each on its honest fastest path.
The field, fairness scoping, and per-tool invocations live in
[`bench/_compete.sh`](bench/_compete.sh).

```bash
bench/equality.sh 150 1      # gist ≡ rg over a byte-exact corpus SNAPSHOT, per needle
bench/headtohead.sh          # WARM: gist resident p50 vs the unindexed scanners
bench/coldquery.sh           # COLD literal: gist vs csearch/zoekt + the unindexed five
bench/regex_headtohead.sh    # COLD regex: same field, per feature tier
```

`equality.sh` has gist emit its verified matching-file set per pattern **plus a
byte-exact snapshot of the files it indexed** (the corpus is regenerated live by
coworker agents — the snapshot freezes the bytes so the diff can't race), runs
`rg` over that identical snapshot, and diffs. A file in rg's set but not gist's =
a trigram false negative (the one unforgivable bug); a file in gist's but not
rg's = an unsound verify. Both must be zero.

**Measured (17,112 files · 126.5 MiB · `services libs clients contracts scripts quality`):**

- **Correctness** — the oracle (50 literals + 68 regexes at battery 30, hundreds
  more across seeds) is **0 false negatives / 0 false positives** vs ripgrep over
  the byte-identical snapshot. `csearch`, indexing gist's *exact* 16,696-file
  corpus, returns the same sets.
- **Index economics** — gist **1.2 s build · 177 MiB index**; csearch
  **8.2 s · 28 MiB**; zoekt **5.6 s · 346 MiB**. gist builds fastest; its index
  is the heavyweight of the three (the lever behind the one race it loses, below).
- **WARM resident — gist's home turf, uncontested.** In a long-lived session gist
  answers from a RAM-resident index while the scanners re-walk every time.
  Geomean speedup over 15 needles: **rg 1,395× · ag 2,194× · git grep 1,028× ·
  GNU grep 4,764× · ugrep 5,992×** (all 15/15), up to **270,000×** on a guaranteed
  miss. The indexed rivals have no resident CLI (they reload their whole index
  per invocation), so in a session gist is ~25–800× faster per query than even them.
- **COLD one-shot vs every unindexed scanner — gist wins all.** Fresh process,
  cold-load (~30 ms), read only candidate files. Geomean: **ugrep 9.2× · GNU grep
  7.1× · ag 3.5× · rg 2.3× · git grep 1.9×** (gist wins 10–11/11).
- **COLD one-shot literal vs the indexed rivals — gist currently trails, and we
  say why (no vibes).** Geomean csearch **0.3×**, zoekt **0.5×**. Two honest
  causes: gist (a) **deserializes/maps its 177 MiB index** where csearch mmaps
  28 MiB, and (b) runs a corpus-wide freshness stat-walk for read-your-writes
  correctness — work the rivals skip entirely (they go stale until re-indexed).
  Even so gist *beats* csearch on dense / 2-byte needles its prefilter can't help
  (`})` **1.5×**, `import` ties). **Next rung (recorded, not hidden):** make the
  freshness walk incremental.
- **COLD regex — gist is competitive-to-winning against the indexed rivals.** The
  literal/alternation-cover prefilter + the single-pass byte-class DFA put gist
  **≈ csearch** and **faster than zoekt** across 22 tiers (crushing zoekt on
  anchored shapes, `^func\s` 2.4×). Vs unindexed: **≥ rg on ~19/22 · ag 2.0× ·
  GNU grep 3.1× · ugrep 5.5×**, tying git grep. The no-prefilter scan tail now
  sits **at rg's own scan floor**.

The shape of the result is honest and architectural: **gist owns the
agent-session workload it was built for** — a resident index answering in
microseconds, or a cold one-shot that beats every unindexed tool by reading only
candidate bytes. Against the two mature *indexed* engines it splits: gist
matches/beats them on **regex** but trails on the **cold literal one-shot** — the
price of a richer index (2× smaller than zoekt's, but fully mapped) and a
freshness guarantee neither csearch nor zoekt offers.

## C ABI (`include/gist.h`)

- `gist_abi_version() -> u32`
- `gist_trigram_count(text, len, out) -> usize` — distinct ascending trigrams
  (the cross-language parity oracle)

The `Index` (build/query) is Zig-native this cut; the cgo/cffi bindings land
alongside the `tests/parity_gen.zig` corpus oracle.
