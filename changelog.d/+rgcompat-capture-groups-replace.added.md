**`rg` gains a capture-group engine — `-r $1`/named-group replacement and JSON
submatches, no longer a fail-loud gap** (`src/regex/captures.zig` (new),
`src/regex/syntax.zig`, `src/regex/analysis.zig`, `src/regex/compile.zig`,
`src/root.zig`, `bench/rgemit.zig`). The prior `-r` handled only whole-match
`$0`/`$$` and *rejected* a group ref at parse time; ripgrep's own test suite
leans on `$1`/`${name}` substitution, so the drop-in couldn't reach those cases.

- **Group parsing** (`syntax.zig`): `(…)` and named `(?P<n>…)`/`(?<n>…)` now
  capture (1-based index in opening-paren order, names recorded only when a sink
  is given so the hot main-engine parse allocates nothing); `(?:…)` is
  non-capturing; lookaround (`(?=`,`(?!`,`(?<=`,`(?<!`) fails loud as
  `BadPattern` (gist's linear engine can't backtrack).
- **A dedicated capture VM** (`captures.zig`) compiles the same `syntax.zig` AST
  into a Pike VM that threads per-group slot vectors, so a leftmost-first match
  now yields each group's `[start,end)` — without touching the hot boolean/span
  matcher (the new `.capture` AST node the analysis/compile/prefilter passes
  recurse through transparently, so trigram prefilters and anchoring are
  unchanged). Slot count is capped to keep the closure stack bounded.
- **`-r` expands real templates** — `$1`, `${2}`, `$name`, `${name}`, `$0`,
  `$$` — with rust-regex `Replacer` semantics (unknown/out-of-range group →
  empty). The expander is a shared free function (`rgemit.expandInto`) so the
  text printer and the JSON stream replace identically.
- **Two `-r` × `--max-columns` edge cases now match rg byte-for-byte.** A
  replaced over-long line reports match granularity (`[Omitted long line with N
  matches]`, and `--max-columns-preview`'s ` [... N more matches]`) instead of
  the granular-less `[Omitted long matching line]`; and an empty match whose
  start coincides with the previous match's end is skipped (rust-regex
  `find_iter` progress rule), so `-r '${0}f'` over `.*` yields `af`, not `aff`.

Proven against real ripgrep as the oracle: the `-r`/replacement and
max-columns-granularity cases (`f129_replace`, `r1739_replacement_lineterm_match`,
`f1078_max_columns_preview2`) all diff to **0 bytes** vs `rg`, and the regex
engine's adversarial differential/prefilter tests still pass with the new node.
