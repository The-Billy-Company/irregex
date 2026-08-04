# testdata

## `python_oracle.json`

What the reference Python binding reports for a corpus of 94 pattern / flag /
text triples: the match spans, the group spans of each match, and the `is_match`
answer. `tests/oracle.rs` asserts this crate reports exactly the same thing.

Committed rather than generated at test time, so `cargo test` needs no Python.
Regenerate with `python3 ../scripts/python_oracle.py` after changing the corpus.

Every offset is a byte offset. A group the match did not enter is `[-1, -1]`,
which is what the C ABI itself reports, and is a different fact from a group that
matched empty at position `n` (`[n, n]`).

`engine_version` pins which engine build produced the answers.
`oracle::corpus_matches_the_linked_engine` fails with a clear message if the
linked library is a different one, so a stale corpus reads as a stale corpus
rather than as a hundred span mismatches.
