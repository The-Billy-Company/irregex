# kernel/regex/oracle — independent differential oracle

This is the correctness backstop the in-family fuzz cannot provide. `../linear/dfa/dfa_test.zig` checks the DFA against the Pike VM, but the Pike VM is its own reference, so a bug shared by both survives. This tier cross-checks gist's engine against an *independent* oracle, and, for Unicode, against `rg`'s default semantics, so a mistake would have to be replicated in two unrelated implementations to escape.

## Files

- **`adversarial_test.zig`** holds adversarial differential tests against an independent oracle: pattern/haystack generators tuned for anchors, alternation covers, Unicode folding, and prefilter edge cases, plus brute-force prefilter soundness. Each generator asserts a minimum case-count floor rather than a fixed total, so a run that silently generated too few cases fails loudly instead of passing quietly.

This file imports the engine under test folder-relative: `../linear/program/core.zig`, `../syntax/syntax.zig`, `../analysis/prefilter.zig`, and `../unicode/decode.zig`.

## Where The Accelerator Rungs' Correctness Bottoms Out

Each rung under `../linear/` ships its own large differential suite, and every one of them uses the Pike VM as its oracle. Compose's own suite alone asserts a floor of 225,000 line-grain and 110,000 document-grain cases with zero divergences (`shuffle_test.zig`), and the other rungs are the same shape at their own scale — a minimum the generator must clear, not a fixed total, so a silent drop in coverage fails the build instead of passing quietly.

That is the right check for a rung — it proves the fast path answers what the slow path answers — but it is by construction the in-family check this folder exists to backstop: a mistake in the shared parser, the shared lowering, or the Pike VM itself would be invisible to all of them at once.

So the rungs multiply the ways a pattern can be answered without multiplying the ways it can be checked, and the independent oracle is what keeps that from being a net loss. Adding a rung is therefore a reason to run these cases harder, not a reason to trust the pyramid because it grew.

## When To Edit

Edit here for new adversarial generators, Unicode folding edges, or prefilter soundness cases, especially after a shipped bug the in-family DFA-versus-Pike fuzz missed. Never teach the oracle the engine's lowering; independence is the point.
