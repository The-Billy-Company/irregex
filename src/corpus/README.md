# `src/corpus/` — shared source substrate

This tier decides which paths and bytes are eligible for search or indexing, and it owns their persisted, pre-chewed forms.

It knows nothing about matching, ranking, transports, or CLI presentation. Both engines and every surface transport share it, so walk policy cannot fork between them.

## Packages, By What They Own

- **[`scope/`](scope/README.md)** owns path eligibility: the committed `.irregex.toml` charter, ignore precedence, and `filter.zig` — the PathFilter half of the old `glob.zig`.
- **[`read/`](read/README.md)** owns byte legibility: encoding decode, the portable stat projection, and the line-splitting model every matcher reads through.
- **[`tree/`](tree/README.md)** owns the walk itself, the corpus it materializes, and the stdout cadence (`drain.zig`).
- **[`fresh/`](fresh/README.md)** owns freshness: the build anchor, the amend journal, and the sweep — what makes a days-old artifact still answer correctly.
- **[`index/`](index/README.md)** owns the persisted artifacts (trigrams, postings, crest, content, phantom, shelf) and the wire floor beneath them (`frame/`). The kinship artifacts (atlas, frag) are built on that floor but live in the sibling `relate` repo.

## Why It Exists

One walk skeleton, `tree/haystack.zig`, feeds the parallel search, the index build, and the freshness stat-walk, with a different per-file action plugged into each.

The committed charter (`scope/charter.zig`) is what makes every clone search the same corpus without per-machine folklore. Freshness was promoted out of the trigram folder so every persisted artifact shares one law instead of each inventing its own clock.

## When To Edit

Come here for skip-directory policy, ignore helpers, bulkstat / portable-stat parity, the `-g` / `-t` type tables, charter keys, encodings, freshness, and persisted formats.

rg-compatible ignore *dialect* wiring for the cold face lives beside the cold engine in `exec/cold/`, not here.

Deep dives: [`tree/`](tree/README.md), [`scope/`](scope/README.md), [`index/`](index/README.md), [`fresh/`](fresh/README.md), and [`read/`](read/README.md).
