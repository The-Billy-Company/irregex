# exec/cold — the Unified rg-DEFAULT Engine

The cold search path. This is what backs the exact-search face's bare
`<pattern>` form, its `rg` alias, and its `search` verb: a byte-for-byte
ripgrep-DEFAULT drop-in over an arbitrary tree (gitignore precedence, piped
stdin, coloring, exit codes), with the persisted trigram index used only as a
read-elision accelerator when it covers the searched roots.

One matcher, three orchestration modes under [`engine/`](engine):

- **serial** is the certified control plane — fallbacks, stdin, JSON, quiet,
  and exit codes.
- **swarm** is the fused work-stealing walk+read+match, taken when the flag
  set allows.
- **ranked** is the `--rank` definition-first view, the face's one native shape.

The warm daemon and the FFI session do not reimplement matching: they call
the shared `kernel/query/query.zig` core and, for line frames, reuse this
face's own `Emitter` / `read/binary.zig` so warm bytes cannot drift from
cold.

## Concern Packages

- **[`argv/`](argv)** owns the flag grammar → `Opts`; its `flag_catalog`
  also drives `--schema`.
- **[`writ/`](writ)** owns what the patterns decide — the matcher, its
  gates and filters, and their guards.
- **[`quarry/`](quarry)** owns what is in the tree: what must be read, in
  what order, from where.
- **[`read/`](read)** owns per-file ingest — bytes off disk, made legible,
  binary policy, and stats.
- **[`emit/`](emit)** owns presentation — framing, color, `--json`,
  multiline, and per-file render.
- **[`engine/`](engine)** owns the scheduling that drives the five packages
  above.
- **[`view/`](view)** owns the face's own ways of looking at a match, the
  shapes ripgrep has no flag for.

The first six are the pipeline in order — argv → writ → quarry → read →
emit — with `engine/` choosing which scheduler walks it (the cold-engine
deep-module split). `view/` sits beside that pipeline rather than in it: a
lens branches before the certified rg path and finishes the run itself,
which is exactly what keeps the parity certificate meaningful as the face
grows native shapes.

Corpus admission and path vocabulary are shared below the CLI in
[`corpus/tree/`](../../corpus/tree) and [`corpus/scope/`](../../corpus/scope).

Named for what each module *is*, not to mirror ripgrep's source layout. The
rgsuite certificate the face package mints over a running binary is the
parity gate for this path.
