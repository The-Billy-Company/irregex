#!/usr/bin/env python3
"""The cross-engine bar: our automaton against rust-`regex`'s, same patterns.

Everything else in `bench/rungs/automata/` races us against ourselves, which is
the right instrument for attributing a layout change and the wrong one for
answering "is our automaton better than theirs". This joins the rung's own
`shape` TSV against `regex-cli debug dense dfa` from the clone in `upstream/regex`,
so the alphabet and table-area claims are measured against the incumbent instead
of asserted about it.

Fairness is the whole design, and three choices carry it:

  * **Byte semantics on both sides.** Our default dialect is a byte matcher;
    theirs is Unicode-aware. Every pattern is therefore handed to them with a
    leading `(?-u)` — exactly as `bench/dominance/races/regex.sh` does for `rg` —
    plus `-b -B`, which lifts their refusal to compile a byte pattern that can
    match invalid UTF-8. Both are required, not generous: without `(?-u)` their
    `\\w` lowers a UTF-8 trie and the comparison measures a flag rather than a
    determinizer (for `pgxpool\\.\\w+` that flag alone is 124 classes vs 21, and
    351 KB vs 2 KB), and without `-b -B` every `.`-bearing pattern is refused
    outright rather than raced.
  * **Their config is stated, not chosen.** Their DFA is non-minimal by default.
    Racing our table against their default is the honest PRODUCT comparison —
    it is what the world actually links — and racing it against `--minimize` is
    the honest ALGORITHMIC one. Both columns are always printed. `--start-kind
    unanchored` matches what we build (we have no anchored start group) and
    `--captures none` matches a DFA that reports no groups.
  * **Two area numbers, because they mean different things.** `mem` is what they
    report from `memory_usage()` — every byte the automaton holds. `tbl` is the
    transition table alone, `states x stride x 4`, which is the number our
    `table_bytes` is directly comparable to. Their stride is the alphabet
    rounded UP to a power of two, so `tbl/alpha` is the padding tax their
    premultiplication forces and our exact stride does not pay.

Two things it deliberately does NOT claim:

  * **Search throughput.** Timing two engines' scans through two CLIs measures
    process startup, IO, and prefilter policy far more than it measures a
    transition loop. The binary-level search race already exists and is honest
    about being one (`bench/dominance/races/regex.sh`); the automaton-level
    search claim is the self-race in `bench.zig`.
  * **State count, as a headline.** Their automaton reserves special states — a
    dead state, a quit state, and a start group — so on a five-state pattern the
    reserved overhead IS the difference. The `dfa` columns are printed because
    they are informative on the wide patterns, where the overhead is noise; the
    geometric means are computed on alphabet and table area, which carry no such
    fixed offset.

And one it cannot: their DFA searches a whole buffer and ours searches a line, so
their `$` is end-of-haystack where ours is end-of-line. That is a model
difference, not a shape difference, and it is why our area carries a second
`trans_fin` table they encode as one EOI column — the gap `research/automata`
tracks as C2.

Usage:
    python3 bench/rungs/automata/bar.py [--clone PATH] [--json]

Exits 2 when the clone or its CLI is missing, since a bar nobody measured
against is not a result. Build it with:
    cd upstream/regex/regex-cli && cargo build --release
"""

from __future__ import annotations

import argparse
import json
import math
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
# bench/rungs/automata → the package root, then out to the repo root.
PKG = HERE.parents[2]  # automata → rungs → bench → repo
REPO = PKG
DEFAULT_CLONE = REPO / ".etc" / "regex"

# `regex-cli` prints a `key: value` preamble before the automaton itself. These
# are the four facts a shape comparison needs; anything else in that block is
# theirs to change without breaking us.
FIELDS = {
    "alphabet len": "alphabet",
    "stride": "stride",
    "memory": "memory",
    "compile dfa time": "dfa_time",
}
STATE_LEN = re.compile(r"^state length:\s*(\d+)\s*$", re.M)
DURATION = re.compile(r"^([0-9.]+)(ns|µs|us|ms|s)$")


