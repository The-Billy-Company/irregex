---
doc_radar:
  counts:
    - description: "index keeps nine packages: trigrams · postings · atlas · codex · crest · frame · frag · phantom · content"
      glob: pkg/kernels/irregex/src/corpus/index/*
      unit: dirs
      equals: 9
  sentinels:
    - description: "the elision contract every index package is built on"
      file: pkg/kernels/irregex/src/surface/exec/cold/engine/README.md
      contains: "Index is an accelerator, not an authority."
---

# `src/corpus/index/` — candidate, self, and kinship indexes

Persisted structures that may **elide reads, never own truth**. The live walk
(`corpus/` + `corpus/tree/`) decides which files exist; indexes only
prove that some of them cannot match (or answer count/find/restore /
kinship without a full scan). `--no-index`, a missing anchor, or a corrupt
artifact always degrades to slower-but-identical answers.

| Package                 | Job                                                                              |
| ----------------------- | -------------------------------------------------------------------------------- |
| [`trigrams/`](trigrams) | **T0** positional trigram candidate index + **T3** mtime/ctime freshness         |
| [`postings/`](postings) | LEB128 + CSR blob codecs the trigram bodies ride                                 |
| [`crest/`](crest)       | Per-doc forced-class-run vectors (`crest.bin`) for literal-free class runs       |
| [`codex/`](codex)       | FM-index self-index: `count` / `find` / `restore` at entropy space               |
| [`atlas/`](atlas)       | Persisted LZJD sketches for warm `relate similar` / `dups` / `clusters`          |
| [`frag/`](frag)         | Persisted per-function silhouettes (`concepts.frag`) for warm `relate concepts`  |
| [`frame/`](frame)       | Shared wire discipline: LE ints, fail-closed cursor, NUL catalogs, `onDisk` gate |
| [`phantom/`](phantom)   | Directory-membership snapshot (`tree.map`): one lstat proves a dir, walk elided  |
| [`content/`](content)   | Corpus-content blob (`content.shard`): one mmap serves unchanged bytes, no open  |

## The one law

> Index is an accelerator, not an authority.

That sentence is load-bearing. `bench/gates/index_elision_parity.sh` asserts
indexed ≡ unindexed byte-exact line multisets and exit codes, normalizing only
the parallel walk's incidental cross-file scheduling order. Soundness rules:

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
[`../../../research/crest/`](../../../research/crest/); production math is
[`../../kernel/primitives/crest.zig`](../../kernel/primitives/crest.zig).
