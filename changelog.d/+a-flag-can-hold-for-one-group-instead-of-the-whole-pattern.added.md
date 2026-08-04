`(?i:…)`, `(?s:…)`, `(?u:…)` and `(?-u:…)` parse. The flags hold for the group's body and are put back at its closing paren, so the rest of the pattern is unaffected.

This is not a corner of the syntax. Generated lexer slates are full of it: a language whose keywords are case-insensitive spells every one of them `(?i:…)`, and a generator that emits per-token Unicode mode wraps each token body in `(?u:…)`. Across thirty tree-sitter grammars pressed into slates, 114 of 115 refused patterns refused on this one construct, 87 of them in a single grammar.

A scoped `i` folds its own subtree at the closing paren rather than waiting for the caller's whole-tree fold, which never runs when the caller did not ask for `-i`. Without that the pattern would parse and then match case-sensitively, which is worse than refusing.

`m` and `x` refuse, and so does a bare `(?flags)`. This engine's `multiline` is whole-buffer matching rather than JavaScript's line-anchored `^`, `x` is not implemented, and a bare group's flags scope to the end of the enclosing group. Each of those is a wrong answer available cheaply; a refusal says so.

`Munch` now says why it turned a pattern down. `declined` carries the ordinals and the new `because` carries a `Munch.Because` for each - `syntax`, `states`, or `word_context` - so a caller can tell a pattern this engine cannot express from one it merely would not build.
