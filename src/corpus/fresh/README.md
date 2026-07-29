---
doc_radar:
  counts:
    - description: "fresh keeps anchor · journal · sweep (+ tests)"
      glob: pkg/kernels/irregex/src/corpus/fresh/*.zig
      unit: files
      min: 3
  sentinels:
    - description: "the dual-clock anchor is the crate's central truth mechanism"
      file: pkg/kernels/irregex/src/corpus/fresh/fresh.zig
      contains: ["pub fn readAnchor", "pub fn writeAnchor"]
    - description: "the model's one predicate reads BOTH clocks and treats absence as change"
      file: pkg/kernels/irregex/src/corpus/tree/bulkstat.zig
      contains: "pub fn needsLiveRead"
---

# `src/corpus/fresh/` — when may an artifact speak for live bytes?

The freshness law. Promoted out of `corpus/index/trigrams/` because every
persisted accelerator — atlas, frag, shelf, phantom, content, crest, the
trigram pair — folds through the same T3 rule: _index accelerates, never
overrules_. A days-old artifact is still correct under a tree ~10 agents are
editing because this package says so, not because any one format invented a
private clock.

| File | Job |
| ---- | --- |
| `fresh.zig` | Dual-clock build anchor + conservative freshness probe |
| `journal.zig` | macOS FSEvents change-journal replay (the sweep's OS accelerator; never a correctness dependency) |
| `sweep.zig` | Work-stealing "what changed since anchor" metadata walk |

Sits **above** the trigram pair on the ward page (it reads the pair's layout
to prove currency) and **below** the rest of `index/` that trusts the fold.
The build stamps the anchor _before_ reading the corpus; a file whose
mtime/ctime reaches the anchor is re-verified live.

`journal.zig` moved here from `corpus/tree/` — its only consumer is
`fresh.zig`. The walk substrate does not need a change journal; the freshness
law does.

## The model

This is the "local-filesystem model" the rest of the tree cites, and the thing
every "no false negatives" claim about gist is conditional on. One predicate
carries it — `tree/bulkstat.zig::needsLiveRead`:

> an indexed file's read may be elided only if **both** its mtime and its ctime
> are strictly less than the build anchor. Either clock at-or-after the anchor,
> or either clock unavailable, forces the live read.

Equality is deliberately on the live-read side, so a coarse clock that collapses
a post-anchor write onto the anchor tick stays conservative.

**What the proof assumes.** Three things, true of every local filesystem gist is
built for:

1. a completed ordinary write advances the file's reported **ctime** to the
   anchor tick or later — POSIX requires `write(2)`, `rename(2)`, `truncate(2)`
   and friends to mark st_ctime for update, which is what closes the ordinary
   preserved-mtime hole: `touch -r old new` rewinds mtime and *advances* ctime;
2. the primary live walk reports traversal failures instead of silently dropping
   a subtree (a declined bulk listing degrades to the stat walk, never to
   "nothing changed here");
3. metadata is either reported or reported-absent — a filesystem that cannot
   answer gets the file read.

**What sits outside it**, and what happens there:

| Case | Outcome |
| ---- | ------- |
| **Both** clocks deliberately backdated below the anchor | the read is elided and the answer comes from the stale index. No portable call rewinds ctime, so this takes a tool or filesystem built to do it |
| Path reuse (the index is keyed on path, not inode) | ordinary `rename`/create advances the new inode's ctime, so a replace is caught; a replacement whose ctime is *also* backdated is the row above |
| Network / cache incoherence (NFS attribute caching, a FUSE layer that fabricates clocks) | assumption 1 no longer holds; treat the index as advisory |
| A write racing the metadata→read window | the query resolves to the before- or after-write state — a snapshot was never promised. The next query sees the advanced ctime |
| `git diff HEAD` as a freshness source | unsound, and deliberately not used: a coworker's committed change differs from the older index without appearing in the working-tree diff |

Where the model does not hold, `--no-index` is the answer — it costs time and
nothing else, which is the whole point of an index that may only elide reads.

Each row of the assumption list is a test, not a hope: `fresh_test.zig` writes
real files and drives real syscalls to prove that an ordinary write is surfaced,
that an mtime rewound behind the anchor is *still* surfaced through ctime, and
that a rename over an indexed path is surfaced; `../tree/bulkstat_test.zig`
pins the predicate's boundary exhaustively and cross-checks the bulk walk
against the stat walk over a live tree.
