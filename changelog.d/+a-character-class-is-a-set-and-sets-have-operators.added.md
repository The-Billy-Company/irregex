A character class parsed as a flat list of members. rust-regex parses it as a
*set expression*, and the difference is three operators and a recursion this
engine did not have: `&&` intersection, `--` difference, `~~` symmetric
difference, and a bare `[` that opens a nested class rather than standing for
itself.

The absence was not visible as an error, which is why it lasted. `[a&&b]` read
as the four members `a`, `&`, `&`, `b` - a class that matches, just not the
class you wrote. `[[x]y]` read as `{[,x}` followed by a literal `y]`. rg calls
both of those what they are: an intersection, and `error: unclosed character
class` for the unterminated `[[x]`. Now so do we, in Unicode mode and under
`(?-u)` alike.

The operators fold left-to-right at equal precedence, which is what rust-regex
actually does rather than what its documentation says (`&&` > `--` > `~~`).
`[a-e&&b-d--c]` is `{b,d}` on both engines, and it would be `{b,d}` on neither
reading if the precedence were real - forty cases spanning the operators, the
nesting, POSIX classes as operands, and both engine modes are diffed against rg
14 stdout-and-exit-code, and the parser tests carry the hand-computed sets
beside them.

One test changed rather than one being added: `core_test.zig` asserted that
`[[x]` was the two-member class `{[,x}` and attributed that reading to rg. rg
has never done that - measured 2026-08-05 against rg 14, `[[x]` is `error:
unclosed character class`. The literal is `[\[x]`.

Which is the part worth keeping. A parity test does not fail when the claim
about the competitor is wrong; it fails when we stop agreeing with a claim
nobody re-checked. That one asserted a divergence rg never had, passed green for
its whole life, and was the reason a nested class read as a member for as long
as it did. Every parity assertion here now cites the run and the date it was
measured, so the next person can tell an agreement from a story about one.
