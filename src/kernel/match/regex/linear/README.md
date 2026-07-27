---
doc_radar:
  sentinels:
    - description: "the public Regex handle owns the state and adopts its behavior from the neighbors by name"
      file: pkg/kernels/irregex/src/kernel/match/regex/linear/program/core.zig
      contains:
        ["pub const Regex", "pub const lineMatch = verdict.lineMatch", "pub const matchSpan = span.matchSpan"]
    - description: "the boolean engine ladder (classrun → accelerator tier → DFA → Pike) lives in ladder/verdict.zig"
      file: pkg/kernels/irregex/src/kernel/match/regex/linear/ladder/verdict.zig
      contains: ["pub fn lineMatch", "pub fn docMatch"]
    - description: "the engine-neutral seam forwards to the linear arm or the PCRE2 backend"
      file: pkg/kernels/irregex/src/kernel/match/regex/linear/ladder/matcher.zig
      contains: ["pub const Matcher"]
---

# kernel/match/regex/linear — the linear-time execution engine

The **back of the pipeline**: the RE2/ripgrep-philosophy engine that actually
runs a compiled pattern over bytes — no backtracking, no catastrophic blowup.
The byte-class DFA is the primary O(1)/byte engine; the Pike VM is the capped
fallback and the differential-fuzz correctness reference.

Read as one sentence: **`program/`** is what a pattern becomes, **`ladder/`**
decides who answers a question about it, and **`pike/`** / **`dfa/`** are the two
machines that can — with **`symbolic/`** an alternative route to the same DFA
table, taken when a pattern's Unicode classes would make the byte determinizer
pay for them.

Three more machines sit between the ladder and the DFA, and they exist for one
reason: the DFA's cost is a loop-carried dependent load, so it runs at load-use
latency and no amount of work on the table touches that. Each **rung** escapes
the chain differently rather than shortening it — **`compose/`** replaces the
per-byte lookup with a shuffle over composed transformations, **`parabix/`**
holds a marker bitstream so the dependence is as long as the pattern instead of
the text, and **`sieve/`** refutes whole regions cheaply without ever confirming
one. Every rung is optional, declines at compile time by being absent, and
answers identically to the Pike VM.

| Folder                  | Role                                                                                                                                                                                                                                                                                |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`program/`](program)   | The compiled artifact and its constructor: the public `Regex` handle (immutable state, `deinit`, program-walk predicates) and the compile pipeline that fills it.                                                                                                                   |
| [`ladder/`](ladder)     | Engine selection at every grain: which backend (`Matcher` — linear or PCRE2), which rung answers a boolean question (`verdict` — classrun → accelerator tier → DFA → Pike), and which optional accelerator serves inside that (`rungs` — one interface over compose/parabix/sieve). |
| [`pike/`](pike)         | The Pike VM: reusable scratch, the epsilon-closure that resolves every zero-width assertion, the comptime-specialized boolean walks, and the `-o` leftmost-first span walk.                                                                                                         |
| [`dfa/`](dfa)           | The determinized primary: the immutable, scratch-free byte-class DFA, the subset construction behind it, and the two policies that drive it — eager to fixpoint, or on demand per visited state.                                                                                    |
| [`symbolic/`](symbolic) | The same determinization, over the pattern's own predicates instead of UTF-8 bytes, then crossed back with a decoder into an ordinary byte DFA — so a Unicode class costs what its ASCII twin costs. Declines to `dfa/` for anything it cannot say exactly.                         |
| [`compose/`](compose)   | Rung. Matching as a reduction: each byte's transition becomes a transformation of the whole state set, folded by a SIMD shuffle, so the loop carries a register rather than a load. Small automata only — the shuffle table is the width bound.                                     |
| [`parabix/`](parabix)   | Rung. Matching as bit-parallel arithmetic: one marker bit per haystack position, a pattern step as a shift and a mask over a whole block. Nothing gathered, nothing loaded per byte; flat languages only, since star height becomes runtime iteration.                              |
| [`sieve/`](sieve)       | Rung, and the only one that cannot say yes. An over-approximating quotient of the DFA, so a survivor proves nothing and a rejection proves everything — it narrows the region the machine below has to walk.                                                                        |

`Regex` is one type to every caller (`Regex.compile`, `re.docMatch`,
`Regex.Span` …). Zig has no `usingnamespace`, so `program/core.zig` adopts each
neighbor's entry point by name — behavior lives next to the state it reasons
about, and moving a function between files never touches a call site.

Imports the shared vocabulary from `../syntax/`, `../analysis/`, `../compile/`;
the exhaustive independent-oracle differential lives in `../oracle/`.

## When to edit

DFA / Pike dispatch or the PCRE2 seam (`ladder/`), compile-time engine selection
(`program/lower.zig`), eager-vs-on-demand determinization policy (`dfa/`), the
alphabet a determinization runs over (`symbolic/`). Grammar changes →
`../syntax/`; independent correctness cases → `../oracle/`.

**A new rung goes in its own folder and is named once**, in `ladder/rungs.zig`'s
`order` table — never in `verdict.zig`, `program/core.zig`, or any caller. That
is what let five of these be built concurrently without colliding, and it is
worth preserving over the folder-count guideline the tier now exceeds.
