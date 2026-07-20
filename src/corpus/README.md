---
doc_radar:
  counts:
    - description: "corpus keeps tree · scope · index concerns"
      glob: pkg/kernels/irregex/src/corpus/*
      unit: dirs
      equals: 3
---

# `src/corpus/` — shared source substrate

Which paths and bytes are eligible for search or indexing, and their persisted
pre-chewed forms. This tier knows **nothing** about matching, ranking,
transports, or CLI presentation — both engines and every surface transport
share it so walk policy cannot fork.

| Package | Owns |
| ------- | ---- |
| [`tree/`](tree) | Corpus loading, the coarse Haystack walk, Darwin `getattrlistbulk` + portable freshness metadata |
| [`scope/`](scope) | `-g` glob + `-t` language-type tables shared by cold and resident execution |
| [`index/`](index) | Persisted artifacts — trigram postings, the warm atlas, fragment index, codex/crest sidecars — that accelerate but never change answers |

## Why it exists

One walk skeleton (`tree/haystack.zig`) feeds the parallel search, the index
build, and the freshness stat-walk — each plugs a different per-file action.
Scope prunes **before** disk when the path list is already known (faster
than rg's walk-then-filter).

## When to edit

Skip-directory policy, ignore *shared* helpers that aren't cold-specific,
bulkstat / portable stat parity, `-g` / `-t` tables, persisted artifact
formats (`index/`), or the output budget on loaded corpora. rg-compatible
ignore *dialect* wiring for the cold face lives beside the cold engine in
`surface/exec/cold/`.

Deep dives: [`tree/README.md`](tree/README.md), [`scope/README.md`](scope/README.md),
[`index/README.md`](index/README.md).
