---
doc_radar:
  occurrences:
    - description: "every declared CLI shape is one [[shape]] row in matrix.toml"
      file: pkg/kernels/irregex/bench/matrix/matrix.toml
      pattern: '\[\[shape\]\]'
      equals: 19
  sentinels:
    - description: "the driver reuses the certificate's stats (never a second impl)"
      file: pkg/kernels/irregex/bench/matrix/matrix.py
      contains:
        - "import certify_stats as S"
        - 'sub.add_parser("parity")'
        - 'sub.add_parser("gate")'
---

# gist/bench/matrix — the CLI-shape admission matrix

The races and the certificate prove gist beats the field on a handful of
regex *classes*. This folder proves it across the **shape** dimensions a
real invocation turns on — `mode` (linear / `-U` / `-P`), match `flags`,
walk `scope`, `emit` shape, `select`ivity, and pattern `kind` — with the
plan's discipline: **parity before speed, every divergence declared.**

`matrix.toml` is the machine-readable matrix: one `[[shape]]` row per
supported CLI shape, each carrying the real flags, a corpus pattern of known
selectivity, its parity `bar`, and its performance `expect`ation.
`matrix.py` lowers every row into an actual argv and drives it three ways —
gist cold-indexed, gist cold-unindexed (`--no-index`), and ripgrep — so
eligibility and index-elision are **measured, not inferred**.

```bash
python3 matrix.py parity                 # correctness gate: gist-idx == gist-noidx == rg
GIST_BENCH=1 python3 matrix.py bench --publish   # measure + refresh floors/certificate
python3 matrix.py gate                   # assert committed per-shape floors (hermetic)
python3 matrix.py bench --only <id> --runs 20     # re-measure one shape (no publish)
```

## The three subcommands

- **`parity`** — asserts `gist-idx == gist-noidx == rg` at each row's bar
  (`set` / `lines` / `count`) plus exit-class parity. Fail-closed: any
  unexpected divergence is a hard error. This is the correctness gate, and it
  is what earns a shape the right to a performance verdict.
- **`bench`** — times gist cold-indexed vs ripgrep with the **same**
  bootstrap-CI + Mann-Whitney machinery the certificate uses
  (`certify/certify_stats.py`, imported — the statistics are defined once,
  never re-implemented). One fail-closed `win`/`parity`/`loss` verdict per row;
  `--publish` refreshes `matrix_baseline.json` (floors), `matrix.csv` (rows),
  and `CERTIFICATE_MATRIX.md`.
- **`gate`** — asserts the committed per-shape floors hermetically (no
  re-timing), mirroring `session/gate_session.py`. Floors are conservative:
  a `win` row's floor is 0.75× its measured speedup (≥1.0); a `parity` row
  holds a fixed 0.75× band. `--live` re-benches first (opt-in, `GIST_BENCH=1`).

## The one honest asymmetry — declared losses are report-only

A row may be born `expect="loss"`. The gate reports it but never fails on it,
so a **known** hole can never be hidden by an aggregate win — and can never be
mistaken for a regression either. Today's declared losses:

- **`multiline-*`** (`-U`) — the multiline emit runs on the serial engine
  (whole-buffer cross-line spans the parallel pipeline deliberately does not
  own, to protect its 30/30 parity), forfeiting the parallel walk. Even a
  *rare* span loses; a *common* lazy-dotstar (`[\s\S]*?`) loses hardest.
- **`pcre-backref-files`** — a pure backreference has no extractable required
  literal, so the trigram index has nothing to prefilter on and gist scans the
  whole corpus like rg does.

Correctness still gates every loss (parity passes). Parallelizing `-U` and
narrowing the literal-less PCRE2 path owns turning them green; when that lands,
flip `expect` to `win`/`parity` and the gate starts enforcing a floor.

## Why cold-indexed vs rg (not warm here)

This matrix certifies the **cold-process product path** against ripgrep. The
**in-process ceiling** (`races/headtohead.sh`) and the **resident-product
path** (`session/`) are certified separately and kept distinct in prose and
artifacts — no path's number is ever quietly borrowed for another's claim.
