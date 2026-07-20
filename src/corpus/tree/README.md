---
doc_radar:
  sentinels:
    - description: "all corpus walkers retain the shared gitignore boundary"
      file: pkg/kernels/irregex/src/corpus/tree/haystack.zig
      contains: ["ignore.Ignore", "shouldSkip"]
---

# `src/corpus/tree/` — corpus loading and traversal

The source-tree substrate shared by indexing, cold search, resident search, and
the verification harness. It owns corpus loading, the Haystack walk, and the
rg-compatible ignore protocol; path selection lives beside it in `../scope/`.

| File           | Role                                                                                                          |
| -------------- | ------------------------------------------------------------------------------------------------------------- |
| `corpus.zig`   | Loads non-binary files under the corpus roots and owns the process output budget.                             |
| `haystack.zig` | Defines the shared recursive walk, applying `ignore.zig` plus corpus-only skip-directory policy.              |
| `ignore.zig`   | Compiles gitignore / `.ignore` / `.rgignore` precedence once for gist, indexes, relate, and composed irregex. |
| `bulkstat.zig` | Reads Darwin name/type/mtime/ctime in bulk, with a portable stat fallback and one shared freshness rule.      |
| `*_test.zig`   | Pins path policy, metadata boundaries, and Darwin bulk-stat parity against the portable reference walk.       |

## Local-filesystem freshness model

The persisted trigram index is an acceleration structure, not the authority on
which files exist. Its freshness overlay lives in `../../index/trigrams/` and
drives this live walk. For an indexed non-candidate, it elides the file read only
when both timestamps are available and strictly older than the build anchor:

```text
live_read =
  mtime unavailable OR ctime unavailable OR
  mtime >= anchor OR ctime >= anchor
```

The anchor is a UTC wall-clock instant captured before the index reads the
corpus. `ctime` means status/change time, not creation time. An ordinary write,
truncate, metadata-preserving copy, or replacement advances ctime even when
`touch -r` restores mtime, so preserved-mtime appends and same-size overwrites
are re-read. Equality is deliberately live: a timestamp at the anchor boundary
is never evidence that the file predates the index.

New and renamed paths are absent from the indexed path table and are always
read. Deleted paths are absent from the live walk. A per-file metadata failure
also forces a read; a directory traversal failure is reported by the primary
walk and makes the query fail rather than silently presenting a complete result.
Files selected for reading are matched against their live bytes before output,
so stale index hits cannot create false positives.

The qualified guarantee is: freshness-aware with no false negatives under these
local-filesystem assumptions:

1. The filesystem is coherent and reports mtime/ctime in the anchor's wall-clock
   domain. A completed ordinary content change advances ctime to the anchor's
   representable tick or later.
2. Timestamp resolution may collapse a change onto the anchor tick; `>=` covers
   that case. A filesystem that truncates a post-anchor ctime into an earlier
   tick, reports creation time as ctime, or permits both clocks to be backdated
   requires a full live scan (`--no-index`).
3. The live directory walk either sees a path or reports that it could not
   traverse the directory. Network filesystems with incoherent metadata caches
   are outside this model.
4. Queries are not snapshots. A write racing directory metadata collection and
   the later file read may resolve to the before- or after-write state. Once the
   write and its ctime update are visible, a subsequent query re-reads it.

This avoids git-history assumptions: rebases and already-committed coworker
changes can disappear from `git diff`, but they still change local filesystem
metadata.
