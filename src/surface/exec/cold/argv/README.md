---
doc_radar:
  counts:
    - description: "the argv package is the facade plus its four concern modules"
      glob: pkg/kernels/irregex/src/surface/exec/cold/argv/*.zig
      equals: 5
      unit: modules
  sentinels:
    - description: "args.zig stays a facade whose test block keeps sibling tests discoverable"
      file: pkg/kernels/irregex/src/surface/exec/cold/argv/args.zig
      contains:
        - "pub const parseArgv = grammar.parseArgv;"
        - "_ = catalog;"
      absent:
        - "flag_catalog = [_]FlagSpec"
    - description: "flag_catalog remains the parser and --schema source of truth"
      file: pkg/kernels/irregex/src/surface/exec/cold/argv/catalog.zig
      contains:
        - "pub const flag_catalog"
    - description: "Opts is the one request record, Unicode default-on"
      file: pkg/kernels/irregex/src/surface/exec/cold/argv/intent.zig
      contains:
        - "pub const Opts"
        - "unicode: bool = true,"
---

# surface/exec/cold/argv — flag grammar

Parsing only. This package lowers argv into a single precedence-sensitive
`Opts` (plus the type/glob `Filter`) and owns nothing about I/O or matching.

It implements ripgrep's **default** flag semantics: short-flag bundling,
`--flag` / `--flag=value`, `-A`/`-B` over `-C`, the `-u`/`-uu` unrestrict
tiers, `-t`/`-T`/`-g`/`--glob`/`--iglob` scoping with `!`-exclude,
`{a,b}` alternation, and leading-`/` anchoring. Unicode is default-on
(rg-parity); `--no-unicode` / `(?-u)` opt out.

## The five modules

Four concerns behind one interface. Thirty-odd importers across the tree —
every engine, emitter, face verb, and the FFI session — see only `args.zig`,
so the inside can be re-cut without a call-site edit.

| Module | Owns |
|---|---|
| `args.zig` | The **facade**: the names the rest of the tree may use, and nothing else. |
| `verdict.zig` | Turning one raw token into a typed value, or dying loud — numbers, enums, escapes, `{a,b}` expansion. |
| `intent.zig` | The request record (`Opts`, `Filter`, `Parsed`) **and** the `Builder` that accumulates into it. |
| `catalog.zig` | The declarative `flag_catalog` — one row per flag, comptime-proved against `Opts`. |
| `grammar.zig` | The walk: short bundles, long flags, values, precedence, and the parse tests. |

`args.zig` carries an explicit `test { _ = catalog; … }` block. Zig analyzes a
`pub const` re-export lazily, so without it the package's parse tests silently
stop running while still reporting green — the same reason
[`root.zig`](../../../../root.zig) wires its tiers by hand.

**Fail loud.** Any flag gist cannot honor by design exits 2 with a reason, so
the differential harness scores those N/A rather than silently wrong. The
declarative `flag_catalog` in `catalog.zig` is both the parser's dispatch table
and the rows [`face/gist/schema/`](../../../face/gist/schema) renders into `gist --schema` —
one catalog, two consumers, no prose drift.

Process exit itself is **not** owned here: `die` / `oom` live in
[`cli/outcome.zig`](../../../cli/outcome.zig) beside the other ways a face ends,
and `args.zig` re-exports them for call sites that read better saying `args.die`.

## When to edit

New rg-parity flags, precedence between `-A`/`-B`/`-C`, or default Unicode
behavior. A new flag is usually one `catalog.zig` row plus one `Opts` field; it
only reaches `grammar.zig` when its **carrier** shape is new (a novel value
form or precedence rule). Deep request options that bindings must share also
update [`../../../../../contract/search_api.toml`](../../../../../contract/search_api.toml).

Any flag the warm resident session also honors must stay in step with
[`../../session/request.zig`](../../session/request.zig), which re-classifies argv
on the fast path: a shape it cannot model **identically** has to decline to cold
rather than answer differently. Do not put walk / match / emit logic here —
parsing only.
