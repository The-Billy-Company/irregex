---
doc_radar:
  counts:
    - description: "tools keeps the two hermetic table generators: ucd · whatwg"
      glob: pkg/kernels/irregex/tools/*
      unit: dirs
      equals: 2
---

# `tools/` — table generators

The Python builders that lower fixed data into Zig tables. None of them touches
the network; regenerating is always an explicit, reviewed step.

Two of them are **hermetic** — the input is vendored bytes, so the output is a
generated file and regenerating after a pin bump is mechanical:

| Tool                | Input (vendored)        | Output (generated — do not hand-edit)     |
| ------------------- | ----------------------- | ----------------------------------------- |
| [`ucd/`](ucd)       | Unicode 16.0.0 UCD text | `src/kernel/regex/unicode/tables.gen.zig` |
| [`whatwg/`](whatwg) | WHATWG encoding indexes | `src/corpus/read/encoding_tables.gen.zig` |

```bash
make gen-gist-unicode    # UCD → unicode tables
make gen-gist-encoding   # WHATWG → encoding tables
```

One is a **measurement** — its input is the working tree, so running it is a
re-measurement whose output lands as a hand-reviewed diff, never automatically:

| Tool                    | Input          | Output                                                    |
| ----------------------- | -------------- | --------------------------------------------------------- |
| `build_rarity_table.py` | the Billy tree | `src/kernel/scan/rarity.zig`'s `density` (paste + review) |

```bash
python3 tools/build_rarity_table.py --report   # census diagnostics, no table
python3 tools/build_rarity_table.py            # the declaration, zig-fmt canonical
```

## When to edit here

- Bumping the Unicode or WHATWG pin (update sha / identifier headers + regen).
- Extending the encoding set to stay at `encoding_rs` / `rg -E` parity.
- Re-measuring byte density after the corpus shifts materially — read
  `rarity.zig`'s recorded defect first: the table's contract is ORDERING, and a
  regeneration that saturates or reorders it is a throughput bug, not a nit.

Never edit `*.gen.zig` by hand. Details and pin hashes live in each
subdir's README.
