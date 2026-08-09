The Go module named 38 of the C ABI's 100 symbols, and the 62 it did not name
were not corners - they were five whole planes. A Go host could match a pattern
against a `[]byte` it already held, and could not ask which files a search may
read, search a corpus, narrow one so most files are never opened, index a text it
then throws away, or read the line grid and the literal promises the engine
derives for itself. Every one of those questions was already exported; only Go
could not ask them.

All 62 are bound now, one file per plane: `tree.go` (a warm engine over roots,
searched under a `context.Context`), `walk.go` (the eligible set as a question
instead of a side effect), `sieve.go` (the persisted narrowing tier plus a
pattern's plan), `codex.go` (the FM-index, including the backward-search interval
driven by hand), `lines.go`, `literals.go`, `needles.go`. Iteration crosses the
cgo boundary once per batch rather than once per record, because a cgo call costs
about a hundred Go calls and a corpus search reports thousands of rows; every
string, path and span is copied into Go memory at the boundary, so a result
outlives the handle it came from and a finalizer can never free memory a live
slice still aliases. A stale index and an unbuilt locate layer come back as
`(value, ok)` rather than as errors, because neither is a fault - one is the index
declining to answer, the other a structure nobody asked to build.

Three doors `regexp` has and this package did not come along with them, now that
the engine holds the facts they need: `QuoteMeta`, `LiteralPrefix` read out of the
pattern's own literal plane rather than re-derived, and the
`encoding.TextMarshaler` pair so a `*Regexp` is a field type in a config file. An
option with no inline spelling refuses to marshal instead of silently
downgrading; a case-insensitive pattern that reads correctly in a config and
matches case-sensitively at runtime is the failure a config file is least able to
explain.
