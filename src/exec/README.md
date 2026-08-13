# `src/exec/` — the search runtimes

Where a compiled query meets a corpus. Promoted out of `surface/` so
execution is owned by neither product face: walk, read, match, emit, and the
resident session live here without verb tables, `--help` copy, or NDJSON
shapes. A face imports these engines; an engine never imports a face.

Three rungs share this floor, each a different transport for the same match:

- **[`cold/`](cold)** is transport rung 1, a fresh subprocess per query — the
  certified rg-DEFAULT drop-in that lowers argv through writ, quarry, read,
  engine, and emit.
- **The kinship package's `src/exec/retrieval/`** is a shared rung with no
  transport of its own: fingerprint-lexicon retrieval that the kinship face's
  nearest-neighbor and context-packing verbs ride, used by both cold and warm.
- **[`session/`](session)** is transport rung 2.5, a UDS daemon — the
  resident corpus and index, owning `daemon/{client,serve}` since the
  session-plane move.

## The One Match Opinion

The warm daemon does not reimplement matching. Both rungs lower every query
through `kernel/query/query.zig`, and `session/` reuses `cold/`'s own
`Emitter` / read-plane / file-set machinery.

- **Fail open to cold.** Any warm decline, timeout, TTY, wedged daemon, or
  reconcile doubt falls back to the certified cold subprocess.
- **Index accelerates only.** Missing, stale, or `--no-index` means a live
  scan, never different bytes.
- **Cold owns the walk.** `session/` re-derives its file set from
  `cold/engine/serial.zig::defaultFileSet` on every reconcile.

The in-process C ABI lives in [`surface/ffi/`](../surface/ffi) — it is the
same resident session, called in-process rather than over a socket.

Deep dives: [`cold/README.md`](cold/README.md),
[`session/README.md`](session/README.md), and the retrieval rung's own
`README.md` in the sibling kinship package.
