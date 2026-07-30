---
doc_radar:
  sentinels:
    - description: "output.zig stays the facade — Emitter state plus forwarders, with the mode bodies in output/"
      file: pkg/kernels/irregex/src/exec/cold/emit/output.zig
      contains: ["pub const Emitter", "pub const expandInto", "@import(\"output/grid.zig\")"]
    - description: "maskLiterals is the one place that ranks which literal set a candidate prefilter may sweep, so the three sites cannot disagree about when the alternation cover is sound"
      file: pkg/kernels/irregex/src/exec/cold/emit/output.zig
      contains: ["pub fn maskLiterals"]
    - description: "json's two prefilter sites — the per-line mask and the solo-shard jump — ask maskLiterals rather than deriving a literal set locally"
      file: pkg/kernels/irregex/src/exec/cold/emit/json.zig
      contains: ["output.Emitter.maskLiterals"]
      absent: ["re.lits()"]
    - description: "hints stays a pure-render stderr channel gated by GIST_HINTS (corpus.zig owns the env read), with both triggers — outcome and duration — on the one grammar"
      file: pkg/kernels/irregex/src/exec/cold/emit/hints.zig
      contains: ["pub fn noMatches", "hintsEnabled()", "pub const Vigil", "pub fn renderSlow"]
    - description: "multiline holds the two -U model decisions rg makes differently from the line model: the sequential invert claim scan, and one count over spans rather than start-lines"
      file: pkg/kernels/irregex/src/exec/cold/emit/multiline.zig
      contains: ["pub fn claimed", "pub fn count", "pub const Walk"]
      absent: ["pub fn countStartLines"]
    - description: "one file's worth of rendering is a shared function, not a per-scheduler copy"
      file: pkg/kernels/irregex/src/exec/cold/emit/render.zig
      contains: ["pub fn renderFile", "pub fn emitSharded"]
    - description: "a hyperlink is framing the Emitter brackets around text it was already printing — never a second path formatter"
      file: pkg/kernels/irregex/src/exec/cold/emit/output.zig
      contains: ["fn linkOpen", "pub fn linkClose", "pub fn heading"]
---

# exec/cold/emit — match presentation

Turns match spans into the bytes on stdout. One `Emitter` carries shared match,
context-window, byte-offset, and replacement state across every
byte-compatible ripgrep output mode so heading / content / context lines cannot
disagree with each other.

| File            | Role                                                                                                                                                                                                                                                                        |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `output.zig`    | the `Emitter` façade — per-file emission state, the writer vocabulary every mode frames output with, and the five verbs that forward into [`output/`](output/README.md)                                                                                                     |
| `output/`       | the emit modes themselves, one file per output model: `grid` (per-line), `skim` (line-free literal), `multibuf` (`-U`), `display` (presentation), `replace` (`-r`)                                                                                                          |
| `render.zig`    | one file, start to finish: match it, apply the `-m` / `-l` / `--count` short-circuits, shard long files across cores, and hand the spans to the `Emitter` — the step both cold schedulers call instead of each writing their own                                            |
| `jsonstr.zig`   | rg's JSON string encoding — `text` when the bytes are valid UTF-8, base64 `bytes` when they are not                                                                                                                                                                         |
| `color.zig`     | `--color auto\|always\|never\|ansi` resolution (stdout tty + `NO_COLOR` / `TERM`) and the highlight palette                                                                                                                                                                 |
| `json.zig`      | the `--json` event stream (rg's `begin` / `match` / `end` shapes)                                                                                                                                                                                                           |
| `multiline.zig` | `-U` whole-buffer match model (`Emitter.buffer` + `--json` spans) — and the two places rg's slice model answers differently from its line model: `-c` counts spans, not start-lines, and `-v` claims lines by a sequential rescan so a later match still hides its own line |
| `hints.zig`     | the **stderr** guidance channel, on two triggers: a notable OUTCOME (`gist: no matches …` + up to three ranked `gist: try` / `gist: note:` lines derived from the query's own shape) and a notable DURATION (`Vigil` — a walk still running past its patience reports progress instead of looking hung); muted by `GIST_HINTS=0`, never touches stdout |

The warm session's line renderer ([`exec/session/facet/render.zig`](../../session/facet/render.zig))
deliberately drives **this** `Emitter` rather than a re-derived formatter —
warm `path:line:text` frames are cold frames by construction.

## Clickable rows

The click target itself is decided one directory up, in
[`cli/beacon.zig`](../../../cli/beacon.zig), because `relate` and `irregex`
print paths too. What lives here is only the **framing**: `linkOpen` /
`linkClose` bracket text a row was going to print anyway, so the anchor is
whatever the reader already sees — the whole `path:line` locator, or just the
path under `--heading` and `-l`. Every one of those calls is a null check when
the run resolved no beacon, which is why links-off output stays byte-identical
to ripgrep's. Under `--null` no posture links at all: that list's payload is
the filename's bytes, bound for `xargs -0`.

## Why the vigil is gated harder than a hint

A long walk is indistinguishable from a hung process, so it gets killed like
one — the run that motivated `Vigil` (`gist -uu` over a tree carrying 25 GB of
vendored clones) walked for well over a minute in complete silence and was
killed at six seconds. The fix is for the walk to say it is alive.

But every other line on this channel is a pure function of the query, and a
progress line is a function of the **clock**. So the vigil speaks only when
stderr is a terminal: a pipe, a redirect, a captured stderr, and every parity
harness sit outside its reach by construction. That is the same
destination-conditional posture headings and hyperlinks already take — a human
learns the walk is alive, and nothing an agent or a gate captures moves a byte.

The counters it reports (`Queue.walked`, `Queue.live`) are two atomics the
work-stealing walk already maintains, so arming a vigil cannot slow the walk it
watches.

## One owner for "which literals may I sweep for?"

Before any mode walks a body, it can mark which lines are even worth looking at:
a match must contain one of the pattern's literals, so one fused whole-buffer
sweep rejects most lines and the engine confirms only the survivors. The mark is
a **necessary** condition, never a sufficient one — every consumer re-runs the
matcher on a line it kept, so a false positive costs a confirm and nothing else.

That asymmetry is what makes the set-selection question subtle. A pure-literal
equivalence set (the pattern _is_ this alternation) may decide outright; a
per-branch alternation **cover** may only nominate. Both are legal to sweep for,
and the cover is the one worth having — it is what a class-led pattern like
`[A-Z]+_TYPE|[a-z]+_kind` has instead of literals. But it is unsound under `-i`
(a match may hold a case variant of the bytes) and `-U` (a match may cross the
line the mark is about), and unsound under `-v`, where a match _lacks_ the
literals entirely.

Three sites ask that question — the line-mode mask, the `--json` mask, and
`--json`'s solo-shard jump — and for a while they each answered it themselves,
which meant two of them took the cover and one silently didn't. `maskLiterals`
in [`output.zig`](output.zig) is now the only one that answers, ranking the
pure-literal set first and falling back to the cover where it is sound. A new
mode that wants to skip lines should call it rather than reach for `re.lits()`.

## When to edit

Output framing, color policy, `--json` event shapes, multiline buffer model,
hyperlink destination/emulator detection, or either arm of the coaching channel
(no-match hints, the long-walk vigil).
Changing _what_ matched belongs in `kernel/regex/`; changing _which files_ were
searched belongs in walk/engine.
