# `src/exec/` — the search runtimes

Where a compiled query meets a corpus. Promoted **out of** `surface/` so
execution is owned by neither product face: walk, read, match, emit, and the
resident session live here without verb tables, `--help` copy, or NDJSON
shapes. A `face/` imports these engines; an engine never imports a face.

| Rung | Transport | Job |
| ---- | --------- | --- |
| [`cold/`](cold) | 1 (subprocess) | The certified rg-DEFAULT drop-in: argv → writ → quarry → read → engine → emit |
| `relate/src/exec/retrieval/` | shared | Fingerprint-lexicon retrieval `relate similar` / `pack` ride — shared by cold and warm |
| [`session/`](session) | 2.5 (UDS daemon) | Resident corpus + index; owns `daemon/{client,serve}` since the session-plane move |

## The one match opinion

The warm daemon does **not** reimplement matching. Both rungs lower every query
through `kernel/query/query.zig`, and `session/` reuses `cold/`'s own `Emitter`
/ read-plane / file-set machinery:

- **Fail open to cold.** Any warm decline, timeout, TTY, wedged daemon, or
  reconcile doubt falls back to the certified cold subprocess.
- **Index accelerates only.** Missing / stale / `--no-index` → live scan,
  never different bytes.
- **cold owns the walk.** `session/` re-derives its file set from
  `cold/engine/serial.zig::defaultFileSet` on every reconcile.

The in-process C ABI lives in `gist/src/surface/ffi/`; it
shares the resident session but is documented there.

Deep dives: [`cold/README.md`](cold/README.md),
[`session/README.md`](session/README.md),
`relate/src/exec/retrieval/README.md`.
