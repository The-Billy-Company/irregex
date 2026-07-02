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
  - caches; getting the scope right is shell-fragile and easy to get wrong.
- **re-work** — an agent runs dozens of searches per session; every one pays the
  full walk-and-read cost again. There's no memory between queries.
- **freshness** — coworker agents land commits mid-session. A stale index lies;
  `git diff`-based invalidation breaks under rebases and overlapping edits.
- **ranking** — agents don't want an unordered set of files, they want the _one_
  line that answers the question first (a symbol's **definition**, not its 200
  call sites) and pay tokens for everything below it. `grep` can't express that.

`gist` targets exactly those: a persistent **index** (don't rescan), a
zero-false-negative **freshness** guarantee (read-your-own-writes under churn),
and **ranked, token-compressed** output. The frontier survey and decision trail
live in
[`research/dossiers/locator-sota.dossier.toml`](../../../research/dossiers).

## How it works

The pipeline is five cooperating tiers, each a concern-scoped subfolder under
`src/` (`index/` · `regex/` · `rank/` · `scan/` · `corpus/`), driven by the
command surfaces under `src/commands/`:

**Trigram candidate index** (`src/index/trigram.zig`). Any file containing a literal
must contain every trigram of that literal, so the AND of the per-trigram
posting lists is a _sound_ candidate set — a superset of the true matches,
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

**Freshness overlay** (`src/corpus/fresh.zig`). Keeps a persisted index correct under
heavy concurrent commit churn **without rebuilding or consulting git**. The
build stamps a wall-clock anchor; a file is fresh iff `mtime ≥ anchor`, so any
changed, new, or touched file — including a coworker's commit landing via `git
checkout` — is folded into the candidate set and re-verified. Zero false
negatives, read-your-own-writes, immune to the rebases and overlapping edits that
defeat `git diff` (parallel stat-walk, ~42 ms cold).

**Ranking** (`src/rank/rank.zig`). Turns the verified match set into the list an agent
wants via weighted **Reciprocal Rank Fusion** (Cormack et al. 2009) over four
intrinsic signals — lexical density, a **definition boost** (a match on a decl
line outranks its call sites — the win `grep` can't express), shallow-path
centrality, and an **authored boost** that sinks codegen output (`*_grpc.pb.go`,
`*_pb2.py`, …) below real code: a generated file otherwise floods the head of a
common symbol like `context.Context` because it wins _both_ lexical (most
occurrences) and the def boost (its boilerplate stubs parse as defs), yet the
repo forbids editing it, so it is never the agent's target. The class split is
fused tie-aware (every authored doc shares rank 0, every generated doc shares
rank `n_authored`) so it stays neutral _within_ a class — plus an optional
external ranking (a graph-centrality hook). `search --rank` emits token-compressed
`path:line [def|use|gen] ×n  <line>`.

## Quickstart

gist has **three real verbs** — what it _does_, not which competitor's argv it
apes — plus machine-readable discovery for agents:

```bash
cd pkg/kernels/gist

zig build cli -- index                       # build + persist the index once (~1.2 s)
zig build cli -- status                      # is an index ready, how fresh, how big
zig build cli -- search <pattern> [PATH...]  # find matches — output SHAPE is a flag

zig build cli -- search <pat> --show lines   # `path:line:text` (default) — the rg -n drop-in
zig build cli -- search <pat> --show files   # matching paths only (was `query`/`regex`)
zig build cli -- search <pat> --show count   # per-file match count
zig build cli -- search <pat> --rank         # ranked, token-compressed (a symbol's def first)

zig build cli -- search --help               # the full flag surface (native + legacy)
zig build cli -- --schema                    # a JSON capability manifest for agents
```

`search` replaces the old `query` / `regex` / `rank` / `grep` quartet: they were
four verbs answering one question — _what matches, and how do you want it shaped_
— over one engine. The shape is now a **flag** (`--show` / `--rank` / `--json`),
the pattern is **auto-detected** literal-or-regex (a pure literal is its own
required literal, so it rides the same trigram prefilter — no second code path),
and `gist status` / `gist --schema` answer "am I ready to search fast" and "what
exactly can this tool do" without a query. The full flag surface — native and
legacy — is documented in "How it works as a drop-in" below, and exhaustively
in `--help` / `--schema`.

## Why gist instead of ripgrep — and everything else

`ripgrep` (and `ag`, GNU `grep`, `git grep`, `ugrep`) are all the same shape:
excellent **unindexed** scanners that re-walk and re-read the whole tree on
every invocation. That's the right trade for a one-off terminal search. It's
the wrong trade for an agent that runs dozens of searches a session against a
tree its coworkers are actively editing — which is the workload gist is built
for, proven by dogfooding the existing tools against real questions about this
repo:

- **A resident index beats a rescan, every time.** Warm, gist answers from a
  RAM-mapped posting table in microseconds; a rescanning tool pays the same
  walk-and-read cost on query #40 that it paid on query #1. Geomean over 20
  needles in a warm session: **1,712× faster than `rg`**, up to **266,900×**
  on a guaranteed miss — see Benchmarks.
- **A cold one-shot still wins**, because the trigram prefilter means gist
  reads only the files a query can possibly match — a selective symbol query
  touches ~2% of the corpus instead of all of it, so even the *first* query
  in a session beats an unindexed scan.
- **Freshness is a guarantee, not a cron job.** A coworker agent's commit
  landing mid-session doesn't make the index lie: a wall-clock anchor plus a
  parallel stat-walk folds in anything touched since the build with zero
  false negatives — no `git diff` invalidation to break under a rebase or
  overlapping edits.
- **Ranking gist can express, a line scanner can't.** `--rank` puts a
  symbol's *definition* ahead of its 200 call sites and sinks generated
  boilerplate below hand-written code — a property of the match's context,
  not just its text, that has no equivalent in `grep`'s output model.

Against the two tools that *do* index — `csearch` (Russ Cox's Google Code
Search, gist's direct trigram ancestor) and `zoekt` (Sourcegraph's production
indexed search) — the honest trade is freshness: both are faster **cold
loaders** today (a lighter or sharded index), but neither promises
read-your-own-writes under concurrent commit churn, and gist already turns
the tables wherever a query needs a real scan the trigram filter can't
prefilter. The full seven-tool field race, with every number falsifiable, is
in Benchmarks.

## How it works as a drop-in

The default output, `--show lines`, is a byte-for-byte `rg -n --no-heading`
drop-in: `path:line:text`, served from the persisted index (reading only
candidate files) instead of a whole-tree walk. Point an agent, a script, or a
muscle-memory `rg -n <pattern>` at `gist search <pattern>` and the output
doesn't change — only where it comes from.

Every flag `rg`/`grep` accept keeps working, aliased onto exactly one native
option (never a second, competing behavior) — this is what makes it a real
drop-in rather than a lookalike CLI:

| What you type (either spelling)         | What gist does                                                                                                                                          |
| ---------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `-n -H -R --no-heading --color=<x>`      | no-ops — gist's output is already `path:line:text`                                                                                                       |
| `-l` / `-c`                              | `--show files` / `--show count`                                                                                                                          |
| `-t <lang>` / `-g <glob>`                | `--lang` / `--glob` — pruned **before** touching disk (`--lang go` reads 234 of 18,608 files, **1.44×** faster than `rg -t go`, byte-identical output)   |
| `-w` / `-F` / `-i` / `-S`                | word-boundary / fixed-string / case-insensitive / smart-case                                                                                             |
| `-B N` / `-A N` / `-C N`                 | context lines, rg-exact `:`/`-`/`--` framing                                                                                                             |
| `-m N` / `-o` / `-r <t>`                 | max count per file / only-matching spans / template replace                                                                                              |
| `-e <pat>` / `--`                        | explicit pattern (leading-dash safe) / end of flag parsing                                                                                               |
| `--hidden`, `--no-ignore*`, `-u`/`-uu`   | no-ops — gist's index already searches hidden + gitignored files (see below)                                                                             |

A positional path prunes the same way — `search WalletService
services/backend/api` reads 28 candidate files (vs 86 unscoped, vs rg's
whole-subtree walk) and runs **1.14× faster than `rg …
services/backend/api`** at ~⅕ the syscall time, byte-identical output. Short
flags bundle (`-ln`, `-nC3`), and a leading inline flag group is honored
where gist can (`(?i)` → caseless) and fails loud where it genuinely can't
(see "Where gist departs from ripgrep" below).

`--rank`/`--show files`/`--show count` are gist-native shapes with no rg
equivalent; everything else on this page is the parity surface. It's
guarded, not asserted: a 13-pattern differential battery
([`bench/gates/equality.sh`](bench/gates/equality.sh)) diffs gist's output
against `rg -n --no-heading --no-unicode` over a byte-identical corpus
snapshot, including a 265,286-line and a 147,087-line result, to **0 lines**
of difference. The exhaustive native + legacy flag reference lives in
[`src/commands/search/args.zig`](src/commands/search/args.zig) /
[`compat.zig`](src/commands/search/compat.zig), guarded by
[`args_test.zig`](src/commands/search/args_test.zig).

Streams follow the `rg` convention too, so gist composes in a pipeline the
same way: matches go to **stdout**, timing and guidance go to **stderr**
(`gist search Foo --show files > files` captures only the paths; `gist
search Foo | head` still shows the summary on the terminal) — guarded by
[`bench/gates/streams.sh`](bench/gates/streams.sh).

## Where gist departs from ripgrep — on purpose

**Shares rg's regex philosophy.** Both engines are linear-time — a
byte-level Thompson NFA / DFA, the RE2 lineage — specifically to rule out
catastrophic backtracking. No PCRE, in either tool, on purpose.

**Departs on corpus scope — and proves the two are still equivalent once
that's accounted for.** gist's corpus is the _indexer's_, not the working
directory's:

- **ignores `.gitignore`** — a committed-but-ignored file is still something
  an agent might need to find (rg needs `--hidden --no-ignore` to match this)
- **includes hidden dotfiles** by default (rg needs `--hidden`)
- **skips only the `isSkipDir` build/VCS set** (`.git`, `node_modules`,
  `target`, …) — not the user's `.gitignore`
- **caps each file at 4 MiB**

Neutralize those four knobs on the rg side and the two tools' output is
**byte-identical** — a 13-pattern battery (literal, dot, alternation,
anchors, character classes, counted repetition, case-insensitive) diffs to 0
lines against `rg -n --no-heading --no-unicode` over the shared scope
([`.local/gist-grep-bench/battery.sh`](.local)). The corpus-widening flags
(`--hidden`, `--no-ignore*`, `-u`/`-uu`, `--sort`) are accepted as no-ops for
muscle memory, since gist's default already searches that superset.

**Departs on what "can't" means.** A flag gist genuinely can't honor —
`-P`/`--pcre2` (no backreferences/lookaround in a linear-time engine),
`-U`/`--multiline` (per-line by construction), `--vimgrep`/`--column` (fixed
`path:line:text` model — use `--json`) — **fails loud with the reason and
the `rg` fallback**, and so does a genuinely unrecognized flag. A silently
empty result on an unsupported flag is the worst possible agent failure — a
confident "no matches" that actually means "I didn't understand you."

**Departs on what a match is worth.** rg treats every matching line as
interchangeable; `--rank` doesn't. A **definition boost** puts a symbol's
declaration ahead of its call sites, and an **authored boost** sinks
generated files (`*_grpc.pb.go`, `*_pb2.py`, …) below hand-written code — a
generated file otherwise wins on raw occurrence count for a common symbol,
yet the repo forbids editing it, so it's never the actual answer. This runs
on gist's index via weighted Reciprocal Rank Fusion
([`src/rank/rank.zig`](src/rank/rank.zig), Cormack et al. 2009) over four
signals — it isn't expressible as a line-scanner's output ordering at all.

Supported regex syntax: literals, `.`, `[...]`/`[^...]`, `a-z` ranges, `* + ?
{n,m}`, alternation, groups, `^ $`, `\b \B`, and the classes `\d \w \s \t \n
\r` — see [`src/regex/syntax.zig`](src/regex/syntax.zig). `--ignore-case`
ASCII case-folds the pattern itself (every byte-class gains its
opposite-case twin) so the whole pipeline — NFA, DFA, trigram prefilter —
matches case-insensitively from one transform.

## Build & test

```bash
zig build test                    # unit tests (index · persist · regex NFA + DFA · RRF)
zig build                         # emit libgist.{a,dylib} + include/gist.h into zig-out/
zig build bench                   # corpus build/footprint + full-pipeline latency p50/p95/p99
zig build verify -- 150 1         # emit gist match sets + corpus snapshot for the rg oracle
zig build coverage                # tests under kcov → .local/coverage/ (needs kcov on PATH)
```

## Benchmarks — how gist compares to everything else (every claim falsifiable)

gist is raced against a **seven-tool field**: two other _indexed_ searchers
(`csearch`, Russ Cox's Google Code Search, gist's direct trigram ancestor;
`zoekt`, Sourcegraph's production indexed search) and five unindexed scanners
(`rg`, `ugrep`, `ag`, GNU `grep`, `git grep`), each on its honest fastest path.
The field, fairness scoping, and per-tool invocations live in
[`bench/races/_compete.sh`](bench/races/_compete.sh).

```bash
bench/gates/equality.sh          # gist ≡ rg over a byte-exact corpus SNAPSHOT, per needle
bench/races/headtohead.sh        # WARM: gist resident p50 vs the unindexed scanners
bench/races/coldquery.sh         # COLD literal: gist vs csearch/zoekt + the unindexed five
bench/races/regex_headtohead.sh  # COLD regex: same field, per feature tier
bench/gates/scan_regress.sh      # no-prefilter SCAN path: gist ≡ rg soundness + speed
bench/gates/streams.sh           # output contract: results→stdout, diagnostics→stderr
```

`equality.sh` has gist emit its verified matching-file set per pattern **plus a
byte-exact snapshot of the files it indexed** (the corpus is regenerated live by
coworker agents — the snapshot freezes the bytes so the diff can't race), runs
`rg` over that identical snapshot, and diffs. A file in rg's set but not gist's =
a trigram false negative (the one unforgivable bug); a file in gist's but not
rg's = an unsound verify. Both must be zero.

**Measured (17,112 files · 126.5 MiB · `services libs clients contracts scripts quality`):**

![gist competitive placement across the seven-tool field](assets/gist-competitive.png)

> _Where gist sits in the field — every value below, drawn. **(a)** warm-session
> dominance over the scanners that re-walk on each call; **(b–c)** the cold
> one-shot literal and regex sweeps vs the unindexed five (every bar clears
> parity); **(d)** the honest split against the two indexed engines — gist trails
> on the cold literal one-shot, matches/beats on regex; **(e)** the
> build-time/footprint trade-off (gist builds fastest, carries the middle-weight
> fully-mapped index); **(f)** the architectural "why" — a selective cold query
> reads only candidate files (`pgxpool`: 409 of 17,513)._

- **Correctness** — the oracle (50 literals + 68 regexes at battery 30, hundreds
  more across seeds) is **0 false negatives / 0 false positives** vs ripgrep over
  the byte-identical snapshot. `csearch`, indexing gist's _exact_ 16,696-file
  corpus, returns the same sets.
- **Index economics** — gist **1.2 s build · 30.1 MiB index** (CSR directory +
  delta-varint posting bodies, `src/index/trigram.zig` — was a flat
  `(trigram,doc)` pair table at 195 MiB, 6.5× larger); csearch **9.7 s ·
  31.1 MiB** over the identical corpus; zoekt **6.1 s · 428.7 MiB**. gist now
  builds fastest **and** carries the smallest fully-mapped index of the three
  — the lever behind the cold-literal race below just flipped in gist's favor.
- **WARM resident — gist's home turf, uncontested.** In a long-lived session gist
  answers from a RAM-resident index while the scanners re-walk every time.
  Geomean speedup over 20 needles: **rg 1,712× · ag 2,601× · git grep 1,388× ·
  GNU grep 5,492× · ugrep 7,115×** (all 20/20), and on a guaranteed miss — a
  single empty trigram lookup (~1 µs) — up to **266,900× vs rg** and
  **1,142,000× vs ugrep** (panel a plots both the geomean and the miss). The
  indexed rivals have no resident CLI (they reload their whole index per
  invocation), so in a session gist is ~25–800× faster per query than even them.
- **COLD one-shot vs every unindexed scanner — gist wins all.** Fresh process,
  cold-load (~30 ms), read only candidate files. Geomean: **ugrep 9.2× · GNU grep
  7.1× · ag 3.5× · rg 2.3× · git grep 1.9×** (gist wins 10–11/11).
- **COLD one-shot literal vs the indexed rivals — gist narrowed the gap
  sharply by shrinking its index below csearch's, and says what's left (no
  vibes).** The index used to be the whole story: gist mapped 177 MiB where
  csearch mapped 28 MiB. The CSR + delta-varint rewrite (`src/index/trigram.zig`)
  now puts gist's index at **30.1 MiB — smaller than csearch's own 31.1 MiB**
  over the identical corpus. Geomean moved **csearch 0.3× → 0.7×**, **zoekt
  0.5× → 0.8×** (gist now wins 7/11 needles outright against zoekt), measured
  fresh via `bench/races/coldquery.sh` (18,910 files, 8 needles, hyperfine mean of 8).
  gist still trails csearch on geomean, and the remaining cause is no longer
  index size: it's the corpus-wide freshness `stat()` walk
  (`src/corpus/fresh.zig`) that every cold query pays for read-your-writes
  correctness — work the rivals skip entirely (they go stale until re-indexed).
  Even a guaranteed miss pays the full walk. gist already _beats_ csearch on
  dense / 2-byte needles its prefilter can't help (`})` **1.3×**). **Next rung
  (recorded, not hidden):** make the freshness walk incremental — see the
  Named next rungs below.
- **COLD regex — gist wins the no-prefilter tail.** The literal/alternation-cover
  prefilter + the single-pass byte-class DFA put gist **≈ csearch** and **faster
  than zoekt** across 22 tiers (crushing zoekt on anchored shapes, `^func\s`
  2.4×). Vs unindexed: **≥ rg on ~19/22 · ag 2.0× · GNU grep 3.1× · ugrep 5.5×**,
  tying git grep. The hard case is a regex the index _can't_ prefilter
  (`\w{3,8}`, `[a-f0-9]{2,}`, `[a-z]+_[a-z]+_[a-z]+`, `[0-9]{4}`, `panic|0x`):
  every doc is a candidate, so gist skips the index and scans the **live tree**
  once ([`src/scan/sweep.zig`](src/scan/sweep.zig)) — _more_ correct than the
  index+freshness path (sees files born since the build, no staleness window).
  A tie there was not the floor — **profiled, the phased scan leaked two ways**:
  a ~63 ms serial walk _barrier_ (overlapping nothing) and ~169 ms of _straggler
  idle_ (static file-count sharding stranded the big files on one core — fastest
  done in 158 ms, slowest 327 ms). The rewrite is a **fused work-stealing
  pipeline**: walkers stream paths into a shared queue while a core-sized pool
  steals files dynamically and reads+scans as the walk still runs. Result
  (process-internal clock, so build-wrapper-independent): **worker span Δ 169 ms →
  2.5 ms** (near-perfect balance) and the walk folded under the scan — **~1.7×
  internal speedup**, the proof we were never at the limit. Oversubscription was
  _measured, not assumed_ — warm-cache the tier is CPU/syscall-bound (~190 µs/file
  open+read+close), so ×1 worker/core beat ×2/×3. ReleaseFast, min-of-N vs
  `rg (?-u)` on its fastest gitignore-respecting path (gist scans a
  gitignore-_superset_, so it wins while reading **more** bytes — permanent
  reproducer + soundness gate: [`bench/gates/scan_regress.sh`](bench/gates/scan_regress.sh)):
  `\w{3,8}` **1.3–3.0×** · `[a-f0-9]{2,}` **1.3–1.4×** · `[a-z]+_[a-z]+_[a-z]+`
  **1.2×** · `[0-9]{4}` **1.1×** · `panic|0x` **win-or-tie** (~1.0×) — **0 FN/FP**
  vs rg throughout. The verdict is structural, read
  straight off the data: **gist's time is pattern-independent** (~240 ms, the
  per-file syscall floor — the DFA is one early-exiting pass), while **rg's varies
  2–373 ms with match density** (floor + per-byte scan). So gist wins every
  scan-expensive pattern outright and only ties the cheapest sparse-literal one,
  where rg's own scan is nearly free and both sit on the same read floor.
  **The named next rung (recorded, not hidden):** to win even there, drop _below_
  the floor — batch the per-file `openat`+`read`+`close` (io_uring / `readv`),
  since at ~190 µs/file the syscalls, not the bytes, are the wall.

![gist no-prefilter scan path optimization progression](assets/gist-scan-progression.png)

> _The no-prefilter scan tier, profiled to the floor. **(a)** the phased→fused
> work-stealing rewrite collapsed per-core finish spread (worker-span Δ 169 → 2.5
> ms — the walk folds under the scan); **(b)** premultiplied DFA transition tables
> cut the dense scan to the scalar-DFA floor (~one L1 load-use/byte), PMU-measured
> on Apple Silicon; **(c)** the latency-bound signature — cycles/byte fell ~4× the
> instruction drop while IPC *rose*, so it's a critical-path win, not throughput;
> **(d)** the structural verdict — gist's per-file syscall floor makes its time
> pattern-independent, so the margin over rg widens with match density (gist ≥ rg
> on every pattern, 0 FN / 0 FP)._

### Macroscopic field race — the fail-closed certificate (`certify.sh`)

[`bench/certify/certify.sh`](bench/certify/certify.sh) is the most adversarial cut: a
fresh-process **cold** query for gist **and all seven field tools** over the
byte-identical corpus (hyperfine, 20 runs + 3 warmup), a 95% bootstrap-CI
median per cell, and a gist-vs-ripgrep verdict that is **fail-closed** — a WIN
needs a lower median _and_ Mann-Whitney `p<0.05`. Its 11 probe classes
deliberately include the **saturating** patterns (`})`, `;$`, `\w{3,8}`, a UUID
class) where the trigram prefilter admits _every_ file — the cases the
competition is built to win. Every number below is `certify_macro.csv`
verbatim, re-run after the CSR-index rewrite below; 2 of the 11 classes
(`regex-anchored`/`^func\s`, `regex-classcount`/UUID) dropped a hyperfine
export mid-run on this shared, heavily-coworked box and are omitted rather
than guessed — both were historically gist wins against zoekt, so their
absence understates, not overstates, the numbers below.

> _(the field-race figure predates the index rewrite and is queued for
> regeneration; the numbers in this section are the current source of truth.)_

- **gist vs ripgrep — 7 win · 1 parity · 1 loss (9 classes measured).** gist's
  cold query beats rg **5.91×** (`pgxpool`), **5.83×** (`pgxpool\.\w+`),
  **3.99×** (`context.Context`), **2.54×** (`func`), **2.41×**
  (`func\s+\w+\(`), **2.12×** (`return|continue|break`), **1.32×** (`})`) —
  ties on the saturating `\w{3,8}` (1.02×, p=0.617, correctly called parity
  under the fail-closed test) — and loses one, `;$` (0.90×, p=0.022, a real
  if narrow loss). No fabricated wins, no hidden loss.
- **The saturating tail is close, and it's the one place rg still wins.** The
  cand%=100% classes (every file is a candidate, so the trigram prefilter buys
  nothing) are the tightest races: `\w{3,8}` lands at **parity** (1.02×,
  p=0.617 — not significant, correctly *not* called a win) and `;$` is the one
  genuine loss (0.90×, p=0.022). `})` (2-byte, sub-trigram, no filter by
  design) still wins outright at 1.32×. The honest read: gist is at parity or
  better with rg on 8/9 measured classes, decisively where the prefilter
  prunes, by a hair or a narrow loss where it can't.
- **vs the indexed twins — the honest split, no spin, and it just got much
  closer.** Before the CSR-index rewrite this section read "csearch and zoekt
  win most cold classes" outright; on the 9 classes measured here it's a real
  split. **csearch**: gist wins `return|continue|break` (1.2×), `func` (1.1×),
  `})` (1.8×), `;$` (1.5×), `func\s+\w+\(` (1.1×); csearch still wins `pgxpool`
  (0.7×), `context.Context` (0.9×), `\w{3,8}` (0.8×), `pgxpool\.\w+` (0.7×) —
  geomean **≈1.0×, essentially parity** where the old measurement (177 MiB
  index) put it at a clear csearch win across the board. **zoekt**: gist wins
  `pgxpool` (1.3×), `context.Context` (1.5×), `\w{3,8}` (2.4×), `pgxpool\.\w+`
  (1.3×); zoekt still wins the punctuation/anchor-heavy classes
  (`return|continue|break` 0.7×, `func` 0.8×, `})` 0.2×, `;$` 0.3×,
  `func\s+\w+\(` 0.8×) — geomean **≈0.8×**, closer than before but zoekt's own
  sharding still wins the classes where a heavy scan dominates. The two classes
  that didn't collect this run (`^func\s`, the UUID class) were gist's biggest
  zoekt wins historically (2.6× and 4.1×), so the true 11-class zoekt geomean
  is almost certainly better than 0.8×, not worse. This is the same lever as
  the cold-literal section above, now measured on the macro race too: shrink
  the index, and the "richer index bought freshness" trade-off gets cheaper.

The shape of the result is honest and architectural: **gist owns the
agent-session workload it was built for** — a resident index answering in
microseconds, or a cold one-shot that beats every unindexed tool by reading only
candidate bytes. Against the two mature _indexed_ engines it's now a genuine
split rather than a trail: gist's index is smaller than csearch's own (30.1 vs
31.1 MiB, same corpus) and roughly a 14th of zoekt's sharded 428.9 MiB, so the
cold literal one-shot moved from "gist loses most classes" to "roughly even
with csearch, ahead of zoekt on half the field." The residual gap — still
real, not hidden — is the corpus-wide freshness `stat()` walk every gist cold
query pays and the rivals don't; that is the next rung, not the index.

## C ABI (`include/gist.h`)

- `gist_abi_version() -> u32`
- `gist_trigram_count(text, len, out) -> usize` — distinct ascending trigrams
  (the cross-language parity oracle)

The `Index` (build/query) is Zig-native this cut; the cgo/cffi bindings land
alongside the `tests/parity_gen.zig` corpus oracle.
