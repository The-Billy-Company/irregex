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
**freshness** overlay that is zero-false-negative _under stated local-filesystem
assumptions_ (content writes advance mtime, the freshness walk is readable, live
bytes are re-verified before output — the assumptions and edge cases are
enumerated in the dossier), and **ranked, token-compressed** output. The frontier
survey and decision trail
live in `research/dossiers/locator-sota.dossier.toml` (machine-local research
scratch, archived per the `.local/` lifecycle — see `archive/archive.py show
scope-crazy` to restore it).

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
external ranking (a graph-centrality hook). `--rank` emits token-compressed
`path:line [def|use|gen] ×n  <line>`.

## Quickstart

gist has **two lifecycle verbs** — what it _does_, not which competitor's argv
it apes — plus a single unified search engine reached with no verb at all,
addressed the way an agent's `rg <pattern>` reflex already types it:

```bash
make install-gist       # from repo root: build (ReleaseFast) + symlink ~/.local/bin/gist + index
gist status             # verify the installed CLI + index in one line
```

Or drive the CLI straight from the build graph, no install:

```bash
cd pkg/kernels/gist

zig build cli -- index                    # build + persist the index once (~1.2 s)
zig build cli -- status                   # is an index ready, how fresh, how big

zig build cli -- <pattern> [PATH...]      # find matches — no verb, no setup, zero-config
zig build cli -- rg <pattern> [PATH...]   # the same engine, addressed explicitly

zig build cli -- <pat> -l                 # matching paths only (rg's own `-l`)
zig build cli -- <pat> --rank             # ranked, token-compressed (a symbol's def first)
zig build cli -- <pat> --no-index         # force the pure live walk (skip the index entirely)

zig build cli -- --help                   # the full rg-compatible flag surface
zig build cli -- --schema                 # a JSON capability manifest for agents
```

The bare `gist <pattern>` shorthand and its explicit `gist rg` alias are ONE
engine (`src/commands/ripgrep/run.zig`) — a ripgrep-DEFAULT drop-in on its
**supported surface** (gitignore precedence, exit codes, piped stdin;
byte-identical on 100% of the mined rgsuite corpus — 0 FAIL — with every
by-design boundary tracked under "Where gist departs from ripgrep") that transparently
uses a persisted trigram index, when one covers the searched roots, purely to
**elide reads** of files it proves can't match; it never changes the file set,
ordering, or output. `--rank` is gist's one native shape with no rg
equivalent — a definition-first RRF-ranked view (see "Why gist" below).
`gist status` / `gist --schema` answer "am I ready to search fast" and "what
exactly can this tool do" without running a query. The full flag surface is
documented in "How it works as a drop-in" below, and exhaustively in `--help`
/ `--schema`.

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
  needles in a warm session: **1,730× faster than `rg`**, up to **349,200×**
  on a guaranteed miss — see Benchmarks.
- **A cold one-shot still wins**, because the trigram prefilter means gist
  reads only the files a query can possibly match — a selective symbol query
  touches ~2% of the corpus instead of all of it, so even the _first_ query
  in a session beats an unindexed scan.
- **Freshness is a guarantee, not a cron job.** A coworker agent's commit
  landing mid-session doesn't make the index lie: a wall-clock anchor plus a
  parallel stat-walk folds in anything touched since the build with zero
  false negatives — no `git diff` invalidation to break under a rebase or
  overlapping edits.
- **Ranking gist can express, a line scanner can't.** `--rank` puts a
  symbol's _definition_ ahead of its 200 call sites and sinks generated
  boilerplate below hand-written code — a property of the match's context,
  not just its text, that has no equivalent in `grep`'s output model.

Against the two tools that _do_ index — `csearch` (Russ Cox's Google Code
Search, gist's direct trigram ancestor) and `zoekt` (Sourcegraph's production
indexed search) — the honest trade is freshness: both are faster **cold
loaders** today (a lighter or sharded index), but neither promises
read-your-own-writes under concurrent commit churn, and gist already turns
the tables wherever a query needs a real scan the trigram filter can't
prefilter. The full seven-tool field race, with every number falsifiable, is
in Benchmarks.

## How it works as a drop-in

