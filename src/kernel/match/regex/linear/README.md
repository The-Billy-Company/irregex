---
doc_radar:
  sentinels:
    - description: "the public Regex handle owns the state and adopts its behavior from the neighbors by name"
      file: pkg/kernels/irregex/src/kernel/match/regex/linear/program/core.zig
      contains:
        ["pub const Regex", "pub const lineMatch = verdict.lineMatch", "pub const matchSpan = span.matchSpan"]
    - description: "the boolean engine ladder (classrun → DFA → Pike) lives in ladder/verdict.zig"
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

Four folders, read as one sentence: **`program/`** is what a pattern becomes,
**`ladder/`** decides who answers a question about it, and **`pike/`** / **`dfa/`**
are the two machines that can.

| Folder                | Role                                                                                                                                                                             |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`program/`](program) | The compiled artifact and its constructor: the public `Regex` handle (immutable state, `deinit`, program-walk predicates) and the compile pipeline that fills it.                |
| [`ladder/`](ladder)   | Engine selection at both grains: which backend (`Matcher` — linear or PCRE2) and, inside the linear arm, which rung answers a boolean question (`verdict` — classrun/DFA/Pike).  |
| [`pike/`](pike)       | The Pike VM: reusable scratch, the epsilon-closure that resolves every zero-width assertion, the comptime-specialized boolean walks, and the `-o` leftmost-first span walk.      |
| [`dfa/`](dfa)         | The determinized primary: the immutable, scratch-free byte-class DFA and the powerset construction that builds it (or declines past `max_states`, leaving the Pike VM to serve). |

`Regex` is one type to every caller (`Regex.compile`, `re.docMatch`,
`Regex.Span` …). Zig has no `usingnamespace`, so `program/core.zig` adopts each
neighbor's entry point by name — behavior lives next to the state it reasons
about, and moving a function between files never touches a call site.

Imports the shared vocabulary from `../syntax/`, `../analysis/`, `../compile/`;
the exhaustive independent-oracle differential lives in `../oracle/`.

## When to edit

DFA / Pike dispatch or the PCRE2 seam (`ladder/`), compile-time engine selection
(`program/lower.zig`), powerset `max_states` policy (`dfa/`). Grammar changes →
`../syntax/`; independent correctness cases → `../oracle/`.
