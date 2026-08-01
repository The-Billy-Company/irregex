---
doc_radar:
  counts:
    - description: "six modules — the walk, what it must read, in what order, from where, what may be skipped, and how a failed descent reads"
      glob: src/exec/cold/quarry/*.zig
      equals: 6
  sentinels:
    - description: "the oracle answers in the success position — a declinature is a routing fact, never a fault (fault-channel law 1)"
      file: src/exec/cold/quarry/elide.zig
      contains: ["fault.Answer(Oracle)", "pub fn skip", "const Err = error{"]
    - description: "the parallel engine admits the shared oracle rather than carrying its own"
      file: src/exec/cold/engine/swarm/swarm.zig
      contains: ['@import("../../quarry/elide.zig")', "elide.Lazy"]
    - description: "the serial read plane shares the oracle's indexed-path primitive; its own IndexSkip freshness proof is what the cold-engine deep-module split stage 2 folds in"
      file: src/exec/cold/quarry/intake.zig
      contains: ['@import("elide.zig")', "elide.IndexedPaths"]
---

# exec/cold/quarry — what is in the tree, and what must be read

The walk decides **which files a query is about**. This package decides **which
of those files must actually be opened** — and nothing else. Keeping the second
question out of both engines is what stops "may we skip these bytes?" from being
answered twice, differently, in two schedulers
(the cold-engine deep-module split).

| Module       | Role                                                                                                                                             |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `walk.zig`   | what is in the tree, before a byte is read — the recursive descent and the certified file set both engines answer against                        |
| `elide.zig`  | the read-elision oracle: the persisted trigram index plus the crest sieve, gated on a freshness proof, answering "can this file possibly match?" |
| `intake.zig` | turning walked candidates into readable bytes — reading only what the question needs                                                             |
| `order.zig`  | canonical file order: ripgrep's `--sort`/`--sortr`, exactly                                                                                      |
| `stream.zig` | stdin as a haystack: admitting and draining fd 0                                                                                                 |
| `notice.zig` | how a failed descent reads on stderr: the unopenable path, the `-L` loop, the walk that admitted nothing                                         |

Each of these has consumers in more than one package — and a shared concept
living inside one of its consumers is how the duplicate oracle was born the
first time.

Two freshness proofs still coexist here: `elide.Oracle`, which the parallel walk
consults per file from the bulk listing's own timestamps, and `intake.zig`'s
`IndexSkip`, which the serial read plane builds over the same indexed-path
primitive. Folding the second into the first is the cold-engine deep-module split stage 2 — and having
them side by side in one package, rather than one per engine, is the point of
this package existing before that fold happens.

## The law this package is built around

**The index is an acceleration structure, never a semantic one.** A skipped file
must be one that could not have produced a single line of output — so elision is
byte-invisible, and every reason not to elide (`--no-index`, no index, a stale
index, a table that wouldn't pay for itself) is a **cost** difference rather than
a failure. That is why the oracle returns `fault.Answer(Oracle)`: the declinature
rides in the success position, where a stray `try` cannot silently convert a
routine fall-back to the live read into an aborted run.

Soundness has one direction that matters: a false _negative_ (failing to elide) is
slow; a false _positive_ (eliding a file that could match) is a **wrong answer
with a clean exit code**, the worst failure this engine has. Hence
`Oracle.skip`'s refusal to skip any file whose mtime **and** ctime can't prove it
predates the index anchor — which is also the exact validity condition for
reusing a persisted crest vector.

That condition is this tier's, not the sieve's. The resident session runs the
same two prunings (`exec/session/answer/gather.zig`) with **no** freshness proof
at all, because it computed ρ(d) over the bytes it is holding: a file that
changed is re-read into the session's overlay, whose documents the sieve never
sees. The proof above buys back a vector measured by someone else, at another
time; warm never has to ask.

Gated by `gist/bench/conformance/gates/parity/index_elision_parity.sh`
(indexed and non-indexed runs must produce identical bytes) and
`gist/bench/conformance/gates/oracle/indexed_pcre_oracle.py`.
