#!/usr/bin/env python3
"""Walk cost — what a live tree walk costs in memory, this engine vs ripgrep.

THE CLAIM THIS LANE EXISTS TO SETTLE
    Layer J's residency argument turns on one matched pair. Our query-time
    resident set is large; the first explanation offered was "it must hold its
    index", which `vmmap` refuted; the second was "any engine walking a live
    tree pays this", and ripgrep refutes that one by walking the same tree for a
    fraction of the memory. That refutation is the honest form of the claim, and
    it was carried for a while as two numbers typed into prose — which is
    exactly the shape a fix invalidates silently. This lane measures it.

    The pair is matched on purpose: same needle, same `-uu` scope, same cwd,
    both counting rather than printing, both a fresh process with no index in
    play (`--no-index` + `<prefix>NO_AUTOSERVE=1`, so neither a persisted index nor
    a resident daemon can answer for the walk). The only difference left is the
    implementation of walking.

TWO METRICS, ONLY ONE OF WHICH IS A COST
    `maximum resident set size` charges a process for clean, file-backed,
    instantly-evictable mmap pages it walked through — so an engine that maps
    large files is billed for page cache an engine reading with `read(2)` gets
    for free. `peak memory footprint` (Darwin) is the dirty, anonymous memory
    the process actually owns. Both are reported; the ratio that means something
    is the owned one, and maxrss is reported beside it because a resident set
    that tracks the corpus rather than the query is still a defect worth seeing.

    On Linux `/usr/bin/time -v` reports maxrss only, so the owned column is
    absent rather than invented.

AND THE ANSWER IS CORPUS-SHAPED, WHICH IS WHY `--root` REPEATS
    A single tree cannot carry this claim. Measured on the same day with the
    same binaries, a deep C++ checkout puts us near 1.9x rg on owned memory
    while a tree of many cloned repositories puts it UNDER rg at 0.78x — rg's
    own footprint moves more between those two than ours does. So one root
    would let whoever picks it pick the verdict. Pass every tree the claim is
    supposed to hold over; each becomes its own row pair, and the reporter takes
    its headline from our WORST corpus rather than its best.
    (`scale_resident.tsv` holds the history of what this instrument was built to
    settle, and what it found.)

Usage:
  python3 bench/rungs/sliver/walkcost.py --root <tree> [--root <tree> …]
      [--pattern pgxpool] [--reps 3] [--out bench/rungs/sliver/artifact]

  Our half of the pair is driven by the sibling checkout's release build;
  `$<PREFIX>BIN` pins a specific one (see `product.gist_cli`).
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

from product import gist_cli

HERE = Path(__file__).resolve().parent
KERNEL = HERE.parent.parent.parent

# `/usr/bin/time -l` (Darwin, BSD) and `/usr/bin/time -v` (GNU) name the same
# quantity differently and in different units; both shapes are read so the lane
# runs on either without a platform branch at the call site.
_RSS = (
    re.compile(r"^\s*(\d+)\s+maximum resident set size", re.M),
    re.compile(r"Maximum resident set size \(kbytes\):\s*(\d+)", re.M),
)
_OWNED = re.compile(r"^\s*(\d+)\s+peak memory footprint", re.M)
MIB = 1024.0 * 1024.0


class Sample:
    """One tool's half of one corpus's matched pair, over the reps."""

    def __init__(self, tool: str, argv: list[str], corpus: str, files: int) -> None:
        self.tool, self.argv = tool, argv
        self.corpus, self.files = corpus, files
        self.rss: list[float] = []
        self.owned: list[float] = []
        self.seconds: list[float] = []
        self.hits = -1
        self.failed = ""

    def med(self, xs: list[float]) -> float | None:
        return statistics.median(xs) if xs else None


def _timed(argv: list[str], root: Path, env: dict[str, str]) -> tuple[str, bytes, float]:
    """Run under the platform's resource-reporting `time`, returning its report."""
    t0 = time.perf_counter()
    p = subprocess.run(
        ["/usr/bin/time", "-l" if sys.platform == "darwin" else "-v", *argv],
        cwd=root,
        env=env,
        capture_output=True,
    )
    return p.stderr.decode("utf-8", "replace"), p.stdout, time.perf_counter() - t0


