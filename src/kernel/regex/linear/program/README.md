# linear/program — what a pattern becomes

The **compiled artifact and the pipeline that produces it**. Everything here is
about a `Regex` at rest: the immutable state a match reads, and the one-time
compile that decides what that state contains.

Nothing in this folder scans a haystack. Answering questions is `../ladder/`'s
job; executing them is `../pike/` and `../dfa/`.

| File            | Role                                                                                                                                                                                                                                                                                                                                                                                                                          |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `core.zig`      | The public `Regex` handle: the immutable compiled state with its field-by-field contract, `deinit`, the program-walk predicates (`claimsNewline` / `bansByte`), and the decls adopted from every neighbor.                                                                                                                                                                                                                    |
| `lower.zig`     | Compilation: parse → case-fold → Thompson lowering → the accelerator analyses (required literal, alternation cover, pure literals, first set, zero-width reachability) → which engines to build. That last step now decides three things, not one: which determinizer runs (`../symbolic/` or the byte powerset), whether its result is eager or on demand, and which optional rungs `../ladder/rungs.zig` can offer over it. |
| `core_test.zig` | Parser / Pike VM / prefilter / scan-accelerator cases.                                                                                                                                                                                                                                                                                                                                                                        |
| `chorus.zig`    | The same pipeline for MANY patterns: N patterns lowered into one program whose N terminals sit at indices `0..N-1`, determinized once, walked once. Yields `(end, patterns)` pairs, which is simultaneously attribution, overlapping search, and end-only (HalfMatch) search. Declines to null rather than guessing, so every caller keeps a fallback.                                                                          |
| `chorus_test.zig` | The three tiers, plus the differential that holds one chorus walk against N standalone engines.                                                                                                                                                                                                                                                                                                                             |
| `munch.zig`     | The same slate **anchored**, asking the lexer's question instead of the search one: starting at exactly this offset, which pattern reaches furthest? Any number of patterns (it holds as many automata as the 64-bit attribution masks need), a slate admitted by bisection so one unusable pattern is named in `declined` rather than costing the other hundred and fifty, every tie reported because the tie-break belongs to the grammar, and a per-call `Allow` so a state-directed lexer can ask for the longest match *among the terminals it will accept*. `longest` neither allocates nor fails. |
| `munch_test.zig` | Anchoring is real (`abc` does not match `xabc` at zero), partial admission names the right ordinals, a narrowed slate is provably not a filtered answer, and the differential holding one slate against N whole-span engines at every offset.                                                                                                                                                                                  |

## Why the handle and its constructor sit together

The field contract in `core.zig` and the code that establishes it in `lower.zig`
are one invariant read twice — every field's doc comment names the analysis that
fills it, and `deinit` is the other half of the ownership `lower` takes on. They
change together or the handle lies.

The adopted-decl block in `core.zig` is what keeps that split invisible: Zig has
no `usingnamespace`, so each neighbor's entry point is bound by name and callers
still see one type (`Regex.compile`, `re.docMatch`, `Regex.Span` …).
