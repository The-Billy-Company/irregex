**CLI collapses six competitor-shaped verbs into three real ones, on a native
flag vocabulary with a separated legacy alias layer** (`src/commands/search/`,
`src/commands/status/`, `src/commands/cli/{main,schema}.zig`). The old surface
(`index` · `query` · `regex` · `rank` · `grep` · `rg`) named _which competitor's
argv it aped_, not what gist does — and `query`/`regex`/`rank`/`grep` were four
verbs answering one question (_what matches, and how do you want it shaped_) over
one engine. The new surface says what gist actually does:

- **`gist search <pattern> [PATH…]`** — the one search verb. Pattern is
  auto-detected literal-or-regex (a literal is its own required literal, so it
  rides the same trigram prefilter — no second code path). Output shape is a
  **flag, not a verb**: `--show lines` (default, the byte-exact `rg -n`
  drop-in) / `--show files` (was `query`/`regex`) / `--show count` /
  `--rank [=N]` (was `rank`, top-K default 20). The dispatcher
  (`search/run.zig`) still routes each request to its fastest backend — the
  `drivers` fast paths for `--show files`/`--rank`, the full line engine
  (`emit.zig`) for the feature flags.
- **`gist status`** — new, read-only introspection: whether an index exists,
  file / distinct-trigram / posting counts, on-disk size, build age vs the
  freshness anchor, and corpus roots. Answers "am I ready to search fast"
  before an agent commits to a query, with zero search work.
- **`gist index`** — unchanged, the mutating build/refresh lifecycle action.

**Two flag sets, one behavior each.** Set B (native) is the primary, documented
vocabulary — `--show`, `--rank`, `--lang`, `--glob`, `--word`, `--fixed`,
`--ignore-case`, `--smart-case`, `--invert`, `--before/--after/--context`,
`--limit`, `--spans`, `--replace`, `--only-matching`, `--pattern`, plus two
genuinely new capabilities: **`--live`** (skip the index, scan the live tree —
the capability `gist rg` carried, without keeping a competitor-shaped verb) and
**`--json`** (structured records, the one thing rgsuite marked NA against
`rg --json`). Set A (legacy) is every `rg`/`grep` spelling an agent's muscle
memory types — `-A/-B/-C -i -w -F -l -c -v -o -n -N -S -m -e -t -g -r`, the long
forms, short-flag bundling, the no-op set, the fail-loud set — each an **alias
onto exactly one native option**, split into its own module
(`search/compat.zig`) so the ergonomic surface reads clean.

**Agent discovery.** `gist --schema` emits a JSON capability manifest (verbs →
flags → `{native_name, type, default, legacy_aliases, description}` + exit codes)
so the two-set model is machine-checkable, not just prose — the seed for wiring
gist into `services/ai/tools`.

Dead-code shake per the refactoring rule: `src/commands/grep/` and
`src/commands/cli/drivers.zig` are **deleted**, not deprecated-and-kept; their
logic lives in `search/`. The `ripgrep/` differential-parity engine stays wired
but **undocumented** (dropped from `--help`/`--schema`) — it's the `rgsuite`
441-test harness plumbing, not a public verb. Every bench script
(`_compete.sh`, `streams.sh`, `scan_regress.sh`) and the README are rewritten
around `search`; `bench/rgsuite/run.py` still targets the internal `rg` path, so
the parity certificate is unaffected. Native + legacy parsing is guarded by the
superset test suite `search/args_test.zig`.
