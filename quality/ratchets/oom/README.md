# zig-oom ratchet

One canonical out-of-memory exit, no inline copies. OOM must route through the
one `oom()` helper (`pub const oom` in `src/surface/cli/outcome.zig`, an alias of
`allocFailure` in `src/corpus/scope/paths.zig`), never an inline `die("oom…")` at
the call site and never a copy-pasted local `fn oom(`.

The failure mode this freezes is the parity-bug class: two spellings of the same
exit, one gets the fix, the other silently keeps the bug.

## Tracked Patterns

- **An inline `die("oom…)`** is an OOM exit duplicated at a call site whose
  enclosing `fn` is not `oom`.
- **A non-`pub fn oom(`** is a copy-pasted local twin of the canonical helper.

The enclosing function of a `die("oom` site is the nearest preceding `fn NAME(`
line; only `NAME == oom` exempts it, which is how the canonical body's own
`die("oom` stays out of the count.

Matching is comment/string-aware: a needle inside a `//` comment or a `\\`
multiline-string line never counts, and a match that starts inside a `"…"`
literal is rejected by span. (The needle carries its own opening quote, so this
ratchet keeps string literals in place instead of blanking them — that is the
one deliberate difference from `_lib/zigtext.py`.)

Scope: `src/**/*.zig`, excluding `*_test.zig`, `*.gen.zig`, and generated-header
files.

## Surface

```bash
python3 quality/ratchets/run.py oom             # diff current counts vs oom.baseline (CI gate)
python3 quality/ratchets/run.py oom --refresh   # rewrite the baseline after a deliberate cleanup
```

Baseline format and diff/CLI scaffolding are shared via
`quality/ratchets/_lib/ratchet.py`.
