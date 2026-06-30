**`grep` gains the agent's full ripgrep flag surface** (`bench/lines.zig`,
`bench/pathfilter.zig`). Found by dogfooding gist *as the agent*, racing every
query against `rg`: the three flags an agent reaches for after `-n` were missing,
and an unknown flag was silently swallowed as the pattern — the worst failure
mode (a wrong-but-confident empty result). Now:

- **`-A/-B/-C N` context lines** — read the code *around* a hit without a second
  file round-trip (the #1 affordance after `-n`). Byte-exact `:`/`-`/`--` framing:
  a 17-line `-C2` block and an asymmetric `-A1 -B1` block both diff to **0 lines**
  against `rg -n --no-heading -C`, group separators and all.
- **`-t <lang>` / `-g <glob>` path scoping** (`pathfilter.zig`) — confine to one
  language or subtree. The type table is **codebase-agnostic** (~75 languages with
  rg-compatible names — `java kotlin ruby php c cpp cs haskell elixir terraform
  dockerfile …`, not just the monorepo's seven), so `-t <name>` accepts the same
  name an agent already types at rg, and a row may carry a bare filename
  (`Makefile`, `Dockerfile`, `go.mod`) as well as an extension. This is also the
  one place gist *beats* rg structurally instead of merely matching it: rg applies
  the filter while walking the whole tree, but gist already holds the path list,
  so it **prunes candidate ids before touching disk**. `-t go pgxpool.Pool` reads 234 of 18 608 files and runs **1.44× faster
  than `rg -t go`** (55 ms vs 79 ms, hyperfine 20-run, byte-identical output); the
  pre-fix `-t go` swallowed the flag and degenerated to reading all 18 608 (459 ms).
  Globs are gitignore/rg-shaped (`*` per-segment, `**` across `/`, `?`, `[a-z]`
  classes, `!`-exclude), basename-matched when slash-free.
- **`-w` word-boundary** (wraps `\b(…)\b`), **`-F` fixed-string** (escapes regex
  metachars), **`-l` files-with-matches**, **`-c` per-file count**, **`-v` invert**
  (seeds all docs — an inverted match can occur in a file lacking the literal).
- **Fail-loud parsing** — an unrecognized `-x` now errors with the supported-flag
  list (use `-e <pat>` or `-- <pat>` for a leading-dash literal) instead of
  searching for it.

Correctness is unchanged and re-proven: the new `pathfilter` glob matcher carries
its own adversarial tests (segment vs `/` boundaries, `**` zero-dir, class
negation, pathological star backtracking, exclude veto); a 7-feature line-output
battery (`-w`, `-F`, `^`-anchor, `$`-eol, alternation, class, counted) diffs to
**0 lines** vs `rg` on the shared scope; and the `gist ≡ rg` set oracle still
proves 0 false negatives / 0 false positives. The grep line loop also adopts rg's
`\n`-terminates semantics (a trailing newline yields no phantom empty final line),
so `$`/`^$` match exactly as rg does. Path scoping respects the same documented
corpus policy as the rest of gist (skips `vendor`/`dist-types`/build output) — the
only residual deltas vs a raw `rg` path-arg run, all in skipped subtrees.
