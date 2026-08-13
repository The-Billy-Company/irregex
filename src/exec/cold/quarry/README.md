# exec/cold/quarry — What Is in the Tree, and What Must Be Read

The walk decides which files a query is about. This package decides which
of those files must actually be opened — and nothing else. Keeping the
second question out of both engines is what stops "may we skip these
bytes?" from being answered twice, differently, in two schedulers (the
cold-engine deep-module split).

- **`walk.zig`** answers what is in the tree, before a byte is read — the
  recursive descent and the certified file set both engines answer
  against.
- **`elide.zig`** is the read-elision oracle: the persisted trigram index
  plus the crest sieve, gated on a freshness proof, answering "can this
  file possibly match?"
- **`intake.zig`** turns walked candidates into readable bytes, reading
  only what the question needs.
- **`order.zig`** holds the canonical file order — ripgrep's `--sort`/
  `--sortr`, exactly.
- **`stream.zig`** admits stdin as a haystack: admitting and draining fd 0.
- **`notice.zig`** decides how a failed descent reads on stderr — the
  unopenable path, the `-L` loop, the walk that admitted nothing.
- **`witness.zig`** answers the one question the searched bytes cannot:
  after an empty scoped run, does the string live in a file this scope
  excluded? It reads the same persisted index `elide.zig` prunes with,
  then confirms candidates against their current bytes, so the hint
  channel can name a file instead of saying "try a wider scope" —
  [Naming the File Instead of Waving at the Tree](#naming-the-file-instead-of-waving-at-the-tree).

Each of these has consumers in more than one package, and a shared concept
living inside one of its consumers is how the duplicate oracle was born the
first time.

Two freshness proofs still coexist here: `elide.Oracle`, which the parallel
walk consults per file from the bulk listing's own timestamps, and
`intake.zig`'s `IndexSkip`, which the serial read plane builds over the
same indexed-path primitive. Folding the second into the first is stage 2
of the cold-engine deep-module split — and having them side by side in one
package, rather than one per engine, is the point of this package existing
before that fold happens.

## Naming the File Instead of Waving at the Tree

A scoped search that finds nothing has two very different causes, and the
old stderr line could not tell them apart: the string does not exist, or
the caller pointed at the wrong file. `witness.sight` separates them.

It belongs here rather than in the hint renderer because it is the same
index question this package already owns — and it is the *inverse* of
elision. `elide.zig` uses the index to decide which files need not be
read; `witness.zig` uses it to decide which files are worth reading even
though the query never asked for them. Same postings, opposite direction,
which is why the renderer stays a pure function of an `Evidence` value and
never learns that an index exists.

The index alone may not answer, on the same soundness law as above: a
trigram hit is a *candidate*, so a hint derived from postings would name
files that no longer hold the bytes. Every candidate is therefore read and
re-matched before it is named, and the budget is what keeps that honest —
a handful of confirming reads, each capped, candidates ordered by how much
directory prefix they share with the scope the caller gave, so the first
read is usually the file they meant. Running out of budget yields no hint
rather than an unconfirmed one.

Absence stays unclaimable throughout. A confirmed sighting says "this file
holds it"; nothing here ever says a string is absent from the corpus,
because the index cannot prove that and a bounded set of reads cannot
either.

## The Law This Package Is Built Around

The index is an acceleration structure, never a semantic one. A skipped
file must be one that could not have produced a single line of output — so
elision is byte-invisible, and every reason not to elide (`--no-index`, no
index, a stale index, a table that wouldn't pay for itself) is a cost
difference rather than a failure. That is why the oracle returns
`fault.Answer(Oracle)`: the declinature rides in the success position,
where a stray `try` cannot silently convert a routine fall-back to the
live read into an aborted run.

Soundness has one direction that matters: a false *negative* (failing to
elide) is slow; a false *positive* (eliding a file that could match) is a
wrong answer with a clean exit code, the worst failure this engine has.
Hence `Oracle.skip`'s refusal to skip any file whose mtime and ctime can't
prove it predates the index anchor — which is also the exact validity
condition for reusing a persisted crest vector.

That condition is this tier's, not the sieve's. The resident session runs
the same two prunings (`exec/session/answer/gather.zig`) with no freshness
proof at all, because it computed ρ(d) over the bytes it is holding: a file
that changed is re-read into the session's overlay, whose documents the
sieve never sees. The proof above buys back a vector measured by someone
else, at another time; warm never has to ask.

Gated by the face package's index-elision parity gate (indexed and
non-indexed runs must produce identical bytes) and its indexed-PCRE oracle,
both run over a built binary there.
