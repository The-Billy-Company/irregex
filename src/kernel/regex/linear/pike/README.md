# linear/pike — the Pike VM

A Thompson NFA simulated in lockstep: one thread list per input position, every live state advanced by the same byte, so the work is O(states)/byte with no backtracking and no pattern that can blow up (Thompson 1968; Pike's simulation as popularized by Cox, [Regular Expression Matching Can Be Simple And Fast](https://swtch.com/~rsc/regexp/regexp1.html), 2007 — the same philosophy RE2 and ripgrep are built on).

It is not the fast path. The byte-class DFA in `../dfa/` answers at O(1)/byte and serves almost everything. The Pike VM exists for the jobs determinization cannot do.

- **Fallback.** It is the last rung under both determinization drivers: multiline programs get no DFA at all, and an on-demand cache that outgrows its cap or meets an undecidable Unicode word gap quits to this VM.
- **Oracle.** It is the proven reference the DFA's differential fuzz compares against, so `lineMatchPike` stays public for tests that must force it.
- **Positional truth.** It resolves `-U` multiline `^`/`$` per position against `\n` adjacency, decides the Unicode word boundaries the ASCII-classed DFA quits on, and walks `-o` spans directly when nothing faster proves exact first — the DFA is boolean, so spans need per-thread start offsets.

## Files

- **`scratch.zig`** owns the reusable memory: a `ThreadList` run-list and the generation-counted `seen` dedup, sized to the program once. `Sim` is the boolean grain; `SpanSim` adds start maps.
- **`closure.zig`** computes the epsilon-closure at one fixed position, where `^ $ \b \B \< \> \A \z` are decided, plus the line/buffer anchor predicates the two haystack models share.
- **`search.zig`** holds the boolean walks: one line, comptime-specialized by seeding policy (anchored, first-byte skip, plain re-seed), and `bufMatch` over a whole `-U` buffer.
- **`span.zig`** defines `Span` and `Window` (both re-exported from `../caliper/caliper.zig`, since the caliper's determinized table walk and this VM's thread walk answer the same question and must agree on its shape) and holds `matchSpan`/`matchWindow`. A pure-literal alternation resolves by SIMD substring scan and a span-exact class run by the SIMD window kernel before either engine runs; what neither reduction proves exact goes to the caliper's two determinized table walks, and only what the caliper declines — a budget verdict, never a semantic one — falls through to this file's own per-thread closure.

Callers never import these directly. `../program/core.zig` adopts `Sim`, `SpanSim`, `Span`, `Window`, `lineMatchPike`, `bufMatch`, `matchSpan`, and `matchWindow` onto the `Regex` handle.
