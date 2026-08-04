# exec/cold/emit — Match Presentation

Turns match spans into the bytes on stdout. One `Emitter` carries shared
match, context-window, byte-offset, and replacement state across every
byte-compatible ripgrep output mode so heading / content / context lines
cannot disagree with each other.

- **`output.zig`** is the `Emitter` façade — per-file emission state, the
  writer vocabulary every mode frames output with, and the five verbs that
  forward into [`output/`](output/README.md).
- **`output/`** holds the emit modes themselves, one file per output
  model: `grid` (per-line), `skim` (line-free literal), `multibuf`
  (`-U`), `display` (presentation), `replace` (`-r`).
- **`render.zig`** does one file, start to finish: match it, apply the
  `-m` / `-l` / `--count` short-circuits, shard long files across cores,
  and hand the spans to the `Emitter` — the step both cold schedulers call
  instead of each writing their own.
- **`color.zig`** resolves `--color auto|always|never|ansi` (stdout tty +
  `NO_COLOR` / `TERM`) and the highlight palette.
- **`json.zig`** owns the `--json` event stream (rg's `begin` / `match` /
  `end` shapes), including the JSON string encoding it borrows from
  [`surface/cli/jsonstr.zig`](../../../surface/cli/jsonstr.zig) — `text`
  when the bytes are valid UTF-8, base64 `bytes` when they are not.
- **`multiline.zig`** holds the `-U` whole-buffer match model
  (`Emitter.buffer` + `--json` spans), and the two places rg's slice model
  answers differently from its line model: `-c` counts spans, not
  start-lines, and `-v` claims lines by a sequential rescan so a later
  match still hides its own line.
- **`hints.zig`** is the stderr guidance channel, on two triggers: a
  notable outcome (`gist: no matches …` plus up to three ranked `gist:
  try` / `gist: note:` lines derived from the query's own shape) and a
  notable duration (`Vigil` — a walk still running past its patience
  reports progress instead of looking hung). Muted by `GIST_HINTS=0`,
  never touches stdout.

The warm session's line renderer
([`exec/session/facet/render.zig`](../../session/facet/render.zig))
deliberately drives this `Emitter` rather than a re-derived formatter —
warm `path:line:text` frames are cold frames by construction.

## Clickable Rows

The click target itself is decided one directory up, in
[`cli/beacon.zig`](../../../surface/cli/beacon.zig), because `relate` and
`irregex` print paths too. What lives here is only the framing: `linkOpen`
/ `linkClose` bracket text a row was going to print anyway, so the anchor
is whatever the reader already sees — the whole `path:line` locator, or
just the path under `--heading` and `-l`.

Every one of those calls is a null check when the run resolved no beacon,
which is why links-off output stays byte-identical to ripgrep's. Under
`--null` no posture links at all: that list's payload is the filename's
bytes, bound for `xargs -0`.

## Why the Vigil Is Gated Harder Than a Hint

A long walk is indistinguishable from a hung process, so it gets killed
like one — the run that motivated `Vigil` (`gist -uu` over a tree carrying
gigabytes of vendored clones) walked for well over a minute in complete
silence and was killed early. The fix is for the walk to say it is alive.

But every other line on this channel is a pure function of the query, and
a progress line is a function of the clock. So the vigil speaks only when
stderr is a terminal: a pipe, a redirect, a captured stderr, and every
parity harness sit outside its reach by construction. That is the same
destination-conditional posture headings and hyperlinks already take — a
human learns the walk is alive, and nothing an agent or a gate captures
moves a byte.

The counters it reports (`Queue.walked`, `Queue.live`) are two atomics the
work-stealing walk already maintains, so arming a vigil cannot slow the
walk it watches.

## One Owner for "Which Literals May I Sweep For?"

Before any mode walks a body, it can mark which lines are even worth
looking at: a match must contain one of the pattern's literals, so one
fused whole-buffer sweep rejects most lines and the engine confirms only
the survivors. The mark is a necessary condition, never a sufficient one —
every consumer re-runs the matcher on a line it kept, so a false positive
costs a confirm and nothing else.

That asymmetry is what makes the set-selection question subtle. A
pure-literal equivalence set (the pattern *is* this alternation) may
decide outright; a per-branch alternation cover may only nominate. Both
are legal to sweep for, and the cover is the one worth having — it is
what a class-led pattern like `[A-Z]+_TYPE|[a-z]+_kind` has instead of
literals. But it is unsound under `-i` (a match may hold a case variant of
the bytes) and `-U` (a match may cross the line the mark is about), and
unsound under `-v`, where a match lacks the literals entirely.

Three sites ask that question — the line-mode mask, the `--json` mask, and
`--json`'s solo-shard jump — and for a while they each answered it
themselves, which meant two of them took the cover and one silently
didn't. `maskLiterals` in [`output.zig`](output.zig) is now the only one
that answers, ranking the pure-literal set first and falling back to the
cover where it is sound. A new mode that wants to skip lines should call
it rather than reach for `re.lits()`.

## When to Edit

Output framing, color policy, `--json` event shapes, multiline buffer
model, hyperlink destination/emulator detection, or either arm of the
coaching channel (no-match hints, the long-walk vigil). Changing *what*
matched belongs in `kernel/regex/`; changing *which files* were searched
belongs in walk/engine.