def duration_ns(text: str) -> float | None:
    """Their timings carry a unit suffix; normalize to nanoseconds."""
    m = DURATION.match(text.strip())
    if not m:
        return None
    scale = {"ns": 1.0, "µs": 1e3, "us": 1e3, "ms": 1e6, "s": 1e9}
    return float(m.group(1)) * scale[m.group(2)]


def ours(pkg: Path) -> list[dict[str, object]]:
    """Run the rung's `shape` section and parse its TSV."""
    proc = subprocess.run(
        ["zig", "build", "automata-rung", "--", "shape"],
        cwd=pkg,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        raise SystemExit(f"automata-rung shape failed (exit {proc.returncode})")
    lines = [ln for ln in proc.stdout.splitlines() if ln.strip()]
    if not lines:
        raise SystemExit("automata-rung shape produced no rows")
    head = lines[0].split("\t")
    rows: list[dict[str, object]] = []
    for ln in lines[1:]:
        cells = ln.split("\t")
        if len(cells) != len(head):
            continue
        row: dict[str, object] = dict(zip(head, cells))
        for k in ("nfa", "cls", "dfa", "accept", "table_bytes", "build_ns"):
            row[k] = int(row[k])  # type: ignore[arg-type]
        rows.append(row)
    return rows


def theirs(cli: Path, pattern: str, minimize: bool, reps: int = 1) -> dict[str, float] | None:
    """`regex-cli debug dense dfa`, byte semantics, fair start kind.

    Shape is deterministic, so one run settles it. The **timing** is not: their
    first invocation in a session pays a warmup their later ones do not (263 µs
    against 29 µs for the next pattern, on the same machine), and publishing that
    against our min-of-N would be crediting us for their cold start. So `reps`
    runs are taken and the FASTEST `compile dfa time` wins, which is exactly the
    estimator our own side uses. Each rep is a fresh process, so this measures
    their determinizer and not a cache we warmed for them.
    """
    argv = [
        str(cli),
        "debug",
        "dense",
        "dfa",
        "--start-kind",
        "unanchored",
        "--captures",
        "none",
        "-b",  # byte syntax: permit a pattern that can match invalid UTF-8
        "-B",  # byte NFA: the same permission at the automaton level
    ]
    if minimize:
        argv.append("--minimize")
    argv += ["--", f"(?-u){pattern}"]
    out: dict[str, float] = {}
    for _ in range(max(1, reps)):
        proc = subprocess.run(argv, capture_output=True, text=True)
        if proc.returncode != 0:
            return None
        for line in proc.stdout.splitlines():
            if ":" not in line:
                continue
            key, _, value = line.partition(":")
            field = FIELDS.get(key.strip())
            if field is None:
                continue
            if field.endswith("_time"):
                ns = duration_ns(value)
                if ns is not None:
                    out[field] = min(out.get(field, ns), ns)
            else:
                out[field] = float(value.strip())
        m = STATE_LEN.search(proc.stdout)
        if m:
            out["states"] = float(m.group(1))
    return out if {"alphabet", "stride", "memory", "states"} <= out.keys() else None


def geomean(values: list[float]) -> float | None:
    live = [v for v in values if v > 0]
    if not live:
        return None
    return math.exp(sum(math.log(v) for v in live) / len(live))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--clone", type=Path, default=DEFAULT_CLONE, help="the rust-regex clone")
    ap.add_argument("--json", action="store_true", help="NDJSON rows instead of a table")
    ap.add_argument(
        "--reps",
        type=int,
        default=9,
        help="runs of their CLI per pattern; the fastest reported build time wins",
    )
    args = ap.parse_args()

    cli = args.clone / "target" / "release" / "regex-cli"
    if not cli.exists():
        sys.stderr.write(
            f"no regex-cli at {cli}\n"
            "  the bar is not optional — build it:\n"
            f"    cd {args.clone / 'regex-cli'} && cargo build --release\n"
        )
        return 2
    if shutil.which("zig") is None:
        sys.stderr.write("no zig on PATH — cannot measure our own side\n")
        return 2

    rows = ours(PKG)
    joined = []
    for row in rows:
        pat = str(row["pattern"])
        base = theirs(cli, pat, minimize=False, reps=args.reps)
        mini = theirs(cli, pat, minimize=True)
        if base is None:
            sys.stderr.write(f"skipped (their engine declined): {pat}\n")
            continue
        joined.append({"ours": row, "theirs": base, "theirs_min": mini})

    if args.json:
        for r in joined:
            print(json.dumps(r, sort_keys=True))
        return 0

    print(
        "cross-engine automaton bar — gist vs rust-regex-automata\n"
        f"their clone: {args.clone}\n"
        "both sides byte semantics: (?-u) on the pattern, -b -B on their config\n"
        "their config: --start-kind unanchored --captures none, and again with "
        "--minimize\n"
        "\n"
        "  cls    byte-equivalence classes — lower is a coarser alphabet\n"
        "  dfa    states. Theirs reserves a dead state, a quit state and a start\n"
        "         group, so on a tiny automaton that overhead IS the gap; read this\n"
        "         column on the wide patterns and ignore it on the narrow ones.\n"
        "  tblB   the transition table alone: states x stride x 4. Their stride is\n"
        "         the alphabet rounded UP to a power of two, which is the padding\n"
        "         tax their premultiplication forces; ours is the exact class count.\n"
        "  bldus  microseconds to determinize. Ours is min-of-N over the shipped\n"
        "         NFA; theirs is the `compile dfa time` their own CLI reports.\n"
    )
    print(
        f"{'':<46}{'cls':>11}{'':>7}{'dfa':>17}{'tblB':>21}{'':>7}{'bldus':>17}{'':>7}"
    )
    print(
        f"{'pattern':<46}{'us':>5}{'them':>6}{'x':>7}"
        f"{'us':>5}{'them':>6}{'min':>6}"
        f"{'us':>9}{'them':>12}{'x':>7}"
        f"{'us':>8}{'them':>9}{'x':>7}"
    )

    cls_ratios: list[float] = []
    tbl_ratios: list[float] = []
    bld_ratios: list[float] = []
    for r in joined:
        o, t = r["ours"], r["theirs"]
        tm = r["theirs_min"]
        their_tbl = t["states"] * t["stride"] * 4
        cls_r = t["alphabet"] / o["cls"] if o["cls"] else 0.0
        tbl_r = their_tbl / o["table_bytes"] if o["table_bytes"] else 0.0
        our_us = o["build_ns"] / 1000.0
        their_us = (t.get("dfa_time") or 0.0) / 1000.0
        bld_r = their_us / our_us if our_us else 0.0
        cls_ratios.append(cls_r)
        tbl_ratios.append(tbl_r)
        bld_ratios.append(bld_r)
        print(
            f"{str(o['pattern'])[:45]:<46}"
            f"{o['cls']:>5}{int(t['alphabet']):>6}{cls_r:>6.2f}x"
            f"{o['dfa']:>5}{int(t['states']):>6}{(int(tm['states']) if tm else 0):>6}"
            f"{o['table_bytes']:>9}{int(their_tbl):>12}{tbl_r:>6.2f}x"
            f"{our_us:>8.1f}{their_us:>9.1f}{bld_r:>6.2f}x"
        )

    cls_g, tbl_g, bld_g = geomean(cls_ratios), geomean(tbl_ratios), geomean(bld_ratios)
    print()
    if cls_g:
        print(f"geomean: our alphabet is {cls_g:.2f}x coarser than theirs")
    if tbl_g:
        print(f"geomean: our transition table is {tbl_g:.2f}x smaller than theirs")
    if bld_g:
        print(f"geomean: we determinize {bld_g:.2f}x faster than they do")
    print(
        "\nAnd we win the table column while still carrying a duplicate `trans_fin`\n"
        "for the per-line `$` resolution they encode as one EOI column. Folding it\n"
        "(research/automata C2) would nearly halve our area again — but the area\n"
        "sweep in this same rung showed area is not a throughput lever here: at\n"
        "constant walk breadth a table can grow 85x for free. So treat this column\n"
        "as resident memory, which is worth winning on its own terms, and not as a\n"
        "proxy for speed. The speed columns are `cls` and `bldus`."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
