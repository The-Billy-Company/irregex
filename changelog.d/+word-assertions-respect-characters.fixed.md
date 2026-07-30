`\B` no longer matches inside a character. Over the line `a—b` it reported two
matches, at the gaps between the em dash's three bytes; rg reports none, and rg
is right — those offsets are not positions in the text.

The cause is that "is the character before me a word character?" answers *false*
for a comma and for half of `é` alike, and an assertion that fires on silence
cannot tell the two apart. Every such assertion — `\B` and the two new halves,
which are exactly the masks admitting the all-quiet pair — now also asks whether
each side it reads is a whole character. `\b`, `\<`, and `\>` need no guard and
pay for none: firing requires a word character on some side, and a word
character is a whole one. Under `(?-u)` no decode is attempted at all, so the
ASCII path is untouched.

Both determinized engines quit rather than represent the new case, which is the
strategy the byte-class DFA already used for Unicode word context: the caliper
now declines a line at the first gap that splits a character and hands it to the
Pike VM. 960 comparisons against rg across six output modes — valid multi-byte
text, combining marks, CJK, Cyrillic, and invalid UTF-8 — now agree exactly.
