#!/usr/bin/env python3
"""Walk cost — what a live tree walk costs in memory, gist vs ripgrep.

THE CLAIM THIS LANE EXISTS TO SETTLE
    Layer J's residency argument turns on one matched pair. gist's query-time
    resident set is large; the first explanation offered was "it must hold its
    index", which `vmmap` refuted; the second was "any engine walking a live
    tree pays this", and ripgrep refutes that one by walking the same tree for a
    fraction of the memory. That refutation is the honest form of the claim, and
    it was carried for a while as two numbers typed into prose — which is
    exactly the shape a fix invalidates silently. This lane measures it.

    The pair is matched on purpose: same needle, same `-uu` scope, same cwd,
    both counting rather than printing, both a fresh process with no index in
    play (`--no-index` + `GIST_NO_AUTOSERVE=1`, so neither a persisted index nor
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

Usage:
  python3 bench/rungs/sliver/walkcost.py --root <tree> [--pattern pgxpool]
      [--reps 3] [--out bench/rungs/sliver/artifact]
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

HERE = Path(__file__).resolve().parent
KERNEL = HERE.parent.parent.parent
GIST = KERNEL / "zig-out" / "bin" / "gist"

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
    """One tool's matched-pair measurement over the reps."""

    def __init__(self, tool: str, argv: list[str]) -> None:
        self.tool, self.argv = tool, argv
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
    root = a.root.resolve()
    # `-c` (count) so neither tool is billed for rendering a repo-wide result,
    # and `-F` so the needle is a literal to both engines rather than a regex to
    # one of them. GIST_UNCAP=1 keeps gist's agent-context output budget from
    # clipping the answer, the same fairness flag `_compete.sh` sets.
    pairs = [
        ("gist", [str(GIST), "--no-index", "-uu", "-F", "-c", a.pattern, "."]),
        ("rg", ["rg", "-uu", "--no-messages", "-F", "-c", a.pattern, "."]),
    ]
    out: list[Sample] = []
    for tool, argv in pairs:
        s = Sample(tool, argv)
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
    """`root` relative to the repository, when it is inside it — same reasoning as
    `_shown`, applied to the corpus."""
    repo = KERNEL.parent.parent.parent
    return str(root.relative_to(repo)) if root.is_relative_to(repo) else str(root)


def _walked(root: Path) -> int:
    """How many files the pair actually walks — gist's own `--files` under the
    same `-uu` scope, so the denominator is the tree as measured rather than a
    separate traversal with its own idea of what counts."""
    p = subprocess.run(
        [str(GIST), "--no-index", "-uu", "--files", "."],
        cwd=root,
        env=dict(os.environ, GIST_UNCAP="1", GIST_NO_AUTOSERVE="1"),
        capture_output=True,
    )
    return p.stdout.count(b"\n")


def report(samples: list[Sample], a: argparse.Namespace) -> int:
    out = a.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    tsv = out / "scale_walkcost.tsv"
    by = {s.tool: s for s in samples}
    g, r = by.get("gist"), by.get("rg")
    lines = [
        "# The matched pair behind Layer J's residency refutation: what a LIVE tree",
        "# walk costs in memory, with no index in play on either side. Same needle,",
        "# same -uu scope, same cwd, both counting, both a fresh process.",
        "#",
        "# maxrss charges clean evictable mmap page cache; owned (Darwin 'peak memory",
        "# footprint') is the dirty memory the process cannot have reclaimed. The",
        "# ratio that is a cost is the owned one.",
        "#",
        f"# corpus={_where(a.root.resolve())} files={_walked(a.root.resolve())}",
        f"# needle={a.pattern} reps={a.reps} platform={sys.platform}",
        "tool\tinvocation\tmaxrss_mib\towned_mib\tseconds\tmatches",
    ]
    for s in samples:
        if s.failed and not s.rss:
            lines.append(f"{s.tool}\t{_shown(s.argv)}\t\t\t\t{s.failed}")
            continue
        lines.append(
            f"{s.tool}\t{_shown(s.argv)}\t{_cell(s.med(s.rss))}\t"
            f"{_cell(s.med(s.owned))}\t{_cell(s.med(s.seconds))}\t{s.hits}"
        )
    if g and r and g.rss and r.rss:
        lines.append(
            f"# ratio gist/rg: maxrss {g.med(g.rss) / r.med(r.rss):.2f}x"
            + (f" · owned {g.med(g.owned) / r.med(r.owned):.2f}x" if g.owned and r.owned else "")
        )
    tsv.write_text("\n".join(lines) + "\n")
    print(f"\nwrote {tsv}")
    # The pair is the whole point: a run that could not obtain both halves has
    # measured nothing, and saying so beats publishing one side as a comparison.
    return 0 if (g and r and g.rss and r.rss) else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", type=Path, required=True, help="tree to walk")
    ap.add_argument("--pattern", default="pgxpool", help="literal needle")
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--out", type=Path, default=HERE / "artifact")
    a = ap.parse_args()
    print(f"walk cost · root {a.root} · needle {a.pattern!r} · reps {a.reps}", flush=True)
    return report(measure(a), a)


if __name__ == "__main__":
    sys.exit(main())
