# `analytic` — shared contract plane

The row-schema table, mirrored status/op/param constants, search
`Request`/`Match` shapes, analytic param families, and grade/channel/unit
calibration. Every product binding (gist, relate, blast) imports this package;
none of them redeclares the table.

Generated from `irregex/contract/analytic.toml` by
`tools/build_schema_tables.py`. Nothing here talks to the kernel — that is
[`../runtime`](../runtime/).
