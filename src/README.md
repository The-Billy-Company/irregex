# gist/src

Zig sources for the `gist` code-locator kernel. One file per tier; each is
re-exported through `root.zig` and surfaced via the flat C-ABI in
`../include/gist.h`.

| File          | Role                                                                                                                                                                                                                                          |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `root.zig`    | C-ABI root: re-exports each tier, pins `gist_abi_version`, exposes `gist_trigram_count` (the parity oracle).                                                                                                                                  |
| `ngram.zig`   | N-gram extraction strategy (which grams to emit) — `extractSortedUnique` + helpers. Isolated from the index so the T1 sparse-n-gram variant (ADR-pending) drops in here without touching build/query.                                          |
| `trigram.zig` | **T0** positional-trigram candidate index — `Index.build` / `Index.queryLiteral`, a sound superset of literal matches via posting-list AND, built on `ngram`'s extraction.                                                                     |

See [`../README.md`](../README.md) for the tier roadmap and build commands.
