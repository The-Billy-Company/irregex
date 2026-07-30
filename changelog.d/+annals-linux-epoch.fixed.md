The resident answer keep now works on Linux, and it fails closed when watch
coverage is lost rather than when it is merely uncertain. The inotify backend
never armed the annals ledger — only `coverage.coverRoots` did, and only the
kqueue backend calls it — so `epoch()` returned null and the keep was silently
dead on every Linux daemon; inotify now arms the strip prefix, opens coverage
once its watches are registered, and notes exact FILE deliveries with the same
file/directory split `kqueue.note` applies. Separately, losing coverage
(`IN_Q_OVERFLOW`, a subtree that could not be re-watched) poisoned only the
seqlock: reconciling protected the query while the epoch stood still under a
moving tree, so an answer already held could read fresh indefinitely. Coverage
loss now blinds the ledger, which is the one state that makes `epoch()` decline
outright, and a deliberate idle shed lapses it so answers held before the
unwatched window retire instead of surviving the re-arm.
