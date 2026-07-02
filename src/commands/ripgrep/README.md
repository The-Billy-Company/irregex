# gist/src/commands/ripgrep

The **`rg`-DEFAULT drop-in** — gist over an _arbitrary_ directory tree (not the
persisted Billy index), matching ripgrep's default behavior byte-for-byte so it
can stand in for `rg` in an agent loop anywhere. Split by concern from the one
original `rgcompat` monolith into feature-named modules:

| File         | Role                                                                                                          |
| ------------ | ------------------------------------------------------------------------------------------------------------- |
| `args.zig`   | ripgrep-compatible CLI flag parsing (the `Opts` surface + `die`).                                             |
| `ignore.zig` | `.gitignore` / ignore-file precedence, parent-ancestor ignores, worktree/commondir resolution.                |
| `output.zig` | The match + presentation layer — heading/line framing, context, word/only-matching, replace templates.        |
| `color.zig`  | `--color auto\|always\|never\|ansi` resolution (stdout tty + `NO_COLOR`/`TERM`) and the highlight palette.    |
| `json.zig`   | The `--json` event stream (rg's `begin`/`match`/`end` message shapes).                                        |
| `run.zig`    | The walk + gather + search orchestration loop that drives the above.                                          |

Named for what each module _is_ (its feature), not merely to mirror rg's source
layout.
