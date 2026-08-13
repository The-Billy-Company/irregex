# `src/corpus/fresh/` — when may an artifact speak for live bytes?

This package is the freshness law. It was promoted out of `corpus/index/trigrams/` because every persisted accelerator — atlas, frag, shelf, phantom, content, crest, the trigram pair — folds through the same T3 rule: *index accelerates, never overrules*.

A days-old artifact is still correct under a tree ~10 agents are editing because this package says so, not because any one format invented a private clock.

## Files, By Job

- **`fresh.zig`** holds the dual-clock build anchor and the conservative freshness probe.
- **`journal.zig`** replays the macOS FSEvents change journal — the sweep's OS accelerator, never a correctness dependency.
- **`sweep.zig`** is the work-stealing "what changed since anchor" metadata walk.

This package sits above the trigram pair on the ward page, since it reads the pair's layout to prove currency, and below the rest of `index/` that trusts the fold. The build stamps the anchor *before* reading the corpus, so a file whose mtime or ctime reaches the anchor is re-verified live.

`journal.zig` moved here from `corpus/tree/`, because its only consumer is `fresh.zig`. The walk substrate does not need a change journal; the freshness law does.

## What This Package Buys, Stated Against The Field That Skips It

This law is the reason irregex pays a metadata walk that the other indexed grep-class tools do not, so the cost is only justified by what they give up.

*ripgrep is not the comparator here*: a tool with no index is fresh by construction and has no read to elide, which is why it appears nowhere in this package. The comparison that means anything is against the two indexed engines, csearch and zoekt.

Reproduce it in four commands. Index a two-file corpus where only `a.txt` holds the needle, then, without reindexing anything, add a `c.txt` that holds it, give `b.txt` the needle too, and take it out of `a.txt`. Ground truth is now `b.txt c.txt`.

- **csearch** answers *(nothing)*: the index picks candidates and csearch then greps live bytes, so it never reports content that isn't there, correctly dropping `a.txt`. But `b.txt` and `c.txt` were never candidates, so they are never opened — staleness surfaces as false negatives only.
- **zoekt** answers `a.txt`: matching runs against the content stored in the shard, so it returns the one match that no longer exists and misses the two that do, wrong in both directions.
- **irregex** answers `b.txt c.txt`: identical cold, resident, and across an instant create or delete.

Neither result is a defect in those tools; both are built to be reindexed on a cadence (zoekt ships an index server, `cindex` is a scheduled step), and on a corpus that changes between reindexes rather than during one they are right.

The point is narrower: "answers from current bytes" is a *different guarantee* from "answers fast from an index," and it is the one an agent editing the tree alongside ~10 others actually needs. `needsLiveRead` is what closes both failure modes, and the walk described below is what it costs.

## The Model

This is the local-filesystem model the rest of the tree cites, and the thing every "no false negatives" claim about irregex is conditional on. One predicate carries it, `tree/bulkstat.zig::needsLiveRead`:

> An indexed file's read may be elided only if both its mtime and its ctime are strictly less than the build anchor. Either clock at-or-after the anchor, or either clock unavailable, forces the live read.

Equality is deliberately on the live-read side, so a coarse clock that collapses a post-anchor write onto the anchor tick stays conservative.

**What the proof assumes.** Three things hold true of every local filesystem irregex is built for:

1. A completed ordinary write advances the file's reported ctime to the anchor tick or later — POSIX requires `write(2)`, `rename(2)`, `truncate(2)` and friends to mark `st_ctime` for update, which is what closes the ordinary preserved-mtime hole: `touch -r old new` rewinds mtime and *advances* ctime.
2. The primary live walk reports traversal failures instead of silently dropping a subtree — a declined bulk listing degrades to the stat walk, never to "nothing changed here."
3. Metadata is either reported or reported-absent — a filesystem that cannot answer gets the file read.

**What sits outside it, and what happens there:**

- **Both clocks deliberately backdated below the anchor**: the read is elided and the answer comes from the stale index. No portable call rewinds ctime, so this takes a tool or filesystem built to do it.
- **Path reuse** (the index is keyed on path, not inode): an ordinary rename or create advances the new inode's ctime, so a replace is caught; a replacement whose ctime is also backdated falls into the row above.
- **Network or cache incoherence** (NFS attribute caching, a FUSE layer that fabricates clocks): assumption 1 no longer holds, so treat the index as advisory.
- **A write racing the metadata-to-read window**: the query resolves to the before- or after-write state — a snapshot was never promised. The next query sees the advanced ctime.
- **`git diff HEAD` as a freshness source**: unsound, and deliberately not used, since a coworker's committed change differs from the older index without appearing in the working-tree diff.

Where the model does not hold, `--no-index` is the answer. It costs time and nothing else, which is the whole point of an index that may only elide reads.

Each row of the assumption list is a test, not a hope. `fresh_test.zig` writes real files and drives real syscalls to prove that an ordinary write is surfaced, that an mtime rewound behind the anchor is still surfaced through ctime, and that a rename over an indexed path is surfaced. `../tree/bulkstat_test.zig` pins the predicate's boundary exhaustively and cross-checks the bulk walk against the stat walk over a live tree.
