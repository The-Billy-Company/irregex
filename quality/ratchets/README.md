# Zig lint ratchets

Four baseline-guarded lints over `src/**/*.zig`. They came from the monorepo
irregex was extracted from, where they scanned this same tree; the tree moved, so
the gates moved with it.

## What a ratchet is

A ratchet counts occurrences of one debt pattern **per file** and compares the
count against a committed `.baseline`. It fails when a count went **up**:

- a file not in the baseline must have **zero** findings — new code is born clean;
- a file in the baseline may only **shrink**;
- a file that dropped to zero is removed from the baseline on the next refresh.

That is the whole mechanism. It lets a gate ship over a codebase that does not
yet satisfy it, without either blocking every commit or pretending the debt isn't
there. The debt is written down, in a file, per line, and it can only get
smaller.

**The baseline is never lifted to go green.** Raising a number, or adding a row,
to make a red gate pass is the one forbidden move — it converts a gate that was
telling you something into a gate that tells you nothing. `--refresh` exists for
exactly one situation: you did a cleanup, the counts went *down*, and you want
the new floor recorded. Refreshing is correct after a fix and never instead of
one.

## The four gates

| Gate | Debt it freezes |
| --- | --- |
| [`oom/`](oom/) | out-of-memory exits that don't route through the one canonical `oom()` helper — an inline `die("oom…")`, or a copy-pasted local `fn oom(` |
| [`dup-helper/`](dup-helper/) | the same substantial `fn` body copy-pasted across two files, where a fix lands in one copy and the twin silently keeps the bug |
| [`fault-taxonomy/`](fault-taxonomy/) | an error name produced by production Zig that is not a declared member of `[fault_domains]` in `contract/engine.toml` — the closure that makes `Corrupt`/`BadFormat`/`CorruptIndex` synonyms impossible |
| [`assay-bypass/`](assay-bypass/) | a `std.debug.print(` that bypasses the `assay` diagnostic channel and writes to a host's real stderr |

Each directory holds its driver, its `.baseline`, its unit tests, and a README
explaining the rule and its exclusions in detail.

## Running them

```bash
python3 quality/ratchets/run.py                    # all four
python3 quality/ratchets/run.py oom                # just one
python3 quality/ratchets/run.py oom dup-helper     # a couple
python3 quality/ratchets/run.py --list             # what exists
python3 quality/ratchets/run.py --json             # machine-readable diff
python3 quality/ratchets/run.py oom --refresh      # rewrite a baseline (read the rule above)
```

Stdlib-only Python 3.11+, no dependencies, no Zig toolchain, no build step. Exit
code is 1 if any selected gate failed. This is what CI runs (the `ratchets` job
in `.github/workflows/ci.yml`).

The unit tests are plain `unittest` and live beside each driver:

```bash
for t in quality/ratchets/*/test_*.py; do python3 "$t"; done
```

## Two gates are red on arrival

`oom` and `assay-bypass` pass. `dup-helper` and `fault-taxonomy` do not, and
their baselines were deliberately left as they came rather than reseeded from
the current scan - seeding is how a gate stops being a gate.

Most of what they found is real, and it is in code these baselines predate:

- **dup-helper**, three duplicated bodies across five files. `wallNowNs` in
  `exec/session/watch/inotify.zig` and `.../kqueue.zig`; `thinner` in
  `kernel/regex/analysis/analysis.zig` and `kernel/regex/ast/ast.zig`; and one
  body under two names, `uclassLiteral` in `analysis.zig` and `litOfUclass` in
  `kernel/regex/ast/facts.zig`.
- **fault-taxonomy**, sixteen undeclared names in one file: `corpus/tree/sheaf.zig`'s
  `error.Declined`, which is a declinature riding the error channel - exactly the
  shape `fault.Answer(T)` exists to hold.

It also reported three of `portal.zig`'s Windows mapping faults
(`MappingAlreadyExists`, `MemoryMappingNotSupported`, `PermissionDenied`), and
that turned out to be the detector's fault rather than the code's: they are
members of `std.posix.MMapError`, which is what `ntMap`'s declared `MapError`
*is*, so the Windows arm is restating std's vocabulary because its signature
obliges it. The gate learned the rule it was missing - a `return` into a
declared std error set produces nothing new - rather than the baseline learning
to look away.

Each is a small, local fix. Do them and the gates go green on their own; there
is nothing to refresh.

## Layout

```
quality/ratchets/
├── run.py                    the entry point; discovers ratchets structurally
├── _lib/
│   ├── ratchet.py            baseline read/write, the diff, the CLI, the file walk
│   └── zigtext.py            a Zig lexer: blanks comments and strings so a
│                             pattern named in prose is not a finding
└── <name>/
    ├── <name>_ratchet.py     the detector; exposes scan() and main(argv)
    ├── <name>.baseline       the committed counts
    ├── test_<name>_ratchet.py
    └── README.md
```

Adding a gate is adding a directory: one `*_ratchet.py` whose `main(argv)` calls
`run_count_cli`, and `run.py` picks it up with no roster to edit. The baseline is
resolved relative to the driver's own path, so co-location is load-bearing — a
ratchet directory moves as a unit.
