---
doc_radar:
  counts:
    - description: "corpus keeps its tree and scope concerns"
      glob: pkg/kernels/irregex/src/corpus/*
      unit: dirs
      equals: 2
---

# `src/corpus/` — the shared source substrate

Corpus discovery and selection below both indexes and both search engines.
This tier knows which bytes and paths are eligible; it knows nothing about
matching, ranking, persistence, transports, or CLI presentation.

| Package | Owns |
| --- | --- |
| [`tree/`](tree) | corpus loading, the coarse Haystack walk, and portable/bulk metadata reads |
| [`scope/`](scope) | path globbing and language-type selection shared by cold and resident execution |
