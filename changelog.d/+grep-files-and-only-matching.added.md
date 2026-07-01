**`grep` gains `--files` (file discovery) and `-o`/`--only-matching` (span
extraction)** — the two reflexive ripgrep invocations dogfooding surfaced as the
next holes in the "never reach for `rg`" goal. Both fail-loud gaps before this
(`unknown flag`), so an agent's `rg --files -g …` / `rg -o …` muscle memory hit a
wall mid-loop.

- **`--files [PATH…]`** lists every corpus file the `-t`/`-g`/PATH filter admits
  — and does it with **zero file reads and zero tree walk**. gist already holds
  the whole path list in the mmap'd index, so discovery is a pure in-memory
  filter + sort where `rg --files` must walk the entire tree. On this repo that's
  the difference between an instant answer and a walk that, from the *uncurated*
  root, stalls on the 106 GB of build/vendor mass gist's corpus policy already
  excludes (measured: `rg` content-search from repo root **hangs >20 s**, `rg
  --files` 93 ms; gist projects the index in a few ms). Read-your-own-writes is
  preserved — the freshness overlay folds in files created since the build (a
  stat-only walk, no reads) so a coworker's just-written file still appears; a
  file *deleted* since the last `index` may still list (no read to verify it away)
  and self-heals on rebuild, the same tolerated false-positive the trigram filter
  carries. The projection is intentionally the curated code set: no build caches
  (`.zig-cache/`, `dist-types/`, `.local/`), no binaries, no >4 MiB blobs — arguably
  a *better* discovery list for an agent than rg's raw walk.

- **`-o`/`--only-matching`** emits each non-overlapping match's TEXT alone (not
  the whole line), one `path:line:text` row per match — extraction of idents,
  symbols, URLs, hex, etc. The DFA is match/no-match only, so spans run the Pike
  VM with a per-state start-offset side-channel added to the ε-closure (`starts`
  in `Closure`, null on the hot boolean path — no cost to `lineMatch`/`docMatch`).
  Semantics are rg's `(?-u)` exactly: **leftmost start, then the highest-priority
  thread wins the end** — earlier alternation branches and greedy quantifiers
  extend maximally (empirically fixed against `rg -o`: `a|ab`→`a`, `a+`→greedy,
  `[0-9]{2,}`→longest run). After a match at `[s,e)` the next search resumes at
  `e` (non-overlapping); a zero-width match steps one byte so a nullable pattern
  can't loop.

**Proof (byte-exact vs `rg -o` on the shared corpus):** an 11-pattern
differential battery (`func \w+`, `[A-Z]\w+Error`, `return|continue|break`,
`\bfunc\b`, `[a-z]+[A-Z]\w+`, `a|ab`, `[0-9]{2,}`, …) over `services/backend/gateway`
diffs to **0 lines** against `rg -o -n --no-heading --no-ignore --hidden
--no-unicode` (`.local/gist-dogfood/o_battery.sh`); every residual divergence
across the wider tree is a `.gitignore`/hidden/`isSkipDir` file — gist's
documented corpus policy, not a match bug. Permanent regression coverage:
`matchSpan` leftmost-first/greedy/anchor/boundary cases in `core_test.zig`, and
`-o`/`--files` argv parsing (bundling, pattern-optional, roots) in
`grepargs_test.zig`.
