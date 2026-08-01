`bench/rungs/sliver/artifact/scale_race.json` was tracked in git with its
`corpus` field set to an absolute path on the machine that minted it, so the
artifact published a username and the interior layout of the private monorepo
this package was extracted from. It now records what the corpus **was** rather
than where it sat: shallow clones of linux, llvm, go, rust, **352316 files on
disk**, **5.5 GiB incl. VCS metadata** - the same description `scale_build.tsv`
already carried one file over. That build lane's own header gave the corpus a
scratch path too, and now says only that the four clones sat under one corpus
root.

The bench and vendor prose had the softer version of the same problem: four
citations pointing into a per-experiment scratch directory a reader outside
that repo cannot open. Each pointer is replaced by what the spike
established, so the claim can be judged where it stands.

The patternid rung no longer says it gates a document you cannot read; it says
what it gates and how the gate came out. Attribution, overlapping matches, and
an end-only HalfMatch stream are one mechanism seen three ways, all riding one
ratio, and the design scan read rust-regex's determinizer, dense DFA, NFA,
search, and overlapping/half-match paths before settling the shape and leaving
exactly one thing unmeasured: whether widening the state key multiplies states.
It does not. **1.017-1.121** over six slates, worst on `kin-8`, the slate built
deliberately adversarial out of eight patterns that share both prefixes and
suffixes. The sliver README and the Pareto artifact now name the instrument
instead of its path: a standalone probe over gist's own trigram directory,
**19,440 documents** and **188.2 MiB** at a 256-byte block, pricing every
`(trigram, document)` posting once with a real delta+varint encoder and
bucketing by document frequency so `cost(T)` is a prefix sum rather than a
re-run per threshold. The vendored libsais note describes the harness that
priced OpenMP and declined it: the same translation unit built twice from one
`build.zig`, once plain and once with `-DLIBSAIS_OPENMP` against Homebrew
`libomp`, timed inside the real codex pipeline over a 200 MB corpus at min of 2
reps, with the adapter identity proved byte for byte on every arm and the
thread-scaling table taken only once the box went quiet.

No measured value moved. The three files under `artifact/` changed in their
comment headers and in that one `corpus` string, and nowhere else. `.local/`
stays this repo's scratch convention; only the per-experiment citations went.
