# gist/src/commands/status

The `gist status` verb — read-only introspection of the persisted index.

| File         | Role                                                                                                                                                            |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `status.zig` | Answers "am I ready to search fast, and how fresh?" — index presence, files indexed, distinct trigrams, postings, on-disk size, build age vs the freshness anchor, corpus roots. Derived from the same mmap'd artifacts the query path loads (`index/persist.zig`) + the freshness anchor (`corpus/fresh.zig`); no build, no scan, no mutation. |

A missing index is reported as an actionable state (run `index`), never an
error, so `status` is safe to call blind. See [`../../../README.md`](../../../README.md).
