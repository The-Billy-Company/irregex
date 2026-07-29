Crest sieve: make `\d`, `\w`, and `\s` prune at the engine's default flags. The
linear engine folds them over Unicode scalars, and the sieve measures bytes, so
under Theorem 2 a `uclass` node certified nothing — the sieve stood entirely
down for the ordinary spelling of the exact query family it exists for.
`[0-9]{6}` pruned 92.7% of the corpus while `\d{6}` pruned 0.0% and ran at
1.00x. The repair gives every class a scalar-closed twin, `C+u = C ∪
[0x80,0xFF]`: every byte of a multi-byte UTF-8 sequence has bit 7 set, so a
codepoint class whose ASCII members lie in `C` spends only bytes in `C+u`, and a
run of n such codepoints is a run of at least n such bytes (PROOF.md §3.7,
Lemma 2b). A `uclass` is now priced by the same `atom(set, min_len)` as a byte
class, reading its encoding byte set and its cheapest UTF-8 length off the
engine's own AST — no `unicode` flag reaches the calculus. Measured by ablation
on the 21 854-file corpus: `\d{6}` 0.0% → 73.7% pruned and 1.00x → 2.12x,
`\d{4}` 0.0% → 52.8% and 2.13x, `\s{4}` 5.5%, `\w{8}` 1.4% — the wide classes
stay nearly worthless, which is the honest price of a class that excludes almost
nothing. The eight ASCII lanes keep their indices and their numbers, so nothing
that certified before certifies differently; the family simply grew a second
half only a `uclass` reaches. The sidecar is 32 bytes per document instead of 16
and its schema signet changes, so an existing crest table is rebuilt rather than
misread. Byte parity of search output was checked over 32 query shapes against
the same binary with the sieve disabled, on a frozen corpus, with the output
budget lifted: identical result multisets on every one.
