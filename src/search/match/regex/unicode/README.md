---
doc_radar:
  sentinels:
    - file: pkg/kernels/irregex/src/gist/kernel/regex/unicode/tables.gen.zig
      contains: ['pub const unicode_version = "16.0.0";']
---

# `regex/unicode` — Unicode support for the byte engine

gist matches **bytes**, but ripgrep folds and classifies **codepoints** by
default. This leaf holds the machinery that lets gist's byte automaton speak
Unicode without leaving its O(1)/byte floor:

| File             | Role                                                                                                                                                                                                    |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `utf8seq.zig`    | Scalar-value range → non-overlapping 1–4 byte-range sequences (the surrogate-safe RE2/Thompson decomposition). Lowers a codepoint class into a byte sub-automaton the existing `consume` state accepts. |
| `decode.zig`     | Minimal UTF-8 codepoint decode (`decode` forward, `decodeLast` backward) for the word-boundary engine; fails closed to null (→ non-word) on ill-formed UTF-8.                                           |
| `tables.zig`     | The data API: Perl classes (`word`/`digit`/`space`), `\p{...}` property lookup, simple case-fold orbit expansion, and the codepoint word-ness test.                                                     |
| `tables.gen.zig` | **Generated** compact sorted-range tables. Do not hand-edit.                                                                                                                                            |

## Regenerating the tables

The tables are lowered from a pinned **UCD 16.0.0** subset vendored under
[`../../../../../tools/ucd/`](../../../../../tools/ucd/) by
[`../../../../../tools/build_unicode_tables.py`](../../../../../tools/build_unicode_tables.py):

```bash
make gen-gist-unicode    # regenerate src/gist/kernel/regex/unicode/tables.gen.zig
make gen-gist-verify     # drift gate: regenerate + diff (CI)
```

The generator is stdlib-only and deterministic, so the checked-in
`tables.gen.zig` is exactly what the pinned inputs produce — a byte-diff is the
drift gate. To move to a newer Unicode version, re-vendor the UCD files (update
`pkg/kernels/irregex/tools/ucd/README.md` provenance), bump `UNICODE_VERSION`, and
regenerate.
