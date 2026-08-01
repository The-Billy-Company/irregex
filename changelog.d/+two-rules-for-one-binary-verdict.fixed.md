`--files-without-match` no longer lists a binary file whose NUL sits past the
first few kilobytes. Both engines had a second, weaker definition of "binary" on
this path, and a file could be text by one and binary by the other.

`rg --files-without-match -e generated .` over a 140 KB file of text ending in a
NUL lists nothing; gist listed the file. Two independent causes, one per engine,
both the same mistake - the negated path asked a different question than the
searcher asks.

Serial asked `corpus.isBinary`, which is the INDEX's membership rule: a NUL in
the first 8 KiB. That is the right rule for deciding what belongs in a trigram
corpus and the wrong one for deciding what ripgrep searched, because rg detects a
NUL in whatever read buffer it lands in, however deep. `fileWithoutMatch` now
asks what `renderFile` asks - `verify.firstNulWide` over the whole body, with the
`-U` clause that a NUL the slice model never reads leaves the file text - so the
listing rule and the emit rule are one rule again. It also honors `--null-data`
now (`writ.binaryDetect`'s third flag), where NUL is the line terminator and
therefore not evidence of anything.

Parallel had the gap in the other direction. `gateMiss` - the whole-file literal
gate proving the pattern absent - listed the path in this mode with no binary
question asked at all. Stage 1's prefix sniff hides that most of the time by
returning before the gate runs, but not always: a NUL in the TAIL of a >64 KiB
file is past the sniffed prefix, and a transform run (`-E`/`-z`) reads the whole
file through `ingest` and skips stage 1 entirely, which is why `-E utf-8` was
enough to make gist list four binaries rg suppresses. The two arms now share one
`binaryCut` definition, so which side of the gate a file arrives on cannot change
whether it is listable - the file still carries the exit code through
`Sink.unlisted`, since its abandoned search did find no match.

This was the last of the fuzzer's `--files-without-match` residual: seed 20260727
at 6000 iterations drops from 13 divergences to 9, and the `line-count+exit`
class is gone entirely.
