---
doc_radar:
  counts:
    - description: "index artifact packages (trigrams · postings · crest · atlas · frag · content · phantom · shelf · frame); a transitional empty codex/ shell may still be present"
      glob: pkg/kernels/irregex/src/corpus/index/*
      unit: dirs
      min: 9
      max: 10
  sentinels:
    - description: "the elision contract every index package is built on"
      file: pkg/kernels/irregex/src/exec/cold/engine/README.md
      contains: "Index is an accelerator, not an authority."
    - description: "every mapped artifact loads through the one shared protocol"
      file: pkg/kernels/irregex/src/corpus/index/frame/frame.zig
      contains: ["pub fn mapArtifact"]
---

# `src/corpus/index/` — persisted accelerators

Persisted structures that may **elide reads, never own truth**. The live walk
decides which files exist; indexes only prove that some cannot match (or answer
count/find/restore / kinship without a full scan). `--no-index`, a missing
anchor, or a corrupt artifact always degrades to slower-but-identical answers.

FM-index _math_ lives in [`../../kernel/codex/`](../../kernel/codex/README.md);
the on-disk shelf is [`shelf/`](shelf/README.md). Freshness lives in
[`../fresh/`](../fresh/README.md), not under trigrams. The wire floor
([`frame/`](frame/README.md)) sits architecturally above `fault`, even though
it lives here on disk.

## Indexes, by what they eliminate

| Package | Eliminates | Job |
| ------- | ---------- | --- |
| [`trigrams/`](trigrams) | files that cannot match | T0 trigram candidate index (+ sliver for 1–2 byte needles) + codicil amend |
| [`crest/`](crest) | files a literal-free pattern can't match | Per-doc forced-class-run vectors |
| [`phantom/`](phantom) | directory listing syscalls | `tree.map` membership snapshot |
| [`content/`](content) | per-file open/read/close | `content.shard` mmap of unchanged bodies |
| [`shelf/`](shelf) | the corpus itself (for count/find/restore) | Persisted SHLF over the kernel codex |
| [`atlas/`](atlas) | re-sketching every file | Warm LZJD sketches for `relate similar` / `echoes` |
| [`frag/`](frag) | re-sketching every function | Per-function silhouettes for `--unit function` |

## Substrate packages

| Package | Job |
| ------- | --- |
| [`frame/`](frame) | Wire floor: framing, signet, artifact home, `mapArtifact` |
| [`postings/`](postings) | LEB128 + CSR blob codecs the trigram bodies ride |

## The one law

> Index is an accelerator, not an authority.

`bench/gates/index_elision_parity.sh` asserts indexed ≡ unindexed byte-exact
line multisets and exit codes.
