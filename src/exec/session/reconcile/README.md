# `reconcile/` — May the Session Serve the Bytes It Already Holds

The fail-closed barrier that earns a warm answer. It was renamed from
`freshness/` so the barrier is the identity, and so it never puns with
[`corpus/fresh/`](../../../corpus/fresh/), the artifact-clock law.

Everything here exists so `resident matches == gist --no-index matches == rg
matches` holds by construction. The watcher that makes the answer cheap is a
separate, optional accelerator ([`../watch/`](../watch)); the correctness
lives here.

## Modules

- **[`reconcile.zig`](reconcile.zig)** is the session's **only** writer: the
  generation reload, the scoped O(changed) pass, the full re-walk on
  refusal, and `guardExtras` for queries that reach past the mirror.
- **[`seqlock.zig`](seqlock.zig)** is the freshness seqlock both warm engines
  share — a lock-free clean/dirty bit.
- **[`dirty.zig`](dirty.zig)** is the exact dirty-path log, carrying the
  `exact` / `doubt` soundness bits a scoped pass reads before it trusts a
  drain.
- **[`delta.zig`](delta.zig)** is the O(changed) resolver, re-verifying each
  drained path through cold's own `Ignore` machinery.
- **[`annals.zig`](annals.zig)** is the changed-path ledger a one-shot `gist
  index amend` reads through the daemon: it never drains, so "which files
  changed since instant S?" answers from one warm map lookup instead of a
  fresh stat walk. It also carries the corpus's monotone change `epoch`, the
  cheap WHETHER-anything-moved reading the answer keep compares against.

Suites: `reconcile_test.zig` (barrier vs on-disk oracle) and
`vouch_test.zig` (real watcher backends — kqueue, inotify).

## Fail-Closed Is the Design

A rebuilt index, a reconcile allocation failure, or a walk error declines
with `freshness_unprovable`, and the client falls back to the certified cold
path.

Every scoped-path refusal degrades to the full walk, never to trusting stale
bytes.

## Concurrency Shape

Reads overlap under a shared `Ward` lease (`kernel/math/lease.zig`) while a
reconcile runs alone under the exclusive lease.

`dirty.zig` and `annals.zig` guard their sets with `Latch` from the same
file.
