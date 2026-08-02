# `contract/` — what the engine promises, in Rust

This module is the crate's copy of the substrate contracts —

- `irregex/contract/engine.toml` — versions, request options, exit / status codes
- `irregex/contract/analytic.toml` — `[row_schemas]`, `[row_enums]`, `[analytic.verbs]`
- `relate/contract/kinship.toml` — grades and channels, vendored into
  `irregex/contract/` by `tools/sync_contract.py`

Those three and no more. A product's own contract is mirrored in that product's
crate — gist's published names and tool boundary live in `gist::contract`, next
to the `contract/surface.toml` they answer to. They sat here while the packages
shared a repository, which left this crate's suite unable to run without a gist
checkout beside it.

Nothing here runs; everything here is what the rest of the ecosystem is
_allowed to assume_.

It carries the contract in two forms:

- **Hand-mirrored constants** — ABI version, engine version, request options,
  match kinds, exit and status codes. Held to the TOML by
  `../../tests/contract.rs`.
- **The generated analytic tables** — `schema.gen.rs`, lowered from
  `analytic.toml` by `irregex/tools/build_schema_tables.py` and mounted here
  by path. `DIGEST` proves a loaded engine agrees with it.

## When to edit

Widen the matching contract first, then mirror. For anything under
`[row_schemas]` / `[row_enums]` / `[analytic.verbs]` in
`irregex/contract/analytic.toml`, re-run the generator instead of touching
`schema.gen.rs`.
