The corpus walk stopped paying to hold files it had already refused.

`readMemberRaw` allocated a member's whole body from the worker arena and only
then asked `isBinary` whether it was a member at all. A refused body is never
handed back, and an arena cannot reclaim one allocation, so every binary file
the walk touched sat in memory for the rest of the build — read, judged, and
then carried anyway. On llvm-project that is 1,863 files and 74.3 MiB of bytes
that were dead the instant they arrived.

The verdict now comes from the window the rule actually reads. `isBinary`
inspects `binary_window` bytes and ignores the rest, so the window is the whole
rule rather than a cheaper approximation of it: the worker reads it into one
reusable 8 KiB buffer, and only an admitted file reaches `a.alloc`. An admitted
body is still one sized allocation and still one pass over the file — the window
is copied into place, not re-read — and a refused one now stops after 8 KiB
instead of reading to its end, so the walk does less IO as well.

MEASURED: index build over llvm-project (175,110 docs, 1926.3 MiB), interleaved
against a baseline differing in this file alone, three reps each — peak RSS
2487 → 2413 MiB by median, every rep inside 3 MiB of its own median. The load
phase's own peak falls 2131 → 2057 MiB. Both deltas are 74 MiB, which is what
the census of the corpus said to expect (1,863 binary files, 74.3 MiB) before
the change was written, so the number landed where it was predicted to land
rather than being explained afterwards. Wall time is a wash: 6685 → 6630 ms by
median, inside a spread the machine owns.

PROVEN IDENTICAL: `index.gist` and `paths.list` hash the same before and after
(md5 `9775cadb…` over 161,773,006 bytes and `4864e735…` over 19,439,260), so the
published index is the same bytes and not merely the same answers. A 12-pattern
query differential across the two indexes, from 15 files to 5,570, agrees on
every file list, and the loadpar/serial membership parity test still holds —
membership was never what changed, only when the allocation happens relative to
the decision.

NOT FIXED, and worth saying plainly: this is 3% of the build's peak. 1926 of the
remaining 2413 MiB is the corpus itself, held in anonymous memory because every
consumer — the trigram build, the crest sieve, the content shard — is handed the
whole `docs` slice after the walk has finished. That is the actual ceiling, and
it is untouched here. `<PREFIX>_TRACE=index` now closes the attribution it needed to
even state that: `loadpar` reports the arena capacity it reserved beside the doc
bytes it was asked to hold, so the load phase's peak can be read as corpus or as
bookkeeping instead of one number standing for both.
