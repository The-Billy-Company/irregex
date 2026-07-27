---
doc_radar:
  sentinels:
    - description: "the sieve has two answers and never a third; the cost policy and the horizons it is judged at"
      file: pkg/kernels/irregex/src/kernel/match/regex/linear/sieve/sieve.zig
      contains:
        [
          "pub const Verdict = enum { miss, unproven };",
          "pub const speed_ratio: f64 = 0.40;",
          "pub const nominal_line: f64 = 64;",
        ]
    - description: "the harvest's four hard bounds — register width, conjunction width, core size, closure work"
      file: pkg/kernels/irregex/src/kernel/match/regex/linear/sieve/quotient.zig
      contains:
        [
          "pub const cap: u8 = 16;",
          "pub const max_conjuncts: usize = 2;",
          "pub const max_core_states: u16 = 96;",
          "pub const max_closure_steps: u64 = 1_500_000;",
        ]
    - description: "the kernel takes the shared 16-wide shuffle from compose rather than carrying a fourth copy"
      file: pkg/kernels/irregex/src/kernel/match/regex/linear/sieve/sheng.zig
      contains: ['@import("../compose/lanes.zig")', "pub const resident"]
---

# linear/sieve — the SP-quotient sieve

**A rung that can refute a match but never confirm one.** `scan` answers `.miss`
— proven, nothing in this haystack matches — or `.unproven`, and the ladder
falls through unchanged. There is deliberately no `.hit`: the machine it runs is
an _over-approximation_ of the pattern, so a survivor proves nothing and a
rejection proves everything.

`../../../../primitives/crest.zig` is the same shape one abstraction down — it prunes
whole DOCUMENTS by class-run length. This prunes POSITIONS by automaton
quotient, which is why it can front patterns crest has no shape for.

## Why a quotient is sound

Partition the DFA's states so that the partition is **closed** under the
transition function: if `p ≡ q` then `δ(p,b) ≡ δ(q,b)` for every byte. This is
the substitution property (Hartmanis & Stearns, _Algebraic Structure Theory of
Sequential Machines_, 1966); the SP partitions of a machine form a lattice under
refinement. Any SP partition induces a well-defined quotient automaton on the
blocks, and if every block containing an accepting state is made accepting, the
quotient accepts a **superset** of the language. So:

> the real automaton reaches an accepting state ⟹ every quotient does.

Contrapositive: if any quotient fails to accept anywhere in the haystack, no
match exists. A conjunction of quotients is therefore a sound **necessary
condition** — and strictly stronger than either conjunct, because the kernel
asks for one position where _all_ of them accept, not for each of them accepting
somewhere.

## What is ours and what is not

The contract — over-approximate, reject early, verify survivors exactly — is
**not novel**, and the adversarial referee for this lane found it substantially
anticipated. It is prior art three times over:

- **Luchaup, De Carli, Jha & Bach, INFOCOM 2014** — CODFA / DFA-trees
  ([10.1109/INFOCOM.2014.6847977](https://doi.org/10.1109/INFOCOM.2014.6847977)).
  Their Definition 7 is exactly `|D'| < |D|` with `L(D) ⊆ L(D')`; matching stops
  at the first rejecting node and leaves verification to an exact matcher; the
  paper itself calls its shrunk DFAs "a special case of quotient automaton", and
  measured 4.7×. **This is the same idea.**
- **Češka, Havlena, Holík, Lengál & Vojnar, arXiv:1904.10786 (2019)** — a
  multi-stage cascade of small crude over-approximating NFAs, approximation
  chosen by a probabilistic model of the traffic.
- **Hyperscan `HS_FLAG_PREFILTER`** — shipping, for years: matches are a
  superset, the caller confirms with an exact matcher.

What this module claims as its own is narrow and deliberately so: the **SP-
lattice harvest** as the source of the approximation (rather than a hand-built
tree of shrunk DFAs or a learned model), the **≤16-state Sheng-resident
conjunction selection** that makes the filter cost one shuffle per byte with no
memory for state, and the **training-free compile-time selectivity gate** for
single-pattern per-byte scan. Nothing here observes traffic, learns, or disables
itself at runtime.

## Aborting when worthless

A filter that rejects nothing is not neutral — it is pure addition on every
byte, and its worst case is the case where everything survives to verification.
CODFA measured +26% in exactly that shape. Our own harvested selectivity is
**bimodal**, which means the hazard is live rather than theoretical: on the
lane's slate the sieve retires 99.98% of positions on one pattern and 37% on
another, with nothing in between that a single policy could straddle.

It is also decidable before the scan starts, and that is the mitigation.
`fallthroughRate` computes each quotient's stationary distribution over its own
transition table (Cesàro-averaged, so a periodic quotient converges) under two
byte priors — uniform and English-ish text — and the pessimistic one decides.
The sieve arms only if a whole nominal buffer is unlikely to hold any survivor:

```text
(1 - f)^nominal_doc  >  speed_ratio
```

The **buffer** grain, not the line grain, and deliberately: per-position
rejection does not translate into buffer retirement, because pattern-shaped
bytes cluster and one survivor drags a whole file into verification.
`[0-9]{4}-[0-9]{2}-[0-9]{2}` rejects 99.03% of positions and still keeps 80.2%
of documents. Judged per line it arms and measures 0.80×; judged per buffer it
declines. The same margin covers the estimate's known optimism — it is a
memoryless model of a very non-memoryless process, and it was low by five orders
of magnitude on one row of the slate.

Failing that leaves the field null. So do all four of: no register-resident
shuffle on this target, no closed partition small enough, a `project`
precondition the walk cannot honor, and an accelerator already skipping bytes
above (`Above.skip_armed`) — because a rung that touches every byte loses to one
that touches a twentieth of them, however cheap its byte is.

## Files

| File             | Role                                                                                                                                                                                                                                        |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sieve.zig`      | The entry seam: `Verdict`, the compiled `Sieve`, the cost policy, and the four-part compile-time gate. The only file the ladder above needs to know about.                                                                                  |
| `quotient.zig`   | The harvest. `project` states the soundness preconditions and reduces the DFA to a walkable core; `harvest` climbs the SP lattice from the coarsest closed partitions and selects the conjunction; `fallthroughRate` estimates selectivity. |
| `sheng.zig`      | The register-resident kernel — Langdale's Sheng shape applied to a quotient. One `tbl`/`pshufb` per byte per conjunct, newline-split lanes for whole-buffer scans, and the scalar transcription the differential test holds it to.          |
| `sieve_test.zig` | Unit cases, kernel ≡ scalar agreement, the worthless-abort proof, and randomized differential fuzz against the Pike VM.                                                                                                                     |

The 16-wide shuffle itself is **not** here: it is `../compose/lanes.zig`'s
shared primitive, which imports nothing but `std` and `builtin` precisely so a
sibling rung can take the instruction without taking the rung.

## Proving it

`zig build sieve` walks the real Billy corpus and checks, at every byte position
of every document, that the DFA being in a matching state implies every quotient
accepting. One violation exits non-zero. It publishes the measured selectivity
beside the compile-time estimate that gates it — including the rows where the
sieve is worthless, because a table with no ≈0% row is hiding something — and
times the kernel against the shipped engine in the same run on the same machine.
