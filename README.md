# gist

A fast, regex-first, **agent-friendly** code locator kernel for the Billy
monorepo, implemented in Zig with a minimal C ABI for its trigram oracle.

> **Scope:** this is build-time dev tooling for the coding agents that work _on_
> Billy. It has nothing to do with Billy-the-product.

## What it is

`gist` is a persistent code-search engine built for the way an agent actually
searches a large repo: ask many small questions over a long session, against a
tree that other agents are concurrently editing, and pay tokens for every line
of output. It builds a trigram **index once**, then answers each query by
touching only the files that can possibly match — instead of re-walking and
re-reading the whole tree like `grep`/`ripgrep` do on every invocation.

Gist ships as a Zig library plus the production CLI (`zig build cli`). Search
embedding is Zig-native or CLI-based; the minimal C ABI does not expose the
index/search engine.

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
assumptions_ (ordinary writes advance status ctime, metadata is readable, and
live bytes are re-verified before output — see `src/corpus/README.md`), and
**ranked, token-compressed** output. The frontier
survey and decision trail
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
O(n) counting sort on the 24-bit key (~3.2 s over 143 MiB on the certificate
machine). Queries resolve each
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

**Freshness overlay** (`src/corpus/fresh.zig`). Keeps a persisted index correct
under heavy concurrent commit churn **without rebuilding or consulting git**.
The build stamps a wall-clock anchor; a file is conservatively fresh when its
mtime **or status ctime** reaches the anchor, so restored/backdated mtimes still
cannot hide an ordinary write. The common parallel path gets both timestamps
from the directory listing it already needed, eliminating the old second
corpus-wide `stat()` walk; exotic serial modes retain the standalone overlay.
Queries have before/after semantics under concurrent writes, not snapshots.

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

zig build cli -- index                    # build + persist the index once (~3.2 s here)
zig build cli -- status                   # is an index ready, how fresh, how big

zig build cli -- <pattern> [PATH...]      # find matches — no verb, no setup, zero-config
zig build cli -- rg <pattern> [PATH...]   # the same engine, addressed explicitly

zig build cli -- <pat> -l                 # matching paths only (rg's own `-l`)
zig build cli -- <pat> --rank             # ranked, token-compressed (a symbol's def first)
zig build cli -- <pat> --no-index         # force the pure live walk (skip the index entirely)

