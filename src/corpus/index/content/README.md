# `src/corpus/index/content/` — The Content Shard

`content.shard` is the persisted **corpus-content blob** behind this engine's
second walk floor. Once the phantom snapshot removed the directory-listing
syscalls, the residual cost on a full-scan query — a 2-byte literal like
`})`, a dense class count, a bare `-c`, anything with **no usable trigram
filter** — is the per-file `openat`+`read`+`close` over _every_ corpus file
(~20k opens on this repo).

That syscall wall is what leaves irregex behind a static memory-mapped server
index (zoekt) on exactly those classes.

## How It Removes The Floor

The shard removes it the same way zoekt does. An index build concatenates
every corpus body — the **same** membership `corpus.readMember` already
computed (non-binary, non-empty, ≤ `per_file_cap`) — into one contiguous
blob with a doc→offset catalog.

A later query serves each unchanged file's bytes from that **one mmap**
instead of opening it. 20k opens collapse to a single map plus page faults
the OS keeps warm across runs.

## Soundness Contract

The shard is a **read accelerator, never an authority** — the law every
artifact in this family obeys. A served slice is byte-identical to the
file's bytes only while the file is unchanged, so the shard returns a slice
exactly when the T3 rule proves it: `mtime < anchor AND ctime < anchor` (the
conservative `bulkstat.needsLiveRead`; equality stales).

A changed file — or one the shard never held (new since the build, binary,
over cap, outside the indexed roots) — misses the lookup and is read live,
so the walk's answer is the walk's answer whether or not a shard is loaded.

This is proven continuously by the `shard-*` / `shard-freshness` cases in
the sibling exact-search repo's
`bench/conformance/gates/parity/index_elision_parity.sh`, which diff the
shard-served run against `--no-index` (pure live walk).

## Build And Fail-Open Behavior

Built by an index build (whole-CWD indexed corpora only), self-anchored —
its own build instant rides in the `GISTSHD2` header, so the freshness gate
binds to the shard's _own_ anchor and a stale shard beside a fresh index (or
the reverse) only serves _fewer_ slices, never a wrong one.

Fail-open everywhere: a missing, corrupt, foreign, or future-dated blob
loads as null and every file is read live exactly as before.
`<prefix>NO_SHARD=1` and `--no-index` both disable it.

## Integrity Seal

The blob is sealed with a
[`signet`](../frame/signet.zig), checked only when someone calls
`View.verify`. Layout validation cannot see bit rot inside a body — flip a
content byte and every offset, length, and name still agrees — so the seal
is what stands between a served slice and bytes that are no longer the
file's.

Checking it at load would digest ~215 MB to save 20k `open` calls, which is
the saving this artifact exists to make, so it waits to be asked.
