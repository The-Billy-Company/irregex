`commentMask` answered one bit per byte: is this commented out. That is the only question a ranker needs, and the wrong shape for a consumer that has to tell a call site apart from a name printed inside a string.

`spanMask` returns the three-way answer the lexer already computed and threw away - `code`, `comment`, or `literal` - one `Span` per byte. `commentMask` is now a projection of it, so the two cannot disagree about where a comment ends, and both walk through one shared `paint` routine instead of two copies of the state machine.

`lexspan` also joins the root test block by name. It sits a level below what `refAllDecls` analyzes, so its assertions compiled and never ran.

`blast` is the first consumer: a symbol named in a benchmark's string constant is no longer reported as code that breaks when you change it.
