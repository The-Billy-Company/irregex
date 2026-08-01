<!--
doc_radar:
  sentinels:
    - file: contract.go
      contains:
        - "ABIVersion    = 2"
        - "func Verb(op Op) (VerbDef, bool)"
        - "func Schema(id uint32) (SchemaDef, bool)"
        - "func EnumOrdinal(id uint32, label string) (int64, bool)"
    - file: schema_gen.go
      contains:
        - "const Digest"
        - "package analytic"
    - file: request.go
      contains:
        - "type Request struct"
        - "type Match struct"
    - file: ../../../contract/analytic.toml
      contains:
        - "[row_schemas"
        - "[analytic.verbs]"
    - file: ../../../contract/engine.toml
      contains:
        - "[status_codes]"
-->

# `analytic` — shared contract plane

The row-schema table, mirrored status/op/param constants, search
`Request`/`Match` shapes, analytic param families, and grade/channel/unit
calibration. Every product binding (gist, relate, blast) imports this package;
none of them redeclares the table.

Generated from `irregex/contract/analytic.toml` by
`tools/build_schema_tables.py`. Nothing here talks to the kernel — that is
[`../runtime`](../runtime/).
