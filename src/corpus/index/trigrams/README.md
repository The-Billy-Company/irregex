---
doc_radar:
  sentinels:
    - description: "trigram Index + freshness remain the T0/T3 surface"
      file: pkg/kernels/irregex/src/corpus/index/trigrams/trigram.zig
      contains: "pub const Index"
    - description: "freshness fails closed when the anchor is missing"
      file: pkg/kernels/irregex/src/corpus/index/trigrams/fresh.zig
      contains: "anchor"
    - description: "codicil builds and decodes the incremental amendment segment"
      file: pkg/kernels/irregex/src/corpus/index/trigrams/codicil.zig
      contains: ["pub fn build", "pub fn decode", "pub const Decoded"]
    - description: "codicil publish is atomic on the persist layer, and both build paths flip the generation through the one function that also retires"
      file: pkg/kernels/irregex/src/corpus/index/trigrams/persist.zig
      contains: ["pub fn publishCodicil", "fn publishGeneration"]
    - description: "generation retention fences a candidate on ordering, grace, and the survivor window"
      file: pkg/kernels/irregex/src/corpus/index/trigrams/lapse.zig
      contains: ["pub fn reclaim", "grace_ns", "fn parseGen"]
    - description: "sweep work-steals the freshness metadata walk"
      file: pkg/kernels/irregex/src/corpus/index/trigrams/sweep.zig
      contains: "buildWorkItems"
---

# `src/corpus/index/trigrams/` — T0 candidate index + T3 freshness

Gist's structural edge over a whole-tree scan. A file containing a literal
must contain every trigram of that literal, so the AND of per-trigram
posting lists is a **sound candidate set**: false positives expected and
verified away; false negatives impossible for literals ≥ 3 bytes.

## Files

| File                    | Job                                                                                                                                                   |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ngram.zig`             | Extract distinct ascending trigrams from a byte slice                                                                                                 |
| `trigram.zig`           | In-memory `Index`: build, rarest-first intersect, query                                                                                               |
| `persist.zig`           | Zero-copy `mmap` load / publish of the CSR posting blob; codicil-layered query (`queryLiteral` / `queryAny` = base ∪ codicil ∪ tombstones)            |
| `fresh.zig`             | Wall-clock mtime/ctime freshness overlay vs build anchor                                                                                              |
| `sweep.zig`             | Self-balancing, work-stealing metadata walk for the freshness overlay — BFS breadth-expansion feeding a thread pool                                   |
| `codicil.zig`           | Incremental amendment to a published generation — re-indexes only changed files (LSM-style delta segment), fused with the T3 freshness walk           |
| `lapse.zig`             | Retention: retires the generations a publish superseded, fenced against builds in flight (published id, newer ids, a grace window, a survivor window) |
| `codicil_test.zig`      | Adversarial codicil round-trip + layered query suite                                                                                                  |
| `lapse_test.zig`        | Retention fences, each asserted alone, plus batch bounding                                                                                            |
| `ngram_test.zig`        | Trigram extraction parity + edge cases                                                                                                                |
| `trigram_test.zig`      | Index candidate-set correctness vs naive scan oracle                                                                                                  |
| `persist_test.zig`      | Blob round-trip, corruption refusal, generation-atomic publish parity                                                                                 |
| `fresh_test.zig`        | Freshness overlay: anchor boundary, missing timestamps, fail-closed cases                                                                             |
| `trigram_fuzz.zig`      | Fuzz harness for trigram extraction                                                                                                                   |
| `trigram_load_test.zig` | End-to-end load-time validation of persisted blobs                                                                                                    |

Codecs live in [`../postings/`](../postings). Crest sidecar (literal-free
class runs) lives in [`../crest/`](../crest).

## Invariants

- **Accelerator only** — indexed ≡ unindexed output
  (`bench/gates/index_elision_parity.sh`).
- Anchor stamped **before** corpus read; missing / unreadable timestamps →
  live-read; missing anchor seeds every doc fresh (fail closed).
- Equality at the anchor boundary is live (`mtime >= anchor` or
  `ctime >= anchor`). Model assumes a local FS whose ctime advances on
  ordinary writes — see [`../../tree/README.md`](../../tree/README.md).
- Codicil postings for a dirty doc are false-positive only (the query layer
  unions, never subtracts); false-negative holes are closed by construction.
- Generations are **self-contained**: a codicil publish hardlinks its base
  blobs forward rather than referencing them, so no generation is reachable
  from another and retiring a superseded one cannot make the live pair
  incomplete. Retention is a disk-space tier, never correctness — every fence
  it applies is about not disturbing a _concurrent_ build, and a failed removal
  is spared, never propagated into a publish.

## When to edit

Posting-list query strategy, persist magic, freshness policy, codicil layering,
or the parallel sweep's work-balancing. Changing n-gram width or soundness
claims needs gate + doc updates together.

Build / inspect: `gist index` / `gist status`.
