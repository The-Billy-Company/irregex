`bench/certificate/mint/crest.sh` ran the crest proof against `CORPUS` — cd'd
there first, exactly as every other lane does, since a lane resolves its own
roots relative to wherever it stands — but then copied its evidence CSV from
`${KERNEL}/.local/crest-evidence/crest.csv`. `bench.zig`'s evidence writer
also resolves that path relative to its own CWD, so the two only agreed when
`CORPUS == KERNEL` (measuring the checkout against itself). Point
`GIST_CORPUS_ROOT` anywhere else — the certificate's own declared
`ecosystem-v1` corpus, the whole reason this script takes a `CORPUS` distinct
from `KERNEL` — and it silently copied whatever leftover file happened to sit
under the checkout from the last time someone ran `zig build crest` there,
never the run this mint had just watched pass.

It did not fail loud. The proof printed the right corpus (`corpus: 1241 files
· 22.4 MiB`), exited 0, and the script happily spliced a `crest.csv` from a
different corpus (760-ish self-checkout files) into a certificate whose header
claims 1241. Nothing downstream checks that the two numbers agree, so the
mismatch would have shipped as a plausible-looking but wrong Layer E — exactly
the failure mode the fail-closed proof exists to rule out, reintroduced one
layer up in the shell around it.

`CREST_RAW` now reads `${CORPUS}/.local/crest-evidence/crest.csv`, matching
where the binary that just ran actually wrote it.
