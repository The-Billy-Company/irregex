The literal prefilter's kernel choice was audited against the alternative nobody
measures — not arming one at all — and the cascade it was accused of being turns out
to be right for a reason its critics and its author both had wrong.

The accusation held on inspection. `scan/literal_set.zig` picks its kernel by
**needle count and nothing else**: one needle takes rare-byte `memmem`, up to 64 take
grouped Teddy, beyond that a sparse Aho-Corasick, and nothing anywhere on the path
consults the corpus byte statistics the sieve already computes. Those statistics
exist, they are described in their own header as "one fact shared by DFA
acceleration, Compose, Parabix, and Sieve", and the literal dispatcher is not one of
the sharers. So the hole is real and exactly where it looked.

`automata-rung -- sift` prices it. Each pattern is paired against documents built to
disagree — anchors saturating every position, anchors absent entirely, and a slab of
real code — then run twice, once with the literal scan in place and once with it
nulled out, so the delta is attributable to the prefilter rather than to the pattern.
A helper walks widening alternations to find where the cascade actually changes
kernels rather than trusting the constant.

Arming pays on **10 of 11 rows**, geomean **2.47-2.95x**, and **3.96-4.16x** on the
real-code documents that resemble what anyone actually searches. The single loss is
**0.18x**, on a document tiled so densely with the needle's own anchor bytes that
verification never stops running.

That loss is not gateable, which is the finding. Its two twin rows share every number
derivable from the pattern — same needles, same lengths, same rarity ranks — and want
the opposite decision, so no pattern-derived predicate can separate them; only the
document can, and the dispatcher runs before the document. Worse, the specific
statistic proposed as the gate answers "don't arm" on **9 of 11 rows**, including
rows where arming wins by 4x. It is the correct statistic for deciding whether to
skip with a byte-class kernel and the wrong one for deciding whether to verify a
nine-byte needle found from two rare anchors, because the two mechanisms fail for
unrelated reasons.

No engine behavior changes. The count-keyed cascade stays, now with a measured floor
under it and a named adverse case, and the pricing that would have replaced it is
recorded as the wrong currency rather than an untried idea.
