---
doc_radar:
  counts:
    - description: "four modules — the compiled writ, plus the three derivations it owns"
      glob: src/exec/cold/writ/*.zig
      equals: 4
  sentinels:
    - description: "prune eligibility has exactly one owner — the predicate the tier used to re-spell at five call sites"
      file: src/exec/cold/writ/gate.zig
      contains:
        ["pub fn observesEveryByte", "pub fn mayDropFileUnread", "pub fn mayElideByIndex"]
    - description: "binary-detection liveness has one owner, and the writ computes rather than carries"
      file: src/exec/cold/writ/writ.zig
      contains: ["pub fn binaryDetect", "pub fn compile"]
    - description: "the engine face reads the writ instead of re-deriving the gates"
      file: src/exec/cold/engine/serial.zig
      contains: ["writ.Writ.compile", "const filters = w.filters;", "w.binary_detect"]
---

# exec/cold/writ — what the patterns decide

A **writ** is what an invocation's argv patterns compile to. Not the matcher
alone: the matcher _plus_ every value derived from it — both literal gates, the
trigram prefilters, the crest sieve, whether binary detection is live — each
already stood down wherever it would be unsound.

| Module          | Role                                                                                                                                                                                                                                           |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `writ.zig`      | the `Writ` itself: one `compile` call resolves every derived value, guards included; plus `binaryDetect`, the one owner of "is the detector live?"                                                                                             |
| `directive.zig` | many argv patterns → one effective pattern: `-F`/`-f`/`-e` folding and leading `(?flags)` reconciliation across a single run-wide engine                                                                                                       |
| `gate.zig`      | the prefilters and the three predicates that say when each may fire — the required-literal gate, the trigram filter, the crest sieve; its `winnow` draws the cover plan and the sieve off one shared derivation the resident session reads too |
| `arm.zig`       | which engine compiles this pattern: linear, PCRE2 outright (`-P`), or an `--engine auto` escalation, and the `-r` capture matcher that follows it                                                                                              |

## Computes, does not carry

The obvious shape for this package is a context struct — a bag of parameters
threaded through the pipeline to shorten signatures. That is the shallow module
Ousterhout warns about, and it was
explicitly rejected under the cold-engine deep-module split:
it shortens signatures without removing a single duplication, because callers
still reach in and re-derive.

A `Writ` **computes**. `filters` is already empty when index elision is
inadmissible; `file_needle` is already null when the output mode must read every
body. There is no "remember to also check" left for a caller to forget.

## One owner per policy

Two predicates in this tier are load-bearing, and both used to be written out by
hand wherever they were needed:

- **`observesEveryByte`** — does this run emit or tally _non-matching_ bytes?
  `--stats`, `--json`, and `--passthru` do, which makes "skip what cannot match"
  a wrong answer rather than a faster one. This was spelled at five call sites;
  a new output mode that forgot one would return a wrong result **with a clean
  exit code**.
- **`binaryDetect`** — `-a` / `--binary` / `--null-data` each stand the detector
  down. This was spelled seven times across four files in three different
  arities, and two of those spellings were equal only by an unstated coupling to
  a caller's eligibility check.

`mayDropFileUnread` and `mayElideByIndex` stay **separate** predicates on
purpose: `--files-without-match` forbids the whole-file gate but still permits
index prefiltering, so folding them together would be a silent behavior change.
Each says why in its own doc comment.

Proved by the rgsuite differential harness (`bench/rgsuite/`) and
[`bench/gates/index_elision_parity.sh`](../../../../bench/conformance/gates/parity/index_elision_parity.sh):
a gate may change speed, never results.
