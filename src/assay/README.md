# `src/assay/` — The Instrumentation Floor

An *assay* is a precise measurement of composition. This is the one module
the whole package reaches for when it needs to time, count, or report — so
those three concerns speak a single, deliberately-shaped vocabulary instead
of the ~90 hand-rolled `std.debug.print` calls, ~25 open-coded `nowNs`/`ms`
pairs, and several near-duplicate tally structs that used to be scattered
across `kernel/`, `corpus/`, and `surface/`.

It sits at the bottom of the package DAG — it imports only `std` — so every
layer above can consume it without inversion. `assay.zig` is the small
facade (`const assay = @import(".../assay/assay.zig")`); the engines behind
it are one file each.

## Modules

- **[`span.zig`](span.zig)** owns time, with the two clocks made
  non-interchangeable: `Span`/`Duration` ride the monotonic-awake clock (the
  only thing that renders as `ms`), and `Anchor` rides the wall clock (the
  only freshness stamp `writeAnchor` accepts). A monotonic reading can no
  longer masquerade as a build anchor, and a duration can no longer be
  computed across the wall clock.
- **[`tally.zig`](tally.zig)** owns counters: `Tally(Schema)`, one
  comptime-checked counter set indexed by an enum of field names, with an
  allocation-free vector `fold` for the parallel engine's per-worker → run
  merge. One mechanism, reused per distinct output schema.
- **[`channel.zig`](channel.zig)** owns diagnostics: the branded env
  vocabulary (`envSpan`/`envFalsy`/`envUsize`/`envFlag`), the `TRACE` lens
  gate (one list replacing four bare-presence `*_TRACE` vars), the
  `Chatter` muffle gate behind `--no-messages`, and the thread-local sink
  every diagnostic routes through.
- **[`brand.zig`](brand.zig)** owns program identity — the name that opens
  a diagnostic line, the namespace its environment knobs live in, and the
  directory its artifacts are written to. `gist`, `relate`, and `blast` are
  three binaries over one library, and a root module that declares
  `irgx_brand` picks its own name and artifact directory while sharing the
  ecosystem's `env_prefix` and `artifact_dir` conventions; one that declares
  nothing gets the historical `gist` defaults byte-for-byte.
- **[`assay.zig`](assay.zig)** is the facade plus `Run`: it opens a `Span`
  and emits one summary line, byte-identical to the former `debug.print` in
  text mode, or a single NDJSON record in `--json` mode.

## Standing a Fourth Program Up On This Floor

Two declarations on the root module, both read at comptime, both optional,
and both defaulting to what this package has always emitted:

```zig
pub const irgx_brand: irregex.Brand = .{
    .name = "outliner",          // signs every diagnostic line
    .env_prefix = "OUTLINER_",   // so the knob is OUTLINER_TRACE
    .artifact_dir = ".outliner",
};
pub const irgx_lenses = enum { lex, press, weave, folio };
```

`Brand` answers *who is speaking*; `irgx_lenses` answers *what it has to say*.
Shipping only the first left an embedder owning a `TRACE` knob with no
vocabulary to put through it — its phases are not `warm` or `reconcile` — so
`OUTLINER_TRACE=press` lit nothing and, because an unrecognized token used to
be dropped in the name of forward compatibility, said nothing either. Declared
lenses are welded onto the engine's own set to make **one** enum, which is why
there is still one mask, one knob, one `all`, and one `trace`: a guest lens is
not a second-class lens, and no call site knows which half it names.

Engine lenses keep their ordinals, so adding a guest set cannot renumber a
mask computed elsewhere. Two mistakes are compile errors rather than a lens
that quietly never lights: naming more lenses than the 32-bit mask has bits,
and re-spelling a name the engine already owns. A token matching neither half
is now reported — `gist: note: TRACE names no lens 'pres'` — because an
ignored token and an unset knob were indistinguishable from outside.

The root module belongs to the **compilation**, though, not to the package, and
it moves: under a custom test runner the runner can be the root, and a C-ABI
host has no Zig root at all. `std_options` lives with the same rule. So `lit`
and `trace` take the lens *name* — spelled `.press`, exactly as before — and
resolve it at comptime, which lets the answer be three different things on
purpose. An engine lens always resolves. A guest lens resolves wherever the
declaration reached. A name matching neither is a **compile error** where a
guest set was declared (the vocabulary is closed there, so this is a typo among
your own lenses) and a **dark channel** where none was (nothing can name it and
no `TRACE` token can light it, so the call folds to an empty mask). The
alternative was that a library's own trace line becomes the reason its tests
will not build.

