# `src/corpus/index/` — Persisted Accelerators

Persisted structures that may **elide reads, never own truth**. The live walk
decides which files exist; indexes only prove that some cannot match (or
answer count/find/restore / kinship without a full scan). `--no-index`, a
missing anchor, or a corrupt artifact always degrades to slower-but-identical
answers.

FM-index _math_ lives in [`../../kernel/codex/`](../../kernel/codex/); the
on-disk shelf is [`shelf/`](shelf/). Freshness lives in
[`../fresh/`](../fresh/README.md), not under trigrams. The wire floor
([`frame/`](frame/README.md)) sits architecturally above `fault`, even though
it lives here on disk. Kinship artifacts (atlas / frag) live in the sibling
`relate` repo.

## Indexes, By What They Eliminate

- **[`trigrams/`](trigrams)** eliminates files that cannot match: a T0
  trigram candidate index, plus a sliver tier for 1–2 byte needles and a
  codicil amend layer.
- **[`crest/`](crest)** eliminates files a literal-free pattern can't match:
  per-doc forced-class-run vectors.
- **[`phantom/`](phantom)** eliminates directory-listing syscalls: a
  `tree.map` membership snapshot.
- **[`content/`](content)** eliminates per-file open/read/close: a
  `content.shard` mmap of unchanged bodies.
- **[`shelf/`](shelf)** eliminates the corpus itself, for count/find/restore:
  a persisted SHLF over the kernel codex.
- **`relate/src/corpus/index/atlas/`** eliminates re-sketching every file:
  warm LZJD sketches for `relate similar` / `echoes`.
- **`relate/src/corpus/index/frag/`** eliminates re-sketching every function:
  per-function silhouettes for `--unit function`.

## Substrate Packages

- **[`frame/`](frame)** is the wire floor: framing, signet, artifact home,
  `mapArtifact`.
- **[`postings/`](postings)** carries the LEB128 + CSR blob codecs the
  trigram bodies ride.

## The One Law

Index is an accelerator, not an authority. Every persisted artifact in this
family must degrade to the same answer a live, unindexed walk would produce —
never a different one, only a slower one.

The sibling `gist` repo's
`bench/conformance/gates/parity/index_elision_parity.sh` asserts indexed ≡
unindexed byte-exact line multisets and exit codes.
