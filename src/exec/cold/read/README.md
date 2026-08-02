# exec/cold/read — per-file ingest

Everything that turns a path into matchable UTF-8 — and the per-file search that
consumes those bytes. Serial and parallel engines both call into here, so binary
policy, BOM/UTF-16, and stats cannot drift between walk modes.

| File | Role |
| ---- | ---- |
| `binary.zig` | what a NUL costs you — rg's quit strategy, the line vs `-U` slice geometries, and the two binary notes |
| `stats.zig` | the search tally behind `--stats`, the `--json` summary, and the `GIST_TRACE=query` diagnostic |
| `ingest.zig` | content transforms before match: `-z` decompress, `--pre` preprocess, `-E` dispatch |

Byte legibility (encoding · inode · legible · slurp) moved to [`../../../corpus/read/`](../../../corpus/read/README.md).

`auto` encoding (the default) sniffs BOM — UTF-8 stripped, UTF-16 transcoded.
`none` disables even that; an explicit WHATWG label forces a transcode.
Generated tables are refreshed by `python3 tools/build_encoding_tables.py` (see
[`../../../../tools/whatwg/`](../../../../tools/whatwg/)).

Walk-failure wording (`printWalkError`, `printNothingSearched`) is **not** here —
it describes the descent rather than a file's bytes, so it lives beside the walk
in [`../quarry/notice.zig`](../quarry/notice.zig).

## When to edit

Binary policy, staged-read strategy, `-z` / `--pre` / `-E` ingest, or WHATWG
decoder coverage. Encoding pin bumps go through
`tools/whatwg/` — never hand-edit
`encoding_tables.gen.zig`.
