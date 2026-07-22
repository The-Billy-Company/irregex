Beat ripgrep on the single-file line-scan modes by adopting the two things its
one-file-one-thread architecture can't: **data-parallel single-file sharding**
and **mmap'd reads**, plus an NFA-free span path. On a 57 MB single-file corpus
(`function|const|return|struct`, warm cache, hyperfine): `-c` 2.0×, `-o` 2.0×,
`-b` 1.95×, `--count-matches` 1.96×, `-n` 1.81× faster than `rg` — the
`--json` match stream stays byte-identical and ahead.

- **Single-file sharding** (`serial.zig` `emitFileSharded`/`lineShardBounds`):
  a lone big file is split at line boundaries into byte-balanced shards, each
  running the line-free literal fast path (`Emitter.fileLit`) over the SHARED
  global body on its own core, then merged in line order (emit modes) or summed
  (count modes). Byte offsets, the unterminated tail, and `-n` line numbers
  (each shard's global base via one cumulative `countByte` pass) all stay
  global, so output is identical to the serial scan — this is the win rg leaves
  on the table for a single file.
- **mmap for large files** (`grepfile.mapFile`, wired into `readOneCandidate`):
  an untransformed file ≥ 4 MiB is memory-mapped instead of read-loop + arena
  duped, so its pages fault in lazily during the (sharded) scan rather than
  paying a serial ~2× copy up front — ripgrep's large-file strategy.
- **Parallel binary detection** (`verify.firstNulWide`): the whole-buffer NUL
  scan that gates the fast path is fanned across cores with a quit-at-first-NUL
  poll (the binary-detection twin of `gateWide`), so it faults pages in parallel
  instead of serializing one redundant full pass ahead of the scan.
- **NFA-free literal spans** (`output.zig` `litNextSpan`/`emitMatchesLit`,
  `prefixFree`): for a prefix-free literal set (no literal a prefix of another —
  so at most one matches at any offset), `-o`/`--count-matches`/`--column`
  resolve each span with one `indexOfAnyPos` jump + a length lookup instead of a
  Pike-VM run per line, and never allocate a `SpanSim`. A non-prefix-free set
  (e.g. `con|const|co`) falls back to `matchSpan`, so spans stay byte-exact.
- **Early-exit presence** (`anyMatch`): `-q` short-circuits on the first literal
  occurrence (`indexOfAnyPos`) instead of materializing every line of the body
  — an 11× → parity swing on a top-matching 57 MB file.

Byte-identical to ripgrep — `bench/rgsuite/run.py` 405/405 (parallel and
serial), full Zig unit + differential-fuzz suite green (new `memchr` /
`lastIndexOfScalar` / `countByte` / `firstNulWide` oracles vs `std.mem`), and
span-mode spot-checks over `-o`/`-n`/`-b`/`--column`/`--count-matches` including
the prefix-overlap adverse case. The repo-wide *indexed* `-l`/`-c` race is
unaffected and still 6–100× over rg's unindexed walk.
