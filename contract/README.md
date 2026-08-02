# `contract/` — engine and evidence contracts

[`engine.toml`](engine.toml) is the source of truth for the search engine's
**request and process contract**:

- `SearchRequest` options every face accepts
- `Match` kinds it returns
- Process exit codes
- C ABI and engine version axes

Row schemas and the analytic verb table are substrate and live next door in
`analytic.toml` — gist, relate and blast all return those rows, so no product
owns them. What stays with a product is that product's own surface: transports,
session rules and the tool boundary in `gist/contract/surface.toml`, the
composed verbs in `blast/contract/compose.toml`, and the compression kinship
vocabulary in `relate/contract/kinship.toml`.

## Why it exists

The sibling `gist` / `relate` / `blast` CLIs, the Python `gist` package,
and the Rust bindings all speak **one** request shape over **one** engine.
This file freezes the enumerations they share so a package constant and the
binary's version can never silently diverge. Widening `[request_options]` is
an interface change — review it like an ABI bump, not a casual edit.

## Who reads it

| Consumer                                                            | How                                                                    |
| ------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| Python `gist/bindings/python`   | `gist.contract` + parity tests                                         |
| Rust `gist/bindings/rust`         | `gist::contract` + `tests/contract.rs`                                 |
| CLI `--schema`                                                      | Flag rows name the rg-parity flags in `exec/cold/argv` `flag_catalog` |
| Reviewers                                                           | Decide deep contract vs CLI-only presentation flag                     |

## When to edit

- New matcher controls that every face must honor → add here first.
- Then update bindings + Zig `flag_catalog` in the same PR.
- Transport / session / relate / compose changes belong in the surface or
  kinship contracts above, not here.

Flag _parsing_ still lives in
[`../src/exec/cold/argv/args.zig`](../src/exec/cold/argv/args.zig);
each `flag = …` here names the rg-parity flag a request option lowers into.

## `performance_evidence.toml` — the evidence contract

[`performance_evidence.toml`](performance_evidence.toml) is the source of truth
for every published Gist **operational-envelope** claim, the way `engine.toml`
is for the request and process contract. It freezes the measurement regimes (lifecycle / resource /
scale / concurrency, with parity as a build-sanity precondition), the corpora, the
required competitors, the provenance every bundle must carry, and the publication
rule (clean tree only) — plus the `[[claim]]` rows that bind a prose number to one
artifact. Cold/warm query dominance is **not** re-timed here; that is the
Dominance-and-Fit Certificate's job (sibling `gist` package,
`gist/bench/certificate/`). The evaluator that reads it
lives in `gist/bench/dominance/evaluate/`;
the evaluate-verify gate in the sibling `gist` package holds it fail-closed. Absolute latency is
machine-specific and never gated across machines — only the index/corpus footprint
ratio and scaling shape are.
