# `warm/` — What Is Held Across Queries

The resident engine plus the byte stores it answers from.

Nothing here decides what an answer looks like — that is
[`../facet/`](../facet) — and nothing here proves the held state still
matches disk — that is [`../reconcile/`](../reconcile).

## Modules

- **[`resident.zig`](resident.zig)** is `ResidentSession`, the exact-search
  face's warm state: the mirror plus trigram index, the mutation overlay, the
  freshness seqlock and dirty log, and `beginRead`, the read lease every
  answer passes through.
- **[`mirror.zig`](mirror.zig)** is the in-RAM corpus mirror. An unchanged
  member binds to the persisted `content.shard` mmap; a changed, new,
  binary, or oversize doc heap-reads with cold's own per-file treatment. It
  also holds each doc's crest vector ρ(d) — what the sieve prunes a
  candidate by with a handful of integer compares and no byte scan — built
  by the persisted `crest.bin` sidecar's own builder over the mirror's own
  bytes, so a resident vector and the on-disk one for the same bytes cannot
  disagree and the vectors need no freshness gate.
- **[`overlay.zig`](overlay.zig)** is the mutation store: live edits become
  answerable substitutions without rebuilding the base mirror.
- **[`truth.zig`](truth.zig)** is an independent filesystem oracle for
  adversarial tests. It never runs the engine.

Suites: `resident_test.zig` and `scoped_test.zig` sit beside their subjects.

The sibling kinship package holds the retrieval engine's own warm session —
`RetrievalSession` never held file contents here, and it left with the rest
of the kinship engine when the packages split.

## Naming

This was `warm/corpus.zig` and `warm/recall.zig`. It was renamed so the file
says what it is (`mirror`) and so *recall* stays free for
`kernel/kinship/recall/`.
