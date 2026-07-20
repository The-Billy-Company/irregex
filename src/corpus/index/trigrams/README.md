---
doc_radar:
  sentinels:
    - description: "trigram Index + freshness remain the T0/T3 surface"
      file: pkg/kernels/irregex/src/corpus/index/trigrams/trigram.zig
      contains: "pub const Index"
    - description: "freshness fails closed when the anchor is missing"
      file: pkg/kernels/irregex/src/corpus/index/trigrams/fresh.zig
      contains: "anchor"
---

# `src/index/trigrams/` — T0 candidate index + T3 freshness

Gist's structural edge over a whole-tree scan. A file containing a literal
must contain every trigram of that literal, so the AND of per-trigram
posting lists is a **sound candidate set**: false positives expected and
verified away; false negatives impossible for literals ≥ 3 bytes.

## Files

| File | Job |
| ---- | --- |
| `ngram.zig` | Extract distinct ascending trigrams from a byte slice |
| `trigram.zig` | In-memory `Index`: build, rarest-first intersect, query |
| `persist.zig` | Zero-copy `mmap` load / publish of the CSR posting blob |
| `fresh.zig` | Wall-clock mtime/ctime freshness overlay vs build anchor |

Codecs live in [`../postings/`](../postings). Crest sidecar (literal-free
class runs) lives in [`../crest/`](../crest).

## Invariants

- **Accelerator only** — indexed ≡ unindexed output
  (`bench/gates/index_elision_parity.sh`).
- Anchor stamped **before** corpus read; missing / unreadable timestamps →
  live-read; missing anchor seeds every doc fresh (fail closed).
- Equality at the anchor boundary is live (`mtime >= anchor` or
  `ctime >= anchor`). Model assumes a local FS whose ctime advances on
  ordinary writes — see [`../../corpus/tree/README.md`](../../corpus/tree/README.md).

## When to edit

Posting-list query strategy, persist magic, or freshness policy. Changing
n-gram width or soundness claims needs gate + doc updates together.

Build / inspect: `gist index` / `gist status`.
