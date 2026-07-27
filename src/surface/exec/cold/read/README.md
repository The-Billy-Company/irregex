---
doc_radar:
  sentinels:
    - description: "binary policy is one module both walk engines call — the NUL cut, the two geometries, and the notes stay together"
      file: pkg/kernels/irregex/src/surface/exec/cold/read/binary.zig
      contains: ["pub fn committedPrefix", "pub fn handleBinary", "pub fn multilineBinary"]
    - description: "one read strategy and one raw-stat projection, so neither engine invents its own"
      file: pkg/kernels/irregex/src/surface/exec/cold/read/slurp.zig
      contains: ["pub const BUFCAP", "pub const StagedFile", "pub fn mapFile"]
    - description: "-E still covers the WHATWG CJK multi-byte decoders"
      file: pkg/kernels/irregex/src/surface/exec/cold/read/encoding.zig
      contains: ["gb18030", "shift_jis", "euc_jp"]
---

# surface/exec/cold/read — per-file ingest

Everything that turns a path into matchable UTF-8 — and the per-file search that
consumes those bytes. Serial and parallel engines both call into here, so binary
policy, BOM/UTF-16, and stats cannot drift between walk modes.

| File           | Role                                                                                                               |
| -------------- | ------------------------------------------------------------------------------------------------------------------ |
| `slurp.zig`    | one candidate's bytes off disk: the staged open (`BUFCAP` prefix now, tail on demand) and the large-file mmap path |
| `legible.zig`  | raw bytes made legible: BOM sniff, UTF-16 transcode, and rg's line model                                           |
| `binary.zig`   | what a NUL costs you — rg's quit strategy, the line vs `-U` slice geometries, and the two binary notes             |
| `stats.zig`    | the search tally behind `--stats`, the `--json` summary, and the `GIST_TRACE=query` diagnostic                     |
| `inode.zig`    | the portable `stat(2)` projection — device id, mode, size, birth/mtime/ctime, over statx or fstatat                |
| `ingest.zig`   | content transforms before match: `-z` decompress, `--pre` preprocess, `-E` dispatch                                |
| `encoding.zig` | WHATWG legacy-code-page decoders (single-byte + CJK multi-byte); label table in `encoding_tables.gen.zig`          |

`auto` encoding (the default) sniffs BOM — UTF-8 stripped, UTF-16 transcoded.
`none` disables even that; an explicit WHATWG label forces a transcode.
Generated tables are refreshed by `make gen-gist-encoding` (see
[`../../../../../tools/whatwg/`](../../../../../tools/whatwg/)).

Walk-failure wording (`printWalkError`, `printNothingSearched`) is **not** here —
it describes the descent rather than a file's bytes, so it lives beside the walk
in [`../quarry/notice.zig`](../quarry/notice.zig).

## When to edit

Binary policy, staged-read strategy, `-z` / `--pre` / `-E` ingest, or WHATWG
decoder coverage. Encoding pin bumps go through
`pkg/kernels/irregex/tools/whatwg/` — never hand-edit
`encoding_tables.gen.zig`.
