Ladder admission moved from boolean gates to **costed offers**: every decider
that can represent the pattern is built, each prices itself as an `Offer`
(compile + per-byte scan cost), and exactly one is kept — they are alternatives,
not a pipeline. The DFA fallback is an offer too, priced from the prefilter's
expected stride (`analysis/prefilter.zig`'s `Economics`), so a rung can lose to a
start-skip instead of merely standing down beside one; the sieve, which narrows
without deciding, is offered the winner's per-byte cost and applies its own
survival inequality against it.

This is what lets Parabix and the SP-quotient sieve arm on their populations
where the old order-and-boolean gates never reached them, and lets an
unprofitable candidate decline at _compile_ time rather than arm into a loss —
proven on the lane slate, where the sieve gate declines 6 of 9 patterns as
`unprofitable` and the Parabix rung stands down on star-height-2 and codepoint
classes while arming on the assertion populations composition cannot serve.
