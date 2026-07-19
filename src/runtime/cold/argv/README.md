---
doc_radar:
  sentinels:
    - description: "flag_catalog remains the parser and --schema source of truth"
      file: pkg/kernels/irregex/src/runtime/cold/argv/args.zig
      contains:
        - "flag_catalog"
        - "pub const Opts"
        - "unicode: bool = true,"
---

# runtime/cold/argv — flag grammar

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
and the rows [`cli/gist/schema/`](../../../cli/gist/schema) renders into `gist --schema` —
one catalog, two consumers, no prose drift.
