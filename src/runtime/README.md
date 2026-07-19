---
doc_radar:
  counts:
    - description: "runtime keeps three hosts: cold · session · ffi"
      glob: pkg/kernels/irregex/src/runtime/*
      unit: dirs
      equals: 3
  sentinels:
    - description: "cold serial engine remains the root search re-export"
      file: pkg/kernels/irregex/src/root.zig
      contains: 'pub const search = @import("runtime/cold/engine/serial.zig");'
---

# `src/runtime/` — execution hosts

How a compiled query meets a corpus. Runtime drives `corpus/` + `search/`
without owning product UX: no verb tables, no `--help` copy, no relate NDJSON
shapes. The CLI imports runtime; runtime never imports the CLI.

| Host | Rung | Job |
| ---- | ---- | --- |
| [`cold/`](cold) | 1 (subprocess) | rg-DEFAULT argv → walk → read → match → emit; serial / parallel / ranked |
| [`session/`](session) | 2.5 (UDS daemon) | Resident corpus + index behind `gist serve`; errors, never `die()` |
| [`ffi/`](ffi) | 3 (in-process) | Same session as C ABI: `irregex_open` / `irregex_search` / `irregex_close` |

## Shared contracts across hosts

- **One match opinion.** Warm and FFI reuse cold's `Emitter` / `grepfile` /
  file-set machinery and the shared `search/match/query.zig` core so output
  cannot become a second opinion.
- **Fail open to cold.** Any warm decline, timeout, TTY, wedged daemon, or
  reconcile doubt falls back to the certified cold subprocess.
- **Index accelerates only.** Missing / stale / `--no-index` → live scan,
  never different bytes.
- **Never abort the host.** Session and FFI return typed errors / status
  codes; a bad pattern kills the *child* on the subprocess path, not an
  embedding process.

## When to edit here

- Flag catalog / `--schema` (`cold/argv`).
- Ignore walk, encoding ingest, or emit framing (`cold/{walk,read,emit}`).
- Warm eligibility, UDS protocol, watcher / dirty / delta reconcile.
- FFI status codes or callback lifetime rules (`include/irregex.h` in lockstep).

Deep dives: [`cold/README.md`](cold/README.md),
[`session/README.md`](session/README.md), [`ffi/README.md`](ffi/README.md).
