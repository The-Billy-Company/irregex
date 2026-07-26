---
doc_radar:
  sentinels:
    - description: "output.zig stays the facade — Emitter state plus forwarders, with the mode bodies in output/"
      file: pkg/kernels/irregex/src/surface/exec/cold/emit/output.zig
      contains: ["pub const Emitter", "pub const expandInto", "@import(\"output/grid.zig\")"]
    - description: "hints stays a pure-render stderr channel gated by GIST_HINTS (corpus.zig owns the env read)"
      file: pkg/kernels/irregex/src/surface/exec/cold/emit/hints.zig
      contains: ["pub fn noMatches", "hintsEnabled()"]
    - description: "one file's worth of rendering is a shared function, not a per-scheduler copy"
      file: pkg/kernels/irregex/src/surface/exec/cold/emit/render.zig
      contains: ["pub fn renderFile", "pub fn emitSharded"]
---

# surface/exec/cold/emit — match presentation

Turns match spans into the bytes on stdout. One `Emitter` carries shared match,
context-window, byte-offset, and replacement state across every
byte-compatible ripgrep output mode so heading / content / context lines cannot
disagree with each other.

| File            | Role                                                                                                                                                                                                                                  |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `output.zig`    | the `Emitter` façade — per-file emission state, the writer vocabulary every mode frames output with, and the five verbs that forward into [`output/`](output/README.md)                                                                |
| `output/`       | the emit modes themselves, one file per output model: `grid` (per-line), `skim` (line-free literal), `multibuf` (`-U`), `display` (presentation), `replace` (`-r`)                                                                    |
| `render.zig`    | one file, start to finish: match it, apply the `-m` / `-l` / `--count` short-circuits, shard long files across cores, and hand the spans to the `Emitter` — the step both cold schedulers call instead of each writing their own      |
| `jsonstr.zig`   | rg's JSON string encoding — `text` when the bytes are valid UTF-8, base64 `bytes` when they are not                                                                                                                                   |
| `color.zig`     | `--color auto\|always\|never\|ansi` resolution (stdout tty + `NO_COLOR` / `TERM`) and the highlight palette                                                                                                                           |
| `json.zig`      | the `--json` event stream (rg's `begin` / `match` / `end` shapes)                                                                                                                                                                     |
| `multiline.zig` | `-U` whole-buffer match model (`Emitter.buffer` + `--json` spans)                                                                                                                                                                     |
| `hints.zig`     | the no-match **stderr** guidance channel — `gist: no matches …` + up to three ranked `gist: try` / `gist: note:` lines derived from the query's own shape (`-i`/`-U`/`-F`/`-uu`/scope); muted by `GIST_HINTS=0`, never touches stdout |

The warm session's line renderer ([`exec/session/facet/render.zig`](../../session/facet/render.zig))
deliberately drives **this** `Emitter` rather than a re-derived formatter —
warm `path:line:text` frames are cold frames by construction.

## When to edit

Output framing, color policy, `--json` event shapes, multiline buffer model,
or the no-match coaching channel. Changing _what_ matched belongs in
`kernel/match/`; changing _which files_ were searched belongs in walk/engine.
