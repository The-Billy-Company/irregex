Crest sieve: keep one forced crest per top-level alternative — a `crest.Swell` —
instead of collapsing the branches into a single componentwise-min vector. The
fold was sound but blind: two alternatives forcing disjoint classes min to `0⃗`,
and multi-`-e` reaches the engine as exactly that shape, so every multi-pattern
search ran with the sieve silently disarmed. A document is now pruned only when
it clears no alternative, which is weakly more selective than the fold on every
document and never less sound (PROOF.md §3.9, Theorem 4 + Corollary 4). On the
206 MiB Billy corpus `[0-9a-f]{12}|~{60}` goes from 0.0% to 84.4% of files
pruned and `[0-9]{6}|[A-Z]{6}` from 0.5% to 38.5%; `gist -e '[0-9a-f]{12}' -e
'[~]{60}' -l` runs 2× faster end-to-end for a byte-identical answer, and every
single-alternative query is bit-for-bit unchanged. The split walks the branch
spine iteratively and holds 8 alternatives inline, so a longer chain degrades
back toward the fold rather than allocating or recursing; one branch demanding
nothing disarms the whole swell. `zig build crest` now carries the fold as a
measured ablation column and fails closed if the disjunction ever leaves more
survivors than it.
