`irgx_find_all(re, "x\ny")` for the pattern `\n` now reports (1,2) under the PCRE2
arm, as the linear arm and every general-purpose regex library already did. It used
to report nothing, and the two arms of one library answering a two-byte question
differently is the defect - the header promises that a buffer verb "diff[ed]
against a general-purpose regex library" agrees with it.

The cause was not in PCRE2. It was the shadow gate, the linear over-approximation
that lets the backtracking engine only ever CONFIRM candidates. The shadow is
compiled once from the same knobs PCRE2 got, and `multiline` was among them - but
`multiline` does not name a language here, it names the GRAIN the gate scans at,
and the shadow is assertion-free by construction, so there is nothing in it for
`multiline` to move. Built at line grain, the gate could not find a `\n` in
anything, because no line contains its own terminator. It then answered a whole
BUFFER question with that, and gated the arm out of a buffer plainly holding one.

It is pinned to buffer grain now instead of mirrored. A gate handed a line still
scans that line, so nothing about the line model moved; a gate handed a buffer
scans the buffer. The direction is the safe one either way - a wider gate admits
more, and admitting more is what an over-approximation is allowed to do.

Only the buffer grain was ever wrong. Per line both arms already agreed, and agreed
with ripgrep, which refuses a literal `\n` outright and whose `-P` exits 1; `-U`
and `-UP` both matched before this and still do. That is also why it hid: every
CLI path was correct, and only a host calling the ABI directly could see it. The
regression test pins all three - the buffer answer, the line refusal it must not
break, and `\r`, which is not a terminator and fails the moment the gate stops
gating at all.
