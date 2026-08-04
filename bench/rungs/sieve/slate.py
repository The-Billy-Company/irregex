#!/usr/bin/env python3
"""The slate — what Layer L asks, and whether a corpus can answer it.

Two things that have to agree, so they live together: the probe rows as the Zig
registries declare them, and the judgement of whether a given tree exercises
those rows at all.

WHY THE SECOND HALF EXISTS. Layer L compares two index planners by the candidate
bytes each admits. A class matching **no** file and a class matching **every**
file admit the identical candidate set under both planners — the first admits
nothing, the second admits the corpus — so either endpoint is a row that cannot
distinguish them no matter how the planners differ. It still prints a number,
and the number still feeds a fail-closed verdict, which is the dangerous part: a
degenerate row can flip a certificate on noise. Over 754 Zig files the Go-shaped
`if err != nil` survived in a handful of vendored fixtures, and the byte fraction
came down to which two large files each plan happened to admit; over a 16k-file
synthetic Go corpus five stress classes matched nothing and one matched
everything. Both trees looked fine until measured.

So the corpus is audited against the slate before it is declared, with an engine
that is not the engine under test — Python's own `re` over the bytes on disk.
A corpus whose classes sit in the discriminating band is what makes Layer L's
verdict mean something; `bench/certificate/corpus.toml` records the reading, and
`--audit` is how it is taken.

Deliberately NOT on the mint's hot path. The audit is ~20 full passes over the
corpus in pure Python and costs a couple of minutes; it is a property of a
*declared* corpus, taken once when the corpus is declared or its pinned
revisions move, not a per-mint tax. The mint verifies the cheap thing — that it
is measuring the corpus that was declared.

    python3 slate.py --probes ../../apparatus/harness/probes.zig --probes stress.zig
    python3 slate.py --probes … --audit /path/to/corpus

stdlib only.
"""

from __future__ import annotations

import re
from pathlib import Path

PROBE_ROW = re.compile(
    r'\.class\s*=\s*"([^"]+)"\s*,\s*\.kind\s*=\s*\.(\w+)\s*,\s*\.pattern\s*=\s*"((?:[^"\\]|\\.)*)"'
)

#: The one class allowed to match every file. `\w{3,8}` finds a word in any text
#: whatsoever, so requiring it to discriminate would be requiring a corpus with
#: no words in it. It earns its place by being the class no index can prefilter,
#: which is a claim about the scan, not about the planner.
UNIVERSAL = frozenset({"regex-dense-scan"})

#: A file this small cannot hold a search result, so a universal class missing
#: one says nothing about the corpus. Every miss in a real tree is a zero-byte
#: marker (`py.typed`, `.gitkeep`) or a version stub (`{".": "0.1.0"}`), and the
#: audit prints the misses rather than accepting a fraction near 1.0 — a
#: threshold would swallow a genuine regression at the same rate it forgives
#: these, where a named file is something a reader can judge.
TRIVIAL_BYTES = 64

#: Classes whose job is to price what the trigram directory buys when a needle
#: sits in a *few* files. Above this band they are measuring a full scan while
#: wearing a selective class's name — the floors would still be met, by a
#: measurement of something else.
SELECTIVE = frozenset({"literal-rare", "regex-dotted", "regex-classcount"})
SELECTIVE_CEILING = 0.15


def zig_unescape(s: str) -> str:
    """Decode a Zig string-literal body (only `\\\\`, `\\"`, `\\n`, `\\t` occur here)."""
    out, i = [], 0
    simple = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "'": "'"}
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            nxt = s[i + 1]
            if nxt in simple:
                out.append(simple[nxt])
                i += 2
                continue
            if nxt == "x":
                out.append(chr(int(s[i + 2 : i + 4], 16)))
                i += 4
                continue
        out.append(c)
        i += 1
    return "".join(out)


def read_probes(path: Path) -> list[tuple[str, str, str]]:
    """(class, kind, pattern) rows from a Zig probe registry.

    Commented rows are skipped: `probes.zig` carries staged classes in `//`
    comments, and Layer L must speak about exactly the live slate Layers A and D
    do — no more.
    """
    live = "\n".join(ln for ln in path.read_text().splitlines() if not ln.lstrip().startswith("//"))
    return [(cls, kind, zig_unescape(pat)) for cls, kind, pat in PROBE_ROW.findall(live)]


