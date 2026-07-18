# gist/contract — the unified search-API contract

[`search_api.toml`](search_api.toml) is the single source of truth for GIST's
**unified search contract** ([ADR-352](../../../../docs/architecture/3-decisions/352-gist-unified-search-api.md)):
the `SearchRequest` options every face accepts, the `Match` kinds it returns,
the process exit codes it speaks, the C ABI version, and the transports that
realize it.

## Why it exists

GIST is reachable several ways — the `gist` CLI, the importable `billy-gist`
Python package, the standalone Rust `gist` crate, and Billy's agent code-search
tool. All express **one** request shape and consume **one** engine (the certified
rg-parity walk); this file freezes the enumerations they share so a package
constant and the binary's own version can never silently diverge. It is a
_contract_, reviewed as an interface change — widening `[request_options]` is a
deliberate deepening of the `SearchRequest` surface, not a casual edit.

## Who reads it

- The Python package
  ([`../bindings/python/gist`](../bindings/python)) mirrors these constants in
  `gist.contract` and asserts them against the live binary in its parity test.
- The Rust crate ([`../bindings/rust`](../bindings/rust)) mirrors them in
  `gist::contract` and asserts them in `tests/contract.rs` — same drift gate,
  second language.
- Reviewers, when deciding whether a new search capability belongs in the deep
  contract or stays a CLI-only presentation flag.

The engine's actual flag surface lives in
[`../src/gist/faces/ripgrep/args.zig`](../src/gist/faces/ripgrep/args.zig)
(`flag_catalog`); each `flag = …` here names the rg-parity flag the package
lowers a request option into.
