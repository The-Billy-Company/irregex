---
doc_radar:
  counts:
    - description: "index keeps five packages: trigrams · postings · atlas · codex · crest"
      glob: pkg/kernels/irregex/src/index/*
      unit: dirs
      equals: 5
  sentinels:
    - description: "the elision contract every index package is built on"
      file: pkg/kernels/irregex/src/runtime/cold/engine/README.md
      contains: "Index is an accelerator, not an authority."
---

# `src/index/` — candidate, self, and kinship indexes

Persisted structures that may **elide reads, never own truth**. The live walk
(`corpus/` + `runtime/cold/walk/`) decides which files exist; indexes only
prove that some of them cannot match (or answer count/find/restore /
kinship without a full scan). `--no-index`, a missing anchor, or a corrupt
artifact always degrades to slower-but-identical answers.

| Package | Job |
| ------- | --- |
| [`trigrams/`](trigrams) | **T0** positional trigram candidate index + **T3** mtime/ctime freshness |
| [`postings/`](postings) | LEB128 + CSR blob codecs the trigram bodies ride |
| [`crest/`](crest) | Per-doc forced-class-run vectors (`crest.bin`) for literal-free class runs |
| [`codex/`](codex) | FM-index self-index: `count` / `find` / `restore` at entropy space |
| [`atlas/`](atlas) | Persisted LZJD sketches for warm `relate similar` / `dups` / `clusters` |

## The one law

> Index is an accelerator, not an authority.

That sentence is load-bearing. `bench/gates/index_elision_parity.sh` asserts
indexed ≡ unindexed output byte-for-byte. Soundness rules:

- Trigram AND of required literals ≥ 3 bytes is a **sound** candidate set
  (false positives OK; false negatives forbidden).
- Freshness stamps the wall-clock anchor **before** reading the corpus;
  missing timestamps or a missing anchor fail closed (live-read).
- Crest `decode` nulls on framing mismatch → query runs without the sieve.
- Atlas / corrupt / `--no-index` → live rebuild, byte-identical answers.

## When to edit here

- On-disk magic, layout, or generation-atomic publish of a pair
  (`trigrams` + `crest`, atlas shelf).
- Freshness model, mmap load path, or codex layer math.
- Anything that could change which files are skipped — that needs a gate
  update in the same change.

Theory for the crest sieve lives in
[`../../research/crest/`](../../research/crest/); production math is
[`../math/crest.zig`](../math/crest.zig).
