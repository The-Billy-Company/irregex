---
doc_radar:
  sentinels:
    - description: "flag_catalog remains the parser and --schema source of truth"
      file: pkg/kernels/irregex/src/surface/exec/cold/argv/args.zig
      contains:
        - "flag_catalog"
        - "pub const Opts"
        - "unicode: bool = true,"
---

# surface/exec/cold/argv — flag grammar

Parsing only. This package lowers argv into a single precedence-sensitive
`Opts` (plus the type/glob `Filter`) and owns nothing about I/O or matching.

It implements ripgrep's **default** flag semantics: short-flag bundling,
`--flag` / `--flag=value`, `-A`/`-B` over `-C`, the `-u`/`-uu` unrestrict
tiers, `-t`/`-T`/`-g`/`--glob`/`--iglob` scoping with `!`-exclude and
leading-`/` anchoring. Unicode is default-on (rg-parity); `--no-unicode` /
`(?-u)` opt out.

**Fail loud.** Any flag gist cannot honor by design exits 2 with a reason, so
the differential harness scores those N/A rather than silently wrong. The
declarative `flag_catalog` in `args.zig` is both the parser's dispatch table
and the rows [`face/gist/schema/`](../../../face/gist/schema) renders into `gist --schema` —
one catalog, two consumers, no prose drift.

## When to edit

New rg-parity flags, precedence between `-A`/`-B`/`-C`, or default Unicode
behavior. Deep request options that bindings must share also update
[`../../../../../contract/search_api.toml`](../../../../../contract/search_api.toml).
Do not put walk / match / emit logic here — parsing only.
