# `src/corpus/read/` — byte legibility

Is this file readable text? Encoding decode, inode identity, and the slurp /
legible helpers every walk uses before a matcher sees bytes. Moved out of
`exec/cold/read/` so corpus eligibility is not a cold-engine private.

| File | Job |
| ---- | --- |
| `encoding.zig` | WHATWG encoding decoders + label resolution |
| `inode.zig` | Inode identity for hard-link / same-file decisions |
| `legible.zig` | Text-vs-binary legibility gate |
| `slurp.zig` | Whole-file read helpers the walk and index build share |

Cold-specific content transforms (`-z` / `--pre` / `-E`) stay in
`exec/cold/read/` — those are argv-driven ingest, not corpus eligibility.
