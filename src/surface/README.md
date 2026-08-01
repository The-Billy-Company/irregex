---
doc_radar:
  counts:
    - description: "surface keeps cli · face · ffi (plus a transitional empty exec/ shell that may still be present)"
      glob: src/surface/*
      unit: dirs
      min: 3
      max: 4
  sentinels:
    - description: "cold serial engine remains the root search re-export (exec promoted out of surface)"
      file: src/root.zig
      contains: 'pub const search = @import("exec/cold/engine/serial.zig");'
---

# `src/surface/` — vocabulary, API, FFI, faces

Everything a user or host touches. Execution moved to [`../exec/`](../exec/);
what remains is the shared CLI vocabulary, the hosted analytic API, the C-ABI
plane, and the three thin product faces. Engines never import a face.

| Piece | Job |
| ----- | --- |
| [`cli/`](cli) | Shared vocabulary: flags, emit, manifest, grade, guide, outcome (`die`/`oom`), reprise (answer keep), jsonstr, primer (man + completions) |
| `api.zig` | Hosted analytic Zig API — drives the session from above |
| `gist/src/surface/ffi/` | C-ABI session + analytic plane over `api.zig` |
| `gist/src/surface/face/` | The three faces — `gist` · `relate` · `irregex` — verb tables, `--help`, `--schema`, NDJSON shapes |

## Shared contracts

- **One match opinion.** Warm and FFI reuse cold's machinery and
  `kernel/query/query.zig`.
- **Fail open to cold.** Any warm decline falls back to the certified subprocess.
- **Index accelerates only.** Never changes answers.
- **Never abort the host.** Session and FFI return typed errors / status codes.

## When to edit here

- Shared flag / emit / outcome vocabulary (`cli/`).
- Verb dispatch, help copy, or NDJSON shapes (`face/{gist,relate,irregex}`).
- FFI status codes or callback lifetime (`include/irregex.h` in lockstep).
- Analytic API surface (`api.zig`).

Cold argv / walk / emit / warm reconcile live under [`../exec/`](../exec/).

Deep dives live in the sibling `gist` repo: `gist/src/surface/cli/` ·
`gist/src/surface/ffi/` · `gist/src/surface/face/`.
