# gist/src/commands/ripgrep

The **`rg`-DEFAULT drop-in** — gist over an *arbitrary* directory tree (not the
persisted Billy index), matching ripgrep's default behavior byte-for-byte so it
can stand in for `rg` in an agent loop anywhere. Split by concern from the one
original `rgcompat` monolith into feature-named modules:

| File         | Role                                                                                                     |
| ------------ | -------------------------------------------------------------------------------------------------------- |
| `args.zig`   | ripgrep-compatible CLI flag parsing (the `Opts` surface + `die`).                                         |
| `ignore.zig` | `.gitignore` / ignore-file precedence, parent-ancestor ignores, worktree/commondir resolution.            |
| `output.zig` | The match + presentation layer — heading/line framing, context, color, word/only-matching, replace templates. |
| `json.zig`   | The `--json` event stream (rg's `begin`/`match`/`end` message shapes).                                    |
| `run.zig`    | The walk + gather + search orchestration loop that drives the above.                                      |

Named for what each module *is* (its feature), not merely to mirror rg's source
layout.
