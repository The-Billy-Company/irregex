**`rg` honors ancestor ignore files and finds the git repo by ascent**
(`bench/rgignore.zig`). ripgrep reads `.gitignore`/`.ignore` from every directory
*above* the search root and discovers `.git` at any ancestor; gist only read
CWD-and-below, so searching from a repo subdirectory ignored the wrong set.

- **`gitRootDepth`** ascends from CWD looking for `.git` (dir or worktree file),
  replacing the CWD-only `isGitRepo` — so a search run inside `repo/sub/` now
  enables VCS ignores from `repo/`'s `.gitignore` (`no_parent_ignore_git`).
- **`loadParents`** walks each ancestor shallow→deep (deeper wins), reading its
  `.gitignore` (bounded to the git root) and `.ignore`/`.rgignore` (to `/`),
  skipped under `--no-ignore-parent`. An **anchored ancestor rule is re-anchored**
  onto the search subtree: `readFile`/`addLine` take a `strip` prefix (CWD's path
  relative to that ancestor) — a rule like `/parent/*.txt` seen from `parent/`
  becomes `*.txt`, and a rule targeting a sibling of CWD is dropped. Slash-less
  ancestor rules match a basename at any depth unchanged.

Proven against real ripgrep as the oracle: `no_parent_ignore_git`, `r829_2778`,
`r3173_hidden_whitelist_only_dot`, and `f1757` (a `.ignore` above the search root
excluding `target/`) now diff to **0 bytes** vs `rg`.
