---
doc_radar:
  sentinels:
    - description: "Emitter remains the shared presentation state across rg output modes"
      file: pkg/kernels/irregex/src/gist/faces/cli/search/emit/output.zig
      contains: ["pub const Emitter", "pub fn expandInto"]
---

# gist/faces/cli/search/emit — match presentation

Turns match spans into the bytes on stdout. One `Emitter` carries shared match,
context-window, byte-offset, and replacement state across every
byte-compatible ripgrep output mode so heading / content / context lines cannot
disagree with each other.

| File | Role |
| --- | --- |
| `output.zig` | the `Emitter` — framing, context (`-A`/`-B`/`-C`), `-o` / `--only-matching`, replace templates |
| `color.zig` | `--color auto\|always\|never\|ansi` resolution (stdout tty + `NO_COLOR` / `TERM`) and the highlight palette |
| `json.zig` | the `--json` event stream (rg's `begin` / `match` / `end` shapes) |
| `multiline.zig` | `-U` whole-buffer match model (`Emitter.buffer` + `--json` spans) |

The warm session's line renderer ([`session/render.zig`](../../../../session/render.zig))
deliberately drives **this** `Emitter` rather than a re-derived formatter —
warm `path:line:text` frames are cold frames by construction.
