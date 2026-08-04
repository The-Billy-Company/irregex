# irregex/bench

Benchmark, verification, and competitive-proof harness for the search engine —
no engine code lives here (that is all under `src/`).

The certificate split three ways when the four packages did, on one rule every
package's own charter states: *a package certifies what it builds.* A claim
measurable by linking the engine belongs to `irregex`; a claim that needs a
running product binary belongs to whichever package builds that binary — the
CLI races and the `gist` binary's own layers to `gist`, retrieval and
multi-pattern attribution to `relate`. Each package now mints its own bundle,
over its own corpus, with its own ledger, and none of the three borrows a
number from either of the others.

- **[`apparatus/`](apparatus/README.md)** holds the instruments — the shared
  Zig modules (`probes`, `pmu`, `stats`) plus the vendored shell/Python layer
  (`roots.sh`, `statcore.py`, `field.sh`, `hyperfine.py`, `provenance.py`,
  `shared_drift.py`) that is byte-identical across all four packages.

- **[`bounds/`](bounds/README.md)** holds Layers B–D — this package's distance
  from a stated physical or information-theoretic limit: [`port/`](bounds/port/README.md)
  the `llvm-mca` static bound plus the on-machine measurement, [`roofline/`](bounds/roofline/README.md)
  the memory roof, and [`lowerbound/`](bounds/lowerbound/README.md) the
  candidate-byte floor. Layer F, the codex self-index against the order-0
  entropy bound, lives in `relate/bench/bounds/codex/`.

- **[`rungs/`](rungs/README.md)** holds the per-mechanism production proofs:
  [`crest/`](rungs/crest/README.md) (Layer E), plus [`sieve/`](rungs/sieve/README.md)
  (also the source of Layer L's index-quality head-to-head), [`shuffle/`](rungs/shuffle/README.md),
  [`parabix/`](rungs/parabix/README.md), and [`sliver/`](rungs/sliver/README.md)
  (also the source of Layer J's scale measurement). The multi-pattern arm
  that used to race here moved to `relate/bench/rungs/multipattern/`, next to
  the Layer K it feeds.

- **`certificate/`** is this package's own Dominance-and-Fit bundle — `mint/`
  the mint script, `report/` the layer splicers, `guard/` the reproducibility
  and roster checks, `ledger/` the mint history, and `artifact/` the frozen
  published receipts. It mints Layers B, B′, C, D, E, J, and L: everything
  this package can certify by linking the engine, and nothing that needs a
  running `gist` or `relate` binary.

Two more evidence genres live entirely with the packages that build the
binaries they measure:

- **`gist/bench/dominance/`** (sibling `gist` repo) is measured product
  performance in the world — `races/` the competitor field and the
  multi-tool head-to-heads, `session/` the warm resident-daemon tier,
  `evaluate/` the operational envelope (lifecycle cost, footprint, scaling,
  concurrency).

- **`gist/bench/certificate/`** and **`relate/bench/certificate/`** are the
  other two packages' own bundles, structured the same way as this one's.
  `gist`'s mints Layers A (empirical dominance over ripgrep), H (the
  portability matrix), and I (scanner mode, the index taken away). `relate`'s
  mints Layers F (the codex self-index), G (the retrieval contract), and K
  (multi-pattern attribution, against Hyperscan/Vectorscan).

- **`gist/bench/conformance/`** is fail-closed CLI correctness — no timing
  claim lives there — and **`relate/bench/conformance/relate/`** is the
  retrieval contract's own correctness gate.

Every lane installs on its own named step, and `zig build lab` installs all
fourteen at once. A bare `zig build` builds only the library and its C ABI:

```bash
cd <irregex-repo-root>
zig build lab                                    # all 14 → zig-out/bin
zig build -Doptimize=ReleaseFast crest           # one production rung
zig build -Doptimize=ReleaseFast roofline        # one certificate layer
zig build -Doptimize=ReleaseFast portbound       # Layer B′ with real cycles
```

Each run step sets cwd to the package root, so path arguments are
package-relative. Certificate layers honor whatever `-Doptimize` you ask for,
since a cycles/byte number is a claim about *this* build; production rungs
default to `-Dlab-optimize=ReleaseFast` because a rung that races the shipped
ladder has to be compiled the way the shipped ladder is, or the ratio is
about the build mode rather than the machine.

The one certificate layer that is **not** a claim about this build is the
memory roof: `bounds/roofline/` measures the machine's bandwidth, and a Debug
build of its vector reduction measures its own codegen instead — flat across
all three cache tiers, roughly an order of magnitude low, and
indistinguishable from a real hierarchy once it is JSON. It therefore refuses
to run unoptimized rather than publish, so the `-Doptimize` above is not
advice.

The corpus-slate lane (`zig build bench`) moved to the `gist` package with
the `gist-bench` binary. The candidate count it reports is a **sound
superset** of `rg`'s true match-file count; the gap is the trigram filter's
false-positive rate, verified away by the caller's real regex.

## The Field — Who Gist Races

The product-level races below live in the sibling `gist` repo, not this one —
this section documents what they measure so a reader here knows what a Layer
A number means before opening that repo. `gist/bench/dominance/races/`,
`conformance/gates/`, and `gist/bench/certificate/` all race `gist` against
the same **seven** code searchers, split by whether they keep an index. The
registry, fairness scoping, and per-tool invocations live in
`gist/bench/dominance/races/field.sh` (sourced by every script below except
`equality.sh`), which itself sources the vendored, cross-package
`bench/apparatus/field.sh` for the corpus-scoping and hyperfine-timing rules
every package's races share; columns auto-skip when a binary is not
installed.

- **gist** — indexed, our engine's product — resident RAM index (warm) or
  instant cold-load (cold).
- **csearch** — indexed, Google Code Search (Russ Cox) — gist's direct
  trigram ancestor, the apples-to-apples rival.
- **zoekt** — indexed, Sourcegraph's production indexed search (trigram +
  ctags symbols).
