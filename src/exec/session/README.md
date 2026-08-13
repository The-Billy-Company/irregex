# `src/exec/session/` — The Resident Search Session

The warm, in-memory engine behind the resident daemon. It productizes the
in-memory bench path as a real per-repository service: corpus bytes and
trigram index held resident so an eligible request skips the cold
subprocess's startup.

The session selects its corpus with cold's own certified walk
(`exec/cold/engine/serial.zig::defaultFileSet`), ingests each file exactly as
a cold read would, and lowers each query through the shared search core — but
every entry point **returns errors** instead of calling `die()`.

The daemon transport and the in-process C-ABI session shims live in the
sibling face package, not here — this folder is the shared engine-side
runtime both that daemon and the kinship package's `RetrievalSession` are
built on. What lives here is the fd-passed shared-memory buffer
([`conduit/`](conduit)) a large answer rides back through, and the barrier +
watcher machinery ([`reconcile/`](reconcile), [`watch/`](watch)) both warm
engines share.

## The Six Planes

- **[`answer/`](answer)** answers what may be asked warm, and what comes
  back.
- **[`warm/`](warm)** holds what is held **across** queries — the resident
  and retrieval engines, the mirror, the overlay.
- **[`facet/`](facet)** is the four faces one answer can wear: set, count,
  bytes, stream.
- **[`reconcile/`](reconcile)** decides whether the session may serve the
  bytes it already holds.
- **[`watch/`](watch)** decides whether that barrier can skip the walk, and
  how narrowly.
- **[`conduit/`](conduit)** carries a large answer's bytes back to the client
  without a socket copy.

The sibling face package owns the two pieces that ride on top of this: its
own `src/exec/session/daemon/` (dial + serve loop, the transport both faces
share) and `src/exec/session/warden/` (how much memory a resident session may
hold, enforced where it allocates).

## The Invariant

`resident matches == cold no-index matches == rg matches`. It holds because
both the base corpus and every reconcile re-derive their file set from cold's
own certified walk, and because per-file ingest is cold's own
(`warm/mirror.zig`).

A query is answered from resident bytes only in a watcher-proven-clean
window; otherwise the session reconciles first — **scoped** via
`reconcile/delta.zig` when it can prove the dirty set covers every
divergence, else **full**. Any doubt declines with `freshness_unprovable`
and the client uses the certified cold path.

`rg` appears in that invariant as the **output** oracle, and it is the right
one for what matches come back. It is the wrong one for why this package
exists: ripgrep holds nothing between runs, so it has no residency to get
wrong.

The architectural comparator is **zoekt**, the one rival that is also a warm
resident server holding corpus content in memory-mapped shards — and holding
content resident is precisely why zoekt can answer from bytes the tree no
longer has. Measured on a corpus mutated after indexing, it returns a match
that was deleted while missing two that were added
(`corpus/fresh/README.md` § What this package buys).

That is the whole reason `reconcile/` and `watch/` are planes here rather
than an optimization: this session is meant to be zoekt's residency without
zoekt's staleness, which costs a proof-of-clean barrier in front of every
warm answer and a decline whenever the proof won't close. csearch is not a
comparator at all on this axis; it is one-shot and holds nothing across
queries.

Deep dives live in each plane's own README.
