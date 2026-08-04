# `src/surface/` — Vocabulary, API, C-ABI

Everything a host or binding touches. Execution lives under
[`../exec/`](../exec); what remains here is the shared CLI vocabulary, the
hosted analytic Zig API, and the C-ABI substrate every package's ABI links.
Engines never import a face.

## Pieces

- **[`cli/`](cli)** is the shared vocabulary every text-facing face draws
  from: `outcome` (`die`/`oom`/the three-code exit contract), `emit` and
  `jsonstr` (NDJSON/text row framing, one JSON string escaper), `guide` (the
  stderr suggestion grammar), and `beacon` (the OSC-8 hyperlink layer that
  turns a printed path into a click).
- **[`api.zig`](api.zig)** is the hosted analytic Zig API — it drives a
  session from above, so a host embeds `Engine`/`Cursor`/`CancelToken`
  without shelling a subprocess.
- **[`ffi/`](ffi)** is the C-ABI substrate shared by every package in the
  ecosystem: `contract.zig` owns the one status and fault vocabulary
  `librelate`, `libgist`, and `libblast` all return; `rows.zig` is the
  self-describing analytic row every kinship, retrieval, sweep, and
  composed verb answers with; `answer.zig` is the shared row cursor one
  walk batches from; `pattern.zig` is the regex-over-text plane for a host
  with a pattern and a buffer but no corpus; `corpus.zig` is the warm
  corpus every analytic producer is handed plus the cancel handle any
  thread may trip; `exports.zig` is `libirgx`'s own C-ABI root, kept
  separate from `src/root.zig` so the `export fn` shims are emitted once
  rather than once per linking package; `schema.gen.zig` is generated from
  `contract/analytic.toml` and must never be hand-edited.

The three product faces (`gist`, `relate`, `blast`) — their verb tables,
`--help`, `--schema`, and NDJSON shapes — live in the sibling repos that own
each binary, not here. What they share instead is this substrate: one match
opinion, one status vocabulary, one row protocol.

## Shared Contracts

- **One match opinion.** Warm and FFI reuse cold's machinery through
  `kernel/query/query.zig`.
- **Fail open to cold.** Any warm decline falls back to the certified
  subprocess.
- **Index accelerates only.** It never changes an answer.
- **Never abort the host.** The session and every FFI entry point return
  typed errors or status codes.

## When to Edit Here

- Shared flag, emit, or outcome vocabulary belongs in `cli/`.
- The status vocabulary, row protocol, or pattern-plane C-ABI belongs in
  `ffi/`, kept in lockstep with `include/irgx.h`.
- The hosted analytic API surface belongs in `api.zig`.

Cold argv, walk, and emit, plus warm reconcile, live under
[`../exec/`](../exec). Verb dispatch, help copy, and NDJSON shapes for a
specific product face live in that product's own sibling repo.
