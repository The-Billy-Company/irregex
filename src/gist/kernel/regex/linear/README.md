---
doc_radar:
  sentinels:
    - description: "the public Regex handle + its DFA-primary / Pike-fallback dispatch live here"
      file: pkg/kernels/irregex/src/gist/kernel/regex/linear/core.zig
      contains: ["pub const Regex", "pub fn lineMatch", "pub fn docMatch"]
    - description: "the engine-neutral seam forwards to the linear arm or the PCRE2 backend"
      file: pkg/kernels/irregex/src/gist/kernel/regex/linear/matcher.zig
      contains: ["pub const Matcher"]
---

# gist/kernel/regex/linear — the linear-time execution engine

The **back of the pipeline**: the RE2/ripgrep-philosophy engine that actually
runs a compiled pattern over bytes — no backtracking, no catastrophic blowup.
The byte-class DFA is the primary O(1)/byte engine; the Pike VM is the capped
fallback and the differential-fuzz correctness reference.

| File | Role |
| --- | --- |
| `core.zig` | Public `Regex` handle: `compile` orchestration, the Pike VM (`Sim` scratch, epsilon-closure, comptime-specialized search), and `lineMatch`/`docMatch` dispatch (DFA primary, Pike fallback). One engine state kept whole (`MONOLITHIC`). |
| `dfa.zig` | The immutable, scratch-free byte-class DFA (`match` / `docMatch`) — one table lookup per byte, whole-document in a single fused pass that detects newlines inline. |
| `powerset.zig` | Powerset (subset) construction: eagerly determinizes the Thompson NFA into the immutable `dfa.zig` `Dfa`, or null on `max_states` blow-up (Pike fallback). |
| `matcher.zig` | The engine-neutral `Matcher` seam: forwards to the linear `Regex` default or the opt-in PCRE2 `Pcre` backend, so callers select an engine without branching on backend. |
| `core_test.zig` | Parser / Pike VM / prefilter / scan-accelerator cases. |
| `dfa_test.zig` | DFA unit cases + differential fuzz against the Pike VM. |
| `powerset_test.zig` | Determinizer structural invariants + exhaustive language equivalence vs a from-scratch NFA spec. |

Imports the shared vocabulary from `../syntax/`, `../analysis/`, `../compile/`;
the exhaustive independent-oracle differential lives in `../oracle/`.