- **rg** — unindexed, ripgrep — the gold-standard parallel scanner.
- **ugrep** — unindexed, claims-fastest grep — SIMD + PCRE2-JIT.
- **ag** — unindexed, the_silver_searcher.
- **ggrep** — unindexed, GNU grep (`ggrep` on macOS) — the classic baseline.
- **git grep** — unindexed, the in-repo dev-workflow default.

Install the optional ones: `brew install ugrep grep` ·
`go install github.com/google/codesearch/cmd/{cindex,csearch}@latest` ·
`go install github.com/sourcegraph/zoekt/cmd/{zoekt-index,zoekt}@latest`.

### Which Rival, Exactly — the Identity a Mint Records

`@latest` names no version, so the roster above does not pin itself: the
rival is whatever the machine happened to have. Every mint therefore writes
each tool's identity to **`tool-versions.txt`** beside the receipts — the
version the tool reports of itself **and** the sha256 of the executable that
resolved. Both, because either alone degrades quietly.

A **digest alone** can name the wrong file. Under a version manager
`command -v csearch` resolves to the multiplexer, not the rival — a `mise`
shim is a symlink to `mise` — so shimmed tools hash to one launcher while
still reading as exact pins. Measured here: `csearch`, `zoekt`, and `zig` all
recorded the single digest `20d3bc06…`, which is `mise`. `guard/artifacts.py`
now fails closed when two tool ids share a digest, and identity resolution
walks `PATH` for a candidate whose name survives symlink resolution (a
multiplexer renames itself; a real install does not), so the digest names the
rival rather than the launcher.

A **version alone** cannot distinguish two local builds of one release. Both
csearch copies on this box are module `v1.2.0` compiled by different Go
toolchains, and only the digest separates them.

csearch and zoekt carry **no version flag at all**, so their pin is the
embedded Go module version, read from build metadata rather than by running
them — `csearch version` treats `version` as the *regexp* and prints a
matching corpus line, which scraped a bogus `26.3.0` into an identity before
the probe order was fixed. Expect `github.com/google/codesearch v1.2.0` and a
`github.com/sourcegraph/zoekt` commit pseudo-version.

- **`gist/bench/dominance/races/warm.sh`** races **warm**: gist's resident-index
  p50 against the unindexed scanners — the long-lived agent-session model.
- **`gist/bench/dominance/races/cold.sh`** races **cold literal**: fresh-process
  gist against csearch/zoekt (indexed) plus rg/ugrep/ag/ggrep/git-grep
  (unindexed).
