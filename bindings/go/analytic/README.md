# `analytic`

This package is the shared contract plane: the row-schema table, mirrored
status/op/param constants, search `Request`/`Match` shapes, the five analytic
param families, and the grade/channel/unit calibration a kinship row is graded
against.

Every product binding (gist, relate, blast) imports this package, and none of
them redeclares the table. Most of it is generated from
`irregex/contract/analytic.toml` by `tools/build_schema_tables.py`; the
hand-written parts are the request/param structs and the grade math that reads
the generated tables.

Nothing here talks to the kernel. That is [`../runtime`](../runtime/).
