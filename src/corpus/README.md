# `src/corpus/` — shared source substrate

Which paths and bytes are eligible for search or indexing, and their persisted
pre-chewed forms. This tier knows **nothing** about matching, ranking,
transports, or CLI presentation — both engines and every surface transport
share it so walk policy cannot fork.

| Package | Owns |
| ------- | ---- |
| [`scope/`](scope) | Path eligibility: charter (`.irregex.toml`), ignore precedence, `filter.zig` (the PathFilter half of the old `glob.zig`) |
| [`read/`](read) | Byte legibility: encodings, inode identity — is this file readable text |
| [`tree/`](tree) | The walk itself, the corpus it materializes, and the stdout cadence (`drain.zig`) |
| [`fresh/`](fresh) | Freshness: build anchor, amend journal, sweep — what makes a days-old artifact still answer correctly |
| [`index/`](index) | Persisted artifacts (trigrams, postings, crest, atlas, frag, content, phantom, shelf) + the wire floor (`frame/`) |

## Why it exists

One walk skeleton (`tree/haystack.zig`) feeds the parallel search, the index
build, and the freshness stat-walk — each plugs a different per-file action.
The committed charter (`scope/charter.zig`) ensures every clone searches the
same corpus without per-machine folklore. Freshness was promoted out of the
trigram folder so every artifact shares one law.

## When to edit

Skip-directory policy, ignore helpers, bulkstat / portable stat parity,
`-g` / `-t` tables, charter keys, encodings, freshness, persisted formats.
rg-compatible ignore _dialect_ wiring for the cold face lives beside the cold
engine in `exec/cold/`.

Deep dives: [`tree/`](tree/README.md) · [`scope/`](scope/README.md) ·
[`index/`](index/README.md) · [`fresh/`](fresh/README.md) · [`read/`](read/README.md).