- **`gist/bench/dominance/races/regex.sh`** races **cold regex**: the same
  field, gist's byte-class DFA against RE2 (csearch/zoekt) and PCRE (`-P`) /
  `(?-u)`.
- **`conformance/gates/parity/equality.sh`** proves **correctness**: gist ≡
  `rg` over a byte-exact corpus snapshot — the soundness oracle, index path.
- **`conformance/gates/parity/scan_regress.sh`** is the **scan-path
  regression + race**: the no-prefilter live-tree scan ≡ `rg` (gate, exits 1
  on a false negative/positive) plus min-of-N against `rg` and the
  straggler-balance canary.
- **`conformance/gates/contract/streams.sh`** gates the **output contract**
  (exits 1 on violation): results to stdout, diagnostics to stderr, across
  the literal, rank, and scan paths — the `rg`-conventional split that makes
  gist composable in agent pipelines.
- **`gist/bench/certificate/mint/mint.sh`** mints the **statistical
  certificate**: the same field, per regex class, with a fail-closed
  bootstrap-CI + Mann-Whitney verdict against ripgrep.

Each race prints per-query times with gist's speedup, then a summary:
**geomean speedup and win-rate per tool**, split indexed versus unindexed.
Raw rows land in `.local/gist-compete/{cold,regex,warm}.csv` for your own
analysis. See `gist/bench/dominance/races/README.md` and
`conformance/gates/README.md` for the scenario-level detail.

`gist/bench/dominance/races/warm.sh` times gist's **in-process** engine (the
microsecond ceiling — no transport, no process spawn), which no client
actually rides. The honest warm-**product** path — a persistent client
dialing a `gist serve` daemon once and replaying the slate over that warm
connection — is certified separately in `gist/bench/dominance/session/`, the
only sound basis for a "warm is Nx faster than ripgrep" claim.

## Fairness — Stated, Not Hand-Waved

Every tool is scoped to the same source roots (`$GIST_ROOTS` when set, else
the tree's own roots — `field.sh` resolves them once, mirroring
`corpus.resolveRoots`) and given its honest fastest path.

- **rg / git grep** honor `.gitignore` natively (skip the gitignored ~99 GB
  of build artifacts). **ag** is handed `--path-to-ignore .gitignore` (the
  root ignore set `rg` reads for free). **ugrep / GNU grep** have no
  per-file gitignore, so they get the heavy dir-exclude set (`$XDIRS`) —
  they still scan a slightly *larger* file set (gitignored individual files
  `rg` skips), which only makes them do **more** work, so gist's win over
  them is conservative.
- **gist / rg** additionally run under `--no-ignore-vcs` plus the root
  `.gitignore`, so a multi-root race can't hit ripgrep's nondeterministic
  parent-ignore re-anchoring. That also discards every *nested* `.gitignore`,
  which is why `field.sh` re-applies the build-output exclusions as globs
  (`$SCOPE`): without them these two alone walk build artifacts the root
  ignore never names — Elixir `_build`/`deps`/`cover`, Electron `out/` —
  that `gist index` prunes and csearch therefore never indexes. Not the
  whole of `$XDIRS`, because `vendor` holds tracked source; mix output is
  anchored per `mix.exs` root for the same reason rule-of-five anchors it.
- **csearch** indexes gist's **exact corpus file list** (the persisted
  `paths.list` doc→path table) → byte-for-byte the same files → result sets
  ≈ `rg`'s. It is the faithful indexed twin (the small delta is the few
  files csearch's own binary heuristic drops: 16,696 of 17,112).
- **zoekt** has no file-list input, so it indexes the roots tree under the
  same heavy ignore set; its corpus is a documented superset (no per-file
  gitignore plus ctags symbol indexing). Quoted-literal counts still match
  `rg` on selective needles — treat it as a production-grade **timing
  reference**, not a correctness oracle (`rg` plus `csearch` are).
- Timing is `hyperfine` mean, warm page cache, fresh process. Every command's
  output is drained (`… | wc -l`) so ugrep's lazy multithreaded `-l` actually
  scans (it short-circuits when a harness discards its stdout) and a needle
  *miss* (grep exits 1) doesn't abort the run. **Ratios** are the headline
  number — robust to this shared dev box's load because each query's tools
  run back-to-back under the same conditions.

## Dominance-and-Fit Certificate (Layers A–L)

