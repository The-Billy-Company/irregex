An event the macOS kqueue backend could not attribute to a watch — an
`EV_ERROR`, or a `udata` indexing no live slot — raised doubt in the dirty log
alone, leaving the annals ledger vouching a change epoch it had never counted
that event into. A reconcile's full walk protects the QUERY, which re-derives
its answer from the tree; an answer already HELD is trusted purely on the epoch
standing still, so the resident keep could serve a stale answer across such an
event and a one-shot `gist index` amend could read a path set missing the file
behind it. Both backends now route an unplaceable delivery through one shared
`Watcher.noteUnattributable`, which loses the WHICH permanently (no walk exists
in the ledger to re-derive a lost path) and still counts the WHETHER, so a held
answer retires. `vouch_test.zig` grades it through the keep on whichever exact
backend the platform ships.
