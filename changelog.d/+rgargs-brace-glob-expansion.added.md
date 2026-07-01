**`-g`/`--glob` supports `{a,b,c}` brace alternation** (`bench/rgargs.zig`).
ripgrep's glob dialect expands `{…}` groups; gist treated the braces literally, so
`--glob '*.{js,py,go}'` matched nothing.

- **`braceExpand`** lowers a glob into the cartesian product of every brace group
  (nesting-aware, unbalanced `{` left literal) at registration time, so
  `*.{js,py}` becomes the include set `*.js`, `*.py` and
  `!{.git,node_modules}/**` becomes the excludes `!.git/**`, `!node_modules/**`.
  `addGlob` expands, then routes each variant through `addGlobOne` (the prior
  include/exclude/iglob logic) — one glob dialect across `-g`, `--iglob`, and
  `--type-add`.

Proven against real ripgrep as the oracle: `r391` (a real editor's
`!{.git,node_modules,plugged}/**` + `*.{js,json,…,py,…}` glob combo) now diffs to
**0 bytes** vs `rg`.