The race scripts above report *means and ratios*. The **certificate** turns
that into a checkable claim — every number carries a 95% bootstrap
confidence interval and, against its named rival, a Mann-Whitney
significance test, so a "win" is **statistically real**, not box noise. It
is not a proof of universal or hardware optimality, and no layer claims one.

Twelve named layers span the three packages, each publishing over its own
corpus with its own ledger:

- **A** — empirical dominance over ripgrep on the registered workloads,
  fail-closed (`gist`).
- **B / B′** — port-optimality: the static µarch bound, then the same bound
  measured on this machine (`irregex`, this package).
- **C** — roofline: the memory ceiling and the fraction of it reached
  (`irregex`).
- **D** — the algorithmic lower bound: the information-theoretic
  candidate-byte floor (`irregex`).
- **E** — the crest sieve: fail-closed pruning of the literal-free
  class-repetition blind spot every trigram index concedes (`irregex`).
- **F** — the codex self-index: compressed below the order-0 entropy coder
  yet searchable and byte-exact decodable (`relate`).
- **G** — the relate retrieval contract: boundary, recall@1, and
  anti-redundant pack, graded rather than raced (`relate`).
- **H** — the portability matrix, graded by what was actually executed
  (`gist`).
- **I** — scanner mode: gist with the index taken away, on ripgrep's own
  home turf (`gist`).
- **J** — positional and substring index tiers at scale, including the tier
  measured and declined (`irregex`).
- **K** — multi-pattern simultaneous matching, against Hyperscan/Vectorscan
  (`relate`).
- **L** — index quality head-to-head against csearch (`irregex`).

This package's own bundle — Layers B, B′, C, D, E, J, and L — is minted by
`bench/certificate/mint/mint.sh` and published to `bench/certificate/artifact/`.
Its most recent mint (`bench/certificate/ledger/LEDGER.md`) recorded all
seven of its layers present, none absent. The other five layers are not
missing from this repository — they are published by `gist` and `relate`,
over their own corpora, with their own ledgers, and this README does not
restate their numbers.

Always build **`-Doptimize=ReleaseFast`** — a Debug build is not vectorized
and its cycles/byte and bandwidth numbers are meaningless (a Debug scan
measures loop overhead, not the memory hierarchy). The report splicers
resolve `.gist/` at the repo root by default, so they run from anywhere.

Mint or refresh this package's bundle with one command:

```bash
# Full mint of Layers B/B′/C/D/E/J/L, wall-clock only for B′ (no sudo):
bash bench/certificate/mint/mint.sh

# Same, plus Layer B′'s measured cycles/byte (needs a passwordless sudo rule
# or an interactive prompt — see bench/apparatus/privilege/README.md):
CERT_SUDO=1 bash bench/certificate/mint/mint.sh

# Mint and publish the frozen receipts:
CERT_PUBLISH_DIR=bench/certificate/artifact CERT_SUDO=1 \
  bash bench/certificate/mint/mint.sh
```

Run a full mint in a clean, stable checkout or isolated worktree. A live
coworking tree is not a benchmark corpus: files can change between tools,
invalidating equivalence, timing, and corpus hashes. `CERT_ALLOW_DIRTY=1`
permits local exploratory evidence only; it does not make a dirty result a
publishable, commit-reproducible certificate. `CERT_CORPUS_ID` names which
declared corpus in `bench/certificate/corpus.toml` the mint measures
(default `ecosystem-v1`, the four sibling packages side by side — Layer J
and L need a corpus where every probe class discriminates, which this
package's own tree alone does not); `GIST_CORPUS_ROOT` points the mint at a
tree already on disk instead of fetching one.

`CERT_SUDO=auto` (default) uses passwordless `sudo -n` when configured, else
degrades loudly; `CERT_SUDO=1` prompts once; `CERT_SUDO=0` never escalates.
Each layer degrades gracefully rather than failing the whole mint — but
**loudly in the artifact**: Layer B without `llvm-mca` prints a documented
skip; Layer B′ without `sudo` records wall-clock ns and fail-closed labels
cycles as cross-checked-only. None invents a number for hardware it can't
measure (no fabricated Apple-Silicon `llvm-mca` model, no wall-clock dressed
up as cycles via an assumed frequency — see [`bounds/port/README.md`](bounds/port/README.md)).
