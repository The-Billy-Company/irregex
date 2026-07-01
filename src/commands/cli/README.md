# gist/src/commands/cli

The `gist` binary's entrypoint + the core-verb drivers.

| File          | Role                                                                                                    |
| ------------- | ------------------------------------------------------------------------------------------------------- |
| `main.zig`    | The `gist` executable entrypoint — imports the `gist` module and dispatches `index` / `query` / `regex` / `rank` / `grep` / `rg` to their handlers. |
| `drivers.zig` | The `index` / `query` / `regex` / `rank` driver bodies — build+persist once, then serve each cold query from the `mmap`ed index (via `index/persist.zig`), fusing corpus load, freshness, verify, and ranking. |

`grep` lives in [`../grep/`](../grep) and the arbitrary-tree `rg` drop-in in
[`../ripgrep/`](../ripgrep); this folder is the persisted-index verbs. Build and
run with `zig build cli -- <verb>` (see [`../../../README.md`](../../../README.md)).
