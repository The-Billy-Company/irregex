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
python3 tools/build_unicode_tables.py            # UCD → unicode tables
python3 tools/build_unicode_tables.py --check    # drift gate
python3 tools/build_encoding_tables.py           # WHATWG → encoding tables
python3 tools/build_encoding_tables.py --check   # drift gate
python3 tools/build_schema_tables.py             # contract → schema tables (+ sibling gist bindings)
python3 tools/build_schema_tables.py --check     # drift gate
```

One is a **measurement** — its input is the working tree, so running it is a
re-measurement whose output lands as a hand-reviewed diff, never automatically:

| Tool                    | Input          | Output                                                    |
| ----------------------- | -------------- | --------------------------------------------------------- |
| `build_rarity_table.py` | a large source tree | `src/kernel/scan/rarity.zig`'s `density` (paste + review) |

```bash
python3 tools/build_rarity_table.py --report   # census diagnostics, no table
python3 tools/build_rarity_table.py            # the declaration, zig-fmt canonical
```

Two are **gates** — they read the tree and answer yes or no:

| Tool                 | Asks                                                            |
| -------------------- | --------------------------------------------------------------- |
| `version_parity.py`  | do every mirror of `build.zig.zon`'s `.version` still agree, and does the release bot know about each one? |
| `sync_contract.py`   | does each contract vendored from a sibling still match what its author wrote? |

```bash
python3 tools/version_parity.py          # the gate (CI's `version` job)
python3 tools/version_parity.py --json   # the mirrors it found, for a machine
python3 tools/sync_contract.py           # refresh the vendored copies
python3 tools/sync_contract.py --check   # the gate (relate's `contract` job)
```

`sync_contract.py` is the only one here that also writes, and it writes a copy
rather than a generated file. Exactly one contract is vendored — relate's
`kinship.toml`, which the bindings mirror — because relate is private, and a
public package whose own tests need a clone of a private one is a package the
public cannot test. gist's `surface.toml` is deliberately absent: gist is
public, so CI checks it out and reads the original. The `--check` gate runs from
relate's CI rather than this one, since only the repository that authors the
contract can see both files at once.

`build.zig.zon` is the single place this package's version is written: Zig reads
it through a build option, Rust reads `CARGO_PKG_VERSION`, Python reads its
installed distribution metadata. The copies that remain are manifests that
cannot import anything, each carrying an `x-release-please-version` marker the
release bot rewrites. The gate discovers those markers rather than holding a
list, so it fails both on a mirror that drifted and on one
`release-please-config.json` never learned about.

## When to edit here

- Bumping the Unicode or WHATWG pin (update sha / identifier headers + regen).
- Extending the encoding set to stay at `encoding_rs` / `rg -E` parity.
- Re-measuring byte density after the corpus shifts materially — read
  `rarity.zig`'s recorded defect first: the table's contract is ORDERING, and a
  regeneration that saturates or reorders it is a throughput bug, not a nit.

Never edit `*.gen.zig` by hand. Details and pin hashes live in each
subdir's README.
