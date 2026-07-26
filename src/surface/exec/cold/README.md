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

- **serial** — the certified control plane (fallbacks, stdin, JSON, quiet, exit)
- **swarm** — fused work-stealing walk+read+match when the flag set allows
- **ranked** — `--rank` definition-first view (gist's one native shape)

The warm daemon and the FFI session do **not** reimplement matching: they call
the shared `kernel/match/query/query.zig` core and, for line frames, reuse this
face's own `Emitter` / `read/binary.zig` so warm bytes cannot drift from cold.

## Concern packages

| Package             | Owns                                                                 |
| ------------------- | -------------------------------------------------------------------- |
| [`argv/`](argv)     | flag grammar → `Opts`; the `flag_catalog` `--schema` rides           |
| [`writ/`](writ)     | what the patterns decide — matcher, gates, filters, and their guards |
| [`quarry/`](quarry) | what is in the tree, what must be read, in what order, from where    |
| [`read/`](read)     | per-file ingest — bytes off disk, made legible, binary policy, stats |
| [`emit/`](emit)     | presentation — framing, color, `--json`, multiline, per-file render  |
| [`engine/`](engine) | scheduling that drives the packages above                            |
| [`view/`](view)     | gist's own ways of looking at a match, which rg has no flag for      |

The first six are the pipeline in order: **argv → writ → quarry → read → emit**,
with `engine/` choosing which scheduler walks it
([ADR-376](../../../../../../../docs/architecture/3-decisions/376-cold-engine-deep-modules.md)).
`view/` sits beside that pipeline rather than in it — a lens branches before the
certified rg path and finishes the run itself, which is exactly what keeps the
parity certificate meaningful as gist grows native shapes.

Corpus admission and path vocabulary are shared below the CLI in
[`corpus/tree/`](../../../corpus/tree) and [`corpus/scope/`](../../../corpus/scope).

Named for what each module _is_, not to mirror ripgrep's source layout. The
rgsuite certificate (`bench/rgsuite/`) is the parity gate for this face.
