---
doc_radar:
  sentinels:
    - description: "the shard is a read accelerator gated on the same T3 clock rule the elide overlay uses, behind its own magic"
      file: src/corpus/index/content/shard.zig
      contains:
        - "needsLiveRead"
        - "GISTSHD2"
        - "pub fn verify"
---

# `corpus/index/content/` — the content shard

`content.shard` is the persisted **corpus-content blob** behind gist's
second walk floor. Once the phantom snapshot removed the directory-listing
syscalls, the residual cost on a full-scan query — a 2-byte literal like `})`,
a dense class count, a bare `-c`, anything with **no usable trigram filter** —
is the per-file `openat`+`read`+`close` over _every_ corpus file (~20k opens on
this repo). That syscall wall is what leaves gist behind a static memory-mapped
server index (zoekt) on exactly those classes.

The shard removes it the same way zoekt does. `gist index` concatenates every
corpus body — the **same** membership `corpus.readMember` already computed
(non-binary, non-empty, ≤ `per_file_cap`) — into one contiguous blob with a
doc→offset catalog, and a later query serves each unchanged file's bytes from
that **one mmap** instead of opening it. 20k opens collapse to a single map plus
page faults the OS keeps warm across runs.

Soundness — a **read accelerator, never an authority** (the law every gist
artifact obeys). A served slice is byte-identical to the file's bytes only while
the file is unchanged, so the shard returns a slice exactly when the T3 rule
proves it: `mtime < anchor AND ctime < anchor` (the conservative
`bulkstat.needsLiveRead`; equality stales). A changed file — or one the shard
never held (new since the build, binary, over cap, outside the indexed roots) —
misses the lookup and is read live, so the walk's answer is the walk's answer
whether or not a shard is loaded. This is proven continuously by the
`shard-*` / `shard-freshness` cases in `bench/gates/index_elision_parity.sh`,
which diff the shard-served run against `--no-index` (pure live walk).

Build: `gist index` (whole-CWD indexed corpora only), self-anchored — its own
build instant rides in the `GISTSHD2` header, so the freshness gate binds to the
shard's _own_ anchor and a stale shard beside a fresh index (or the reverse)
only serves _fewer_ slices, never a wrong one. Fail-open everywhere: a missing,
corrupt, foreign, or future-dated blob loads as null and every file is read live
exactly as before. `GIST_NO_SHARD=1` and `--no-index` both disable it.

The blob is sealed with a
[`signet`](../../../corpus/index/frame/signet.zig), checked only when someone
calls `View.verify`. Layout validation cannot see bit rot inside a body — flip a
content byte and every offset, length, and name still agrees — so the seal is
what stands between a served slice and bytes that are no longer the file's.
Checking it at load would digest ~215 MB to save 20k `open` calls, which is the
saving this artifact exists to make, so it waits to be asked.
