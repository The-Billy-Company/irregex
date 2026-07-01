**`rg` honors a linked git worktree's shared `info/exclude`** (`bench/rgignore.zig`,
`bench/rgcompat.zig`). The ignore engine only read `.git/info/exclude` at CWD via
a shallow `.git`-dir check, so searching a *worktree* path (whose `.git` is a
gitfile pointing elsewhere) missed the repo's excludes and surfaced ignored
files.

- **`Ignore.init` now takes the search's positional roots** and probes each for
  its own `.git`, so `rg <flags> some-repo` honors that repo's VCS ignores even
  when CWD isn't a repo (`anyRootRepo`).
- **`resolveGitDir`** mirrors ripgrep's `resolve_git_commondir`: a `.git`
  directory is the git dir; a `.git` **file** is followed through `gitdir: …` →
  its `commondir` (relative commondir joined to the worktree git dir, absolute
  used as-is), and `<commondir>/info/exclude` is loaded anchored to the worktree
  root. `isGitRepo` was refactored onto the shared `hasDotGit` probe so a CWD
  worktree gitfile is now detected too.

Proven against real ripgrep as the oracle: `r1446_respect_excludes_in_worktree`
(a worktree whose commondir exclude ignores one file) now diffs to **0 bytes**
vs `rg`.
