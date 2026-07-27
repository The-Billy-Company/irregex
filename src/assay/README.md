<!-- doc_radar:
paths_exist:
  - pkg/kernels/irregex/src/assay/span.zig
  - pkg/kernels/irregex/src/assay/tally.zig
  - pkg/kernels/irregex/src/assay/channel.zig
  - pkg/kernels/irregex/src/assay/assay.zig
sentinels:
  - file: pkg/kernels/irregex/src/assay/channel.zig
    contains: ["GIST_TRACE", "pub const Lens", "pub const Sink", "pub const Chatter"]
-->

# `src/assay/` — the instrumentation floor (time · count · debug)

An _assay_ is a precise measurement of composition. This is the one module the
whole package reaches for when it needs to **time**, **count**, or **report** —
so those three concerns speak a single, deliberately-shaped vocabulary instead
of the ~90 hand-rolled `std.debug.print` calls, ~25 open-coded `nowNs`/`ms`
pairs, and several near-duplicate tally structs that used to be scattered across
`kernel/`, `corpus/`, and `surface/`.

It sits at the **bottom of the package DAG** — it imports only `std` — so every
layer above can consume it without inversion. `assay.zig` is the small facade
(`const assay = @import(".../assay/assay.zig")`); the three engines behind it are
one file each.

| File          | Owns                                                                                                                                                                                                                                                                                                                                                            |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `span.zig`    | **Time**, with the two clocks made non-interchangeable: `Span`/`Duration` ride the monotonic-awake clock (the only thing that renders as `ms`), `Anchor` rides the wall clock (the only freshness stamp `writeAnchor` accepts). A monotonic reading can no longer masquerade as a build anchor, and a duration can no longer be computed across the wall clock. |
| `tally.zig`   | **Counters**: `Tally(Schema)`, one comptime-checked counter set indexed by an enum of field names, with an allocation-free vector `fold` for the parallel engine's per-worker → run merge. One mechanism, reused per distinct output schema.                                                                                                                    |
| `channel.zig` | **Diagnostics**: the `GIST_*` env vocabulary (`envSpan`/`envFalsy`/`envUsize`/`envFlag`), the `GIST_TRACE` **lens** gate (one list replacing four bare-presence `*_TRACE` vars), the `Chatter` **muffle** gate behind `--no-messages`, and the thread-local **sink** every diagnostic routes through.                                                           |
| `assay.zig`   | The facade + `Run`: opens a `Span` and emits one summary line that is byte-identical to the former `debug.print` in text mode, or a single NDJSON record in `--json` mode.                                                                                                                                                                                      |

## Why the sink is thread-local

The sink is the seam that makes two properties true _by construction_ rather
than by auditing every call site:

- **The C-ABI / in-process session never writes stdout/stderr or exits** (ADR-352,
  `src/root.zig`): the FFI session scopes a `.dark` sink for the call, so any
  diagnostic anywhere below it is discarded.
- **A warm (daemon) query's timing reaches the client**: a daemon worker scopes a
  `.buffer` sink for one request and ships the captured bytes back over the
  protocol, so a warm `--rank` is as measurable as a cold one.

The cold CLI leaves the default `.stderr` sink in place.

## Three emits: `diag`, `trace`, `note`

The sink decides _where_ a diagnostic goes; these three decide _whether_ it is
written at all. They are not interchangeable, and picking the wrong one is how a
flag comes to silence more or less than it promises.

| Emit                  | Speaks when              | For                                                                    |
| --------------------- | ------------------------ | ---------------------------------------------------------------------- |
| `diag(…)`             | always                   | a summary, a truncation notice, a usage error — nothing silences these |
| `trace(.<lens>, …)`   | its lens is lit          | phase timings, routing verdicts: dark until someone names the lens     |
| `note(.<chatter>, …)` | its class is not muffled | ripgrep's per-file messages, and only those                            |

`Chatter` is the exact inverse of `Lens`: **a lens is dark until it is named, a
chatter class speaks until it is muffled.** It has two members, `corpus` (a path
that would not open, descend, or preprocess, plus the "no files were searched"
verdict) and `ignore` (an ignore SOURCE that would not open). `--no-messages`
muffles both; `--no-ignore-messages` muffles only the second — the nesting is
resolved once in `muffle`, never re-derived per call site.

Muffling changes what is **reported**, never what happened. Flagging the run and
reporting it are separate statements at every producer, so a silenced walk error
still exits 2 — ripgrep's own rule, and the half of the feature a careless
implementation breaks. The two switches are flags, not env vars, so `serial.run`
lands them via `assay.muffle` right after argv parses and before anything can
walk a tree; argv errors above that line stay audible on purpose.

## Env knobs

| Knob                                                                                | Effect                                                                                                                                                                                                                                                                               |
| ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `GIST_TRACE=amend,journal,reconcile,warm,rank,index,query,session,fault` (or `all`) | Light one or more phase-trace lenses (off by default). Replaces the former `GIST_AMEND_TRACE` / `GIST_JOURNAL_TRACE` / `GIST_RECONCILE_TRACE` / `GIST_DEBUG_WARM`.                                                                                                                   |
| `GIST_TRACE=fault`                                                                  | Not a phase but a disposition: shows every failure the kernel **spared** because it could not change the answer (`fault.spare`, ADR-373 law 8) — a stale socket that would not unlink, an optional sidecar that would not write. Silent by default, so best-effort work stays quiet. |
| `GIST_TRACE_FORMAT=text\|json`                                                      | Render summaries/traces as prose or NDJSON. Defaults to a `--json` run's own format, so `gist --json`'s stderr is machine-parseable too.                                                                                                                                             |

## When to edit

Add a timing site → open a `Span`, read a `Duration`. Add a counted quantity →
give it a `Tally` schema. Add a diagnostic → pick from the three emits above.
Never reintroduce a raw `std.debug.print` for a diagnostic: it bypasses the sink
and breaks the never-write contract.

Reach for `note` only for a message ripgrep's two switches actually govern — one
line per offending path. A timing summary, a truncation notice, and the
`GIST_HINTS` guidance channel each answer to their own switch, and folding them
into a chatter class would silence more than `--no-messages` promises.

Discarding a failure is not a diagnostic decision and does not belong here —
reach for `fault.spare`, which routes to the `fault` lens. A bare `catch {}` is
banned outright (`zig-zlinter`'s `no_swallow_error`), because it cannot be told
apart from having forgotten to handle the error at all.
