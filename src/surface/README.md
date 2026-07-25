---
doc_radar:
  counts:
    - description: "surface keeps cli · exec · ffi · face"
      glob: pkg/kernels/irregex/src/surface/*
      unit: dirs
      equals: 4
  sentinels:
    - description: "cold serial engine remains the root search re-export"
      file: pkg/kernels/irregex/src/root.zig
      contains: 'pub const search = @import("surface/exec/cold/engine/serial.zig");'
---

# `src/surface/` — transports + faces

How a compiled query meets a corpus, and how a human drives it. `exec/` + `ffi/`
drive `corpus/` + `kernel/` without owning product UX (no verb tables, no
`--help` copy, no relate NDJSON shapes); `face/` owns exactly that UX and imports
the engines below it — the engines never import a face. `cli/` is the vocabulary
the faces are built from — argv/root/emit plumbing shared so no face forks a flag
value, a root rule, or the JSON escaper.

| Transport                       | Rung             | Job                                                                                                           |
| ------------------------------- | ---------------- | ------------------------------------------------------------------------------------------------------------- |
| [`exec/cold/`](exec/cold)       | 1 (subprocess)   | rg-DEFAULT argv → walk → read → match → emit; serial / parallel / ranked, plus relate's cold retrieval engine |
| [`exec/session/`](exec/session) | 2.5 (UDS daemon) | Resident corpus + index behind `gist serve`; errors, never `die()`                                            |
| [`ffi/`](ffi)                   | 3 (in-process)   | Same session as C ABI: `irregex_open` / `irregex_search` / `irregex_close`                                    |
| [`face/`](face)                 | product          | The three faces — `gist` · `relate` · `irregex` — verb tables, `--help`, `--schema`, NDJSON shapes            |
| [`cli/`](cli)                   | shared           | The face vocabulary all three speak: `flags` (argv → values + roots) · `emit` (NDJSON / text rows)            |

## Shared contracts across engines

- **One match opinion.** Warm and FFI reuse cold's `Emitter` / `grepfile` /
  file-set machinery and the shared `kernel/match/query/query.zig` core so output
  cannot become a second opinion.
- **Fail open to cold.** Any warm decline, timeout, TTY, wedged daemon, or
  reconcile doubt falls back to the certified cold subprocess.
- **Index accelerates only.** Missing / stale / `--no-index` → live scan,
  never different bytes.
- **Never abort the host.** Session and FFI return typed errors / status
  codes; a bad pattern kills the _child_ on the subprocess path, not an
  embedding process.

## When to edit here

- Flag catalog / `--schema` (`exec/cold/argv`); the shared flag-value / root / emit vocabulary (`cli/`).
- Ignore walk, encoding ingest, or emit framing (`exec/cold/{read,emit}`).
- Warm eligibility, UDS protocol, watcher / dirty / delta reconcile (`exec/session/`).
- FFI status codes or callback lifetime rules (`include/irregex.h` in lockstep).
- Verb dispatch, help copy, or NDJSON shapes for a face (`face/{gist,relate,irregex}`).

Deep dives: [`cli/README.md`](cli/README.md), [`exec/cold/README.md`](exec/cold/README.md),
[`exec/session/README.md`](exec/session/README.md), [`ffi/README.md`](ffi/README.md),
[`face/README.md`](face/README.md).
