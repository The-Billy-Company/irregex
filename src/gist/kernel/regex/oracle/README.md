---
doc_radar:
  sentinels:
    - description: "the oracle is independent — it cross-checks the engine against a reference the engine does not share"
      file: pkg/kernels/irregex/src/gist/kernel/regex/oracle/adversarial_test.zig
      contains: ["ADVERSARIAL"]
---

# gist/kernel/regex/oracle — independent differential oracle

The correctness backstop the in-family fuzz can't provide. `../linear/dfa_test.zig`
checks the DFA against the Pike VM — but the Pike VM is its own reference, so a
bug **shared** by both survives. This tier cross-checks gist's engine against an
*independent* oracle (and, for Unicode, against `rg`'s default semantics), so a
mistake would have to be replicated in two unrelated implementations to escape.

| File | Role |
| --- | --- |
| `adversarial_test.zig` | Adversarial differential tests against an independent oracle: pattern/haystack generators tuned for anchors, alternation covers, Unicode folding, and prefilter edge cases — plus brute-force prefilter soundness. |

Imports the engine under test folder-relative (`../linear/core.zig`,
`../syntax/syntax.zig`, `../analysis/prefilter.zig`, `../unicode/decode.zig`).
