# linear/shuffle — matching as a reduction

**The eager DFA's cost is a pointer chase, not a table.** `s = trans[s + class[b]]` is one loop-carried dependent load, so it runs at load-use latency and nine states cost exactly what seventy-three do. No constant-factor work on the table changes that, because the table is not the problem; the chain is.

This rung changes the *bound type*. A transformation of a |Q|-state machine is a |Q|-byte vector — lane `i` holds where state `i` goes — and composing two of them is `(f∘g)[i] = f[g[i]]`, which is literally `TBL f, g`, one constant-time AArch64 instruction.

Composition is associative, so the per-byte transformations of a chunk can be combined in any order, and matching only wants the final state. That makes the scan a *reduction*. A binary tree over `n` leaves has `n−1` internal nodes — exactly what the serial fold pays — so re-association is free in instruction count and buys a quarter of the dependency depth: one loop-carried shuffle per 32-byte chunk instead of one dependent load per byte.

Measured against the shipped `Dfa.docMatch`, same buffer, same process, interleaved round by round (`zig build compose-rung`, walking the real host corpus — see [`bench/rungs/shuffle/README.md`](../../../../../bench/rungs/shuffle/README.md) for the harness and a current reference run):

- **16 lanes.** The class-alternation family (9–15 states) arms here and measures a 4.7–4.8× speedup over the shipped eager DFA.
- **32 lanes.** The wider hex/digit family (17–22 states) arms here instead and measures a 2.3× speedup — lower than the 16-lane rows, which is the axis the slate exists to show.

## What The Lowering Has To Solve

Composition yields a chunk's final state and throws the intermediate ones away, but a line matches if it ever touched an accepting state. So "ever" has to live in the state: every accepting DFA state folds into one absorbing MATCH lane, after which *some prefix accepted* ≡ *the final lane is MATCH* — which is what a reduction computes.

A `\n` row maps every live lane back to START, reproducing the per-line model (`^` re-seeds, a match never crosses a line) inside one fused pass over the whole buffer.

`$` is the subtle one. The DFA resolves it with a second table consulted only on a line's last content byte, and composition has no "after the fact" to consult it in. The lowering instead detects whether any `(lane, class)` accepts under the end-of-line table without already accepting under the interior one — which is precisely a `$` that can fire where the interior step did not already report a match.

When it can, the table doubles to 512 rows indexed by `byte | (next_is_newline << 8)` and the kernel reads one byte ahead. The index still depends only on input bytes, so the loads stay independent and the parallelism survives. Detecting this rather than assuming *no `$` in the pattern* is what keeps the 256-row fast path sound.

## Where It Stands Down

It is a *decider*: it declines at compile time by being null, and once armed it is total. Every refusal is a real hole rather than a convenience.

- **Not AArch64.** The kernel *is* one instruction there; `runPortable` exists as the spec and the test oracle, never as a shipping path.
- **`\b` / `\B` word context.** Resolved per line by a second table axis this lowering does not carry.
- **More than 31 non-accepting states.** 32 lanes with MATCH is the ceiling — see below.
- **The start closure already accepts.** START and MATCH would be the same lane, and the DFA answers such patterns in O(1) anyway.
- **A start-state accelerator is armed.** This is a question of dispatch, not representability — see below.

Thirty-one states is an instruction boundary, not a cache one. Sixty-four lanes needs `TBL` with a four-register list, which retires at 1.33/cycle against the 1- and 2-register forms' 4.02, and the bottleneck flips from the load port to the shuffle port in a single step. The technique returns ~1.2× there and is not worth a code path. The widest table this file will build is 32 KiB against a 128 KiB L1D, so cache is nowhere near the limit.

The armed literal skip is the honest loss. When the DFA has start acceleration, it touches a twentieth of the haystack; composition must retire every byte of it. Measured on `q~x.*j~w.*m~p`: 0.15× — 6.7× *slower*. Faster per byte loses to touching almost none of them, so `build` refuses and the ladder keeps the accelerated DFA. `lower` is the same construction without that judgment, which is how the bench publishes the row it must not take.

## Files

- **[`../../../scan/lanes.zig`](../../../scan/lanes.zig)** holds the algebra: `Vec`, the two widths, `shuffle` / `shufflePair`, the group-amortized source load, the reduction, and `runPortable` as the scalar definition. It imports nothing but `std` and `builtin`.
- **`shuffle.zig`** is the rung: lowering a `Dfa` into transformation tables, the gates, `match` / `docMatch`.
- **`shuffle_test.zig`** holds kernel ≡ scalar fold, fail-closed gate cases, and the line + document differential against the Pike VM.

### `scan/lanes.zig` Is The Shareable Half

A sibling wanting the byte-shuffle primitive imports `lanes.zig` directly and depends on no rung: the file is semantics-free, takes its tables from the caller, and knows nothing about regexes. `shuffle` is the 16-wide lookup that `scan/teddy.zig`, `scan/classrun.zig` and the quotient sieve each carry their own copy of; `lanes.native` is the compile-time answer to *can this target arm a composition at all*, which callers read before they ask.

Lineage: transformation monoids over an automaton's transition functions — the algebra behind parallel prefix scans (Ladner–Fischer 1980) and behind Sheng's register-resident `PSHUFB` state step (Hyperscan). New here is treating the match question as a reduction rather than a scan, and folding the end-of-line decision into the table index so the whole per-line model survives one pass.
