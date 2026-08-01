---
doc_radar:
  sentinels:
    - description: "the generated schema table is mounted, not re-declared"
      file: bindings/rust/src/contract/mod.rs
      contains: ['#[path = "../schema.gen.rs"]', "pub mod schema"]
    - description: "the four row_enums vocabularies have typed faces"
      file: bindings/rust/src/contract/calibration.rs
      contains: ["Grade = 1", "Channel = 2", "Unit = 3", "row_enum!"]
    - description: "analytic tables are generated from analytic.toml"
      file: bindings/rust/src/schema.gen.rs
      contains: ["contract/analytic.toml", "DIGEST"]
---

# `contract/` — what the engine promises, in Rust

This module is the crate's copy of the substrate contracts —

- `irregex/contract/engine.toml` — versions, request options, exit / status codes
- `irregex/contract/analytic.toml` — `[row_schemas]`, `[row_enums]`, `[analytic.verbs]`
- `relate/contract/kinship.toml` — grades and channels
- gist's `contract/surface.toml` — transports, tool boundary, package names
  (mirrored here so one parity gate can hold the whole surface)

Nothing here runs; everything here is what the rest of the ecosystem is
_allowed to assume_.

It carries the contract in two forms:

- **Hand-mirrored constants** — ABI version, engine version, request options,
  match kinds, exit codes, the tool-boundary aliases. Held to the TOML by
  `../../tests/contract.rs`.
- **The generated analytic tables** — `schema.gen.rs`, lowered from
  `analytic.toml` by `irregex/tools/build_schema_tables.py` and mounted here
  by path. `DIGEST` proves a loaded engine agrees with it.

## When to edit

Widen the matching contract first, then mirror. For anything under
`[row_schemas]` / `[row_enums]` / `[analytic.verbs]` in
`irregex/contract/analytic.toml`, re-run the generator instead of touching
`schema.gen.rs`.
