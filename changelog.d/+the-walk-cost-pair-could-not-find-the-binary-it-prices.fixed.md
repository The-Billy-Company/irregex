The two `bench/rungs/sliver/` lanes can find the exact-search CLI again, and the walk-cost
pair they mint is measured over more than one corpus.

Both lanes pinned the binary inside this repo's own `zig-out/bin/`, which stopped
existing when the kernel split into four packages and the face package took that CLI
with it. The lane that
guards the walk's memory footprint therefore died on a missing-file traceback rather
than naming the binary it wanted, which is how a shipped win went a release without its
evidence being re-taken: `scale_resident.tsv` still argued from a pre-fix capture and
called the walk's overhead "an open optimization target ... until it is profiled" after
it had been profiled and closed twice over. `product.gist_cli` resolves `$GIST_BIN`,
then the sibling checkout's release build, then `PATH`, and says which three it tried
when there is none.

`--root` now repeats, because the ratio turned out to be **corpus-shaped** and one tree
would let whoever picked it pick the verdict - ripgrep's own footprint swings further
between two real trees than ours does. Over a zero-match `pgxpool` needle at 3 reps,
llvm-project (193,744 files) puts ours at 69.6 MiB maxrss / 57.0 MiB owned against
ripgrep's 33.8 / 31.8, an owned ratio of **1.79x**; the wider `.etc` tree (449,684
files) puts ours at 89.2 / 76.6 against ripgrep's 112.4 / 110.4, an owned ratio of
**0.69x** - ours owning less than ripgrep for the same answer. Layer J renders every
corpus and takes its headline from our **worst**, so the certificate cannot be
accused of shopping for a tree. Each corpus is its own row pair in the artifact, and a
ratio is computed from the cells as published, so dividing the two numbers in front of
you lands on the number printed beside them.

The narrative that pair supports is corrected with it. The certificate credited the
whole closure to dropping held file mappings, which moves `maxrss` and by its own note
left owned memory untouched; owned was closed separately, by the walk no longer
materializing every path it walks in the immortal per-worker arena. Both are now named
against the column each one moves. The `csearch`/`zoekt` rows in `scale_resident.tsv`
are stamped pre-fix rather than re-typed - refreshing them needs the multi-GB corpus
with rival indexes rebuilt over byte-identical files, and inventing the delta would be
worse than labeling it.
