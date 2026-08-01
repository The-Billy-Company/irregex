---
doc_radar:
  sentinels:
    - file: ../../../../contract/analytic.toml
      contains: ["[row_schemas]", "[analytic.verbs]", "[analytic.producers]"]
      description: The row-schema table this package mirrors is authored in irregex's analytic contract.
    - file: ../../../../contract/engine.toml
      contains: ["[request_options]", "[exit_codes]"]
      description: The request surface and exit codes remain engine-contract sections.
---

# `irregex.contract` — the mirrored substrate

Everything here is generated from or checked against the four contracts,
resolved by author: `irregex/contract/{analytic,engine}.toml`,
`relate/contract/kinship.toml`, and `gist/contract/surface.toml`. Nothing here
decides product behavior; it is what every binding is allowed to believe.

| Module | What it carries |
|---|---|
| `abi.py` | mirrored TOML constants — ABI/engine versions, request options, exit codes, CDEF strings |
| `grades.py` | kinship calibration — channels, bands, `grade_of` — mirroring relate's `channel.zig` |
| `table.py` | indexed view of `../schema.gen.py` — schemas, enums, verb → producer routing |
| `../schema.gen.py` | generated table from `tools/build_schema_tables.py` — never hand-edited |

`table.DIGEST` is the fingerprint the runtime compares against
`irregex_schema_digest()` before decoding a native row.
