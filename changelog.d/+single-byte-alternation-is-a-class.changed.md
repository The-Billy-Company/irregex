An alternation whose every branch consumes exactly one byte now lowers to **one**
`consume` state over the union rather than to N consumes behind N−1 splits.
`(a|b|c|d|e|f|g|h)` is a byte class written the long way, and the Thompson
construction was taking it literally: `ast/algebra.zig` had always known this, but
on a graph the compiler deliberately does not read, because interning
re-associates the alternation spine and re-association is not leftmost-first-safe.
So the fold lands at the Thompson seam itself (`compile.zig::oneByteUnion`),
without re-bracketing anything.

For `(a|b|c|d|e|f|g|h){10}`: **151 → 11** NFA states, **9 → 2** byte classes,
**792 → 176** table bytes, and determinization **56.9 µs → 3.6 µs (15.8×)**. For
`(a|b)*a(a|b){5}` and its 8-fold cousin: 21 → 9 and 30 → 12 NFA states, 1.40× and
1.52× faster determinization, with DFA state count, accept count, and table bytes
**byte-identical** — the language and the alphabet are unchanged there, so the win
is purely a narrower closure per determinization step.

It also closes a loose end rather than just adding a win. The table-reduction pass
had one everyday-slate row where a post-hoc column merge still found redundancy,
recorded as a suspected front-end artifact; that row now arrives minimal and the
**ASCII column collapse went from 1/32 rows to 0/32**, which upgrades the
suspicion to a result. The 4.5× of table came with a 15.8× faster build instead of
costing 2% of a determinization already paid in full.

**Why it is safe where re-associating an alternation is not.** Leftmost-first
selection depends on branch order only when two branches reach the same start with
different ends. When every branch consumes one byte to the same continuation, each
branch's thread arrives at the identical (state, position) pair — which the Pike VM
already dedupes — so the surviving thread is the same one whichever branch had
priority. The fold therefore declines, by construction, everything that could
observe order: `.concat` and `.uclass` (more than one byte), `.empty` and the
assertions (none), and every quantifier (a variable count). `a|ab ⇒ a` is
unaffected because `ab` is a concat, and the capture VM has its own alternation
lowering, so no group boundary is reachable from here.

Judged by two new structural tests (confirmed load-bearing by deliberately
breaking them), the full suite including the Pike-vs-DFA differential fuzz and the
independent adversarial oracle, identical ripgrep file sets on ten alternation
patterns tree-wide, byte-identical `-o` streams per file, and 6/6 on the order
probes that are the real hazard: `a|ab ⇒ a`, `ab|a ⇒ ab`, `e|er|err ⇒ e`,
`err|er|e ⇒ err`. `(?:foo|bar|baz|qux|quux|corge){8}` is the untouched control —
concat branches, so 209 states and 163 µs before and after.
