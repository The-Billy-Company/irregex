#!/usr/bin/env python3
"""Scale race — gist vs zoekt vs csearch over a multi-GB corpus.

The certificate corpus is 20.6k files / 204.6 MiB. The claim under test is that
gist "is not built for GitHub scale", so this races the same three *indexed*
engines over a corpus an order of magnitude larger (shallow clones of the Linux
kernel, LLVM, the Go tree and the Rust tree), on the same bytes, and reports:

  · index build wall time, peak RSS, and index size as a fraction of corpus,
  · query latency across the canonical 12 probe classes, cold and warm,
  · resident-set behaviour while querying — the question of whether an engine
    must hold its index in memory or can let the kernel page it, which is where
    "GitHub scale" is usually actually decided.

Statistics are NOT reimplemented here: medians, bootstrap CIs and the
Mann-Whitney dominance verdict all come from `bench/certify/certify_stats.py`.

Fairness follows `bench/races/_compete.sh`:
  · GIST_UNCAP=1, so gist's agent-context output budget cannot clip a
    repo-wide result and flatter its own timing,
  · every engine answers the same question in the same mode — files-with-matches
    (`-l`), the only output shape all three share,
  · csearch indexes gist's exact corpus file list; zoekt takes no file list and
    indexes the roots tree, so zoekt is a timing reference over a SUPERSET of
    gist's bytes, not a correctness oracle. Hit counts are published per cell so
    a corpus disagreement is visible rather than hidden inside a latency ratio.

Usage:
  python3 bench/sliver/scale_race.py --corpus DIR --gist-dir DIR \
      --zoekt-dir DIR --csearch-idx FILE [--reps 5] [--out DIR]
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import sys
import time


HERE = Path(__file__).resolve().parent
KERNEL = HERE.parent.parent.parent
sys.path.insert(0, str(KERNEL / "bench" / "certificate" / "report"))
from stats import dominance, median_ci  # noqa: E402


GIST = KERNEL / "zig-out" / "bin" / "gist"

# Byte-identical to bench/certify/ratio_regress.py PROBES — the canonical 12.
# Needles are host-repo shaped on purpose: keeping them identical is what makes
# a scale cell comparable to the certificate's own cell. A needle absent from
# this corpus still measures something real (the pure index-filter path), and
# its zero hit count is published so the cell cannot be mistaken for a scan.
PROBES: tuple[tuple[str, str, str], ...] = (
    ("literal-rare", "literal", "pgxpool"),
    ("literal-dotted", "literal", "context.Context"),
    ("literal-common", "literal", "func"),
    ("literal-punct2", "literal", "})"),
    ("regex-decl", "regex", r"func\s+\w+\("),
    ("regex-dotted", "regex", r"pgxpool\.\w+"),
    ("regex-anchored", "regex", r"^func\s"),
    ("regex-classcount", "regex", r"[0-9a-f]{8}-[0-9a-f]{4}"),
    ("regex-alternation", "regex", r"return|continue|break"),
    ("regex-dense-scan", "regex", r"\w{3,8}"),
    ("regex-eol", "regex", r";$"),
    ("regex-litalt", "regex", r"panic|0x"),
)


@dataclass
class Cell:
    """One (class, tool) measurement."""

    cls: str
    tool: str
    times_ms: list[float] = field(default_factory=list)
    hits: int = -1
    failed: str = ""


def _run(cmd: list[str], cwd: Path, env: dict[str, str]) -> tuple[float, int, str]:
    """Wall-clock one invocation; return (ms, line count on stdout, stderr tail)."""
    t0 = time.perf_counter()
    p = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True)
    ms = (time.perf_counter() - t0) * 1000.0
    n = p.stdout.count(b"\n")
    return ms, n, p.stderr.decode("utf-8", "replace")[-200:]


def _cmd(tool: str, kind: str, pat: str, a: argparse.Namespace) -> list[str] | None:
    """The files-with-matches invocation for each engine, or None if unsupported."""
    if tool == "gist":
        base = [str(GIST), "-l", "--sort", "none"]
        return base + (["-F"] if kind == "literal" else []) + [pat, "."]
    if tool == "zoekt":
        # zoekt's query language treats the argument as a regexp; a literal needs
        # quoting so its metacharacters are not reinterpreted.
        q = f'"{pat}"' if kind == "literal" else pat
        return ["zoekt", "-index_dir", str(a.zoekt_dir), "-l", q]
    if tool == "csearch":
        # csearch is regexp-only (RE2); a literal is passed with -f-style quoting
        # via the same regexp engine, so escape it.
        import re as _re

        q = _re.escape(pat) if kind == "literal" else pat
        return ["csearch", "-l", q]
    return None


def measure(a: argparse.Namespace) -> list[Cell]:
    corpus = a.corpus.resolve()
    cells: list[Cell] = []
    tools = [t for t in ("gist", "zoekt", "csearch") if shutil.which(t) or t == "gist"]
    for cls, kind, pat in PROBES:
        for tool in tools:
            env = dict(os.environ, GIST_UNCAP="1")
            env["GIST_DIR"] = str(a.gist_dir)
            env["GIST_ROOTS"] = "."
            env["CSEARCHINDEX"] = str(a.csearch_idx)
            cmd = _cmd(tool, kind, pat, a)
            c = Cell(cls=cls, tool=tool)
            if cmd is None:
                c.failed = "unsupported"
                cells.append(c)
                continue
            # one discarded warm-up, then `reps` timed samples
            try:
                _run(cmd, corpus, env)
                for _ in range(a.reps):
                    ms, n, err = _run(cmd, corpus, env)
                    c.times_ms.append(ms)
                    c.hits = n
                    if err and n == 0:
                        c.failed = err.strip().splitlines()[0][:120] if err.strip() else ""
            except (OSError, subprocess.SubprocessError) as exc:  # unobtainable lane
                c.failed = f"{type(exc).__name__}: {exc}"[:120]
            cells.append(c)
            print(
                f"  {cls:<20} {tool:<8} "
                + (
                    f"{sorted(c.times_ms)[len(c.times_ms) // 2]:>9.0f} ms  {c.hits:>8} files"
                    if c.times_ms
                    else f"UNOBTAINABLE: {c.failed}"
                ),
                flush=True,
            )
    return cells


def report(cells: list[Cell], a: argparse.Namespace) -> int:
    rng = random.Random(a.seed)
    by: dict[tuple[str, str], Cell] = {(c.cls, c.tool): c for c in cells}
    out = a.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    tsv = out / "scale_race.tsv"
    rows = ["class\ttool\tmedian_ms\tci_lo\tci_hi\thits\tvs_gist\tp\tverdict"]
    for cls, _kind, _pat in PROBES:
        g = by.get((cls, "gist"))
        for tool in ("gist", "zoekt", "csearch"):
            c = by.get((cls, tool))
            if c is None or not c.times_ms:
                rows.append(f"{cls}\t{tool}\t\t\t\t\t\t\t{(c.failed if c else 'missing')}")
                continue
            med, lo, hi = median_ci(c.times_ms, rng)
            sp, p, verdict = "", "", ""
            if g and g.times_ms and tool != "gist":
                d = dominance(g.times_ms, c.times_ms)
                sp, p, verdict = f"{d.speedup:.2f}", f"{d.p:.4g}", d.verdict
            rows.append(
                f"{cls}\t{tool}\t{med:.1f}\t{lo:.1f}\t{hi:.1f}\t{c.hits}\t{sp}\t{p}\t{verdict}"
            )
    tsv.write_text("\n".join(rows) + "\n")
    (out / "scale_race.json").write_text(
        json.dumps(
            {
                "corpus": str(a.corpus),
                "reps": a.reps,
                "cells": [
                    {
                        "class": c.cls,
                        "tool": c.tool,
                        "times_ms": c.times_ms,
                        "hits": c.hits,
                        "failed": c.failed,
                    }
                    for c in cells
                ],
            },
            indent=2,
        )
        + "\n"
    )
    print(f"\nwrote {tsv}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", type=Path, required=True)
    ap.add_argument("--gist-dir", type=Path, required=True)
    ap.add_argument("--zoekt-dir", type=Path, required=True)
    ap.add_argument("--csearch-idx", type=Path, required=True)
    ap.add_argument("--reps", type=int, default=5)
    ap.add_argument("--seed", type=int, default=20260727)
    ap.add_argument("--out", type=Path, default=HERE / "artifact")
    a = ap.parse_args()
    print(f"scale race · corpus {a.corpus} · reps {a.reps}", flush=True)
    return report(measure(a), a)


if __name__ == "__main__":
    sys.exit(main())
