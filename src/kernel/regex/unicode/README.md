# regex/unicode — Unicode support for the byte engine

This engine matches *bytes*, but ripgrep folds and classifies *codepoints* by default. This leaf holds the machinery that lets the byte automaton speak Unicode without leaving its O(1)/byte floor.

## Files

- **`utf8seq.zig`** turns a scalar-value range into non-overlapping 1–4 byte-range sequences, the surrogate-safe RE2/Thompson decomposition. It lowers a codepoint class into a byte sub-automaton the existing `consume` state accepts.
- **`decode.zig`** does minimal UTF-8 codepoint decode (`decode` forward, `decodeLast` backward) for the word-boundary engine, failing closed to null (non-word) on ill-formed UTF-8.
- **`tables.zig`** is the data API: Perl classes (`word`/`digit`/`space`), `\p{...}` property lookup, simple case-fold orbit expansion, and the codepoint word-ness test.
- **`tables.gen.zig`** holds the generated compact sorted-range tables. Do not hand-edit.

## Regenerating The Tables

The tables are lowered from a pinned UCD 16.0.0 subset vendored under [`../../../../tools/ucd/`](../../../../tools/ucd/) by [`../../../../tools/build_unicode_tables.py`](../../../../tools/build_unicode_tables.py).

Regenerate `tables.gen.zig` or check it for drift with the same script:

```bash
python3 tools/build_unicode_tables.py            # regenerate tables.gen.zig
python3 tools/build_unicode_tables.py --check    # drift gate
```

The generator is stdlib-only and deterministic, so the checked-in `tables.gen.zig` is exactly what the pinned inputs produce, and a byte-diff is the drift gate. To move to a newer Unicode version, re-vendor the UCD files (update `tools/ucd/README.md` provenance), bump `UNICODE_VERSION`, and regenerate.
