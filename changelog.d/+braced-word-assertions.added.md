`\b{start}`, `\b{end}`, `\b{start-half}`, and `\b{end-half}` now parse and run,
so the four spellings rust-regex added are no longer a reason to reach for
another tool. The first two are the names `\<` and `\>` already had. The halves
are genuinely new: each constrains one side of the gap and says nothing about
the other, which is what you want when the thing on the far side is the match
itself rather than a word — `\b{start-half}foo` finds a `foo` nothing wordy runs
into, whether or not `foo` starts with a word character.

Adding them collapsed the family rather than growing it. All six word
assertions ask one question about two neighbors, so there is now one AST node
and one NFA state carrying a four-bit mask — a bit per (before, after) pair —
where there used to be a node and a state per spelling. Every engine evaluates
any of them with a shift and a test, the one-pass builder intersects two masks
on an ε-path and sees `\B\<` collapse to the empty mask at build time instead of
re-deciding it per byte, and a seventh spelling would be a table row rather than
a case in nine switches.
