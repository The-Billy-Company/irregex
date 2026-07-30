A boolean document scan (`gist -l`, and the compiled-query path the resident
session and the FFI share) no longer crosses the buffer twice. When a pattern has
a mandatory literal, the ladder already scanned for it — and then threw away
*where* it was, so the slowest machine in the ladder restarted from byte zero to
rediscover a position the SIMD kernel had already had. `presence` is literally
`findRaw(hay, 0) != null`; the offset was free and discarded.

`docMatch` now calls `find` and hands the machines below it the suffix beginning
at the line that holds that occurrence. It is sound for exactly the reason the
per-line model exists: no match crosses `\n`, and every match contains the
mandatory literal, so a line lying entirely before the literal's first occurrence
cannot match. Finding the seam is one `lastIndexOfScalar` bounded by a line, so it
costs a line's worth of work however large the buffer, and `-U` — the one model
where a match may cross `\n` and the offset proves nothing about a start — enters
through `bufMatch` and is guarded out explicitly.

**16.30× geomean over 30 (pattern × match-position) pairs** on 2 MiB documents,
28–37× on the eight slate rows with an interior literal and a late match
(`[0-9a-f]{8}-…-[0-9a-f]{12}` 35.51×, `\w+X` 29.92×, `a.*b.*c` 28.08×). End to
end against the incumbent on this repository, best of 5 with byte-identical file
sets: `\w+X` 206 ms vs ripgrep's 386 ms, `[a-z]+_[a-z]+_[a-z]+` 209 vs 453,
`if\s+err\s*!=\s*nil` 212 vs 347, `\w+\.\w+\(` 224 vs 585.

The controls are why this is a free mechanism rather than a trade. Two slate rows
read **1.00×**: their match-free fill can itself spell the literal, so the first
occurrence is at lead 0%, the suffix is the whole buffer, and they save exactly
nothing while costing exactly nothing. A new adverse arm makes that a measurement
instead of an argument — the same documents with no match spliced at all, so every
row rejects and the seam can only cost: **worst 0.98×**, the instrument's noise.
It also fails the run if a suffix ever reports a match the whole buffer does not
hold, which is the one way this could be wrong rather than slow.

`automata-rung -- inner` carries the audit that scoped it. Of 33 rows, 25 prove a
mandatory literal the engine already searches for, 11 of those are *interior* and
so beyond a first-byte skip's reach, and where both strides are comparable the
literal skips 6.9× further than the first-byte set. Only 3 rows could bound a
confirmation *window* — an interior literal and a finite longest match — which is
why this ships as a line seam and not as the reverse automaton the field builds
for the same claim: `inf` is the ordinary case, so there is no window to confirm
inside. Span queries are unchanged; the caliper's reverse jaw already answers
those.
