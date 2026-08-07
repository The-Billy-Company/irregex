# `contract/` — Engine, Surface, and Evidence Contracts

- [Engine Contract](#engine-contract)
- [Analytic Contract](#analytic-contract)
- [Export Surface](#export-surface)
- [Import Topology](#import-topology)
- [Kinship Vocabulary](#kinship-vocabulary)
- [Evidence Contracts](#evidence-contracts)
- [Why These Files Exist](#why-these-files-exist)
- [When to Edit](#when-to-edit)

## Engine Contract

[`engine.toml`](engine.toml) is the source of truth for the search engine's request and process contract: the `SearchRequest` options every face accepts, the `Match` kinds it returns, the process exit codes, and the C-ABI and engine version axes.

This package authors the file; the Go, Python, and Rust bindings under `../bindings/` each resolve it directly from this checkout rather than copying its enumerations by hand, so a package constant and the binary's version can never silently diverge. Widening `[request_options]` is an interface change — review it like an ABI bump, not a casual edit.

## Analytic Contract

[`analytic.toml`](analytic.toml) is the row schema and verb table behind every analytic result: a schema ID, a presence mask, and a flat `irgx_value` array, plus which library answers which op code. `tools/build_schema_tables.py` lowers it into `src/surface/ffi/schema.gen.zig` and into each binding's generated table, and its `--check` flag is the drift gate — nothing here is mirrored by hand.

## Export Surface

[`exports.toml`](exports.toml) is the outward half of the import-topology law: it declares every name `src/root.zig` may export, tiered as *stable* (semver-protected), *provisional* (shipping but still settling), or *internal* (no promise, product-seam only). [`quality/surface/check.py`](../quality/surface/check.py) judges the actual root module against this file — a name exported without a row here fails, and a row without a matching export fails too.

Each row carries a `why` field naming the reader the export is for, so adding a public name costs one line explaining who needs it. Run the gate locally with the same command CI uses:

```bash
python3 quality/surface/check.py
```

## Import Topology

[`../charter.zone`](../charter.zone) is the machine-checkable half of the package's layering — which tier a file may import from, judged by the standalone [`zoning`](https://github.com/The-Billy-Company/zoning) tool rather than convention. `src/README.md` and the per-tier READMEs are the prose version of the same law; that file is what actually fails a build when an import points the wrong way. It sits at the package root rather than in this drawer because a contract governs the directory it sits in, and the thing it governs is the whole package. CI runs it as the `topology` job:

```bash
uv run --no-project --with zoning==1.3.1 zoning verify --complete
```

## Kinship Vocabulary

[`kinship.toml`](kinship.toml) is vendored from the sibling `relate` repository's `contract/kinship.toml` and must not be edited here — it defines compression-as-search vocabulary (sketches, channels, grades, verbs) that `relate` owns, kept as a local copy so this package's corpus and FM-index stay checkable against the same vocabulary `relate` builds kinship search on top of.

## Evidence Contracts

Two files freeze what a published claim is allowed to say, the way `engine.toml` freezes what a request is allowed to ask.

- **[`performance_evidence.toml`](performance_evidence.toml)** is the source of truth for every published *operational-envelope* claim about this engine — index lifecycle cost, footprint ratios, scaling shape, and concurrency — as distinct from the field-dominance and correctness numbers minted into `bench/certificate/artifact/CERTIFICATE.md`. It freezes the measurement regimes, the corpora, the required competitors, the provenance every bundle must carry, and the `[[claim]]` rows binding a prose number to one artifact.
- **[`crest_evidence.toml`](crest_evidence.toml)** freezes the proof inputs and package shape for the CREST benchmark — the forced-class-run necessary condition proved in `research/crest/`, measured by `bench/rungs/crest/bench.zig` and run with `zig build crest`.

## Why These Files Exist

The sibling `gist`, `relate`, and `blast` CLIs, this package's own Go/Python/Rust bindings, and any future consumer all speak one request shape over one engine. Freezing the enumerations in a contract file means a language binding and the engine's own version can never quietly drift apart from each other.

## When to Edit

Add a new matcher control that every face must honor to `engine.toml` first, then update the bindings and the Zig `flag_catalog` in the same change. Add a new public name to `exports.toml` in the same change that exports it from `root.zig`.

Flag *parsing* itself lives in [`../src/exec/cold/argv/args.zig`](../src/exec/cold/argv/args.zig); each `flag = …` entry in `engine.toml` names the rg-parity flag a request option lowers into.
