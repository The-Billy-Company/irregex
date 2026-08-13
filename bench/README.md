# irregex/bench

Benchmark, verification, and competitive-proof harness for the search engine —
no engine code lives here (that is all under `src/`).

The certificate split three ways when the four packages did, on one rule every
package's own charter states: *a package certifies what it builds.* A claim
measurable by linking the engine belongs to `irregex`; a claim that needs a
running product binary belongs to whichever package builds that binary — the
CLI races and the shipped binary's own layers to the exact-search face,
retrieval and multi-pattern attribution to the kinship face. Each package now
mints its own bundle, over its own corpus, with its own ledger, and none of the
three borrows a number from either of the others.

- **[`apparatus/`](apparatus/README.md)** holds the instruments — the shared
  Zig modules (`probes`, `pmu`, `stats`) plus the vendored shell/Python layer
  (`roots.sh`, `statcore.py`, `field.sh`, `hyperfine.py`, `provenance.py`,
  `shared_drift.py`) that is byte-identical across all four packages.

- **[`bounds/`](bounds/README.md)** holds Layers B–D — this package's distance
  from a stated physical or information-theoretic limit: [`port/`](bounds/port/README.md)
  the `llvm-mca` static bound plus the on-machine measurement, [`roofline/`](bounds/roofline/README.md)
  the memory roof, and [`lowerbound/`](bounds/lowerbound/README.md) the
  candidate-byte floor. Layer F, the codex self-index against the order-0
  entropy bound, lives in the kinship package's `bench/bounds/codex/`.

- **[`rungs/`](rungs/README.md)** holds the per-mechanism production proofs:
  [`crest/`](rungs/crest/README.md) (Layer E), plus [`sieve/`](rungs/sieve/README.md)
  (also the source of Layer L's index-quality head-to-head), [`shuffle/`](rungs/shuffle/README.md),
  [`parabix/`](rungs/parabix/README.md), and [`sliver/`](rungs/sliver/README.md)
  (also the source of Layer J's scale measurement). The multi-pattern arm
  that used to race here moved to the kinship package's
  `bench/rungs/multipattern/`, next to the Layer K it feeds.

- **`certificate/`** is this package's own Dominance-and-Fit bundle — `mint/`
  the mint script, `report/` the layer splicers, `guard/` the reproducibility
  and roster checks, `ledger/` the mint history, and `artifact/` the frozen
  published receipts. It mints Layers B, B′, C, D, E, J, and L: everything
  this package can certify by linking the engine, and nothing that needs a
  running product binary.

Two more evidence genres live entirely with the packages that build the
binaries they measure:

- **The exact-search face's `bench/dominance/`** is measured product
  performance in the world — `races/` the competitor field and the
  multi-tool head-to-heads, `session/` the warm resident-daemon tier,
  `evaluate/` the operational envelope (lifecycle cost, footprint, scaling,
  concurrency).

- **Each face's own `bench/certificate/`** is that package's bundle,
  structured the same way as this one's. The exact-search face mints Layers A
  (empirical dominance over ripgrep), H (the portability matrix), and I
  (scanner mode, the index taken away). The kinship face mints Layers F (the
  codex self-index), G (the retrieval contract), and K (multi-pattern
  attribution, against Hyperscan/Vectorscan).

- **The exact-search face's `bench/conformance/`** is fail-closed CLI
  correctness — no timing claim lives there — and the kinship face carries the
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

The corpus-slate lane (`zig build bench`) moved to the exact-search face along
with the bench binary that drives it. The candidate count it reports is a
**sound superset** of `rg`'s true match-file count; the gap is the trigram
filter's false-positive rate, verified away by the caller's real regex.

## The Competitor Field Is Documented Where It Runs

The rival roster, each rival's honest fastest invocation, the tool-identity
pinning a mint records, and the fairness contract every race honors are not
restated here. They govern lanes that drive a product binary this package does
not build, so they live with those lanes, in the exact-search face's
`bench/dominance/README.md`. What matters on this side is only the boundary:
those races time a shipped CLI end to end, and everything under this directory
times the engine by linking it.

The one piece of that contract this package does own is the vendored floor at
[`apparatus/field.sh`](apparatus/README.md) — the corpus-scoping and
hyperfine-timing rules every package's races share, byte-identical in all four
checkouts. A face's own field script sources it rather than re-deriving it.

## Dominance-and-Fit Certificate (Layers A–L)

The race scripts above report *means and ratios*. The **certificate** turns
that into a checkable claim — every number carries a 95% bootstrap
confidence interval and, against its named rival, a Mann-Whitney
significance test, so a "win" is **statistically real**, not box noise. It
is not a proof of universal or hardware optimality, and no layer claims one.

Twelve named layers span the three packages, each publishing over its own
corpus with its own ledger:

- **A** — empirical dominance over ripgrep on the registered workloads,
  fail-closed (the exact-search face).
- **B / B′** — port-optimality: the static µarch bound, then the same bound
  measured on this machine (`irregex`, this package).
- **C** — roofline: the memory ceiling and the fraction of it reached
  (`irregex`).
- **D** — the algorithmic lower bound: the information-theoretic
  candidate-byte floor (`irregex`).
- **E** — the crest sieve: fail-closed pruning of the literal-free
  class-repetition blind spot every trigram index concedes (`irregex`).
- **F** — the codex self-index: compressed below the order-0 entropy coder
  yet searchable and byte-exact decodable (the kinship face).
- **G** — the retrieval contract: boundary, recall@1, and anti-redundant
  pack, graded rather than raced (the kinship face).
- **H** — the portability matrix, graded by what was actually executed
  (the exact-search face).
- **I** — scanner mode: the shipped CLI with the index taken away, on
  ripgrep's own home turf (the exact-search face).
- **J** — positional and substring index tiers at scale, including the tier
  measured and declined (`irregex`).
- **K** — multi-pattern simultaneous matching, against Hyperscan/Vectorscan
  (the kinship face).
- **L** — index quality head-to-head against csearch (`irregex`).

This package's own bundle — Layers B, B′, C, D, E, J, and L — is minted by
`bench/certificate/mint/mint.sh` and published to `bench/certificate/artifact/`.
Its most recent mint (`bench/certificate/ledger/LEDGER.md`) recorded all
seven of its layers present, none absent. The other five layers are not
missing from this repository — they are published by the exact-search and
kinship faces, over their own corpora, with their own ledgers, and this README
does not restate their numbers.

Always build **`-Doptimize=ReleaseFast`** — a Debug build is not vectorized
and its cycles/byte and bandwidth numbers are meaningless (a Debug scan
measures loop overhead, not the memory hierarchy). The report splicers resolve
the artifact home at the repo root by default, so they run from anywhere.

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
