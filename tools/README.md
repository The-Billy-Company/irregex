# `tools/` — Table Generators

The Python builders that lower fixed data into Zig tables. None of them touches
the network; regenerating is always an explicit, reviewed step.

Two of them are hermetic — the input is vendored bytes, so the output is a
generated file and regenerating after a pin bump is mechanical.

- **[`ucd/`](ucd)** takes Unicode 16.0.0 UCD text and writes
  `src/kernel/regex/unicode/tables.gen.zig`.
- **[`whatwg/`](whatwg)** takes the WHATWG encoding indexes and writes
  `src/corpus/read/encoding_tables.gen.zig`.

Run either generator and its matching drift check with these commands:

```bash
python3 tools/build_unicode_tables.py            # UCD → unicode tables
python3 tools/build_unicode_tables.py --check    # drift gate
python3 tools/build_encoding_tables.py           # WHATWG → encoding tables
python3 tools/build_encoding_tables.py --check   # drift gate
python3 tools/build_schema_tables.py             # contract → schema tables (Zig + this package's own Go/Python/Rust bindings)
python3 tools/build_schema_tables.py --check     # drift gate
```

One is a measurement — its input is the working tree, so running it is a
re-measurement whose output lands as a hand-reviewed diff, never automatically.
**`build_rarity_table.py`** reads a large source tree and produces the
`density` table pasted into `src/kernel/scan/rarity.zig`. Run it, then paste
and review the result:

```bash
python3 tools/build_rarity_table.py --report   # census diagnostics, no table
python3 tools/build_rarity_table.py            # the declaration, zig-fmt canonical
```

Three are gates — they read the tree and answer yes or no.

- **`version_parity.py`** asks whether every mirror of `build.zig.zon`'s
  `.version` still agrees, and whether the release bot knows about each one.
- **`sync_contract.py`** asks whether each contract vendored from a sibling
  still matches what its author wrote.
- **`registry_readme.py`** asks whether every relative link in `README.md`
  still resolves — and, when writing, produces the corrected copy an index
  publishes.

Run the gates and their write-mode counterparts with these commands:

```bash
python3 tools/version_parity.py          # the gate (CI's `version` job)
python3 tools/version_parity.py --json   # the mirrors it found, for a machine
python3 tools/sync_contract.py           # refresh the vendored copies
python3 tools/sync_contract.py --check   # the gate (the author's `contract` job)
python3 tools/registry_readme.py --check # the gate (CI's `version` job)
python3 tools/registry_readme.py         # mint bindings/rust/PROJECT_README.md
```

## Making the README Work on Package Indexes

PyPI and crates.io each show a README as the whole project page, and each
resolves a relative link against its own URL. `include/irgx.h` is correct on
GitHub, a 404 under `pypi.org/project/irregex/`, and on crates.io a well-formed
URL into the crate's subdirectory pointing at a file that was never there — the
worst of the three, because nothing looks broken.

`registry_readme.py` is the one rewriter both ends share. It absolutizes every
relative target against the `repository` URL the manifest already declares —
`raw` for an image, `tree` or `blob` by what the path is on disk — and refuses
outright on a target the repository does not contain. Python calls it from
`bindings/python/hatch_readme.py` at wheel-build time, so the corrected page
exists only inside the artifact. Cargo has no metadata hook, so for crates.io
this writes `bindings/rust/PROJECT_README.md`, which is gitignored and which
`readme` points at: `cargo package` fails loudly if it was never generated, and
`cargo build` never reads it. Mint it immediately before `cargo package`,
never earlier: a missing file fails loudly, a stale one would ship quietly.

`sync_contract.py` is the only one here that also writes, and it writes a copy
rather than a generated file. Exactly one contract is vendored — the kinship
package's `kinship.toml`, which the bindings mirror — because that package is
private, and a public package whose own tests need a clone of a private one is a
package the public cannot test. The exact-search face's `surface.toml` is
deliberately absent: that face is public, so CI checks it out and reads the
original. The `--check` gate runs from the kinship package's CI rather than this
one, since only the repository that authors the contract can see both files at
once.

`build.zig.zon` is the single place this package's version is written: Zig reads
it through a build option, Rust reads `CARGO_PKG_VERSION`, Python reads its
installed distribution metadata. The copies that remain are manifests that
cannot import anything, each carrying an `x-release-please-version` marker the
release bot rewrites. The gate discovers those markers rather than holding a
list, so it fails both on a mirror that drifted and on one
`release-please-config.json` never learned about.

## When to Edit Here

- Bumping the Unicode or WHATWG pin (update sha / identifier headers + regen).
- Extending the encoding set to stay at `encoding_rs` / `rg -E` parity.
- Re-measuring byte density after the corpus shifts materially — read
  `rarity.zig`'s recorded defect first: the table's contract is ORDERING, and a
  regeneration that saturates or reorders it is a throughput bug, not a nit.

Never edit `*.gen.zig` by hand. Details and pin hashes live in each
subdir's README.
