# `irgx.contract` — the mirrored substrate

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
`irgx_schema_digest()` before decoding a native row.