zig build cli -- --help                   # broad tested rg-compatible subset
zig build cli -- --schema                 # a JSON capability manifest for agents
```

The bare `gist <pattern>` shorthand and its explicit `gist rg` alias are ONE
engine (`src/commands/ripgrep/run.zig`) — a ripgrep-DEFAULT drop-in on its
**supported surface** (gitignore precedence, exit codes, piped stdin;
**0 FAIL** on the mined rgsuite corpus, with PASS + ORDER counted as
supported-surface parity — ORDER means identical match _sets_ with
worker-discovery line order only; see rgsuite — and every by-design boundary
tracked under "Where gist departs from ripgrep") that transparently
uses a persisted trigram index, when one covers the searched roots, purely to
**elide reads** of files it proves can't match; it never changes the file set
or match set (parallel ORDER deviations are documented, not claimed
byte-identical). `--rank` is gist's one native shape with no rg
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

- **A resident index still owns the latency floor.** Warm, gist answers from a
  RAM-mapped posting table in microseconds; a scanner re-walks on query #40.
  Residency is now an optional latency tier, not a prerequisite for beating rg.
- **A cold one-shot usually wins too.** Trusted mmap loading, fused freshness,
  compact path lookup, topology-aware workers, and regex literal gates target
  fail-closed cold dominance versus ripgrep; republish
  [`bench/certify/artifact/`](bench/certify/artifact/) on a clean HEAD to bind
  the scoreboard (see that dir's `REGENERATE.md`).
- **Freshness is a guarantee, not a cron job.** A coworker commit landing
  mid-query cannot make the index lie under the documented local-filesystem
  model: the walk's own mtime/ctime metadata forces touched files through
  verification.
- **Ranking gist can express, a line scanner can't.** `--rank` puts a
  symbol's _definition_ ahead of its 200 call sites and sinks generated
  boilerplate below hand-written code — a property of the match's context,
  not just its text, that has no equivalent in `grep`'s output model.

Against the two tools that _do_ index — `csearch` (Russ Cox's Google Code
Search, gist's direct trigram ancestor) and `zoekt` (Sourcegraph's production
indexed search) — the honest trade remains freshness: they may win a selective
cold cell by trusting a stale-until-rebuilt corpus; gist verifies live changes.
The full eight-tool field certificate (gist plus seven competitors), including
every loss, is in Benchmarks.
See [Prior art and scope](PRIOR_ART.md) for the wider search/code-intelligence
landscape and the boundaries of Gist's novelty claim.

## How it works as a drop-in

The default output targets `rg -n --no-heading` on its supported surface
(**0 FAIL**; PASS + ORDER = supported-surface parity — ORDER is same lines,
discovery order may differ under the parallel engine; by-design boundaries
below are NA): `path:line:text`, with a persisted trigram index transparently used to skip
reading files that provably can't match — a whole-tree walk otherwise. Point
an agent, a script, or a muscle-memory `rg -n <pattern>` at bare `gist -n
<pattern>` (no verb, no setup) or the explicit `gist rg -n <pattern>` alias and
the output doesn't change — only how many files get opened to produce it.

A broad, documented subset of the flags `rg`/`grep` accept maps onto exactly one
native option (never a second, competing behavior); flags outside that subset are
either accepted-and-ignored or fail loud (never silently wrong). The parser-derived
four-bucket matrix lives in `--schema`. This is what makes gist a real drop-in on
its supported surface rather than a lookalike CLI:

The current matrix contains **67 supported**, **5 supported-with-differences**,
**15 accepted-but-ignored**, and **6 unsupported-fail-loud** long-flag entries;
short flags are reported alongside it.

| What you type (either spelling)        | What gist does                                                                                                                                                                              |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `-n -H -R --no-heading --color=<x>`    | no-ops — gist's output is already `path:line:text`                                                                                                                                          |
| `-l` / `-c`                            | native rg flags — files-with-matches / per-file match count                                                                                                                                 |
| `-t <lang>` / `-g <glob>`              | `--lang` / `--glob` — pruned **before** touching disk (`--lang go` reads 234 of 18,608 files, **1.44×** faster than `rg -t go`, byte-identical output)                                      |
| `-w` / `-F` / `-i` / `-S`              | word-boundary / fixed-string / case-insensitive / smart-case                                                                                                                                |
| `-B N` / `-A N` / `-C N`               | context lines, rg-exact `:`/`-`/`--` framing                                                                                                                                                |
| `-m N` / `-o` / `-r <t>`               | max count per file / only-matching spans / template replace                                                                                                                                 |
| `-e <pat>` / `--`                      | explicit pattern (leading-dash safe) / end of flag parsing                                                                                                                                  |
| `--hidden`, `--no-ignore*`, `-u`/`-uu` | real, functional — widen the walk exactly as they do in rg (see below)                                                                                                                      |
| `--sort` / `--sortr` / `--sort-files`  | accepted-but-ignored for argv compatibility — value is consumed; **output ordering is not implemented** (schema `.accepted_but_ignored`); only ignore-walker anchoring observes sorted mode |

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
PASS / 15 ORDER / 0 FAIL / 41 NA / 121 SKIP**. Supported-surface parity is
**(PASS+ORDER)/(PASS+ORDER+FAIL) = 100% with zero FAIL** — ORDER is explicitly
_not_ byte-identical stdout (identical match set, worker-discovery order only).
Exact byte-identical classes are additionally gated by
[`bench/gates/line_parity.sh`](bench/gates/line_parity.sh)
(both engines plus deterministic exact-output generators for the 265,286- and
147,087-line result classes). The by-design boundaries are listed under "Where
gist departs from ripgrep." The exhaustive rg-compatible flag reference lives in
[`src/commands/ripgrep/args.zig`](src/commands/ripgrep/args.zig).

Streams follow the `rg` convention too, so gist composes in a pipeline the
same way: matches go to **stdout**, and — a stronger bar than `rg` itself, not
just parity with it — the default path puts NOTHING on stderr at all (`gist
Foo -l > files` captures only the paths; `gist Foo | head` shows only
matches). The one deliberate exception is `--rank`, which prints its
cold-load/rank timing to stderr so an agent can see the cost of the ranked
view — guarded by [`bench/gates/streams.sh`](bench/gates/streams.sh).

## Where gist departs from ripgrep — on purpose

**Departs on stdout ordering under the parallel engine.** Fifteen rgsuite cases
are **ORDER** (identical match set, worker-discovery line order) — counted toward
supported-surface parity, **not** toward byte-identical PASS. Do not read
"100% supported-surface parity" as "100% byte-identical stdout."

**Departs on `--sort` / `--sortr` / `--sort-files`.** Accepted for argv
compatibility and ignored for output ordering (see `--schema`); gist does not
implement ripgrep's sorted emitters.

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

**Current measured corpus (15,840 files · 142.9 MiB ·
`services libs clients contracts scripts quality`, Apple M2):**

- **Correctness first.** The frozen oracle checks **140 literals + 70 regexes**
  with **0 false negatives / 0 false positives**. The live no-prefilter gate
  separately proves the fused walk against rg on five dense patterns, also
  **0/0**. The mined rgsuite is **279/279 supported cases** (264 exact + 15
  order-only, 0 failures).
- **Index economics.** gist builds in **3.2 s** to a **28.1 MiB posting blob**
  and **29.0 MiB required runtime cache** (`index.gist` + `paths.list` +
  `built.ns`). Verification/certificate outputs are reported separately as
  workspace bytes and never counted as the cache. On the same run, csearch built
  in **11.1 s / 29.6 MiB** and zoekt in **6.2 s / 385.6 MiB**. The loader maps
  and structurally validates a trusted local blob in ~0.4 ms; posting groups
  decode only when queried.
- **Cold fresh-process.** The committed fail-closed certificate below is now
  **targeted** cold dominance against official ripgrep across eleven
  literal and regex classes. The old 0/11 artifact measured the now-deleted full posting
  validation + second freshness walk, not an architectural floor.
- **What changed.** The common path fuses freshness metadata into directory
  enumeration, admits the index only for broad/selective queries, stores exact
  indexed paths in a compact open-addressed table, routes selective work to four
  workers on this 8-core host, and reuses the compiled regex's sound required
  literal as a SIMD line/file gate. None changes output.
- **Resident mode.** Keeping the mmap resident still removes process startup and
  the live walk, so it remains the ultra-low-latency tier. It is no longer
  justified as a mandatory daemon merely to outrun rg cold.
- **No-prefilter floor.** With no sound literal, gist reads the live tree once
  through the fused work-stealing pipeline. The permanent gate currently
  measures ~**201–207 ms** for gist versus **219–299 ms** for rg on four dense
  patterns (**1.06–1.49× faster**); the sparse `panic|0x` case is the honest
  exception at **0.93×**. All five sets are byte-identical. The remaining floor
  is per-file `openat` + read + close, not regex execution.

![gist no-prefilter scan path optimization progression](assets/gist-scan-progression.png)

> _The no-prefilter scan tier, profiled to the floor. **(a)** the phased→fused
> work-stealing rewrite collapsed per-core finish spread (worker-span Δ 169 → 2.5
> ms — the walk folds under the scan); **(b)** premultiplied DFA transition tables
> cut the dense scan to the scalar-DFA floor (~one L1 load-use/byte), PMU-measured
> on Apple Silicon; **(c)** the latency-bound signature — cycles/byte fell ~4× the
> instruction drop while IPC *rose*, so it's a critical-path win, not throughput;
> **(d)** the structural verdict — gist's per-file syscall floor makes its time
> nearly pattern-independent, so the margin over rg widens with match density;
> the sparse-literal tail can still favor rg. 0 FN / 0 FP._

### Macroscopic field race — the fail-closed certificate (`certify.sh`)

[`bench/certify/certify.sh`](bench/certify/certify.sh) is the most adversarial cut: a
fresh-process **cold** query for gist **and all seven field tools** over the
same declared roots (csearch gets gist's exact path list; zoekt's documented
ignore-limited superset), with hyperfine 20 runs + 3 warmup, a 95% bootstrap-CI
median per cell, and a gist-vs-ripgrep verdict that is **fail-closed** — a WIN
needs a lower median _and_ Mann-Whitney `p<0.05`. The certificate is **committed
and reproducible** under [`bench/certify/artifact/`](bench/certify/artifact/):
the rendered `CERTIFICATE.md`, microscopic `certify.csv`, `certify_macro.csv`
(median + 95% CI + verdict per cell), per-cell hyperfine JSON, exact tool
identities, the timed command log, and a per-file SHA-256 corpus manifest. The
figure below renders from the committed macro CSV; `check_artifacts.py` gates the
bundle and required-cache accounting. Every plotted number is
`certify_macro.csv` verbatim, all 11 classes.

![gist fail-closed statistical certificate forest plot](assets/gist-certify-forest.png)

> _The certificate itself, rendered from the committed `certify_macro.csv`.
> **(a)** gist's median (blue diamond) vs rg's median + 95% bootstrap CI per
> class, log-ms — non-overlapping whiskers are what make the verdict statistically
> real. **(b)** gist's speedup over the indexed rivals csearch/zoekt, log-x, `<1`
> means the rival wins cold._

- **gist vs ripgrep — cold fail-closed path (republish certificate on clean HEAD).**
  Ten classes are both faster in median and Mann-Whitney significant. Wins span
  selective literals, anchored/dotted/declaration regexes, alternation, the dense
  scan, and EOL; the UUID-like classcount is statistically tied.
- **The win did not weaken freshness.** The parallel walk already needs directory
  metadata, so it now makes the indexed/non-indexed decision from those same
  mtime/ctime values instead of paying a second corpus traversal. Unknown, new,
  and touched paths still fail open to live reads; malformed persisted state
  fails closed.
- **Indexed rivals remain useful context, not the oracle.** csearch can still win
  highly selective cold cells and zoekt wins some shapes; both skip gist's
  read-your-writes guarantee. The certificate's field block reports every one of
  those outcomes alongside rg, ugrep, ag, GNU grep, and git grep.
- **Residency is optional.** A long-lived mmap remains the absolute latency floor
  for an agent issuing many queries, but the cold CLI now beats rg on 10/11
  classes and ties the other. A resident daemon is therefore an optional
  throughput optimization, not required architecture.

The previous 0/11 certificate was valuable evidence, but its diagnosis was too
broad: freshness itself was not the floor. Full posting validation on every load,
a redundant freshness walk, all-path hash construction, fixed worker topology,
and missed regex literals were removable overheads. The current committed raw
samples supersede that artifact.

### Certificate of Optimality — the scan kernel is at the hardware limit

Layer A measures the **end-to-end cold query** (republish for the live scoreboard; no
losses). The next three layers make a narrower claim about the **scan kernel
itself**: once gist is reading candidate bytes, that inner loop is at the chip's ceiling — no
implementation on this core can scan materially faster. Each layer is
cheapest-evidence-first, splicing into one generated `CERTIFICATE.md` (recipe +
full tables in
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

This ABI is intentionally minimal and does **not** expose index build, open,
search, result ownership, or errors. The search engine is consumed through Zig
or the CLI; `zig build test` compiles, links, and runs a C smoke against the two
exported symbols.
