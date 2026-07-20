Closed the last supported-surface divergences between `gist rg` and ripgrep
15.1.0: the mined differential suite now scores **405/405 = 100%** on _both_
walk engines (parallel and serial), zero FAIL, zero deferred entries.

- **`--include-zero` / `--no-include-zero`** (last-wins) are honored across
  `-c`/`--count` and `--count-matches`: a searched file with no match now emits
  its `path:0` line like rg, so the two flags round-trip. Zero-count output
  disables the whole-file match gate and index read-elision (a file provably
  without a match must still be _named_), and the request is routed to the
  serial engine so every candidate is accounted for; exit status stays 1 when
  nothing matched.
- **NUL-bearing patterns** are rejected under default binary detection exactly
  where rg's `regex::ban` rejects them — a pattern that _literally_ contains a
  NUL byte (`Regex.bansByte`: a singleton `{0}` consume state), not one that
  merely _can_ match NUL (`.`, a range) — while `-a`/`--text` and `--null-data`
  still allow it. The ban rides the linear engine only; PCRE2 (`-P`) keeps rg's
  PCRE2 semantics.
- **Inline `(?-m)` / `(?s)` under `-U`** now reshape whole-buffer matching:
  multiline mode and the `^`/`$` line-anchor behavior are tracked separately, so
  `gist -U '(?-m)…'` anchors to the buffer and `(?s)` lets `.` cross newlines,
  matching rg instead of being silently inert.
- **PCRE2 whole-buffer multiline lookahead** — `(?s)alpha(?=.*bar)` and friends
  operate over the entire multiline buffer in normal, count, and files-only
  modes (JIT and interpreter agree), locked by adverse backend tests.
- **Ancestor-ignore parity**: ignore files in the directories _between_ CWD and
  an explicitly-named positional root are now loaded (`Ignore.loadRootAncestors`,
  rg's `add_parents`), an escaped trailing slash (`foo\/`) marks a rule dir-only
  without leaking the backslash into the glob, and a leading `**/` in an anchored
  ancestor rule floats depth-independently instead of being stripped.
- **`--schema` authority** advertises the real flag catalog at
  `src/surface/exec/cold/argv/args.zig:flag_catalog` (was a stale `runtime/cold`
  path), proven by a compile-time `@embedFile` assertion so it cannot drift again.

Verified by `python3 bench/rgsuite/run.py` (both engines), the strict
`bench/rgsuite/check_results.py` (no `--allow-fail`), and `zig build test`.
