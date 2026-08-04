# `bench/rungs/crest` — The Crest Sieve's Production Proof Harness

`zig build crest` (from the repository root) links the real engine, walks
the real host corpus, and proves the **crest sieve**
(`src/kernel/math/crest.zig`, theory in `research/crest/PROOF.md`)
fail-closed against the shipped `Regex.docMatch`. A companion release package
lives beside this file at [`evidence/`](evidence/README.md).

## What It Proves, In Order

1. **Fixed-pattern regression.** A small pinned slate runs first; if it fails,
   the harness refuses to spend time on corpus timing at all.
2. **Soundness, the load-bearing claim.** For every file, matched ⇒ ¬pruned,
   checked against the production matcher. One violation exits non-zero — no
   bandaid, fix the calculus.
3. **Scan parity.** The shipped interleaved block scan is checked byte for
   byte against an independent per-byte reference implementation before
   either is timed, so a faster scan can never be a scan that computes
   something else.
4. **Pruning and speed.** Wall time of a full scan against sieve-plus-survivors,
   same matcher on both sides, on the literal-free class-repetition slate
   where the trigram index prunes 0%.
5. **Two ablations at the same forced-run threshold ĝ**, both sound and both
   dominated: the retired single-vector *fold* (componentwise min over a
   disjunction's alternatives) and the weaker *count* cousin (total class
   population). A disjunction row that ever prunes fewer files than its own
   fold is a dominance violation, checked directly rather than argued.
6. **Randomized adversarial soundness**, in all four combinations of engine
   mode (byte/ASCII, Unicode) and case sensitivity, each pattern's ĝ computed
   with the same mode flag the compiled matcher got — exactly how production
   `gate.winnow` pairs them.

## Why The Slate Carries Caseless And Default-Flag Rows

The query slate is not just class-repetition patterns; it exists to catch two
specific regressions that plain ASCII patterns cannot see.

The caseless rows exercise the case-closed extension, because a naive fold
widens a class enough to erase its selectivity — `[A-Z]{6}` caseless has to
still prune, not degrade to "any six letters."

The **default-flag spellings** (`\d{6}`, `\w{8}`, `\s{4}`) are the queries a
caller actually types, and they measure a different sieve from their
character-for-character ASCII twins: the engine's Unicode default lowers a
Perl escape to a codepoint class, and `\d{6}` used to certify nothing at all
and prune 0% where the byte-class twin `[0-9]{6}` pruned 92.7%. Both rows run
side by side so a regression in the codepoint path shows up as a widening gap
between twins, not just a falling number.

The two **disjunctive rows** (`[0-9a-f]{12}|~{60}`, `[0-9]{6}|[A-Z]{6}`) force
alternatives with no common superclass. A collapsed single-vector ĝ is the
zero vector for both branches, which used to stand the whole sieve down —
exactly what `gist -e A -e B` compiles to — so these rows are the regression
test for the disjunction fix itself.

## Reading The Table

Each row prints the forced ĝ per alternative, three prune percentages (`RUN`
the disjunction, `FOLD` the retired single-vector sieve, `CNT` the count
cousin), full-scan and sieve-plus-survivors wall time, and the resulting
speedup. `RUN` prune% is always at or above `FOLD`, and both dominate `CNT`.

Two class-repetition rows are deliberately wide (`\w{3,8}`, `[A-Za-z]{5}`)
and are kept honest: they should prune close to nothing, and a run where they
start pruning heavily means the slate has drifted away from the trigram
index's actual blind spot.

## Artifacts

A run writes `crest.csv` (the aggregate summary table), `crest-run.json`
(every raw sample in execution order, the seeds, and the randomized-sweep
counts — independently replayable), and `corpus-manifest.tsv`, all beside the
other bench artifacts. `evidence/` builds a signed release package on top of
this same run; see its own [README](evidence/README.md) for what that adds.

## The Shipped Integration

Everything above proves the kernel; the CLI path that spends the proof is
exercised end to end rather than assumed. `gist index` persists the sidecar
at `crest.bin` (`src/corpus/index/crest/sidecar.zig`), and a query like
`gist '[0-9a-f]{12}'` elides pruned reads through that sidecar — compare
timing against `--no-index` for the before/after a caller actually sees.
