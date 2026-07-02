# gist/src/index

**T0** — the positional-trigram candidate index, gist's structural edge over a
whole-tree scan.

| File          | Role                                                                                                                                                             |
| ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ngram.zig`   | N-gram extraction strategy (which grams to emit) — `extractSortedUnique` + helpers, isolated so a sparse-n-gram variant drops in here.                           |
| `trigram.zig` | `Index.build` / `Index.queryLiteral` — the sound candidate superset via posting-list AND (rarest-gram seed, intersect outward).                                  |
| `persist.zig` | Zero-copy persistence — serialize to a native-endian blob, load back via `mmap` so postings alias the mapped pages (cold query faults in only the probed pages). |

Any file containing a literal must contain every trigram of that literal, so the
AND of the per-trigram posting lists is a **sound** candidate set — false
positives are verified away downstream; false negatives (the one unforgivable
bug) are impossible for literals ≥ 3 bytes. See [`../README.md`](../README.md).
