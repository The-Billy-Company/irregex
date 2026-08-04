# `src/corpus/tree/` — the walk, the corpus, the drain

This package is the source-tree substrate shared by indexing, cold search, resident search, and the verification harness.

It owns corpus loading (serial and fused parallel), the Haystack walk, the rg-compatible ignore protocol, and the stdout drain that `corpus.zig`'s `writeStdout` seam arms. Path selection lives beside it in [`../scope/`](../scope/README.md); the freshness law and the FSEvents journal live in [`../fresh/`](../fresh/README.md).

## Files, By Role

- **`corpus.zig`** loads non-binary files under the corpus roots and owns the process output budget and the charter-aware roots resolution.
- **`haystack.zig`** is the shared recursive `Walker` — ignore policy plus corpus skip policy plus charter skips.
- **`ignore.zig`** compiles gitignore / `.ignore` / `.rgignore` precedence once for every face.
- **`drain.zig`** is the stdout cadence — `line` / `block` / `relay` policies, whose only consumer is `corpus.zig`.
- **`bulkstat.zig`** holds the freshness policy over batched metadata: the elision law, the fresh-file overlay, and the portable fallback.
- **`sheaf.zig`** is the batched-enumeration ABI itself: Darwin `getattrlistbulk`, Windows `NtQueryDirectoryFile`, POSIX `getdirentries`/`getdents64`.
- **`loadpar.zig`** is the fused parallel walk+read loader, membership-parity with `haystack.Walker`.

## Why `drain` Sits Here

Stdout buffering looks like emit policy, but its only caller is `corpus.writeStdout`. Parking it under `exec/cold/emit/` would have forced a corpus-to-cold edge for a cadence table, so it lives with the corpus seam that arms it instead.

## Freshness Model

The persisted trigram index accelerates; it never overrules live bytes. The dual-clock anchor and change journal that make a days-old artifact still correct live in [`../fresh/`](../fresh/README.md), shared by every artifact rather than a trigram private.

See that README for the qualified local-filesystem guarantee.

## When To Edit

Come here for walk policy, the ignore dialect, drain syscall budgets, and parallel-loader parity. Charter keys and PathFilter composition belong in [`../scope/`](../scope/README.md); artifact clocks belong in [`../fresh/`](../fresh/README.md).
