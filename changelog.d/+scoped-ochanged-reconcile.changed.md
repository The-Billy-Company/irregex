The resident session's freshness proof is now O(changed) instead of O(tree)
whenever it can be proven sound. macOS FSEvents runs with per-file events and
feeds an exact dirty-path log (`src/session/dirty.zig`: bounded, deduped,
overflow/OOM ⇒ sticky doubt); the reconcile drains it and — when the backend
promised exactness, the batch is doubt-free, one covering full pass already
ran, and no ignore-semantics path (`.gitignore`/`.ignore`/`.rgignore`, `.git`
topology) is in the batch — verifies exactly those paths through the cold
walk's own `Ignore` admission rules (`src/session/delta.zig`: canonical
realpath mapping, ASCII case-alias tombstoning, subtree enumeration for
coalesced directory events) instead of re-walking the tree. Every refusal
degrades to the full walk, never to trusting stale bytes; `.git` internal
churn (index/objects/refs) now costs a hash probe instead of a full reconcile.
Rootless daemons previously armed an FSEvents stream over an empty path array
and silently watched nothing (reconcile-always); they now watch `.`. Linux
inotify stays coarse (never arms exactness) and now poisons the session
permanently on queue overflow or an unwatchable newly-created directory
instead of racing a staleness hole. Measured on this 150k-file repo: an
edit-then-query warm cycle drops from ~290 ms (full covering walk per dirty
query) to ~6.6 ms (scoped drain), ~44× on the O(changed) path, with warm-clean
latency and the cold/unindexed paths unchanged. Adversarial suite
(`src/session/scoped_test.zig`) asserts scoped answers against an independent
on-disk oracle and proves the fail-closed degradations (ignore-source edit,
doubted/overflowed batch, non-exact backend, poisoned watcher, racing writes).
