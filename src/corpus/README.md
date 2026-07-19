---
doc_radar:
  counts:
    - description: "corpus keeps its tree and scope concerns"
      glob: pkg/kernels/irregex/src/corpus/*
      unit: dirs
      equals: 2
---

# `src/corpus/` — shared source substrate

Which paths and bytes are eligible for search or indexing. This tier knows
**nothing** about matching, ranking, persistence formats, transports, or CLI
presentation — both engines and every runtime host share it so walk policy
cannot fork.

| Package | Owns |
| ------- | ---- |
| [`tree/`](tree) | Corpus loading, the coarse Haystack walk, Darwin `getattrlistbulk` + portable freshness metadata |
| [`scope/`](scope) | `-g` glob + `-t` language-type tables shared by cold and resident execution |

## Why it exists

One walk skeleton (`tree/haystack.zig`) feeds the parallel search, the index
build, and the freshness stat-walk — each plugs a different per-file action.
Scope prunes **before** disk when the path list is already known (faster
than rg's walk-then-filter).

## When to edit

Skip-directory policy, ignore *shared* helpers that aren't cold-specific,
bulkstat / portable stat parity, `-g` / `-t` tables, or the output budget on
loaded corpora. rg-compatible ignore *dialect* wiring for the cold face
still lives beside the walk in `runtime/cold/walk/`.

Deep dives: [`tree/README.md`](tree/README.md), [`scope/README.md`](scope/README.md).
