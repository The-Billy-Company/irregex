---
doc_radar:
  sentinels:
    - description: "the oracle is independent — it cross-checks the engine against a reference the engine does not share"
      file: pkg/kernels/irregex/src/kernel/match/regex/oracle/adversarial_test.zig
      contains: ["ADVERSARIAL"]
---

# search/match/regex/oracle — independent differential oracle

The correctness backstop the in-family fuzz can't provide. `../linear/dfa_test.zig`
checks the DFA against the Pike VM — but the Pike VM is its own reference, so a
bug **shared** by both survives. This tier cross-checks gist's engine against an
_independent_ oracle (and, for Unicode, against `rg`'s default semantics), so a
mistake would have to be replicated in two unrelated implementations to escape.

| File                   | Role                                                                                                                                                                                                               |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `adversarial_test.zig` | Adversarial differential tests against an independent oracle: pattern/haystack generators tuned for anchors, alternation covers, Unicode folding, and prefilter edge cases — plus brute-force prefilter soundness. |

Imports the engine under test folder-relative (`../linear/core.zig`,
`../syntax/syntax.zig`, `../analysis/prefilter.zig`, `../unicode/decode.zig`).

## When to edit

New adversarial generators, Unicode folding edges, or prefilter soundness
cases — especially after a shipped bug the in-family DFA↔Pike fuzz missed.
Never teach the oracle the engine's lowering; independence is the point.
