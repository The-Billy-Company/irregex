A wire format for the finished DFA — build the table once, embed or map it, skip
determinization — was priced and will not be built as a performance feature, because
the median table in this engine is cheaper to **construct** than to **read back**.

Caching is an exchange, and the cost it *removes* is the only half usually measured.
`automata-rung -- build` already timed the half being removed: determinization alone,
min of 15, per pattern. The half being added is what a load costs, and at these sizes
that is a syscall rather than a transfer. A frozen table is row-major
`[state][class]` u32, so the widest pattern on the slate needs 6,168 bytes and an
ordinary one 864; measured on this machine, `open`+`read`+`close` of a warm file
costs **5.6 to 5.9 microseconds at best and does not care whether it is 1 KB or
25 KB** — and 11 microseconds when the machine is busy.

Put the two columns side by side and the feature inverts on half the slate. Median
build is **5.5 to 5.7 microseconds** against a best-case load floor of the same
size, so **16 to 18 of 33 patterns determinize faster than they could be read** —
23 of 33 at the contended floor. A cache that cost literally nothing to maintain,
key, or validate would still be a regression on them. The entire 33-pattern slate
determinizes end to end in about **2.05 milliseconds**.

Where it wins, it wins nothing that matters. The one pathological row — a 514-state
automaton from a 512-repetition class — builds in ~1.5 ms, which is **3.19%** of that
pattern's own 47.4 ms tree-wide query and inside its run-to-run deviation. For
ordinary patterns the share is four orders down: **0.014%** of a 40 ms query. And the
most build-heavy workload the tool can even express — 121 regexes compiled against a
zero-byte file, where scanning is free by construction — spends **0.9 ms of 7.5 ms**
on compilation, flat from 41 patterns onward, with the remainder being process
startup that no table format touches.

The structural finding is the one worth keeping. Table entries are premultiplied row
offsets indexed directly, and the transition rows are deliberately **not total** —
both properties are load-bearing for the engine's fastest inner loop. Together they
mean a table read from disk is an unvalidated array of raw offsets, so a trustworthy
loader must bounds-check every entry while preserving all-or-nothing row filling:
a sweep over states times classes, **the same order as the determinization it was
meant to avoid**. The honest load cost is therefore strictly worse than the floor it
already loses to.

The format keeps its case as a *feature* — an embedder that ships a fixed pattern set
with no parser is a real request, and none of this touches it. What is settled is that
such a format may never be sold as speed, and may never soften the premultiplied
non-total layout to make serialization convenient: that trade would spend a measured
1.10-1.16x on the hot loop to save a median 5.6 microseconds of construction.

Nothing in the shipped engine changed. This is measurement, and it says which half of
a cache to measure first.