## Why the Sink Is Thread-Local

The sink is the seam that makes two properties true by construction rather
than by auditing every call site.

- **The C-ABI / in-process session never writes stdout or stderr, and never
  exits** (`src/root.zig`). The FFI session scopes a `.dark` sink for the
  call, so any diagnostic anywhere below it is discarded.
- **A warm (daemon) query's timing reaches the client.** A daemon worker
  scopes a `.buffer` sink for one request and ships the captured bytes back
  over the protocol, so a warm `--rank` is as measurable as a cold one.

The cold CLI leaves the default `.stderr` sink in place.

## Three Emits: `diag`, `trace`, `note`

The sink decides *where* a diagnostic goes; these three decide *whether* it
is written at all. They are not interchangeable, and picking the wrong one
is how a flag comes to silence more or less than it promises.

- **`diag(…)`** speaks always — a summary, a truncation notice, a usage
  error. Nothing silences these.
- **`trace(.<lens>, …)`** speaks only when its lens is lit — phase timings
  and routing verdicts, dark until someone names the lens.
- **`note(.<chatter>, …)`** speaks only when its class is not muffled —
  ripgrep's per-file messages, and only those.

`Chatter` is the exact inverse of `Lens`: a lens is dark until it is named,
a chatter class speaks until it is muffled. It has two members, `corpus` (a
path that would not open, descend, or preprocess, plus the "no files were
searched" verdict) and `ignore` (an ignore source that would not open).
`--no-messages` muffles both; `--no-ignore-messages` muffles only the
second — the nesting is resolved once in `muffle`, never re-derived per
call site.

Muffling changes what is reported, never what happened. Flagging the run
and reporting it are separate statements at every producer, so a silenced
walk error still exits 2 — ripgrep's own rule, and the half of the feature
a careless implementation breaks. The two switches are flags, not env
vars, so `serial.run` lands them via `assay.muffle` right after argv parses
and before anything can walk a tree; argv errors above that line stay
audible on purpose.

## Env Knobs

- **`TRACE=amend,journal,reconcile,warm,rank,index,query,session,fault,link,walk`**
  (or `all`) lights one or more phase-trace lenses, off by default.
- **`TRACE=fault`** is not a phase but a disposition: it shows every
  failure the kernel *spared* because it could not change the answer
  (`fault.spare`, fault-channel law 8) — a stale socket that would not
  unlink, an optional sidecar that would not write. Silent by default, so
  best-effort work stays quiet.
- **`TRACE=link`** shows the OSC-8 hyperlink decision — whether a run
  linked and which destination it resolved — for a feature that is on by
  default and otherwise invisible when it declines.
- **`TRACE=walk`** shows what the corpus walk retained, per worker and by
  cause: the arena that outlives a directory, the per-worker read scratch,
  the coalesced path-list buffer, the deferred backlog.
- **`TRACE_FORMAT=text|json`** renders summaries and traces as prose or
  NDJSON. It defaults to a `--json` run's own format, so a JSON run's
  stderr is machine-parseable too.

Every knob resolves under the active `Brand`'s `env_prefix` — `GIST_TRACE`
for the historical default, or a different prefix for an embedder that
declared its own brand.

## When to Edit

Add a timing site by opening a `Span` and reading a `Duration`. Add a
counted quantity by giving it a `Tally` schema. Add a diagnostic by
picking from the three emits above.

Never reintroduce a raw `std.debug.print` for a diagnostic — it bypasses
the sink and breaks the never-write contract.

Reach for `note` only for a message ripgrep's two switches actually
govern — one line per offending path. A timing summary, a truncation
notice, and the hints guidance channel each answer to their own switch,
and folding them into a chatter class would silence more than
`--no-messages` promises.

Discarding a failure is not a diagnostic decision and does not belong
here — reach for `fault.spare`, which routes to the `fault` lens. A bare
`catch {}` is banned outright (`zig-zlinter`'s `no_swallow_error`), because
it cannot be told apart from having forgotten to handle the error at all.
