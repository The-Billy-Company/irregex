---
doc_radar:
  sentinels:
    - description: "the oracle is independent — it cross-checks the engine against a reference the engine does not share"
      file: src/kernel/regex/oracle/adversarial_test.zig
      contains: ["ADVERSARIAL"]
---

# kernel/regex/oracle — independent differential oracle

The correctness backstop the in-family fuzz can't provide. `../linear/dfa/dfa_test.zig`
checks the DFA against the Pike VM — but the Pike VM is its own reference, so a
bug **shared** by both survives. This tier cross-checks gist's engine against an
_independent_ oracle (and, for Unicode, against `rg`'s default semantics), so a
mistake would have to be replicated in two unrelated implementations to escape.

| File                   | Role                                                                                                                                                                                                               |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `adversarial_test.zig` | Adversarial differential tests against an independent oracle: pattern/haystack generators tuned for anchors, alternation covers, Unicode folding, and prefilter edge cases — plus brute-force prefilter soundness. |

Imports the engine under test folder-relative (`../linear/program/core.zig`,
`../syntax/syntax.zig`, `../analysis/prefilter.zig`, `../unicode/decode.zig`).

## Where the accelerator rungs' correctness bottoms out — here

Each rung under `../linear/` ships its own differential (compose 350,200 cases,
symbolic 419,250, parabix ~23,000, one-pass 16,320), and every one of them uses
the **Pike VM** as its oracle. That is the right check for a rung — it proves
the fast path answers what the slow path answers — but it is by construction the
in-family check this folder exists to backstop: a mistake in the shared parser,
the shared lowering, or the Pike VM itself would be invisible to all of them at
once. So the rungs multiply the ways a pattern can be answered without
multiplying the ways it can be checked, and the independent oracle is what keeps
that from being a net loss. Adding a rung is therefore a reason to run these
cases harder, not a reason to trust the pyramid because it grew.

## When to edit

New adversarial generators, Unicode folding edges, or prefilter soundness
cases — especially after a shipped bug the in-family DFA↔Pike fuzz missed.
Never teach the oracle the engine's lowering; independence is the point.
