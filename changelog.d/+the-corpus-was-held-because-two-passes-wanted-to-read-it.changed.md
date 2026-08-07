An index can now be built over a corpus nobody is holding.

Every consumer of a build — the trigram extractor, the crest sieve, the content
shard — was handed the whole `docs` slice after the walk finished, so the corpus
sat in anonymous memory from the first read to the last write. On llvm-project
that is 1926 of the build's 2464 MiB peak: not a leak, not slack, just the shape
insisting the corpus be resident because two passes wanted to read it.

The shape now has a second form. `corpus.census` runs the same walk under the
same membership rule and in the same doc order, keeping only each member's path
and stated size — 107 MiB for 175,110 documents, where holding them costs 1926.
`Census.recall` reads one of them back into a caller's buffer, allocating
nothing. `kiln.Source` is the seam that makes it useful: the block builder never
saw the corpus as one array to begin with, it saw a doc range and asked for one
doc at a time, so where those bytes come from is not a fact the index format can
observe. A worker holds one buffer sized to the largest doc in its own range,
and the footprint stops scaling with the input.

Two things ride along rather than pay a second read. `kiln.Witness` hands each
doc's bytes to a second consumer while the extractor has them, which is how the
crest sieve stops being its own pass, and how the build records what it
ACTUALLY read — the only honest input to a content shard's offset catalog, since
the catalog precedes the bodies and every reader trusts it without re-checking.
`shard.buildRecalled` builds from those lengths and declines the whole tier if a
body has since disagreed with one, because losing the shard costs a query its
fast path where a skewed catalog would cost it the right answer.

Reading a doc back is also parallel, which is most of what makes this viable.
Writing the shard is sequential — the bodies are a concatenation in doc order —
but reading them is not, and a doc at a time is 175k dependent opens on one
thread. A 64 MiB window is filled by every core and handed to the writer as one
region: the shard tier fell from 42.1 s to 6.7 s on llvm-project, and that one
change is the difference between streaming costing 2.2x wall and costing 1.7x.

MEASURED: llvm-project (175,110 docs, 1926.3 MiB), 128 GiB machine, warm page
cache, interleaved — peak RSS 2464 → 597 MiB, a 4.1x cut, for 8.2 → 13.8 s wall.
The wall is the honest cost and it is structural, not slack: a held build's
second pass over the corpus is a memcpy where a streamed build's is a file read.
On a 149.4 MiB tree (16,325 files) the same trade is 314 → 165 MiB peak with
wall inside the machine's own spread, because there the corpus never dominated
the reads. The census phase peaks at 107 MiB regardless.

PROVEN IDENTICAL, at llvm scale: `index.gist` (161,773,006 bytes), `crest.bin`
(8,405,376) and `paths.list` (9,107,770) compare byte-for-byte equal between a
held and a streamed build. `content.shard` (2,030,371,064) and `tree.map` agree
across every byte of catalog, path table, and body — they differ only in the
8-byte build anchor and the 32-byte seal that covers it, which is exactly what
differs between two runs of the SAME binary. The `kiln.Source` refactor was
proven inert on its own first, against a binary built minutes before it.

Held builds are untouched. `fire` is still `fireFrom(.{ .held = docs })`, still
degrades to the serial builder on an allocation failure, and still reaches the
same bytes. `buildStreamed` deliberately has no such fallback: a held build can
degrade because its caller already paid for the corpus in memory, and quietly
materializing it to recover would spend the exact peak the stream exists to
avoid.

The window this opens is real and worth naming. A streamed build reads a file
after the walk classified it, so a file edited or deleted in between is indexed
as it is at read time, or as empty if it is gone. That is not a new hazard — it
is the window the freshness anchor already exists to close. The anchor is
stamped before the walk, so any file whose clocks moved after it is folded in
live at query time regardless of which bytes the build saw. A held build narrows
the window; it has never closed it, because the corpus keeps changing while the
index is written either way.
