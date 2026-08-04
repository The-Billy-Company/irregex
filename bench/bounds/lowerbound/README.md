# bench/bounds/lowerbound — Layer D (algorithmic lower bound)

Layer D of [irregex's Dominance-and-Fit Certificate](../README.md#dominance-and-fit-certificate-layers-al),
one of the seven layers this package mints itself. Where Layer A (minted by
the sibling `gist` repo) proves empirical dominance over ripgrep on the
registered workloads and Layer C places cycles/byte against the *hardware*
ceiling, Layer D proves the last thing left to prove: the engine's
**algorithm** matches the **information-theoretic floor** for the search
operation — no algorithm on any machine can do asymptotically less work.

## What It Is

A **fail-closed, structural byte-touch audit**. `gist-lowerbound` builds the
trigram index over the real host corpus, then for each of the twelve regex
classes (imported from [`../../apparatus/harness/probes.zig`](../../apparatus/harness/probes.zig),
the *same* module the sibling `gist` repo's `certify.zig` uses, so Layer D
lines up 1:1 with Layers A–C by construction, not by a hand-kept copy) it
measures:

- **candidate bytes** — Σ lengths of the documents the trigram filter admits
  (the full-scan verify floor);
- **passes / candidate byte** — the bytes an _independent single-pass
  re-implementation_ touches ÷ candidate bytes;
- **cand%** — candidate bytes ÷ corpus bytes (the pruning the filter achieves).

`report.py` splices the formal argument + the measured table into the mint's
working `CERTIFICATE.md` (`.gist/` by default, or `$GIST_DIR`) as the
`## Layer D` section.
[`mint.sh`](../../certificate/mint/mint.sh) copies the finished file into the
committed [`bench/certificate/artifact/`](../../certificate/artifact/)
snapshot only when asked (`CERT_PUBLISH_DIR=...`).

No production code is instrumented. The audit is *structural*: it re-implements
the fused scan in the harness with a byte counter, asserts (a) that reference's
match verdict equals the engine's **real** verify (`simd.contains` /
`Regex.docMatch`) on **every** document — a disagreement is a real correctness
defect — and (b) that the fused DFA path touches **exactly** the floor while
the SIMD literal path stays **≤** it.

## Why It Exists

"Fastest it can mathematically be" is a claim you either prove or don't make.
The floor has two independently-citable parts, and the engine meets both —
measured, not asserted:

1. **The verify stage is Ω(candidate bytes), in one pass.** Deciding whether a
   pattern occurs in a candidate document forces you, in the worst (adversarial)
   case, to examine every one of its bytes: an unread byte could *be* the match,
   or could *break* one — the adversary sets it after you commit. The fused
   byte-class DFA (`src/kernel/regex/linear/dfa/dfa.zig`) reads each candidate
   byte **exactly once** — `passes ≡ 1.0000` for every DFA class — with none of
   the memchr-then-rescan *double* byte-traffic a per-line matcher pays. The SIMD
   literal path (`src/kernel/scan/simd.zig`) reads **≤ N** through vector
   first/last-byte skips and early exit on the first hit. A **dense class**
   (`\w{3,8}`) is served in production by the SIMD class-run kernel
   (`src/kernel/scan/classrun.zig`), which skips DFA construction entirely;
   Layer D certifies its floor against an independent one-pass DFA reference it
   force-builds for the same pattern, asserting `docMatch` agrees on **every**
   candidate document — so the class-run verdict is pinned to an exact-one-pass
   oracle.

2. **The trigram filter makes total work sublinear.** The engine never touches
   most of the corpus, because the index prunes candidates *before* verify
   runs. On this corpus the selective classes admit only a measured fraction of
   the bytes; the generated certificate records that live fraction and its
   complement.

Together: trigram prune → single fused verify pass = the minimum reads any
correct algorithm can make. **12/12 classes at the floor, fail-closed.**

The gate is proven non-tautological by fault injection: adding a single extra
byte-read per line drives `passes` to 1.02 and trips a hard `exit 1`.

## How to Run

`bash bench/certificate/mint/mint.sh` runs the whole bundle, seeding
`CERTIFICATE.md` itself before any layer splices into it. To run Layer D on
its own instead:

```bash
zig build lowerbound                    # → .gist/lowerbound.csv (gist-lowerbound)

# splice the Layer D section into the certificate:
python3 bench/bounds/lowerbound/report.py \
    --csv .gist/lowerbound.csv \
    --certificate .gist/CERTIFICATE.md
```

`gist-lowerbound` exits non-zero (mirroring the sibling `gist` repo's
`bench/conformance/gates/parity/scan_regress.sh`) if any candidate byte is
read past the single-pass floor, or if the independent reference disagrees
with the engine's real verify — a failure is a real finding about the
engine, never something to paper over by weakening the assertion.

## Prior Art

- **Donald E. Knuth, James H. Morris, Vaughan R. Pratt, "Fast Pattern Matching
  in Strings" (1977), *SIAM Journal on Computing* 6(2):323–350.** The
  linear-time exact string-match result; establishes the Θ(n+m) worst case and,
  with it, the Ω(n) worst-case *read* floor for verifying a match.
- **Robert S. Boyer, J Strother Moore, "A Fast String Searching Algorithm"
  (1977), *Communications of the ACM* 20(10):762–772.** Sublinear on *average*
  (skips via the bad-character / good-suffix heuristics — Ω(n/m) reads minimum),
  but still Ω(n) in the adversarial worst case. The engine's SIMD literal path
  is in this family (first/last-byte vector skips), which is why it reads
  **≤** the candidate-byte floor.
- **Russ Cox, "Regular Expression Matching with a Trigram Index, or How Google
  Code Search Worked" (2012), <https://swtch.com/~rsc/regexp/regexp4.html>.**
  The trigram-index prefilter that makes whole-corpus search sublinear for
  selective patterns — the engine's direct ancestor (see also `../README.md`
  and `src/kernel/regex/linear/dfa/dfa.zig`, which cites Cox's linear-time
  NFA/DFA work). The `cand%` column is the empirical measure of this pruning.
- [`../../apparatus/harness/probes.zig`](../../apparatus/harness/probes.zig) is
  the shared probe-class registry the sibling `gist` repo's `certify.zig`
  (Layer A) also imports, so the two layers speak about the same twelve
  classes by construction.
