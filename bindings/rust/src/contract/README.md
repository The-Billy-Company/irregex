# contract

This module is the crate's own copy of what the engine promises. It mirrors
exactly three files, and no more:

- **`irregex/contract/engine.toml`** carries versions, request options, and exit / status codes.
- **`irregex/contract/analytic.toml`** carries `[row_schemas]`, `[row_enums]`, and `[analytic.verbs]`.
- **The kinship package's `contract/kinship.toml`** carries grades and channels, vendored into `irregex/contract/` by `tools/sync_contract.py`.

A product's own contract is mirrored in that product's own crate instead — the
exact face's published names and tool boundary live in its own crate's
`contract` module, next to the `contract/surface.toml` they answer to. These
three sat here while the packages shared one repository, which is what used to
leave this crate's test suite unable to run without that face's checkout
sitting beside it.

The mirrored constants carry no logic of their own; everything here is what
the rest of the ecosystem is allowed to assume. The crate embeds them so it
carries no runtime dependency on the repository's own TOML files, which an OSS
checkout of this crate does not ship, and the parity test in
`../../tests/contract.rs` reads the canonical TOML and asserts this copy still
matches it.

The contract arrives in two mirrored forms:

- **Hand-mirrored constants** — ABI version, engine version, request options, match kinds, exit and status codes.
- **The generated analytic tables** — `schema.gen.rs`, lowered from `analytic.toml` by `irregex/tools/build_schema_tables.py` and mounted here by path. Its `DIGEST` proves a loaded engine agrees with it.

This module also defines the result records both faces hand back: `Match`,
`Submatch`, `MatchKind`, and the ranked-view pair `Ranked` / `RankKind`.
Unlike the mirrored constants above, these do run — they are what
`SearchRequest::run` and the `--rank` view actually construct at call time.

## When to Edit

Widen the matching contract first, then mirror it here. For anything under
`[row_schemas]`, `[row_enums]`, or `[analytic.verbs]` in
`irregex/contract/analytic.toml`, re-run the generator instead of touching
`schema.gen.rs` by hand.
