A resident daemon started from a content-addressed build artifact no longer
strands the warm tier. Retirement on build skew used to rest entirely on a
daemon noticing its own executable had been rewritten, which a cache-path
binary can never observe — the path embeds a hash of its own bytes, so they
never change. Such a daemon held the socket for the rest of the day: every
rebuilt client detected the skew, declined, and ran cold, and the idle TTL
wants ten *continuous* quiet minutes that a tree ~10 coworker agents query
never gets. Measured on one machine: 10 orphaned daemons resident at once, and
every eligible query paying the full corpus walk — 60-160 ms where the daemon
beside it answers in 0-20 ms.

Build skew now settles with a tiebreak over the two stamps (`image.hosts`).
It claims no recency — a stamp is still an identity and not an order — only
that both peers compute the same winner from the same pair, so exactly one
build hosts the rendezvous and two live builds can never take turns evicting
each other. The loser stays cold exactly as it did before, so the worst case is
the previous behavior, while a fresh install against a stale orphan gets the
socket back after a single cold query.
