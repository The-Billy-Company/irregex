# The C ABI

This folder is the whole engine as a hundred C symbols, and it is the only place
in the package where a promise is made to a linker.

`exports.zig` is the artifact's root, and it is deliberately *not* `src/root.zig`.
A Zig `export fn` is emitted by every compilation that reaches it, so shims living
in the library module would be duplicated into every face library that imports it,
and a host linking two of them would hit a duplicate symbol for a symbol it asked
for once.

Everything else here is one plane, and every plane answers one question.

## The Vocabulary

`contract.zig` owns layout and status, and no execution at all. It is the
substrate the other libraries in the ecosystem speak: every face links this one
and returns these status codes, this fault struct, these pattern flags.

`rows.zig` is its analytic sibling — the self-describing row a kinship or compose
producer hands back, walked by the `irgx_rows_*` cursor. `schema.gen.zig` is the
row-schema table lowered from `contract/analytic.toml`, handed to a host verbatim
so the two sides cannot disagree about what a field means.

`request.zig` is the request every search verb takes. One struct a host fills
rather than one verb per option, so the next mode is a bit instead of four more
names to bind.

`answer.zig` is a materialized answer and a host's position in it, because walking
rows is the same question no matter which producer made them.

## The Engine Over Bytes

`pattern.zig` is the plane a host reaches for when it has a pattern and a buffer:
compile once, then ask `is_match`, `find_all` or `captures`.

`slate.zig` answers about N patterns in one pass and keeps which pattern found
what. `needles.zig` does the same for a wordlist, because many literals in one
pass is not a regex question and should not have to be asked as one.

`munch.zig` is the anchored-longest-match plane — a lexer, where the two above
are searches.

`literals.zig` is what a pattern promises about the bytes it can match. The engine
already extracts this to build its own prefilter; publishing it lets a host build
one instead of asking this one to be fast enough.

`lines.zig` turns a byte offset into a line, which is the arithmetic every
grep-shaped host rebuilds and gets subtly wrong.

## The Engine Over A Corpus

`corpus.zig` is the warm corpus every producer is handed, plus the cancel handle
any thread may trip.

`walk.zig` decides which files a search may read, and in what order — gitignore
precedence across nested files, hidden entries, binary detection, symlink policy.

`sieve.zig` is how a search engine declines to open most of the corpus: the
trigram index and the crest sieve.

`tree.zig` is the verb this ABI was missing for as long as it existed. Opening a
warm corpus was possible and searching one was not.

`codex.zig` is the self-index — a byte string compressed into a structure that can
still be counted, located in, and read back without keeping the original.

## What Is Not Here

The session is the first absence, and it is deliberate: the resident pull cursor
and its run entry live in the exact-search face's own library, with its own header
and its own symbol prefix.

The second is every plane whose shape an executable chooses rather than a caller —
the ranking fusion, the rg-shaped output, the flag grammar, the machine-local
preferences file, and the math floor under all of them.

Which planes have a door here is declared per row in
[`contract/exports.toml`](../../../contract/exports.toml), so a gap is a decision
on the record rather than something nobody looked at. `quality/parity/check.py`
holds the header, that table, and all three bindings to each other, and
`zig build header` proves the published header still parses as C99 and as C++17.
