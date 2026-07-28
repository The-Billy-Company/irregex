---
doc_radar:
  sentinels:
    - description: "output.zig stays the facade — Emitter state plus forwarders, with the mode bodies in output/"
      file: pkg/kernels/irregex/src/exec/cold/emit/output.zig
      contains: ["pub const Emitter", "pub const expandInto", "@import(\"output/grid.zig\")"]
    - description: "hints stays a pure-render stderr channel gated by GIST_HINTS (corpus.zig owns the env read)"
      file: pkg/kernels/irregex/src/exec/cold/emit/hints.zig
      contains: ["pub fn noMatches", "hintsEnabled()"]
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
| `hints.zig`     | the no-match **stderr** guidance channel — `gist: no matches …` + up to three ranked `gist: try` / `gist: note:` lines derived from the query's own shape (`-i`/`-U`/`-F`/`-uu`/scope); muted by `GIST_HINTS=0`, never touches stdout                                       |

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

## When to edit

Output framing, color policy, `--json` event shapes, multiline buffer model,
hyperlink destination/emulator detection, or the no-match coaching channel.
Changing _what_ matched belongs in `kernel/regex/`; changing _which files_ were
searched belongs in walk/engine.
