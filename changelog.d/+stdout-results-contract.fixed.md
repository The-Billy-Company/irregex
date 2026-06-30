**Query results now go to stdout, diagnostics to stderr** (`bench/cli.zig`,
`bench/scan.zig`, `bench/corpus.zig`). The `query` / `regex` / `rank` paths
printed *everything* — match paths, ranked rows, and the timing summary —
through `std.debug.print`, which writes to **stderr**. Found by dogfooding gist
as an agent: `gist query Foo > files.txt` captured an **empty file** and
`gist query Foo | head` mixed the `—` summary line into the paths — the opposite
of the `rg` convention every agent and shell pipeline assumes. The match list
(literal `query`), the ranked rows (`rank`), and the live-tree scan match set
(`regex` / sub-trigram `query`) now emit on **stdout** via a raw `posix.write`
loop (`corpus.emitStdout`, EPIPE-safe so `| head` exiting early can't crash the
query); the human-facing `—` summary, the `[pipeline]` straggler canary, and the
`no index` / `bad pattern` guidance stay on **stderr**. Match sets are byte-for-
byte unchanged — the `gist ≡ rg` equality oracle (50 literals + 68 regexes) and
the no-prefilter `scan_regress.sh` gate both still prove 0 false negatives /
0 false positives, and every bench harness (which captures `2>&1` and splits by
content shape) is unaffected. New permanent guard: `bench/streams.sh` asserts
the results→stdout / diagnostics→stderr split across the literal, rank, and scan
paths and reproduces the original empty-file bug as a falsifiable regression.
