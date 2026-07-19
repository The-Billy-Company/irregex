---
doc_radar:
  sentinels:
    - description: "Emitter remains the shared presentation state across rg output modes"
      file: pkg/kernels/irregex/src/runtime/cold/emit/output.zig
      contains: ["pub const Emitter", "pub fn expandInto"]
    - description: "hints stays a pure-render stderr channel gated by GIST_HINTS (corpus.zig owns the env read)"
      file: pkg/kernels/irregex/src/runtime/cold/emit/hints.zig
      contains: ["pub fn noMatches", "hintsEnabled()"]
---

# runtime/cold/emit — match presentation

Turns match spans into the bytes on stdout. One `Emitter` carries shared match,
context-window, byte-offset, and replacement state across every
byte-compatible ripgrep output mode so heading / content / context lines cannot
disagree with each other.

| File            | Role                                                                                                                                                                                                                                  |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `output.zig`    | the `Emitter` — framing, context (`-A`/`-B`/`-C`), `-o` / `--only-matching`, replace templates                                                                                                                                        |
| `color.zig`     | `--color auto\|always\|never\|ansi` resolution (stdout tty + `NO_COLOR` / `TERM`) and the highlight palette                                                                                                                           |
| `json.zig`      | the `--json` event stream (rg's `begin` / `match` / `end` shapes)                                                                                                                                                                     |
| `multiline.zig` | `-U` whole-buffer match model (`Emitter.buffer` + `--json` spans)                                                                                                                                                                     |
| `hints.zig`     | the no-match **stderr** guidance channel — `gist: no matches …` + up to three ranked `gist: try` / `gist: note:` lines derived from the query's own shape (`-i`/`-U`/`-F`/`-uu`/scope); muted by `GIST_HINTS=0`, never touches stdout |

The warm session's line renderer ([`session/render.zig`](../../session/render.zig))
deliberately drives **this** `Emitter` rather than a re-derived formatter —
warm `path:line:text` frames are cold frames by construction.

## When to edit

Output framing, color policy, `--json` event shapes, multiline buffer model,
or the no-match coaching channel. Changing *what* matched belongs in
`search/match/`; changing *which files* were searched belongs in walk/engine.
