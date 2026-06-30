**T4 ranking now demotes codegen output** (`src/rank.zig`). A fourth RRF signal,
`authored`, sinks generated files (`*_grpc.pb.go`, `*_pb2.py`, `*.connect.go`, …)
below hand-written code. Found by dogfooding: `rank context.Context` returned a
head of `*_grpc.pb.go` stubs because a generated file wins *both* the lexical
signal (most occurrences) and the definition boost (its boilerplate `func (c *…)`
parses as a decl) — yet it is never an agent's edit target. The class split is
fused tie-aware (authored docs share rank 0, generated docs share rank
`n_authored`), so it is neutral *within* a class and never re-votes the
density/def order among real files; when a symbol lives only in generated files
the demotion is uniform and the def-first order is untouched. Detection mirrors
the repo shape gates (generated filename suffixes + first-line `// Code
generated` / `@generated` markers). Match sets are unchanged — the gist ≡ rg
oracle still proves 0 false negatives / 0 false positives. `rank` output gains a
`[gen]` tag.
