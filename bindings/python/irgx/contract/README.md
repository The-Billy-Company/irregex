# The `irgx.contract` Package

Everything here is generated from or checked against the three contracts this
engine is answerable for, resolved by author: `irregex/contract/engine.toml`,
`irregex/contract/analytic.toml`, and relate's `contract/kinship.toml`,
vendored beside them by `tools/sync_contract.py`. Nothing here decides
product behavior; it is what every binding is allowed to believe.

A product's own contract stays mirrored in that product's own package —
`gist._contract` carries `gist/contract/surface.toml`, for the same reason
its header does: a mirror can only be gated where the canonical file lives,
and this substrate cannot check a consumer's contract without checking that
consumer out.

- **`abi.py`** carries mirrored TOML constants: ABI/engine versions, request
  options, exit codes, and CDEF strings.
- **`grades.py`** carries the kinship calibration — channels, bands, and
  `grade_of` — mirroring relate's `channel.zig`.
- **`table.py`** carries an indexed view of `../schema.gen.py`: schemas,
  enums, and verb-to-producer routing.
- **`../schema.gen.py`** is the generated table from
  `tools/build_schema_tables.py`, and it is never hand-edited.

`table.DIGEST` is the fingerprint the runtime compares against
`irgx_schema_digest()` before decoding a native row.
