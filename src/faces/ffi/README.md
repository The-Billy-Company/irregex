<!--
doc_radar:
  sentinels:
    - file: src/root.zig
      contains: ["export fn gist_open", "export fn gist_search", "export fn gist_close"]
    - file: include/gist.h
      contains: ["int32_t gist_open(", "int32_t gist_search(", "void gist_close("]
-->

# `ffi/` — the in-process C-ABI search session (ADR-352 rung 3)

`session.zig` is the C-ABI face of the warm engine: `gist_open` /
`gist_search` / `gist_close` let a non-Zig host (the Python `cffi` binding, or
any C caller) hold one corpus warm **in its own process** and stream match
records over a callback — no subprocess, no Unix socket, no `stdout`, no
`exit`.

It is the in-process sibling of the socket-served resident daemon
(`../session/resident.zig`) and draws on the same shared search core
(`../engine/query.zig`), so an in-process answer is byte-identical to the cold
`gist --json` stream and to the UDS daemon.

## Why this is the rung the C search ABI graduated on

[ADR-352](../../../../docs/architecture/3-decisions/352-gist-unified-search-api.md)
gates the C search ABI on one property: **a bad query must never terminate the
embedding host.** The whole warm path returns typed errors instead of calling
`die()`/`exit`, so every failure here is a negative status code the caller
recovers from (`GIST_STALE` → answer cold), never a dead process. The cold CLI
keeps its own fatal shell; this path does not touch it.

## Shape

| Symbol                                         | Role                                                                                                                                               |
| ---------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gist_open(roots, nroots, out)`                | Stand up a warm session (its own `std.Io.Threaded` I/O + corpus + index).                                                                          |
| `gist_search(s, pattern, len, flags, cb, ctx)` | Stream one `gist_match` per matching line to `cb` (which returns 0 to continue / non-zero to stop early); returns `GIST_MATCH`/`GIST_OK`/negative. |
| `gist_close(s)`                                | Tear down the corpus, index, I/O pool, and handle.                                                                                                 |

The three `export fn` shims live in `../root.zig` (the ABI's single export
surface); `session.zig` owns the handle, the `Match`/`Submatch` `extern`
layout, the `Relay` that marshals resident records into C structs, and the
status/flag contract. The C declarations mirror it in `../../include/gist.h`,
exercised end-to-end by the C-ABI smoke test in `../../build.zig`.

Every pointer handed to the callback (`path`, `line`, each submatch `text`)
aliases session/scratch memory valid **only** for that callback invocation —
the caller copies anything it keeps.