class Reading:
    """One measurement of a corpus against the slate.

    Carries the per-class fraction plus, for the universal classes only, the
    files they missed — because "99.4%" and "99.4%, and here are the nine
    zero-byte markers" are different findings and only the second can be judged.
    """

    def __init__(self, files: int, hits: dict[str, int], misses: dict[str, list[Path]]) -> None:
        self.files, self.hits, self.misses = files, hits, misses

    @property
    def share(self) -> dict[str, float]:
        """Fraction of files each class matched."""
        return {cls: n / self.files for cls, n in self.hits.items()}


def measure(slate: list[tuple[str, str, str]], root: Path) -> Reading | None:
    """Judge `root` against the slate with Python's own `re`. None if empty.

    Measured with a foreign engine on purpose. A corpus that satisfies its
    invariants only according to the tool under test is not evidence about the
    tool — it is the tool agreeing with itself.

    Bytes rather than text, and `search` rather than `findall`: the question is
    only whether a file is a candidate, so every pattern short-circuits on its
    first hit and an undecodable file costs nothing extra.
    """
    paths = sorted(p for p in root.rglob("*") if p.is_file() and not p.is_symlink())
    if not paths:
        return None
    compiled = [
        (cls, re.compile(re.escape(pat).encode() if kind == "literal" else pat.encode(), re.M))
        for cls, kind, pat in slate
    ]
    hits = dict.fromkeys((cls for cls, _, _ in slate), 0)
    misses: dict[str, list[Path]] = {cls: [] for cls in UNIVERSAL}
    for path in paths:
        try:
            data = path.read_bytes()
        except OSError:
            continue
        for cls, rx in compiled:
            if rx.search(data):
                hits[cls] += 1
            elif cls in misses:
                misses[cls].append(path)
    return Reading(len(paths), hits, misses)


def faults(reading: Reading) -> list[str]:
    """Every way this corpus fails to exercise the slate.

    Returns all the complaints rather than raising on the first, because a
    corpus tuned one assertion per iteration is how you end up satisfying the
    last invariant by breaking the first.
    """
    out = []
    for cls, frac in sorted(reading.share.items()):
        if frac == 0.0:
            out.append(f"{cls}: matches nothing — vacuous, so every planner admits the empty set")
        elif frac == 1.0 and cls not in UNIVERSAL:
            out.append(
                f"{cls}: matches every file — saturating, so every planner admits the whole "
                "corpus and the row cannot separate them"
            )
        elif cls in SELECTIVE and frac > SELECTIVE_CEILING:
            out.append(
                f"{cls}: matches {frac:.1%}, above the {SELECTIVE_CEILING:.0%} band — it prices "
                "index selectivity and must stay a needle"
            )
    # A universal class is judged on WHAT it missed, not on how close to 1.0 it
    # came. Empty markers and version stubs are files no search could return; a
    # substantive file missing means the class stopped being universal, and that
    # is a planner-comparison result hiding inside a rounding error.
    for cls, missed in sorted(reading.misses.items()):
        if substantive := [p for p in missed if p.stat().st_size >= TRIVIAL_BYTES]:
            shown = ", ".join(p.name for p in substantive[:4])
            out.append(
                f"{cls}: missed {len(substantive)} file(s) larger than {TRIVIAL_BYTES} B "
                f"({shown}) — it is supposed to match anything with words in it"
            )
    return out


def main() -> int:
    """CLI entry point."""
    import argparse

    ap = argparse.ArgumentParser(description="the Layer L slate, and whether a corpus answers it")
    ap.add_argument(
        "--probes",
        type=Path,
        required=True,
        action="append",
        help="a Zig probe registry; repeatable (shared probes.zig, then stress.zig)",
    )
    ap.add_argument(
        "--audit",
        type=Path,
        help="a corpus root to judge — exits 2 if any class is vacuous or saturating there",
    )
    args = ap.parse_args()

    slate = [row for p in args.probes for row in read_probes(p)]
    if not args.audit:
        for cls, kind, pat in slate:
            print(f"{cls:<20} {kind:<8} {pat}")
        return 0

    reading = measure(slate, args.audit)
    if reading is None:
        print(f"slate: {args.audit} holds no files")
        return 2
    share = reading.share
    print(f"# {reading.files} files under {args.audit}")
    for cls, _, _ in slate:
        band = "universal" if cls in UNIVERSAL else "selective" if cls in SELECTIVE else ""
        print(f"{cls:<20} {share[cls]:7.2%}  {band}")
    if bad := faults(reading):
        print("\n" + "\n".join(f"slate: {f}" for f in bad))
        print(
            "\nA class at either endpoint admits the same candidate set under both planners, so "
            "Layer L's verdict over that row is noise. Re-cut the class to a shape this corpus "
            "has, or declare a corpus that has the shape.",
        )
        return 2
    print(f"\nslate: all {len(share)} classes discriminate on this corpus")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
