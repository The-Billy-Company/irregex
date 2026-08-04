# `src/corpus/scope/` — which paths count as the corpus

This package decides path eligibility and holds the committed charter. It answers *may this path be searched or indexed?* and never *does this pattern match?* — that second question belongs to the engine.

Because irregex already holds the full path list, scoping prunes candidates before `open(2)` ever runs. That is the one place irregex can be faster than ripgrep rather than merely matching it: rg applies a glob filter while walking the whole tree, so a `-g '*.go'` query here reads only the Go files instead of touching every candidate.

The old `glob.zig` was two packages wearing one name. The pure matcher (gitignore-shaped `*` / `**` / `!`) lives on the math floor at [`../../kernel/math/glob.zig`](../../kernel/math/glob.zig), so engines and surfaces can share it without importing corpus policy. What remains here is the *PathFilter* — how those matches compose into an include/exclude set for a walk.

## Files, By Job

- **`filter.zig`** implements `PathFilter` — the include/exclude composition over the math-floor glob matcher.
- **`paths.zig`** holds shared path normalization, joining, depth, and ASCII-fold helpers.
- **`types.zig`** is the language → extension/filename table (`-t go` / `py` / `rust` / …).
- **`genus.zig`** implements the corpus partition — `docs` / `code` / `data` behind `--docs` / `--no-code`.
- **`genus_test.zig`** is the partition's oracle: every glob in the type table lands in its own row's genus.
- **`charter.zig`** parses `.irregex.toml`, the committed corpus declaration (`roots`, `skip`, `types`).
- **`charter_test.zig`** holds the adverse tests: every malformed declaration must be refused.

Did-you-mean support stays on the math floor rather than duplicating here: the charter, the cold engine's argv preferences, and the `gist config` verb all resolve an unrecognized key through the one edit-distance helper at [`../../kernel/math/misread.zig`](../../kernel/math/misread.zig).

## Two Different Questions About One Path

`types.zig` answers which language a path is — 223 rows, one per language. `genus.zig` answers a different question: which *kind* of file is this — prose you read to understand, payload you read to configure, or the implementation itself.

That is the question an agent actually asks, and `-t` cannot express it: naming a dozen types still misses the extensionless `CHANGELOG`.

The partition is total and disjoint, so `--docs` and `--no-docs` are exact complements. `code` is deliberately the leftover: an unfamiliar extension lands there, so a gap in the table shows one extra line under `--code` rather than silently hiding a file.

Every classification is comptime-proved against the type table in both directions: a new `-t` type is a compile error until `genus.zig` classifies it, and a renamed one is a compile error until the rename lands here too. `genus_test.zig`'s own oracle test then instantiates every glob in the table at runtime and asserts it lands in its own row's declared genus — the exhaustive check a compile-time proof about spellings cannot make by itself. Edit a genus and expect both to have an opinion.

## The Charter

ripgrep's `.ripgreprc` conflates taste (`--max-columns`) with corpus facts (`--glob=!vendor/*`). The charter is the second half, split out and committed: three keys equally true for the person, the agent, the daemon, and CI.

`--no-config` suppresses it for one run. It is ceilinged at `Reach.corpus` — it may declare which files exist, never what counts as a match inside them.

## When To Edit

Come here for new `-t` aliases, a new type's genus, PathFilter composition, and charter keys. A genus name is a type name, so `--type-add 'docs:notes/**'` extends the partition without a new configuration key.

Ignore-file discovery stays in [`../tree/`](../tree/README.md). The glob dialect itself lives in [`../../kernel/math/glob.zig`](../../kernel/math/glob.zig).
