# Prior art — the throughput × completeness plane

What the field has actually achieved, at what measured throughput, with what
feature set. Assembled from an adversarial survey with a kill mandate, so the
bias runs toward deflating claims rather than repeating them. Vendor
aggregate-Gbps figures are excluded on purpose: they are not single-core
scientific ceilings.

**The headline is that nobody is simultaneously feature-complete and at the
throughput frontier.** There are three nearly disjoint peaks and they do not
coincide, so "beat everyone at everything" is not one problem but several.

## Throughput, normalized to bytes/cycle

Bytes/cycle = (GB/s) / GHz. Numbers are measured unless marked otherwise.

| Approach                                     | bytes/cycle         | Applies when                                            |
| -------------------------------------------- | ------------------- | ------------------------------------------------------- |
| memchr, AVX2/AVX-512 (Muła)                  | ~14–30              | one rare byte; often memory-bandwidth bound in practice |
| **our accelerated path**                     | **8.87–8.99**       | a literal long enough to arm a skip                     |
| Teddy (Hyperscan)                            | 2.67 theoretical    | small multi-literal sets; up to 35× Aho–Corasick        |
| Parabix / icGrep (Cameron et al., PACT 2014) | 0.63–1.6            | bitstreams; collapses on nested Kleene                  |
| Sheng16 (Langdale, 2018)                     | 0.98                | ≤ 16 states, table lives in a shuffle register          |
| Shift-Or / Shift-And                         | ≤ 1 by construction | ≤ _w_ NFA states, one word op per byte                  |
| **our unaccelerated path**                   | **0.277**           | everything else — the hole                              |
| reference table DFA (Langdale, Skylake)      | 0.15                | the naive baseline we already beat                      |

**~1 byte/cycle is the accepted wall for a general table DFA**, and the reason
is microarchitectural rather than asymptotic: each byte's next state depends
on the previous load. Everything that exceeds it does so by leaving the model
— fitting the transition function into a shuffle (Sheng), skipping input
(literal prefilters), or abandoning byte-at-a-time entirely (Parabix). No
published general 100–10k-state DFA sustains multi-byte/cycle on a single
stream without speculation or a model change.

### Parabix, measured on our own hardware

The one alternative model reproduced here rather than cited. A from-scratch
NEON pipeline on the M4 Max, every kernel gated against a scalar oracle
transcribed from the definition of the marker recurrence (not from the
MatchStar identity, which would have proved nothing):

| pattern                   | bytes/cycle | vs our 0.277                |
| ------------------------- | ----------- | --------------------------- |
| `[A-Za-z]+[0-9]+`         | 4.29        | 15.5×                       |
| word / space / word       | 3.35        | 12.1×                       |
| `[0-9]{40,}`              | 3.92        | 14.2×                       |
| nested Kleene, two levels | 0.061       | **0.2× — loses to our DFA** |

It works for a structural reason: the pipeline has no dependent load in the
hot path at all, so the latency floor above simply does not exist in it. The
collapse is equally structural and is a trap — _unanchored_ `([a-z]+ )+` is
seeded all-ones, converges in about two iterations and clocks 3.84; anchoring
the same-looking pattern makes the marker stream sparse and costs 63× more. So
admission must gate on star-height, never on how a pattern reads.

On portability, NEON is _better_ than x86 at the transposition (`packh`/`packl`
are `uzp1`/`uzp2`, and the shift-select pair folds into `sri`/`sli`, which x86
has no equivalent of) but has no movemask, so the published long-stream
addition does not port; moving that step into general-purpose registers, where
AArch64 has real carry flags, recovers 1.47×. Counter-intuitively, wider
vectors do not help uniformly — SSE2→AVX2 halved instruction counts on flat
patterns and made the star kernel _slower_, because a 256-position block needs
more iterations than a 128-position one.

## Parallelising one automaton over one stream

Mytkowicz, Musuvathi & Schulte (ASPLOS 2014) transition from all states at
once and vectorise: ≤ 3× over optimized sequential on one core. Luchaup's
speculative chunking gains ~40% single-threaded. Later work (Qiu et al., ASPLOS
2021; GSpecPal, IPDPS 2022) reports large speedups over _other GPU baselines_,
not over Hyperscan on a core.

All of it after 2014 leans on **convergence** — the empirical fact that state
pairs merge after a short window — and there is no useful general bound
guaranteeing it. The nearest classical object, the synchronizing word and the
Černý conjecture, is about reset words rather than chunk speculation. Every
paper concedes a serial fallback on automata that do not converge.

## Completeness

✓ yes · ~ restricted · ✗ no

| Capability                     | rust/regex | RE2 | Hyperscan | PCRE2-JIT | RE#             |
| ------------------------------ | ---------- | --- | --------- | --------- | --------------- |
| Intersection / complement      | ✗          | ✗   | ✗         | ✗         | ✓               |
| Captures                       | ✓          | ✓   | ✗ ignored | ✓         | ✗ non-capturing |
| Bounded `{n,m}` without blowup | ~          | ~   | ~         | ✓         | ~               |
| Lookaround                     | ✗          | ✗   | ✗         | ✓         | ~ restricted    |
| Multi-pattern / streaming      | ~          | ✗   | ✓✓        | ✗         | ✗               |
| Worst-case linear              | ✓          | ✓   | ✓         | ✗         | ✓               |

**The empty cell:** full Boolean Kleene _and_ real captures _and_ unbounded
lookaround _and_ bounded repetition without blowup _and_ Unicode _and_
Hyperscan-class multi-pattern throughput. Nothing occupies it. The closest
points are completeness without speed (PCRE2, Oniguruma), speed without
completeness (Hyperscan), balanced single-pattern automata (rust/regex), and
Boolean completeness with good single-pattern speed (RE#, POPL 2025 — but
leftmost-longest, non-capturing groups, single-pattern).

Where everyone concedes: counting plus alternation at large bounds without a
special representation; captures at streaming multi-pattern throughput;
adversarial non-convergent automata under speculation; nested Kleene for
bitstream methods; and true intersection or complement in a Hyperscan-class
scanner.

## Unicode

Universally acknowledged as costly, never reduced to a single constant — it
surfaces as automaton blowup, compile spikes, and lazy-cache thrash, all
pattern-dependent. The best known practice for a byte-automaton engine is
codepoint-ranges to UTF-8 sequences plus a minimal-ADFA construction from
sorted keys (Daciuk et al., 2000) for the forward direction, a range trie for
the reverse, and byte equivalence classes to shrink the alphabet before
determinizing. Derivative engines sidestep it differently, operating on
symbolic predicates so a large class is never materialized as a byte trie.

Our own instance of the problem is recorded in
[`../../src/kernel/match/regex/linear/dfa/README.md`](../../src/kernel/match/regex/linear/dfa/README.md):
Unicode `\w` lowers to a roughly 10³-state UTF-8 trie, so a 332-state
automaton still costs ~15 ms to find, which is why the eager driver meters
cost in NFA-state visits rather than in states.

## Benchmark

`rebar` (Gallant) remains the canonical cross-engine barometer. Its own
`BIAS.md` is candid: the curated set favors truly regular workloads and
avoids hard lookaround and backreferences, the author also writes rust/regex,
and different engines appear in different subsets so geometric means are not
strictly comparable across them. Hyperscan leads the public curated search
table (~2.37 geometric mean) ahead of rust/regex (~3.08); RE#'s reported first
place is from a different evaluation that includes RE# and its extension
suites. Use `hsbench` alongside it for multi-pattern work, and trust neither
alone.
