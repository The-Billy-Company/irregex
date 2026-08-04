# `facet/` — The Four Faces One Warm Answer Can Wear

Each module here takes the candidate documents
[`../answer/gather.zig`](../answer/gather.zig) produced and turns them into
one shape: a set, a count, finished bytes, or a record stream.

They are siblings rather than one switch because they differ in what they
*accumulate*, not in how they walk — the walk is shared, which is why no two
faces can prune differently or disagree about which document is live.

## Modules

- **[`fold.zig`](fold.zig)** answers as a set or a count. It is the fold
  face — a **set** of paths (`-l`) or a **count** of matching lines (`-c`),
  sharded over cores above the parallel floor. `-v` is answered as the
  set-complement `lines(f) − matching(f)` so the trigram index stays sound
  and only candidate files run the matcher.
- **[`present.zig`](present.zig)** answers as finished bytes. It holds the
  rendered faces: the default `path:text` line search, its shared-memory
  sibling above the transport floor (same bytes, different carrier), and the
  gist-native definition-first `--rank` view.
- **[`stream.zig`](stream.zig)** answers as records. It holds the per-line
  faces: the in-process FFI's `MatchRecord` stream (rg's line model,
  `-A`/`-B`/`-C` context windows, the `-m` cap, parallel shards reassembled
  in doc order) and the early-halting `-q` existence probe that stops at the
  first admitted match. It owns `LineWalk`, the single line-splitting
  authority.
- **[`render.zig`](render.zig)** answers as the byte frame. It is the warm
  `lines` renderer: the default `path:text` / `-n` `path:line:text` frame,
  produced through the cold engine's **own** `Emitter` and
  `binary.handleBinary` — byte-parity by construction, never a re-derived
  formatter. It is also home to `fanRender` and the `par_min_bytes` floor:
  above it, every warm face shards its scan over cores through the one
  shared `kernel/math/parallel.zig` primitive, byte-identical to the serial
  core below it.

`render_test.zig` sits beside its subject.

## Nothing Here Invents a Format

`present.zig` formats nothing itself: it gathers warm documents and hands
them to a renderer the **cold** path owns — `render.zig` (which drives the
cold engine's own `Emitter`) for the default presentation, `ranked.renderLive`
for `--rank`.

So byte-parity with a piped cold run is a property of construction rather
than of a second formatter that could drift from the first.

## One Line Model, Counted Once

`\n` **terminates** a line — a body ending in `\n` has no phantom final
line.

The `-q` probe, the record stream, the context planner, and
`corpus.gatedLineCount` all count that same split through `LineWalk`, so
none of them can drift from the others by re-deriving the walk locally.