def measure(a: argparse.Namespace) -> list[Sample]:
    return [s for root in a.root for s in _measure_one(a, root.resolve())]


def _measure_one(a: argparse.Namespace, root: Path) -> list[Sample]:
    # `-c` (count) so neither tool is billed for rendering a repo-wide result,
    # and `-F` so the needle is a literal to both engines rather than a regex to
    # one of them. `<prefix>UNCAP=1` keeps the product's agent-context output
    # budget from clipping the answer, the same fairness flag `_compete.sh` sets.
    pairs = [
        ("gist", [gist_cli(), "--no-index", "-uu", "-F", "-c", a.pattern, "."]),
        ("rg", ["rg", "-uu", "--no-messages", "-F", "-c", a.pattern, "."]),
    ]
    where, walked = _where(root), _walked(root)
    print(f"\n{where} · {walked:,} files walked", flush=True)
    out: list[Sample] = []
    for tool, argv in pairs:
        s = Sample(tool, argv, where, walked)
        if tool != "gist" and not shutil.which(tool):
            s.failed = "not installed"
            out.append(s)
            continue
        env = dict(os.environ, GIST_UNCAP="1", GIST_NO_AUTOSERVE="1")
        try:
            _timed(argv, root, env)  # one discarded warm-up: page cache, not the tool
            for _ in range(a.reps):
                report, stdout, wall = _timed(argv, root, env)
                for pat in _RSS:
                    if m := pat.search(report):
                        # BSD reports bytes, GNU kilobytes.
                        scale = 1.0 if pat is _RSS[0] else 1024.0
                        s.rss.append(int(m.group(1)) * scale / MIB)
                        break
                if m := _OWNED.search(report):
                    s.owned.append(int(m.group(1)) / MIB)
                s.seconds.append(wall)
                s.hits = sum(
                    int(line.rsplit(b":", 1)[-1] or 0)
                    for line in stdout.splitlines()
                    if b":" in line
                )
        except (OSError, subprocess.SubprocessError) as exc:
            s.failed = f"{type(exc).__name__}: {exc}"[:120]
        out.append(s)
        print(
            f"  {tool:<5} "
            + (
                f"{s.med(s.rss):>8.1f} MiB maxrss  "
                f"{(f'{s.med(s.owned):.1f}' if s.owned else '—'):>8} MiB owned  "
                f"{s.med(s.seconds):>6.2f} s  {s.hits:>8} matches"
                if s.rss
                else f"UNOBTAINABLE: {s.failed}"
            ),
            flush=True,
        )
    return out


def _cell(x: float | None) -> str:
    return f"{x:.1f}" if x is not None else "—"


def _shown(argv: list[str]) -> str:
    """The invocation as a reader would type it: the built binary's absolute path
    is this machine's, and a committed artifact that carries it diffs on whose
    home directory minted it rather than on what changed."""
    return " ".join([Path(argv[0]).name, *argv[1:]])


def _where(root: Path) -> str:
    """`root` relative to the workspace holding this checkout, when it is inside
    it — same reasoning as `_shown`, applied to the corpus. The anchor is the
    checkout's PARENT because that is where the corpora and the sibling packages
    sit now; anchoring inside the checkout, as the monorepo layout did, would put
    a home directory name in a committed artifact."""
    repo = KERNEL.parent
    return str(root.relative_to(repo)) if root.is_relative_to(repo) else str(root)


def _walked(root: Path) -> int:
    """How many files the pair actually walks — the product's own `--files`
    under the same `-uu` scope, so the denominator is the tree as measured rather
    than a separate traversal with its own idea of what counts."""
    p = subprocess.run(
        [gist_cli(), "--no-index", "-uu", "--files", "."],
        cwd=root,
        env=dict(os.environ, GIST_UNCAP="1", GIST_NO_AUTOSERVE="1"),
        capture_output=True,
    )
    return p.stdout.count(b"\n")


