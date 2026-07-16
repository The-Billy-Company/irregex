# Vendored WHATWG Encoding Standard indexes

These are the exact upstream index files gist's `-E`/`--encoding` legacy-code-page
decoders are lowered from. They are pinned and vendored so table generation is
**hermetic** (no network at build/CI time) and the drift gate is reproducible.
The lowering lives in [`../build_encoding_tables.py`](../build_encoding_tables.py)
→ emits `src/commands/ripgrep/encoding_tables.gen.zig`, which
[`../../src/commands/ripgrep/encoding.zig`](../../src/commands/ripgrep/encoding.zig)
rides. This is the same set `encoding_rs` (ripgrep's transcoder) is built from, so
gist reaches byte-for-byte `-E` parity with `rg` (proven in
[`../../bench/rgsuite/transforms.py`](../../bench/rgsuite/transforms.py)).

## Provenance

- **Source:** `https://encoding.spec.whatwg.org/<file>` (the `index-*.txt` tables +
  `encodings.json`, the label→encoding registry).
- **Pin:** each `index-*.txt` carries WHATWG's own content hash inline as a
  `# Identifier: <sha256>` header (plus a `# Date:`); that header **is** the pin —
  the generator parses the tables verbatim, and `--check` regenerates and diffs, so
  any upstream drift surfaces as a gen-file mismatch.

## What's used

| File(s)                                                                   | Used for                                               |
| ------------------------------------------------------------------------- | ------------------------------------------------------ |
| `encodings.json`                                                          | label → encoding tag map (the full WHATWG alias table) |
| `index-{ibm866,iso-8859-*,koi8-*,macintosh,windows-*,x-mac-cyrillic}.txt` | the single-byte pages (one byte → code point)          |
| `index-gb18030.txt` + `index-gb18030-ranges.txt`                          | gb18030 / GBK (two-byte table + four-byte range map)   |
| `index-big5.txt`                                                          | Big5                                                   |
| `index-jis0208.txt` + `index-jis0212.txt`                                 | EUC-JP / Shift_JIS                                     |
| `index-iso-2022-jp-katakana.txt`                                          | ISO-2022-JP katakana state                             |
| `index-euc-kr.txt`                                                        | EUC-KR (WHATWG euc-kr = CP949/UHC)                     |

Verify the embedded pins with `shasum -a 256 *.txt` (compare to each file's
`# Identifier:`). To upgrade: re-fetch the set from the URL above, then
`make gen-gist-encoding` and re-run `python3 ../../bench/rgsuite/transforms.py run`.
