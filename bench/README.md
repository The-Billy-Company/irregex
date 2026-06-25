# gist/bench

Benchmark harness for the `gist` code-locator kernel. `bench.zig` loads a real
corpus (every code file under the given dirs), builds the T0 trigram `Index`,
and times the query slate — reporting corpus size, one-time build cost, index
footprint, and per-query candidate count + median latency.

```bash
cd pkg/kernels/gist
zig build -Doptimize=ReleaseFast bench                 # default Billy source roots
zig build -Doptimize=ReleaseFast bench -- services libs # scope to specific dirs
```

The run step sets cwd to the repo root, so dir arguments are repo-root-relative.
The candidate count is a **sound superset** of `rg`'s true match-file count; the
gap is the trigram filter's false-positive rate (verified away by the caller's
real regex). Set the numbers against a correctly-scoped `rg` baseline (scope to
source dirs — an unscoped `rg` from repo root drags through ~99 GB of `target/`
+ caches and is not a fair comparison).

## The field — who gist races

Three race scripts pit gist against **seven** code searchers, split by whether
they keep an index. The registry, fairness scoping, and per-tool invocations all
live in **`_compete.sh`** (sourced by every script); columns auto-skip when a
binary isn't installed.

| Tool | Kind | Notes |
|---|---|---|
| **gist** | indexed | our kernel — resident RAM index (warm) or instant cold-load (cold) |
| **csearch** | indexed | Google Code Search (Russ Cox) — gist's direct trigram ancestor; the apples-to-apples rival |
| **zoekt** | indexed | Sourcegraph's production indexed search (trigram + ctags symbols) |
| **rg** | unindexed | ripgrep — the gold-standard parallel scanner |
| **ugrep** | unindexed | claims-fastest grep; SIMD + PCRE2-JIT |
| **ag** | unindexed | the_silver_searcher |
| **ggrep** | unindexed | GNU grep (`ggrep` on macOS) — the classic baseline |
| **git grep** | unindexed | the in-repo dev-workflow default |

Install the optional ones: `brew install ugrep grep` ·
`go install github.com/google/codesearch/cmd/{cindex,csearch}@latest` ·
`go install github.com/sourcegraph/zoekt/cmd/{zoekt-index,zoekt}@latest`.

| Script | Race |
|---|---|
| `headtohead.sh` | **warm**: gist resident-index p50 vs the unindexed scanners (the long-lived agent-session model) |
| `coldquery.sh` | **cold literal**: fresh-process gist vs csearch/zoekt (indexed) + rg/ugrep/ag/ggrep/git-grep (unindexed) |
| `regex_headtohead.sh` | **cold regex**: same field, gist's byte-class DFA vs RE2 (csearch/zoekt) and PCRE (`-P`) / `(?-u)` |
| `equality.sh` | **correctness**: gist ≡ `rg` over a byte-exact corpus snapshot (the soundness oracle) |

Each race prints per-query times with gist's speedup, then a summary: **geomean
speedup and win-rate per tool**, split indexed vs unindexed. Raw rows land in
`.local/gist-compete/{cold,regex,warm}.csv` for your own analysis.

## Fairness — stated, not hand-waved

Every tool is scoped to the same source roots (`services libs clients contracts
scripts quality`) and given its honest fastest path:

- **rg / git grep** honor `.gitignore` natively (skip the gitignored ~99 GB of
  build artifacts). **ag** is handed `--path-to-ignore .gitignore` (the root
  ignore set `rg` reads for free). **ugrep / GNU grep** have no per-file
  gitignore, so they get the heavy dir-exclude set (`$XDIRS`) — they still scan a
  slightly *larger* file set (gitignored individual files `rg` skips), which only
  makes them do **more** work, so gist's win over them is conservative.
- **csearch** indexes gist's **exact corpus file list** (the persisted
  `paths.list` doc→path table) → byte-for-byte the same files → result sets ≈
  `rg`'s. It is the faithful indexed twin (the small delta is the few files
  csearch's own binary heuristic drops: 16,696 of 17,112).
- **zoekt** has no file-list input, so it indexes the roots tree under the same
  heavy ignore set; its corpus is a documented superset (no per-file gitignore +
  ctags symbol indexing). Quoted-literal counts still match `rg` on selective
  needles — treat it as a production-grade **timing reference**, not a
  correctness oracle (`rg` + `csearch` are).
- Timing is `hyperfine` mean, warm page cache, fresh process. Every command's
  output is drained (`… | wc -l`) so ugrep's lazy multithreaded `-l` actually
  scans (it short-circuits when a harness discards its stdout) and a needle
  *miss* (grep exits 1) doesn't abort the run. **Ratios** are the headline
  number — robust to this shared dev box's load because each query's tools run
  back-to-back under the same conditions.

## Scenarios

- **Warm/oracle slate** (`bench.zig`): 20 adversarial literals (rare symbol,
  dotted ident, 2-byte punctuation, guaranteed miss, repeated-char pathological,
  cross-language keywords) + 30 regex shapes spanning every feature tier.
- **Cold literal slate** (`coldquery.sh`): a guaranteed miss (pure index win),
  very-selective symbols, medium, common tokens touching thousands of files, and
  a 2-byte punctuation needle (the `<3 B`, no-trigram-filter fallback).
- **Cold regex slate** (`regex_headtohead.sh`): 22 patterns grouped by tier —
  literal-prefix, anchored `^`/`$`, counted `{n,m}`, dense classes (`\w{3,8}` —
  the byte-class DFA's home), alternation cover sets, and a prefilter-less
  mixed alternation.

`equality.sh` has gist emit its verified matching-file set per pattern **plus a
byte-exact snapshot of the files it indexed** (the corpus is regenerated live by
coworker agents — the snapshot freezes the bytes so the diff can't race), then
runs `rg` over that identical snapshot and diffs. A file in rg's set but not
gist's = a trigram-filter false negative (the one unforgivable bug); a file in
gist's but not rg's = an unsound verify. Both must be zero.

```bash
cd pkg/kernels/gist
bench/equality.sh 150 1      # gist ≡ rg over a byte-exact corpus snapshot, per needle
bench/headtohead.sh          # WARM: gist resident p50 vs the unindexed scanners
bench/coldquery.sh           # COLD literal: gist vs csearch/zoekt + rg/ugrep/ag/ggrep/git-grep
bench/regex_headtohead.sh    # COLD regex: same field, per feature tier
zig build -Doptimize=ReleaseFast bench   # build cost, footprint, latency p50/p95/p99
```
