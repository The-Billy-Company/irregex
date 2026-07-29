The regex syntax plane is six files instead of one, and `syntax.zig` is now a
front door: one `pub const` per exported name. Nothing outside the folder
changed - the same `@import("../syntax/syntax.zig")` still answers `syn.Node`,
`syn.Parser`, `syn.State`, `syn.ByteSet`, `syn.Word`, `syn.foldCaseAst` - so this
is invisible to every consumer and to the compiled output.

The cut follows the grammar's own layering rather than file size, which is why
each file only depends on the ones above it. `tree.zig` is what a parsed pattern
*is* (the byte class, the AST node, the NFA instruction, the one error set);
`assertion.zig` is the word-assertion truth table and its algebra, with zero
imports, so every engine arm can share it; `scalars.zig` holds the Unicode range
accumulator that no node ever carries plus the `-i` fold that rewrites a finished
tree; `escape.zig` is what a backslash denotes, beside the POSIX tables `\d` is
defined against; `bracket.zig` is what a `[...]` body denotes in both modes; and
`parser.zig` keeps the cursor and only the four mutually-recursive grammar levels,
so it reads as the shape of the grammar instead of the shape of the syntax.

The `MONOLITHIC` marker is gone with it, since the reason it existed - the class,
AST, and instruction invariants being co-maintained - turned out to name one file
(`tree.zig`), not the whole plane. Functions moved as-is; the compiled `.text`
segment differs by 48 bytes across the three binaries, which is the embedded
source-location strings changing length, and the test suite is unchanged.
