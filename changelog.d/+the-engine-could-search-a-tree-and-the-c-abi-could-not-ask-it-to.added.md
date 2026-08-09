The C ABI went from 38 symbols to 100, and five planes that only ever existed in Zig
got a door: `tree` (search a corpus, not a buffer you already hold), `walk` (which
files a search is even allowed to read), `sieve` (narrowing, so most of the corpus is
never opened), `codex` (the FM-index - count, locate and restore a text it does not
store), and the `lines` / `literals` / `needles` trio.

None of this is new capability. Every one of these engines was finished, tested and
driven daily by the sibling binaries; the gap was that `libirgx` published a regex
matcher and called itself a search toolkit. A C host could compile a pattern and run
it over a buffer it had already read - which is the one part of a search engine that
is not the hard part. It could not ask which files to read, could not skip the ones
that cannot match, and could not search a tree at all. `gist` could, because `gist`
minted its own cursor shim in its own repo. That shim is now here, where it belongs.

Freezing the surface turned up one real hole rather than just plumbing. `tree`'s own
header comment promised `irgx_matches_count` and `irgx_matches_close`, and neither
function existed - so a C host had no release path and leaked the cursor, its arena,
and every path and line byte the records had borrowed, on every search. Both are
written now, and `count` is the total the answer HOLDS rather than the remainder
still unread, which is the distinction the batch verb's `*written` deliberately
cannot make.

Two verbs read `_describe` instead of `_facts` (`irgx_sieve_describe`,
`irgx_winnow_describe`), because in C a typedef shares a namespace with a function
and the out-param structs own those nouns; the verb matches `irgx_needles_describe`,
which was already there. `irgx_walk_count` returns `size_t` bare instead of a status
plus an out param, like every other infallible read of already-materialized state.

The header and the export table now agree exactly, in both directions, and the parity
gate is what says so rather than a reviewer. It parses clean as C99 and as C++17.
