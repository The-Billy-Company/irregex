**`grep` accepts the reflexive ripgrep surface an agent's muscle memory types**
(`bench/grepargs.zig`, extracted from `bench/lines.zig`; `bench/pathfilter.zig`).
Found by dogfooding gist *as the agent* against `rg` on real repo questions: the
goal is to *never reach for ripgrep*, but three reflexive invocations still broke
— one of them silently, the worst failure mode. All three are closed, byte-exact
vs `rg` (9/9 head-to-head, `.local/gist-dogfood/prove.sh`):

- **Positional PATH args now scope the search** — `grep WalletService services/`
  used to search the *whole repo* while the agent believed it scoped (a
  wrong-but-confident result). Every non-flag token after the pattern is now a
  path root AND-ed into the `PathFilter` and **pruned before any read** — gist's
  structural edge, not just parity: `grep WalletService services/backend/api`
  reads **28 candidates** (vs 86 unscoped, vs rg's whole-subtree walk) and runs
  **1.14× faster than rg at ~⅕ the syscall time** (112 ms vs 590 ms system,
  hyperfine 15-run), output byte-identical.
- **Bundled short flags** — `-ln`, `-in`, `-nw`, `-nC3` used to fail loud as
  "unknown flag". A `-xyz` cluster is now decomposed left-to-right; the first
  *value* flag consumes the cluster remainder (`-nC3` ⇒ `-n -C 3`, `-tgo` ⇒
  `-t go`) or the next token.
- **Harmless rg flags** — `-n` (line numbers, always on), `-H`, `-r`/`-R`,
  `--no-heading`, `--color[=X]`, `--with-filename` are accepted as **no-ops**
  under gist's fixed `path:line:text` model (they used to fail loud); `-N` /
  `--no-line-number` drops the line column for real, and `-S` / `--smart-case`
  folds iff the pattern carries no uppercase (rg's rule). Every existing flag
  also gained its rg **long spelling** (`--ignore-case`, `--context=N`,
  `--type=<lang>`, `--glob=<glob>`, `--max-count=N`, …).

Fail-loud is preserved for genuinely unknown flags (a silent empty result is the
worst agent failure) — the diagnostic now prints the full supported surface. The
parser moved to its own module so `lines.zig` (line emit/verify) drops from 479 →
344 lines and the larger compatibility table lives on its own (both under the
500-line shape cap). New adversarial tests (`bench/grepargs_test.zig`, 12 cases)
pin bundling, no-ops, long-flag `=`/next-token values, smart-case, `-e`/`--`
leading-dash safety, and the fail-loud contract; `bench/pathfilter_test.zig`
gains positional-root coverage (dir-prefix `/`-boundary, exact file, `.`
whole-corpus, `normalizeRoot`). The `gist ≡ rg` set oracle is unchanged.
