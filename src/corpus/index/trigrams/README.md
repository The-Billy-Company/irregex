# `src/corpus/index/trigrams/` — T0 Candidate Index

This tier is the structural edge over a whole-tree scan. A file containing a
literal must contain every trigram of that literal, so the AND of per-trigram
posting lists is a **sound candidate set**: false positives expected and
verified away, false negatives impossible for literals of 3 or more bytes.

A **shorter** needle is served by the same directory rather than by a full
scan. A 1–2 byte sliver must sit inside one of its document's trigrams, so the
UNION of the trigram families that could contain it is also a sound candidate
set. See [`sliver.zig`](sliver.zig) for the argument, the short-document
rescue set the soundness rests on, and the decode budget that declines a
filter which would not filter.

## Files

- **`ngram.zig`** extracts distinct ascending trigrams from a byte slice.
- **`trigram.zig`** is the in-memory `Index`: build, rarest-first intersect,
  query.
- **`kiln.zig`** is the build for a corpus worth streaming: a bounded block
  window sorts compressed runs, then one lockstep sweep merges them into the
  CSR body without ever holding a corpus-sized array.
- **`kiln_test.zig`** checks the block builder's four regions against an
  oracle written from the on-disk format, on corpora sized to force
  multi-block merging.
- **`sliver.zig`** is the sub-trigram tier: it answers a 1–2 byte needle from
  the SAME directory (0 new index bytes), priced against a decode budget
  before it commits.
- **`sliver_test.zig`** checks the Sliver Theorem (matched ⇒ never pruned)
  against a byte-for-byte oracle, and attacks the short-document premise on
  its own.
- **`persist.zig`** does zero-copy `mmap` load / publish of the CSR posting
  blob, and layers codicil queries (`queryLiteral` / `queryAny` = base ∪
  codicil ∪ tombstones) on top.
- **`codicil.zig`** is the incremental amendment to a published generation:
  it re-indexes only changed files as an LSM-style delta segment, fused with
  the T3 freshness walk.
- **`lapse.zig`** owns retention: it retires the generations a publish
  superseded, fenced against builds in flight (published id, newer ids, a
  grace window, a survivor window).
- **`codicil_test.zig`** runs the adversarial codicil round-trip and layered
  query suite.
- **`lapse_test.zig`** asserts each retention fence alone, plus batch
  bounding.
- **`ngram_test.zig`** checks trigram extraction parity and edge cases.
- **`trigram_test.zig`** checks index candidate-set correctness against a
  naive scan oracle.
- **`persist_test.zig`** checks blob round-trip, corruption refusal, and
  generation-atomic publish parity.
- **`trigram_fuzz.zig`** is the fuzz harness for trigram extraction.
- **`trigram_load_test.zig`** runs end-to-end load-time validation of
  persisted blobs.

Codecs live in [`../postings/`](../postings). The crest sidecar (literal-free
class runs) lives in [`../crest/`](../crest). The T3 freshness walk this
package's codicil amend rides on lives in [`../../fresh/`](../../fresh/) —
`fresh.zig` and `sweep.zig` moved there because every persisted accelerator
in the family folds through the same freshness law, not just this one.

## Invariants

- **Accelerator only** — indexed ≡ unindexed output, proven by the sibling
  exact-search repo's
  `bench/conformance/gates/parity/index_elision_parity.sh`.
- The anchor is stamped **before** the corpus read; missing or unreadable
  timestamps force a live read, and a missing anchor seeds every doc fresh
  (fail closed).
- Equality at the anchor boundary is live (`mtime >= anchor` or
  `ctime >= anchor`). The model assumes a local filesystem whose ctime
  advances on ordinary writes — see [`../../fresh/README.md`](../../fresh/README.md).
- Codicil postings for a dirty doc are false-positive only, since the query
  layer unions and never subtracts; false-negative holes are closed by
  construction.
- Generations are **self-contained**: a codicil publish hardlinks its base
  blobs forward rather than referencing them, so no generation is reachable
  from another and retiring a superseded one cannot make the live pair
  incomplete. Retention is a disk-space tier, never correctness — every fence
  it applies is about not disturbing a _concurrent_ build, and a failed
  removal is spared, never propagated into a publish.

## When To Edit

Edit here for posting-list query strategy, persist magic, freshness policy
as it applies to the codicil, or the parallel build sweep's work-balancing.
Changing n-gram width or soundness claims needs gate and doc updates
together.

Build and inspect with a face's `index` / `status` verbs.
