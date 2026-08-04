# `src/corpus/read/` — byte legibility

This package readies a candidate's bytes for the matcher: encoding decode, the portable stat projection, and the whole-file read helpers every walk shares.

It was moved out of `exec/cold/read/` so corpus eligibility is not a cold-engine private.

## Files, By Job

- **`encoding.zig`** holds the WHATWG encoding decoders and label resolution for `-E`/`--encoding`.
- **`legible.zig`** normalizes already-admitted bytes into what the matcher reads: BOM sniff and UTF-16 transcode, UTF-8 lossy repair, and the line-splitting model ripgrep's `-n`/`-A`/`-B` semantics assume.
- **`inode.zig`** is the portable `stat(2)` projection — device identity, kind, size, and the birth/mtime/ctime clocks — despite its name, it no longer tracks inode numbers or hard-link identity.
- **`slurp.zig`** holds the whole-file read helpers the walk and the index build share.

Whether a candidate is binary at all is not this package's decision: that gate, `isBinary`, lives on the corpus membership rule in [`../tree/corpus.zig`](../tree/corpus.zig), because it decides what counts as a corpus member before any of these helpers ever see the bytes.

Cold-specific content transforms (`-z` / `--pre` / `-E` dispatch) stay in `exec/cold/read/` — those are argv-driven ingest, not corpus eligibility.
