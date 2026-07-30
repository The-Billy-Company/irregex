---
doc_radar:
  sentinels:
    - description: "every zero-width assertion is resolved in one place, against one position's flags"
      file: pkg/kernels/irregex/src/kernel/regex/linear/pike/closure.zig
      contains: [".assert_word", ".assert_buf_start", "pub fn closureBuf", "sides: syn.Sides"]
    - description: "the boolean walk keeps its three comptime seeding policies"
      file: pkg/kernels/irregex/src/kernel/regex/linear/pike/search.zig
      contains: ["const Scan = enum { anchored, skip, plain }", "pub fn bufMatch"]
---

# linear/pike — the Pike VM

A **Thompson NFA simulated in lockstep**: one thread list per input position,
every live state advanced by the same byte, so the work is O(states)/byte with
no backtracking and no pattern that can blow up (Thompson 1968; Pike's
simulation as popularized by Cox, [_Regular Expression Matching Can Be Simple
And Fast_](https://swtch.com/~rsc/regexp/regexp1.html), 2007 — the same
philosophy RE2 and ripgrep are built on).

It is **not** the fast path. The byte-class DFA in `../dfa/` answers at
O(1)/byte and serves almost everything. The Pike VM exists for the three jobs
determinization cannot do:

- **Fallback** — the last rung under both determinization drivers: multiline
  programs get no DFA at all, and an on-demand cache that outgrows its cap or
  meets an undecidable Unicode word gap quits to this VM.
- **Oracle** — it is the proven reference the DFA's differential fuzz compares
  against, so `lineMatchPike` stays public for tests that must force it.
- **Positional truth** — `-U` multiline `^`/`$` (resolved per position against
  `\n` adjacency), Unicode word boundaries the ASCII-classed DFA quits on, and
  `-o` spans (the DFA is boolean; spans need per-thread start offsets).

| File          | Role                                                                                                                                                                    |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `scratch.zig` | The reusable memory: a `ThreadList` run-list and the generation-counted `seen` dedup, sized to the program once. `Sim` is the boolean grain; `SpanSim` adds start maps. |
| `closure.zig` | The epsilon-closure at one fixed position — where `^ $ \b \B \< \> \A \z` are decided — plus the line/buffer anchor predicates the two haystack models share.           |
| `search.zig`  | The boolean walks: one line, comptime-specialized by seeding policy (anchored · first-byte skip · plain re-seed), and `bufMatch` over a whole `-U` buffer.              |
| `span.zig`    | `-o` leftmost-first spans, with the SIMD pure-literal and span-exact class-run reductions that pre-empt the VM when they are provably exact.                            |

Callers never import these directly: `../program/core.zig` adopts `Sim`,
`SpanSim`, `Span`, `lineMatchPike`, `bufMatch`, and `matchSpan` onto the `Regex`
handle.
