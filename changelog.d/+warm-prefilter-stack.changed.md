The resident session prunes by the same stack the CLI does. Warm asked the
trigram index exactly one question — the flat OR of the sound prefilter literals
— while cold had been asking two stronger ones: the conjunctive cover plan and
the crest sieve over per-document ρ(d). So the daemon was slower than the cold
path it accelerates on a whole class of patterns: `[0-9a-f]{8}` forces no trigram
at all, and warm read 100% of the corpus for it. It now reads 6%.

Both prunings come off ONE parse. `query.winnow` returns the cover plan and the
forced crest swell together, and cold's `Writ.compile` was paying `lower.parse`
twice to read them separately, so the cold compile path got cheaper on the way
past. `Mirror` grew a per-doc crest vector array built by the persisted sidecar's
own builder — reused rather than re-looped, so a resident vector and the on-disk
`crest.bin` vector for the same bytes are the same computation and cannot drift
into disagreeing about ρ(d). It is 16 B/doc and rides an ingest that already
touched those bytes; a failure to build it costs the sieve and never the load.

Each stand-down is cold's, spelled once: caseless keeps its case-variant filter
(the Unicode-fold bounds are stated in exactly one place and a folded-AST cover
would be a second spelling of that argument), and a `-F` literal or a PCRE2 body
arrives with a null `source`, which is the standing "do not re-parse"
certificate. `GIST_NO_COVER` / `GIST_NO_CREST` stand one half down each, read in
the daemon rather than the client because that is where the pruning is derived.

Measured on 5,883 files of real Billy source, frozen: the cover plan narrows the
index answer 39-93% on the patterns that force several literals, the sieve takes
another 44-94% off the literal-free class repetitions, and end-to-end that is
1.4-1.9x geomean over the ten patterns either half can prune. The candidate
figures are exact and reproduce row for row; the wall-clock range is the honest
one, because both arms are the same client spawn and socket handshake around a
3-18 ms answer and a fixed cost in both terms compresses the ratio toward 1 by an
amount that depends on the machine's load. `warm_parity.sh`
holds all of it byte-identical across 27 cases against a second daemon with both
knobs off, against gist's own `--no-index` read, and against ripgrep — and fails
closed on a half that never fired, since parity is trivially satisfied by a
pruning that does nothing.
