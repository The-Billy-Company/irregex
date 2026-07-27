---
doc_radar:
  sentinels:
    - description: "the lane algebra is the shareable half — one shuffle, two widths, and the AArch64 gate a sibling reads"
      file: pkg/kernels/irregex/src/kernel/match/regex/linear/compose/lanes.zig
      contains:
        - "pub inline fn shuffle"
        - "pub const native = switch (builtin.cpu.arch)"
        - "lanes16 = 16,"
        - "lanes32 = 32,"
      absent: ["lanes64"]
    - description: "the rung declines at compile time by returning null, and `build` is where the armed-skip judgment lives"
      file: pkg/kernels/irregex/src/kernel/match/regex/linear/compose/compose.zig
      contains:
        - "pub const max_states: u8 = 31;"
        - "if (dfa.accel != null) return null;"
        - "pub fn match"
        - "pub fn docMatch"
---

# linear/compose — matching as a reduction

**The eager DFA's cost is a pointer chase, not a table.** `s = trans[s + class[b]]`
is one loop-carried DEPENDENT load, so it runs at load-use latency — measured
3.0 cyc/byte on an Apple M4 Max — and nine states cost exactly what seventy-three
do. No constant-factor work on the table changes that, because the table is not
the problem; the chain is.

This rung changes the **bound type**. A transformation of a |Q|-state machine is
a |Q|-byte vector — lane `i` holds where state `i` goes — and composing two of
them is `(f∘g)[i] = f[g[i]]`, which is literally `TBL f, g`, one constant-time
AArch64 instruction. Composition is associative, so the per-byte transformations
of a chunk can be combined in any ORDER, and matching only wants the final
state. That makes the scan a **reduction**. A binary tree over `n` leaves has
`n−1` internal nodes — exactly what the serial fold pays — so re-association is
free in instruction count and buys a quarter of the dependency depth: one
loop-carried shuffle per 32-byte chunk instead of one dependent load per byte.

Measured against the shipped `Dfa.docMatch`, same buffer, same process,
interleaved (`bench/compose/`, 206 MiB of the real Billy corpus):

|                   | 16 lanes      | 32 lanes     |
| ----------------- | ------------- | ------------ |
| composition       | 2.26 B/cycle  | 1.11 B/cycle |
| shipped eager DFA | 0.335 B/cycle | 0.34 B/cycle |
| speedup           | **6.8×**      | **3.3×**     |

## What the lowering has to solve

Composition yields a chunk's final state and throws the intermediate ones away,
but a line matches if it EVER touched an accepting state. So "ever" has to live
in the state: every accepting DFA state folds into one absorbing MATCH lane,
after which _some prefix accepted_ ≡ _the final lane is MATCH_ — which is what a
reduction computes. A `\n` row maps every live lane back to START, reproducing
the per-line model (`^` re-seeds, a match never crosses a line) inside one fused
pass over the whole buffer.

`$` is the subtle one. The DFA resolves it with a second table consulted only on
a line's last content byte, and composition has no "after the fact" to consult
it in. The lowering instead DETECTS whether any `(lane, class)` accepts under
the end-of-line table without already accepting under the interior one — which
is precisely a `$` that can fire where the interior step did not already report
a match. When it can, the table doubles to 512 rows indexed by
`byte | (next_is_newline << 8)` and the kernel reads one byte ahead. The index
still depends only on input bytes, so the loads stay independent and the
parallelism survives. Detecting this rather than assuming _no `$` in the
pattern_ is what keeps the 256-row fast path sound.

## Where it stands down

It is a **decider**: it declines at COMPILE time by being null, and once armed
it is total. Every refusal is a real hole rather than a convenience.

| Refusal                                | Why                                                                                                           |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| not AArch64                            | the kernel IS one instruction; `runPortable` exists as the spec and the test oracle, never as a shipping path |
| `\b` / `\B` word context               | resolved per line by a second table axis this lowering does not carry                                         |
| more than 31 non-accepting states      | 32 lanes with MATCH is the ceiling — see below                                                                |
| the start closure already accepts      | START and MATCH would be the same lane, and the DFA answers such patterns in O(1) anyway                      |
| **a start-state accelerator is armed** | dispatch, not representability — see below                                                                    |

**Thirty-one states is an instruction boundary, not a cache one.** Sixty-four
lanes needs `TBL` with a four-register list, which retires at 1.33/cycle against
the 1- and 2-register forms' 4.02, and the bottleneck flips from the load port
to the shuffle port in a single step. The technique returns ~1.2× there and is
not worth a code path. The widest table this file will build is 32 KiB against a
128 KiB L1D, so cache is nowhere near the limit.

**The armed literal skip is the honest loss.** When the DFA has start
acceleration, it touches a twentieth of the haystack; composition must retire
every byte of it. Measured on `q~x.*j~w.*m~p`: **0.15× — 6.7× SLOWER**. Faster
per byte loses to touching almost none of them, so `build` refuses and the
ladder keeps the accelerated DFA. `lower` is the same construction without that
judgment, which is how the bench publishes the row it must not take.

## Files

| File               | Role                                                                                                                                                                                                |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `lanes.zig`        | The algebra: `Vec`, the two widths, `shuffle` / `shufflePair`, the group-amortized source load, the reduction, and `runPortable` as the scalar definition. Imports nothing but `std` and `builtin`. |
| `compose.zig`      | The rung: lowering a `Dfa` into transformation tables, the gates, `match` / `docMatch`.                                                                                                             |
| `compose_test.zig` | Kernel ≡ scalar fold, fail-closed gate cases, and the line + document differential against the Pike VM.                                                                                             |

### `lanes.zig` is the shareable half

A sibling wanting the byte-shuffle primitive imports `lanes.zig` **directly**
and depends on no rung: the file is semantics-free, takes its tables from the
caller, and knows nothing about regexes. `shuffle` is the 16-wide lookup that
`scan/teddy.zig`, `scan/classrun.zig` and the quotient sieve each carry their
own copy of; `lanes.native` is the compile-time answer to _can this target arm a
composition at all_, which callers read before they ask.

Lineage: transformation monoids over an automaton's transition functions — the
algebra behind parallel prefix scans (Ladner–Fischer 1980) and behind Sheng's
register-resident `PSHUFB` state step (Hyperscan). New here is treating the
match question as a _reduction_ rather than a scan, and folding the end-of-line
decision into the table index so the whole per-line model survives one pass.
