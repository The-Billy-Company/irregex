# `src/corpus/tree/` — the walk, the corpus, the drain

The source-tree substrate shared by indexing, cold search, resident search, and
the verification harness. Owns corpus loading (serial + fused parallel), the
Haystack walk, the rg-compatible ignore protocol, and the stdout drain that
`corpus.zig`'s `writeStdout` seam arms. Path selection lives beside it in
[`../scope/`](../scope/); the freshness law and FSEvents journal live in
[`../fresh/`](../fresh/).

| File | Role |
| ---- | ---- |
| `corpus.zig` | Loads non-binary files under the corpus roots; owns the process output budget and charter-aware roots |
| `haystack.zig` | Shared recursive `Walker` — ignore + corpus skip policy + charter skips |
| `ignore.zig` | Compiles gitignore / `.ignore` / `.rgignore` precedence once for every face |
| `drain.zig` | Stdout cadence — `line` / `block` / `relay` policies (its only consumer is `corpus.zig`) |
| `bulkstat.zig` | Freshness policy over batched metadata — the elision law, the fresh-file overlay, the portable fallback |
| `sheaf.zig` | The batched-enumeration ABIs themselves: Darwin `getattrlistbulk`, Windows `NtQueryDirectoryFile`, POSIX `getdirentries`/`getdents64` |
| `loadpar.zig` | Fused parallel walk+read loader — membership-parity with `haystack.Walker` |

## Why `drain` sits here

Stdout buffering looks like emit policy, but the only caller is
`corpus.writeStdout`. Parking it under `exec/cold/emit/` forced a corpus→cold
edge for a cadence table. It lives with the corpus seam that arms it.

## Freshness model

The persisted trigram index accelerates; it never overrules live bytes. The
dual-clock anchor + change journal that make a days-old artifact still correct
live in [`../fresh/`](../fresh/) — shared by every artifact, not a trigram
private. See that README for the qualified local-filesystem guarantee.

## When to edit

Walk policy, ignore dialect, drain syscall budgets, parallel loader parity.
Charter keys and PathFilter composition are [`../scope/`](../scope/).
Artifact clocks are [`../fresh/`](../fresh/).
