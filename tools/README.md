---
doc_radar:
  counts:
    - description: "tools keeps the two hermetic table generators: ucd · whatwg"
      glob: pkg/kernels/irregex/tools/*
      unit: dirs
      equals: 2
---

# `tools/` — hermetic table generators

Pinned Unicode / encoding data and the Python builders that lower them into
generated Zig tables. CI never fetches the network; regenerating is an
explicit `make` step after a deliberate pin bump.

| Tool                | Input (vendored)        | Output (generated — do not hand-edit)           |
| ------------------- | ----------------------- | ----------------------------------------------- |
| [`ucd/`](ucd)       | Unicode 16.0.0 UCD text | `src/search/match/regex/unicode/tables.gen.zig` |
| [`whatwg/`](whatwg) | WHATWG encoding indexes | `src/runtime/cold/read/encoding_tables.gen.zig` |

```bash
make gen-gist-unicode    # UCD → unicode tables
make gen-gist-encoding   # WHATWG → encoding tables
```

## When to edit here

- Bumping the Unicode or WHATWG pin (update sha / identifier headers + regen).
- Extending the encoding set to stay at `encoding_rs` / `rg -E` parity.

Never edit `*.gen.zig` by hand. Details and pin hashes live in each
subdir's README.
