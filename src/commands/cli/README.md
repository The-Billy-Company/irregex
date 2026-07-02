# gist/src/commands/cli

The `gist` binary's entrypoint + the machine-readable capability manifest.

| File         | Role                                                                                                                                                                          |
| ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `main.zig`   | The `gist` executable entrypoint — dispatches the three real verbs `index` / `status` / `search`, the top-level `--help` / `--version` / `--schema` flags, and the internal (undocumented) `rg` rgsuite drop-in. |
| `schema.zig` | `gist --schema` — the static JSON capability manifest (verbs, native flags, types, defaults, legacy aliases, exit codes) an agent or codegen step consumes instead of scraping `--help`. |

The one search verb lives in [`../search/`](../search) (parser, drivers, line
engine, `--live`), read-only introspection in [`../status/`](../status), and the
internal arbitrary-tree `rg` parity drop-in in [`../ripgrep/`](../ripgrep). Build
and run with `zig build cli -- <verb>` (see [`../../../README.md`](../../../README.md)).
