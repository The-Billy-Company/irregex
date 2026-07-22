The resident (warm) session now serves scoped searches it previously punted
back to the cold path: an explicit `ROOT…` path argument and `-g`/`-t`
glob/type filters. A new additive `query_ext` wire opcode carries the request's
roots, include/exclude globs, and file-type set alongside the pattern;
`request.classify` parses them into a borrowed `ScopeArgs` scratch that aliases
`argv`, the daemon admits a query only when its requested roots are a subset of
the roots it already serves (`ResidentSession.servesScope`), and prunes
candidates daemon-side through the very same `PathFilter.admits` the cold walk
uses — so a scoped warm hit is byte-identical to cold, just without the
per-query trigram-index + corpus load. Measured ~5× on `-l` against a cold
no-index walk of the same scope.
