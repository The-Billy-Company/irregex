---
doc_radar:
  sentinels:
    - description: "per-file search stays one module shared by both walk engines"
      file: pkg/kernels/irregex/src/gist/faces/cli/search/read/grepfile.zig
      contains: ["pub fn handleBinary", "pub fn readFileRaw", "pub const Stats"]
    - description: "-E still covers the WHATWG CJK multi-byte decoders"
      file: pkg/kernels/irregex/src/gist/faces/cli/search/read/encoding.zig
      contains: ["gb18030", "shift_jis", "euc_jp"]
---

# gist/faces/cli/search/read — per-file ingest

Everything that turns a path into matchable UTF-8 bytes — and the per-file
search that consumes those bytes. Serial and parallel engines both call into
here so binary policy, BOM/UTF-16, and stats cannot drift between walk modes.

| File | Role |
| --- | --- |
| `grepfile.zig` | per-file search machinery — staged reads, binary policy, raw-stat shim, stats; the shared seam both walk engines call |
| `ingest.zig` | content transforms before match: `-z` decompress, `--pre` preprocess, `-E` dispatch |
| `encoding.zig` | WHATWG legacy-code-page decoders (single-byte + CJK multi-byte); label table in `encoding_tables.gen.zig` |

`auto` encoding (the default) sniffs BOM — UTF-8 stripped, UTF-16 transcoded.
`none` disables even that; an explicit WHATWG label forces a transcode.
Generated tables are refreshed by `pkg/kernels/irregex/tools/build_encoding_tables.py`.