The default output targets `rg -n --no-heading` byte-for-byte on its supported
surface (100% of the mined rgsuite corpus is byte-identical — 0 FAIL; the by-design
boundaries below are recorded NA): `path:line:text`, with a persisted trigram index transparently used to skip
reading files that provably can't match — a whole-tree walk otherwise. Point
an agent, a script, or a muscle-memory `rg -n <pattern>` at bare `gist -n
<pattern>` (no verb, no setup) or the explicit `gist rg -n <pattern>` alias and
the output doesn't change — only how many files get opened to produce it.

A broad, documented subset of the flags `rg`/`grep` accept maps onto exactly one
native option (never a second, competing behavior); flags outside that subset are
either accepted-and-ignored or fail loud (never silently wrong) — the full buckets
live in `--schema` and the dossier's compatibility matrix. This is what makes it a
real drop-in on its supported surface rather than a lookalike CLI:

| What you type (either spelling)        | What gist does                                                                                                                                         |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `-n -H -R --no-heading --color=<x>`    | no-ops — gist's output is already `path:line:text`                                                                                                     |
| `-l` / `-c`                            | native rg flags — files-with-matches / per-file match count                                                                                            |
| `-t <lang>` / `-g <glob>`              | `--lang` / `--glob` — pruned **before** touching disk (`--lang go` reads 234 of 18,608 files, **1.44×** faster than `rg -t go`, byte-identical output) |
| `-w` / `-F` / `-i` / `-S`              | word-boundary / fixed-string / case-insensitive / smart-case                                                                                           |
| `-B N` / `-A N` / `-C N`               | context lines, rg-exact `:`/`-`/`--` framing                                                                                                           |
| `-m N` / `-o` / `-r <t>`               | max count per file / only-matching spans / template replace                                                                                            |
| `-e <pat>` / `--`                      | explicit pattern (leading-dash safe) / end of flag parsing                                                                                             |
| `--hidden`, `--no-ignore*`, `-u`/`-uu` | real, functional — widen the walk exactly as they do in rg (see below)                                                                                 |

A positional path prunes the same way — `gist WalletService
services/backend/api` reads 28 candidate files (vs 86 unscoped, vs rg's
whole-subtree walk) and runs **1.14× faster than `rg …
services/backend/api`** at ~⅕ the syscall time, byte-identical output. Short
flags bundle (`-ln`, `-nC3`), and a leading inline flag group is honored
where gist can (`(?i)` → caseless) and fails loud where it genuinely can't
(see "Where gist departs from ripgrep" below).

