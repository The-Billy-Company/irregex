The artifact home resolved against the working directory: `.gist` wherever you
happened to be when you typed the command. That satisfies the one invariant
anybody had written down - two checkouts cannot collide, which is all
`socketBindingPath` ever needed - and quietly breaks the one nobody had. A
search from `services/ai` and a search from the tree root are the same corpus,
and they were building two indexes, running two daemons, and each paying a cold
walk the other had already paid for. Nothing reported this, because both answers
are correct; you just never got the warm one.

The sharper edge was the socket. `gistd.sock` landed in whatever source
directory was current, and a file watcher that cannot watch a unix socket -
chokidar's `fs.watch` throws EUNKNOWN out of a `process.nextTick`, which is not
catchable from where you'd want to catch it - takes a dev server down with it
mid-session. The workaround everyone reached for was pinning `GIST_DIR` to one
absolute path, which fixes the socket by making every checkout on the machine
share one home, so every repo but the pinned one goes permanently cold. Trading
a crash for a silent deoptimization is not a fix.

The home belongs to the TREE now. `home.seek` climbs from the working directory
and takes the first of: an artifact directory already sitting there - a
placement is a decision, and adopting it is how a nested workspace opts out -
then a checkout boundary, where a `.git` FILE counts exactly like a `.git`
directory because a worktree is still a checkout. Finding neither inside the
climb ceiling it stays where it stood, which is the right answer for a tree that
is no checkout at all. `GIST_DIR` still wins outright, so a pinned setup is
unaffected until it stops pinning.

`seek` takes a directory handle rather than reading the process's cwd, so it is
a question you can ask about a directory instead of about the program - which is
what let the suite prove the property that matters by comparing where two
answers LAND (`realpath` through real directories) instead of comparing two
strings, which would only restate the arithmetic the answer already did. The
charter walk one tier up was doing the same climb with its own copy of the
prefix builder and the boundary probe; it now shares this one, so a charter and
the `.gist` beside it can no longer disagree about which checkout they are in.
