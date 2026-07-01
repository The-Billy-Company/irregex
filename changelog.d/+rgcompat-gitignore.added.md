**`rg` now honors the `.gitignore` boundary — the single biggest drop-in gap
closed** (`bench/rgignore.zig` (new), `bench/rgargs.zig`, `bench/rgcompat.zig`).
gist was deliberately ignore-agnostic, so any ripgrep scenario with a
`.gitignore`/`.ignore` searched a superset and diverged. The walk now applies the
same "what's tracked" filter rg does, as a proper per-directory rule model rather
than a bolt-on path test.

- **Full gitignore dialect** (`rgignore.zig`, reusing `pathfilter.globMatch` so
  there's one glob dialect): leading/embedded `/` anchors to the ignore file's
  dir, a slash-less pattern matches a basename at any depth, a trailing `/`
  restricts to directories, `!pat` re-includes, and **last matching rule wins**
  with deeper dirs + `.ignore`/`.rgignore`/`--ignore-file` outranking a shallower
  `.gitignore`. Rules accumulate as the walk descends (loaded once per dir), and
  an ignored directory is *pruned* — so `/*` + `!/dir` re-includes `dir` while
  keeping its siblings excluded, exactly like git.
- **Hidden-file interaction**: a `!`-whitelisted dotfile is un-hidden (overrides
  the default dotfile skip), and `.git` is never walked.
- **The `--no-ignore*` / `-u` control surface is now real**, not a no-op:
  `--no-ignore`, `--no-ignore-vcs` (VCS sources only), `--no-ignore-dot`,
  `--no-ignore-exclude`, `--no-ignore-files`, `--no-require-git` (honor
  `.gitignore` outside a repo), `--ignore-file <path>` (ordered, later wins),
  `--ignore-file-case-insensitive`; `-u`→`--no-ignore`, `-uu`→`+--hidden`. VCS
  rules (`.gitignore`, `.git/info/exclude`) apply only inside a git repo unless
  `--no-require-git`.

Proven against real ripgrep as the oracle: this converts **~30 previously
divergent cases to byte-exact PASS** (anchoring, negation/whitelist, precedence,
`--ignore-file`, `--no-ignore-vcs`, per-dir `.ignore`, hidden whitelist), lifting
supported-surface parity to 98.9% with no regression elsewhere.
