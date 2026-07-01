**`--ignore-file` precedence + `-u`/`--require-git` semantics match ripgrep**
(`bench/rgignore.zig`, `bench/rgargs.zig`). Three ignore-source ordering bugs:

- **`--ignore-file` is now lowest precedence** — added *before* the in-tree
  `.ignore`/`.gitignore` (not after), so a repo `.ignore` `!imp.log` correctly
  overrides an `--ignore-file` `*.log` (`f45_precedence_with_others`).
- **`-u`/`--no-ignore` no longer disables `--ignore-file`** — the explicit
  `--ignore-file` sources are loaded before the `no_ignore` early-return, matching
  rg (an explicit ignore file is honored even unrestricted); only
  `--no-ignore-files` drops them, and **`--ignore-files`** re-enables them
  (`f1466_no_ignore_files`).
- **`--require-git` now undoes `--no-require-git`** (last flag wins) instead of
  being a no-op, so `--no-require-git --require-git` again requires a real `.git`
  before honoring `.gitignore` (`f1414_no_require_git`).

Proven against real ripgrep as the oracle: all three regressions diff to **0
bytes** vs `rg`.
