---
doc_radar:
  counts:
    - description: "exactly two product faces — CLI and C ABI"
      glob: pkg/kernels/irregex/src/gist/faces/*/
      equals: 2
      unit: dirs
  sentinels:
    - description: "commands.* still re-exports both faces through the package root"
      file: pkg/kernels/irregex/src/root.zig
      contains:
        - 'pub const ffi = @import("gist/faces/ffi/session.zig");'
        - 'pub const search = @import("gist/faces/cli/search/engine/serial.zig");'
---

# gist/faces — product surfaces over the shared kernel

A **face** is how something outside the kernel *talks* to gist. The kernels
under `gist/kernel/` and the warm engine under `gist/session/` own matching;
faces own transport, argv, process lifecycle, and host ABI. None of them is a
second matcher — cold CLI, warm daemon, and in-process FFI all execute the one
`CompiledQuery`, so a match-set difference between faces is a bug.

There are exactly two faces:

| Face | Who uses it | Contract |
| --- | --- | --- |
| [`cli/`](cli) | agents, humans, `alias rg=gist` | the `gist` binary — subprocess, stdout, exit codes |
| [`ffi/`](ffi) | Python cffi / any C host | `irregex_open` / `search` / `close` over `libirregex` |

**Why this split.** The CLI is allowed to `die()` and `exit` — that is ripgrep's
contract, and agents depend on it. An embedding host cannot: a bad query must
never kill the process. The FFI face therefore rides the error-returning warm
engine ([ADR-352](../../../../../../docs/architecture/3-decisions/352-gist-unified-search-api.md)
rung 3). The CLI's warm path (`cli/daemon/`) is a separate accelerator over the
same session — Unix socket, fail-open to cold — not a third matcher.

Index *build* (`gist index`) stays a CLI verb. A session searches the live tree;
it does not mutate the persisted trigram artifacts.
