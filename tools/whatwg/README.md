# Vendored WHATWG Encoding Standard Indexes

These are the exact upstream index files the engine's `-E`/`--encoding` legacy-code-page
decoders are lowered from. They are pinned and vendored so table generation is
hermetic (no network at build/CI time) and the drift gate is reproducible.
The lowering lives in [`../build_encoding_tables.py`](../build_encoding_tables.py)
→ emits `src/corpus/read/encoding_tables.gen.zig`, which
[`../../src/corpus/read/encoding.zig`](../../src/corpus/read/encoding.zig)
rides. This is the same set `encoding_rs` (ripgrep's transcoder) is built from,
so the engine reaches byte-for-byte `-E` parity with `rg` — proven by the
`rgsuite` conformance harness in the sibling exact-search face's repository, at
its `bench/conformance/rgsuite/`.

## Provenance

- **Source:** `https://encoding.spec.whatwg.org/<file>` (the `index-*.txt` tables +
  `encodings.json`, the label→encoding registry).
- **Pin:** each `index-*.txt` carries WHATWG's own content hash inline as a
  `# Identifier: <sha256>` header (plus a `# Date:`); that header *is* the pin —
  the generator parses the tables verbatim, and `--check` regenerates and diffs, so
  any upstream drift surfaces as a gen-file mismatch.

## What's Used

- **`encodings.json`** is the label → encoding tag map, the full WHATWG alias
  table.
- **`index-{ibm866,iso-8859-*,koi8-*,macintosh,windows-*,x-mac-cyrillic}.txt`**
  are the single-byte pages, one byte mapping to one code point.
- **`index-gb18030.txt` plus `index-gb18030-ranges.txt`** cover gb18030 / GBK,
  a two-byte table plus a four-byte range map.
- **`index-big5.txt`** covers Big5.
- **`index-jis0208.txt` plus `index-jis0212.txt`** cover EUC-JP and Shift_JIS.
- **`index-iso-2022-jp-katakana.txt`** covers ISO-2022-JP katakana state.
- **`index-euc-kr.txt`** covers EUC-KR (WHATWG's euc-kr is CP949/UHC).

Verify the embedded pins by running `shasum -a 256 *.txt` from this directory
and comparing each result to that file's own `# Identifier:` header:

```bash
shasum -a 256 *.txt
```

To upgrade the pin, re-fetch the set from the WHATWG URL above, then run the
generator from the package root and re-run the conformance suite from the
sibling exact-search face's checkout:

```bash
python3 tools/build_encoding_tables.py
cd <face package checkout> && python3 bench/conformance/rgsuite/transforms.py run
```
