# bench/apparatus

The **instruments.** Nothing here makes a claim; everything here is what the
other buckets — and the sibling packages' own certificates — measure *with*.

- **[`harness/`](harness/README.md)** holds the three shared Zig instruments,
  each exported as its own module: `probes.zig` the 12-class query registry,
  `pmu.zig` the hardware counters, and `stats.zig` the bootstrap-CI /
  Mann-Whitney verdict math.

- **`roots.sh`** answers where this package's siblings are — climbs to the
  package root, then names the checkouts that own the product and kinship
  binaries and the corpus a race runs over. It is vendored byte-identical
  across all four packages — this engine plus its three sibling faces — so
  each package answers "where are my siblings?" the same way rather than
  keeping its own opinion.

- **`statcore.py`** is the Python leg of the same verdict math — Type-7
  quantiles, bootstrap-CI medians, and the tie-corrected Mann-Whitney
  dominance call. `test_statcore.py` holds it to known answers derived from
  the definitions, not from a run of itself. It replaced the older
  `stats.py`; the rename went with a scope change, below.

- **`field.sh`** is the vendored measurement floor every package's races and
  mints stand on: what the corpus is, how a rival tool gets an index built
  over it, and when a timing counts as honest (only after its output is
  proven equivalent to ripgrep's, through one pinned `hyperfine`
  invocation). It is sourced, never executed directly — a package's own
  race script sources it and adds the per-tool command builders and field
  roster, which stay local because what each package *races* is its own.

- **`hyperfine.py`** reads a `hyperfine --export-json` file into
  milliseconds, the one wire format every race speaks; it is the seam
  between the shell that times a cell and the Python that judges it.

- **`provenance.py`** emits the three files a mint needs to be reproducible —
  `machine.json`, `tool-versions.txt`, `corpus-manifest.tsv` — the same way
  in every package, so a bundle blessed by one package's reproducibility
  gate is not rejected by another's.

- **`corpora/ecosystem.sh`** materializes `ecosystem-v1`, the corpus Layers
  J and L measure over: the four sibling packages' own trees side by side —
  this engine plus each of the three product faces — fetched from their
  sibling checkouts or cloned fresh. It exists because neither this package's
  own tree (monoglot, half the size) nor the pattern face's synthetic Go
  corpus makes every probe class discriminate — `slate.py --audit` found most
  of them saturating or vacuous on those two.

- **`SHARED.sha256`** pins the sha256 of every vendored file above (plus a
  handful of `bench/certificate/guard/` and `bench/certificate/ledger/`
  modules) so `shared_drift.py` can fail closed the moment one package's
  copy diverges from the other three's. Regenerate it with
  `python3 bench/apparatus/shared_drift.py --update` only after a
  deliberate edit, and land the refreshed manifest in every package in the
  same change.

These are the only things in `bench/` that a **consumer** package can reach,
and the only reason `bench/apparatus/harness` appears in this package's
`build.zig.zon` `.paths`. `bounds/`, `rungs/`, this package's own
`certificate/`, and the pattern face's omnibus bench binary all import the
same `probes` / `pmu` / `stats` modules, so a competitor race over there and
an engine rung over here map 1:1 by class name and are judged by the same
verdict math. A second copy would silently stop meaning the same thing.

Two things left with the product they measure. The corpus fetcher went with
the conformance slate to the pattern face's `bench/apparatus/corpora/`; the
omnibus bench harness itself (`bench.zig` and its `certify` / `flagbench` /
`sessionprof` modes) went to that package's `bench/apparatus/harness/`,
because its session lane spawns a live resident daemon — and this package is
upstream of the product, so it cannot reach down to one.

`statcore.py` used to be the case where that direction bit: it was only
reachable at `bench/certificate/report/stats.py`, which left
`rungs/sliver/scale_race.py` importing a directory that did not exist here.
That is resolved now, not worked around — the statistical core lives here as
the one vendored copy, and a consumer like `rungs/sliver/scale_race.py`
imports it directly (`sys.path.insert` onto `bench/apparatus`, then
`from statcore import dominance, median_ci`) rather than reaching for a
second copy. `shared_drift.py` is what stops a future copy from quietly
drifting into a different answer.
