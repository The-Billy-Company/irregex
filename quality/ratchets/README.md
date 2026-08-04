# Zig lint ratchets

Five baseline-guarded lints over `src/**/*.zig`. Four came from the monorepo
irregex was extracted from, where they scanned this same tree; the tree moved, so
the gates moved with it. The fifth, `isa-floor`, was written here, against a
defect that had already shipped.

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

## The Five Gates

- **[`isa-floor/`](isa-floor/)** freezes an inline `asm` block selected by
  `builtin.cpu.arch` rather than `cpu.has` — LLVM cannot see inside the
  template, so the instruction ships whatever the target's declared CPU floor
  promised.
- **[`oom/`](oom/)** freezes out-of-memory exits that don't route through the
  one canonical `oom()` helper — an inline `die("oom…")`, or a copy-pasted
  local `fn oom(`.
- **[`dup-helper/`](dup-helper/)** freezes the same substantial `fn` body
  copy-pasted across two files, where a fix lands in one copy and the twin
  silently keeps the bug.
- **[`fault-taxonomy/`](fault-taxonomy/)** freezes an error name produced by
  production Zig that is not a declared member of `[fault_domains]` in
  `contract/engine.toml` — the closure that makes `Corrupt`/`BadFormat`/
  `CorruptIndex` synonyms impossible.
- **[`assay-bypass/`](assay-bypass/)** freezes a `std.debug.print(` that
  bypasses the `assay` diagnostic channel and writes to a host's real stderr.

Each directory holds its driver, its `.baseline`, its unit tests, and a README
explaining the rule and its exclusions in detail.

## Running them

```bash
python3 quality/ratchets/run.py                    # all five
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

## Some Baselines Predate the Gate

The four gates inherited from that monorepo each had their `.baseline` seeded
from whatever the tree already looked like on the day the gate landed — not
reseeded to zero, because seeding a baseline to hide standing debt is how a
gate stops being a gate. A file that already appears in a `.baseline` is
allowed to keep its existing count; it only fails when that count goes *up*
or a file outside the baseline gets its first finding.

A file already sitting in the `.baseline` at an unchanged count reports
nothing at all — the diff only prints `increased` (an existing file whose
count went up) and `new_files` (a file with no baseline entry, first offense).
Inherited debt is invisible in a passing or failing run alike; the only way to
see it is to open a `.baseline` file directly, one `<path>=<count>` line per
offender. Run the live command for the current pass/fail state of all five:

```bash
python3 quality/ratchets/run.py --json
```

The detector has also occasionally been wrong rather than the code —
`fault-taxonomy` once flagged Windows mapping faults that were only restating
`std.posix.MMapError`'s own vocabulary because a signature obliged it, and the
fix there was teaching the gate the rule it was missing, not silencing the
finding.

## Layout

```text
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
