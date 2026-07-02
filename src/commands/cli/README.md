# gist/src/commands/cli

The `gist` binary's entrypoint + the machine-readable capability manifest.

| File         | Role                                                                                                                                                                          |
| ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `main.zig`   | The `gist` executable entrypoint — dispatches the three real verbs `index` / `status` / `search`, the bare `gist <pattern> [PATH...]` shorthand (no verb), the explicit `gist rg` alias, and the top-level `--help` / `--version` / `--schema` flags. |
| `schema.zig` | `gist --schema` — the static JSON capability manifest (verbs, native flags, types, defaults, legacy aliases, exit codes) an agent or codegen step consumes instead of scraping `--help`. |

The one search verb lives in [`../search/`](../search) (parser, drivers, line
engine, `--live`), read-only introspection in [`../status/`](../status). The
bare shorthand and `gist rg` both route through the whole-tree, arbitrary-root
`rg` parity engine in [`../ripgrep/`](../ripgrep) — its own flag surface (rg-exact,
a superset of `search`'s legacy Set A), kept separate from `search` because it
needs byte-identical `rg` default behavior (gitignore precedence, piped stdin,
coloring) the index model doesn't. Build and run with `zig build cli -- <verb>`
(see [`../../../README.md`](../../../README.md)).
