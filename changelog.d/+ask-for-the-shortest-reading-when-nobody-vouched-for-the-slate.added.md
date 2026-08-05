`Munch.shortestAmong` - the shortest non-empty match at an offset, beside the
longest one that was already there.

Maximal munch answers "which token is here" only when something vouched for the
slate. Asked over every pattern a grammar has, it answers something else: such a
slate always contains a run-of-anything-but-a-delimiter, and that member reaches
further than every real token at every byte. The result is a fact about the
grammar's widest regex rather than about the bytes - measured on outliner's wall
survey, the median such answer was **1,777 bytes long**, and one of them named
`xml_text` over a scala file containing no XML.

So a caller with no state behind the question can now ask for the least the
slate can commit to instead. The walk backing it stops at the first accept
rather than the last, which makes it the cheaper of the two as well as the
narrower; empty matches are passed over, since a nullable pattern would
otherwise name every position at length zero.

`longest` and `longestAmong` are untouched, and the shared `scan` takes the mode
as a comptime-known enum, so neither pays for the other.
