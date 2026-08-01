Scrubbed the references to the private monorepo this package was extracted
from. Test fixtures searched for a `WalletService` type in `wallet.go`, ranked
a path under a vendored-tools subtree, wrote charters declaring `graphify-out`,
and asserted against a build-graph source that only existed there; skip lists
hardcoded `graphify-out` outright. None of those resolve to anything a reader
outside that repo can look at, which makes a fixture read as a leak rather than
an example. The ranking signals do not care what the identifier is called, so
they are now `SessionStore`, `tools/indexer/uses.py`, `lib/build/graph.zig`,
and `derived-out` - same shape, same assertions, nothing to look up.

Doc comments citing real measurements kept the numbers and dropped the tree.
"A ranked `graphify` silently dropped 470 real hits" was a true and useful
sentence about a vendored subtree the index prunes and a search walk does not;
it is now stated as that shape, because 470 is the part you can learn from.
Changelog entries cited internal decision-record numbers - `ADR-352`,
`ADR-363`, `ADR-367` and friends - which are unresolvable here, so the
parenthetical is gone where the sentence stood without it and replaced with
what the decision actually said where it did not.

Two categories deliberately survive. The benchmark suite still resolves its
corpus to that checkout and picks patterns against it, so `WalletService` in
`bench/` is a high-match race pattern, not a fixture; renaming it would turn a
saturating query into a zero-match one and quietly invalidate the measurement.
Minted artifacts under `bench/**/artifact/` state which corpus was measured,
and rewriting a record to be more presentable is just falsifying it. A public
corpus for the benches is a separate job.
