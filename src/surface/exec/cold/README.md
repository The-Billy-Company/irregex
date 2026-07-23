---
doc_radar:
  sentinels:
    - description: "serial engine remains the commands.search re-export"
      file: pkg/kernels/irregex/src/root.zig
      contains: 'pub const search = @import("surface/exec/cold/engine/serial.zig");'
---

# surface/exec/cold — the unified rg-DEFAULT engine

The cold search path. This is what backs bare `gist <pattern>`, `gist rg`, and
`gist search`: a byte-for-byte ripgrep-DEFAULT drop-in over an arbitrary tree
(gitignore precedence, piped stdin, coloring, exit codes), with the persisted
trigram index used only as a read-elision accelerator when it covers the
searched roots.

One matcher, three orchestration modes under [`engine/`](engine):

- **serial** — the certified control plane (fallbacks, stdin, JSON, stats, exit)
- **parallel** — fused work-stealing walk+read+match when the flag set allows
- **ranked** — `--rank` definition-first view (gist's one native shape)

The warm daemon and the FFI session do **not** reimplement matching: they call
the shared `kernel/match/query.zig` core and, for line frames, reuse this
face's own `Emitter` / `grepfile` so warm bytes cannot drift from cold.

## Concern packages

| Package             | Owns                                                        |
| ------------------- | ----------------------------------------------------------- |
| [`argv/`](argv)     | flag grammar → `Opts`; the `flag_catalog` `--schema` rides  |
| [`read/`](read)     | per-file ingest (encoding, decompress/preprocess, grepfile) |
| [`emit/`](emit)     | presentation — framing, color, `--json`, multiline          |
| [`engine/`](engine) | orchestration that drives the packages above                |

Corpus admission and path vocabulary are shared below the CLI in
[`corpus/tree/`](../../../corpus/tree) and [`corpus/scope/`](../../../corpus/scope).

Named for what each module _is_, not to mirror ripgrep's source layout. The
rgsuite certificate (`bench/rgsuite/`) is the parity gate for this face.
