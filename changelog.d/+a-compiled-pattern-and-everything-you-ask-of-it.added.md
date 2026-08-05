`Pattern` is the door most callers actually wanted: compile once, then `isMatch`,
`find`, `matches`, `groups`, `replace`, `split`. It owns its own scratch through
a `Pool`, so no signature a consumer touches mentions a Pike VM thread list, and
it compiles the capture arm only if somebody asks for a group. `regex.Regex` is
still there for an index or a planner that genuinely wants the compiled program;
it just stopped being the thing you have to hold to ask a question.

The part worth reading twice is the walk. Resuming at `span.end` is right for a
match that consumed something and an infinite loop for one that did not, so a
cursor has to step past an empty match deliberately. It steps one **byte**. A
codepoint-sized step is the plausible-looking mistake, and the first draft here
made it: `l*` over `héllo` has an empty match at byte 2, the continuation byte of
`é`, and stepping a whole character quietly loses it. Python, `rust-regex` and
ripgrep all report that match. Measuring against them is what caught it; the
test that had been written asserted the bug, in confident prose.

Where the rules genuinely fork is the empty match *adjacent* to the previous one
and the one at the very end of the text, and this package now answers that twice
on purpose. `Cursor` reports both, matching Python `re`, `rust-regex` and JS.
`kernel/query`'s `walk` - what the `gist` CLI runs, and what the C ABI hands a
host's buffer to - suppresses both, matching ripgrep byte for byte. `b*` over
`abcb` is five spans through one door and three through the other. Neither is a
regression: rg drops those because it prints line-oriented rows and they are
noise on a page, and a library that dropped them would disagree with every regex
library its caller has used.

That is the kind of difference someone eventually "fixes" into a single rule,
because it reads like drift until you know which audience each side serves. So
`kernel/query/zero_width_test.zig` holds both sequences side by side, each row
carrying the outside authority it was measured against and one line saying why
that row exists. A case where the two agree is in there for the same reason as
one where they differ: it proves the fork stayed in the empty-match rule and did
not leak into ordinary matching.

Nothing in the C ABI or the three language bindings changed, and looking closely
enough to be sure was the useful half of this. `irgx_find_all` hands the buffer
to that same `walk` as one unterminated unit and returns the whole answer, and
Go, Rust and Python all iterate what it returns rather than running a
`find(from)` loop of their own. The advance rule was never written five times
out there; it was written once, on purpose, and the header in
`surface/ffi/pattern.zig` says so.