def _pairs(samples: list[Sample]) -> dict[str, dict[str, Sample]]:
    """Samples regrouped as corpus → tool → sample, in measurement order."""
    by: dict[str, dict[str, Sample]] = {}
    for s in samples:
        by.setdefault(s.corpus, {})[s.tool] = s
    return by


def _ratio(pair: dict[str, Sample], metric: str) -> float | None:
    """Our half over rg on one metric, or None where either half is missing it.

    Taken over the medians AS PUBLISHED, not the full-precision ones: the cells
    carry one decimal, and a reader dividing the two numbers in front of them
    should land on the ratio printed beside them. Recomputing from hidden digits
    puts a 0.01 disagreement between this artifact and the certificate that
    renders it, which reads as a mistake in whichever one you checked second.
    """
    g, r = pair.get("gist"), pair.get("rg")
    if not g or not r:
        return None
    gv, rv = g.med(getattr(g, metric)), r.med(getattr(r, metric))
    return round(gv, 1) / round(rv, 1) if gv and rv else None


def report(samples: list[Sample], a: argparse.Namespace) -> int:
    out = a.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    tsv = out / "scale_walkcost.tsv"
    lines = [
        "# The matched pair behind Layer J's residency refutation: what a LIVE tree",
        "# walk costs in memory, with no index in play on either side. Same needle,",
        "# same -uu scope, same cwd, both counting, both a fresh process.",
        "#",
        "# maxrss charges clean evictable mmap page cache; owned (Darwin 'peak memory",
        "# footprint') is the dirty memory the process cannot have reclaimed. The",
        "# ratio that is a cost is the owned one.",
        "#",
        "# One row pair PER CORPUS, because the ratio is corpus-shaped and a single",
        "# tree would let whoever chose it choose the verdict — rg's own footprint",
        "# moves more between these trees than gist's does. The reporter takes its",
        "# headline from gist's worst corpus here, never its best.",
        "#",
        f"# needle={a.pattern} reps={a.reps} platform={sys.platform}",
        "corpus\tfiles\ttool\tinvocation\tmaxrss_mib\towned_mib\tseconds\tmatches",
    ]
    for corpus, pair in _pairs(samples).items():
        for s in pair.values():
            stem = f"{corpus}\t{s.files}\t{s.tool}\t{_shown(s.argv)}"
            if s.failed and not s.rss:
                lines.append(f"{stem}\t\t\t\t{s.failed}")
                continue
            lines.append(
                f"{stem}\t{_cell(s.med(s.rss))}\t{_cell(s.med(s.owned))}\t"
                f"{_cell(s.med(s.seconds))}\t{s.hits}"
            )
        rss, owned = _ratio(pair, "rss"), _ratio(pair, "owned")
        if rss:
            lines.append(
                f"# ratio gist/rg over {corpus}: maxrss {rss:.2f}x"
                + (f" · owned {owned:.2f}x" if owned else "")
            )
    tsv.write_text("\n".join(lines) + "\n")
    print(f"\nwrote {tsv}")
    # The pair is the whole point: a corpus that could not obtain both halves has
    # measured nothing, and saying so beats publishing one side as a comparison.
    # Every named corpus must land, so a lane that quietly measured three of four
    # cannot pass as a four-corpus claim.
    pairs = _pairs(samples)
    return 0 if pairs and all(_ratio(p, "rss") for p in pairs.values()) else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--root", type=Path, required=True, action="append", help="tree to walk (repeatable)"
    )
    ap.add_argument("--pattern", default="pgxpool", help="literal needle")
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--out", type=Path, default=HERE / "artifact")
    a = ap.parse_args()
    roots = " · ".join(str(r) for r in a.root)
    print(f"walk cost · needle {a.pattern!r} · reps {a.reps} · roots {roots}", flush=True)
    return report(measure(a), a)


if __name__ == "__main__":
    sys.exit(main())
