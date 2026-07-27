Sub-trigram substring tier — a 1- or 2-byte needle is now answered from the
trigram directory that already exists instead of forcing a full corpus scan, and
it adds **zero bytes to the index**: a sliver must sit inside one of its
document's trigrams, so the union of the trigram families that could contain it
over-approximates the answer. Documents too short to own a trigram are carried
in a rescue set proved from the crest sidecar, so under-pruning stays the only
possible failure mode.

The two classes the certificate recorded at cand% = 100% — the whole corpus
admitted — now prune: `})` falls to 49.18% and `panic|0x` to 37.42% of corpus
bytes delivered to verify. The alternation cover in `requiredAny` no longer
withholds itself when a branch is sub-trigram, which is what sent `panic|0x` to a
full scan. Measured by `zig build scale` and certified fail-closed as Layer J.
