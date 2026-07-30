`argv` is now a five-module package behind one facade: `args.zig` re-exports the
interface the tree's thirty-odd importers see, while `verdict` / `intent` /
`catalog` / `grammar` own value parsing, the request record and its builder, the
declarative `flag_catalog`, and the argv walk. Adding a flag is usually one
catalog row plus one `Opts` field, and the inside can be re-cut without a
call-site edit.

`die` / `oom` moved to `cli/outcome.zig`, beside the other ways a face ends —
which also collapses the second OOM emitter the corpus layer kept in step by
hand, and removes the layering inversion where `corpus/` reached up into the
CLI's flag module to exit.

A braced `-g '{a,b}'` glob no longer answers wrong on the warm resident path.
The session's own argv classifier cannot expand an alternation, so it now
declines one to cold — which expands it — instead of pushing the raw pattern
into a flat filter that matched nothing.