`--rank` is gist's one native shape with no rg equivalent; everything else on
this page is the parity surface, guarded by two **distinct** gates. **File-set
soundness** ([`bench/gates/equality.sh`](bench/gates/equality.sh)) diffs gist's
matching _file set_ against `rg -F -l` / `rg -l '(?-u)…'` over a byte-identical
corpus snapshot — proving zero false negatives / positives (the candidate filter
is sound), but it is a file-set oracle, **not** a line-output diff. **Line-output
parity** is the job of [`bench/rgsuite/`](bench/rgsuite/README.md) (441 mined `rg`
argv replays, on **both** the parallel and serial walk engines — see that
README's "Two engines, one suite"); the committed `results.json` reads **264
PASS / 15 ORDER / 0 FAIL / 41 NA / 121 SKIP = 100% supported-surface parity**
— zero-FAIL, and additionally
gated byte-for-byte by [`bench/gates/line_parity.sh`](bench/gates/line_parity.sh)
(the by-design boundaries are listed under "Where gist departs from ripgrep"). The
exhaustive rg-compatible flag reference lives in
[`src/commands/ripgrep/args.zig`](src/commands/ripgrep/args.zig).

Streams follow the `rg` convention too, so gist composes in a pipeline the
same way: matches go to **stdout**, and — a stronger bar than `rg` itself, not
just parity with it — the default path puts NOTHING on stderr at all (`gist
Foo -l > files` captures only the paths; `gist Foo | head` shows only
matches). The one deliberate exception is `--rank`, which prints its
cold-load/rank timing to stderr so an agent can see the cost of the ranked
view — guarded by [`bench/gates/streams.sh`](bench/gates/streams.sh).

## Where gist departs from ripgrep — on purpose

**Shares rg's regex philosophy.** Both engines are linear-time — a
byte-level Thompson NFA / DFA, the RE2 lineage — specifically to rule out
catastrophic backtracking. No PCRE, in either tool, on purpose.

**Matches rg's corpus scope exactly — the walk decides what's IN scope, the
index only decides what gets READ.** `.gitignore`/`.ignore`/`.rgignore`
precedence (`ignore.zig`) is honored by the live walk that every invocation
runs; `--hidden`, `--no-ignore*`, and `-u`/`-uu` are real, functional flags
(not no-ops) that widen it exactly as they do in rg. The persisted trigram
index (built over a wider corpus policy — see `corpus/corpus.zig` — hidden
files and `.gitignore`d files included, capped at 4 MiB/file) is consulted
**only** to skip opening a file the walk already decided to visit but that
provably can't match; it never adds a file the walk itself would have
skipped. A 13-pattern battery (literal, dot, alternation, anchors, character
classes, counted repetition, case-insensitive) diffs gist's output to 0 lines
against `rg -n --no-heading --no-unicode` over the same scope
([`.local/gist-grep-bench/battery.sh`](.local)) — this is genuine parity, not
a neutralized-knobs equivalence.

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
{n,m}`, alternation, groups, `^ $`, the haystack anchors `\A \z`, the word
boundaries `\b \B` and one-sided `\< \>`, and the classes `\d \w \s \t \n
\r` (NUL is `\x00`) — see [`src/regex/syntax.zig`](src/regex/syntax.zig).
The escape parser is rg-parity **fail-loud**: `\0`–`\9` (backreference
syntax), unrecognized letter escapes (`\q`, `\e`, `\Z`, …), and assertion
escapes inside a class (`[\b]`, `[\A]`, `[\<]`) all exit 2 with the reason
and the `rg --pcre2` fallback — exactly the inputs rg itself rejects — never
a silent wrong literal. `--ignore-case`
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

![gist cold one-shot race across the seven-tool field](assets/gist-cold-field.png)

> _Cold one-shot literal race — 11 real needles, fresh process, the full
> seven-tool field. **(a)** range + geomean per rival (diamond = geomean,
> log-x) — the spread across needles, not one flattering headline number:
> gist's cold win is consistent, not cherry-picked. **(b)** win rate — how
> many of the 11 needles each rival actually loses._

![gist warm resident session dominance across 20 needles](assets/gist-warm-dominance.png)

> _Warm resident session — 20 real needles against the five unindexed
> scanners (the two indexed rivals have no resident CLI, so cold-loading them
> every query would be a straw man). **(a)** geomean vs. worst-case miss —
> `zzqxv`, a guaranteed miss, is the single trigram lookup behind the
> million-x tail. **(b)** the session bill: the same 20 needles' real
> wall-clock time, linearly scaled to a 50-query session — gist finishes in
> 18 ms total, ripgrep is still running 16 seconds later._

![gist cold regex race across 22 tiers and the seven-tool field](assets/gist-regex-matrix.png)

> _Cold regex race — all 22 tiers, from a bare anchored literal to the
> no-prefilter dense-scan tail, against the full seven-tool field.
> **(a)** every tool's speedup relative to gist, log₂-colored (blue = gist
> faster). **(b)** win rate per tool, of 22 — `ag` and GNU `grep` lose zero
> tiers to gist's prefilter + single-pass DFA; ripgrep splits close on the
> no-prefilter saturating patterns it's built to win._

- **Correctness** — the oracle (50 literals + 68 regexes at battery 30, hundreds
  more across seeds) is **0 false negatives / 0 false positives** vs ripgrep over
  the byte-identical snapshot. `csearch`, indexing gist's _exact_ 16,696-file
  corpus, returns the same sets.
- **Index economics** — gist **1.2 s build · 30.1 MiB posting blob** (`index.gist`,
  CSR directory + delta-varint posting bodies, `src/index/trigram.zig` — was a flat
  `(trigram,doc)` pair table at 195 MiB, 6.5× larger); csearch **9.7 s · 31.1 MiB**
  over the identical corpus; zoekt **6.1 s · 428.7 MiB**. Caveat: 30.1 MiB is the
  posting blob only — gist's separate `paths.list` + freshness anchor are not
  counted, so "smaller than csearch" is indicative, not yet strictly
  apples-to-apples (tracked in the dossier / `GIST-ISSUES.md`).
- **WARM resident — gist's home turf, uncontested.** In a long-lived session gist
  answers from a RAM-resident index while the scanners re-walk every time.
  Geomean speedup over 20 needles ([`headtohead.sh`](bench/races/headtohead.sh),
  `.local/gist-compete/warm.csv`): **git grep 1,252× · rg 1,730× · ag 2,774× ·
  GNU grep 5,604× · ugrep 6,861×** (all 20/20), and on `zzqxv`, a guaranteed
  miss — a single empty trigram lookup — up to **349,200× vs rg** and
  **1,424,100× vs ugrep**. The indexed rivals have no resident CLI (they
  reload their whole index per invocation), so in a session gist is
  25–800× faster per query than even them. Projected onto a 50-query
  session, the same sample sums to **18 ms total for gist** against
  **11.7 s (git grep) up to 63.8 s (ugrep)** of real wall-clock time.
- **COLD one-shot vs every unindexed scanner — gist wins all.** Fresh process,
  cold-load (~30 ms), read only candidate files. Geomean over 11 needles
  ([`coldquery.sh`](bench/races/coldquery.sh), `.local/gist-compete/cold.csv`):
  **git grep 2.9× · rg 3.4× · ag 4.9× · GNU grep 10.1× · ugrep 12.2×**
  (gist wins 10–11/11 — ugrep and GNU grep clear parity on all 11 needles;
  rg, ag, and git grep each drop only the sub-trigram `})`).
- **COLD one-shot literal vs the indexed rivals — gist narrowed the gap
  sharply by shrinking its index below csearch's, and says what's left (no
  vibes).** The index used to be the whole story: gist mapped 177 MiB where
  csearch mapped 28 MiB. The CSR + delta-varint rewrite (`src/index/trigram.zig`)
  now puts gist's index at **30.1 MiB — smaller than csearch's own 31.1 MiB**
  over the identical corpus. Geomean over the same 11 needles: **csearch
  0.72×, gist wins 3/11 · zoekt 0.77×, gist wins 6/11**. gist still trails
  csearch on geomean, and the remaining cause is no longer index size: it's
  the corpus-wide freshness `stat()` walk (`src/corpus/fresh.zig`) that every
  cold query pays for read-your-writes correctness — work the rivals skip
  entirely (they go stale until re-indexed). Even a guaranteed miss pays the
  full walk. gist already _beats_ csearch on dense / 2-byte needles its
  prefilter can't help (`func(` **1.3×**, `import` **1.1×**). **Next rung
  (recorded, not hidden):** make the freshness walk incremental — see the
  Named next rungs below.
- **COLD regex — gist wins the no-prefilter tail.** The literal/alternation-cover
  prefilter + the single-pass byte-class DFA put gist **≈ csearch** (1.17×
  geomean over 22 tiers) and **ahead of zoekt** (1.94× geomean, 14/22 tiers —
  crushing it on the UUID class, 11.0×, and anchored shapes). Vs unindexed
  ([`regex_headtohead.sh`](bench/races/regex_headtohead.sh),
  `.local/gist-compete/regex.csv`): **ag 2.2× (22/22) · GNU grep 3.6× (22/22)
  · ugrep 6.4× (20/22) · rg 1.5× (16/22)**, and near-parity with git grep
  (1.2× geomean, 12/22) — the honest tie the saturating tail produces. The
  hard case is a regex the index _can't_ prefilter
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
needs a lower median _and_ Mann-Whitney `p<0.05`. The certificate is **committed
and reproducible** under [`bench/certify/artifact/`](bench/certify/artifact/):
the rendered `CERTIFICATE.md`, `certify_macro.csv` (median + 95% CI + verdict per
cell), per-cell hyperfine JSON, and machine / tool-version / corpus metadata. The
figure below renders from that committed CSV, and `check_artifacts.py` gates the
set for completeness. Every number is `certify_macro.csv` verbatim, all 11 classes.

![gist fail-closed statistical certificate forest plot](assets/gist-certify-forest.png)

> _The certificate itself, rendered from the committed `certify_macro.csv`.
> **(a)** gist's median (blue diamond) vs rg's median + 95% bootstrap CI per
> class, log-ms — non-overlapping whiskers are what make the verdict statistically
> real. **(b)** gist's speedup over the indexed rivals csearch/zoekt, log-x, `<1`
> means the rival wins cold._

- **gist vs ripgrep — 0 win · 0 parity · 11 loss (cold, fail-closed).** On a
  fresh-process cold single-shot, gist runs at **~0.3× ripgrep** across every one
  of the 11 classes (Mann-Whitney `p<0.001` on all), from `0.38×` (`\w{3,8}`) down
  to `0.12×` (the UUID class). It loses outright, and the certificate says so. The
  cause is structural and not hidden: every cold gist query first pays a
  corpus-wide freshness `stat()` walk — reading **every file's mtime** to stay
  sound without git — that ripgrep never pays (rg reads no mtimes at all).
- **Cold, gist also trails the indexed rivals** (csearch, zoekt, and even
  git-grep on several classes — see the "field context" block in
  [`CERTIFICATE.md`](bench/certify/artifact/CERTIFICATE.md)). csearch and zoekt
  answer from a pre-built index and skip both the directory walk and the freshness
  pass, so on a cold one-shot they are faster still. That is precisely the
  indexed-search trade-off gist makes the _other_ way: it keeps a live freshness
  guarantee the others drop until re-indexed.
- **Where gist wins is the warm resident-index session it is built for** — not the
  cold one-shot. With the index resident in RAM across an agent session, the walk
  and the freshness pass amortize away and gist answers **~1770× faster than
  ripgrep** (`bench/rgsuite/README.md`, warm track). The cold certificate above is
  the honest floor; the warm resident path is the design point.

The shape of the result is honest and architectural: **gist owns the warm
agent-session workload it was built for** — a resident index answering in
microseconds — and **loses the cold single-shot** to every tool that doesn't pay a
freshness walk. The prior "9 win · 2 loss" verdict (measured before the harness was
fail-closed and the certificate committed) is superseded by the committed numbers
above. The residual cold gap is the corpus-wide freshness `stat()` walk; whether it
can be narrowed without dropping the freshness guarantee is the open perf question
(the walk cost is largely fundamental — reading N mtimes — not a fixable inefficiency).

### Certificate of Optimality — the scan kernel is at the hardware limit

Layer A above measures the **end-to-end cold query** (where gist loses — it pays a
freshness walk the field doesn't). The next three layers make a narrower, still-true
claim about the **scan kernel itself**: once gist is reading candidate bytes, that
inner loop is at the chip's ceiling — no implementation on this core can scan
materially faster. (This is why gist's _warm_ path wins: with the walk amortized
away, only the at-the-limit scan remains.) Each layer is cheapest-evidence-first,
splicing into one generated `CERTIFICATE.md` (recipe + full tables in
[`bench/README.md`](bench/README.md), rationale in
[ADR-320](../../../docs/architecture/3-decisions/320-gist-optimality-certificate-layers.md)):

- **Layer B — port-optimality** ([`bench/portcert/`](bench/portcert/README.md)):
  byte-faithful copies of the two hot loops, cross-compiled and scored by
  `llvm-mca`. `simd_contains` is throughput-bound at its port ceiling
  (**0.031 cyc/byte** on znver4); `dfa_step` is a latency-bound pointer chase
  (**1.3 cyc/byte**, the loop-carried transition recurrence). LLVM has no
  Apple-Silicon model, so the bound is taken on `znver4`/`neoverse-v2` reference
  cores — an honest cross-check, not a fabricated M-series number.
- **Layer C — roofline** ([`bench/roofline/`](bench/roofline/README.md)):
  gist's scan runs at **~29% of the measured single-core DRAM ceiling**, so the
  verify path is **memory-bandwidth-bound** — the real win is the trigram
  prefilter keeping bytes away from it, not the scan going faster.
- **Layer D — algorithmic lower bound** ([`bench/lowerbound/`](bench/lowerbound/README.md)):
  a fail-closed byte-touch audit proving verify reads each candidate byte
  **exactly once** (fused DFA, `passes ≡ 1.0000`) or fewer (SIMD skips) —
  the Ω(candidate-bytes) floor — with the trigram filter pruning the rest of the
  corpus untouched. **All 11 classes sit at the floor.**

Together: the loop is as tight as the instruction ports allow (B), already reads
a large fraction of what memory can deliver (C), and touches the theoretical
minimum number of bytes (D) — the three ceilings Layer A's empirical dominance
converges toward. The probe copies are drift-guarded against the production hot
loops (`zig build test`), and each layer degrades to a documented skip rather
than inventing a number for hardware it can't measure.

## C ABI (`include/gist.h`)

- `gist_abi_version() -> u32`
- `gist_trigram_count(text, len, out) -> usize` — distinct ascending trigrams
  (the cross-language parity oracle)

The `Index` (build/query) is Zig-native this cut; the cgo/cffi bindings land
alongside the `tests/parity_gen.zig` corpus oracle.
