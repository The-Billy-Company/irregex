#!/usr/bin/env python3
"""Byte census of a large source tree -> `src/kernel/scan/rarity.zig`'s `density`.

The table is the anchor-selection prior for the SIMD substring kernel: the
block filter compares the needle's two RAREST bytes, so what the table has to
carry is the ORDERING of byte frequencies, exactly and without ties. The
previous table stored `min(255, P * 32768)` and 30 printable bytes saturated
at 255 -- 20 of 26 lowercase letters among them -- so a lowercase identifier
had no rarest byte at all and selection fell through to a degenerate fallback.
That cost 1.96x on code and 2.56x on prose (`research/pincer/PROOF.md`).

So: no clamp, and a scale wide enough that no two printable bytes with
different corpus frequencies land on the same cell.

Emits the whole `pub const density` declaration on stdout; `--report` prints
the census diagnostics instead (ordering extremes, collision census, the
resolution floor) without touching the table.

    python3 tools/build_rarity_table.py --report
    python3 tools/build_rarity_table.py > /tmp/density.zig

Not hermetic like its `ucd/` and `whatwg/` siblings: the input is the working
tree, so a regeneration is a deliberate re-measurement and its output is
reviewed as a diff, never auto-applied.
"""

from __future__ import annotations

import argparse
import pathlib
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]  # tools/ → repo root

# Same walk the anchor-selection spike measured against
# (`research/pincer/TESTING.md`), so the shipped table and the numbers that
# justify it describe one corpus.
SKIP_DIRS = frozenset({
    ".git", ".local", ".etc", "node_modules", "target", "dist", "build", ".build",
    "out", ".next", "coverage", ".venv", "venv", "__pycache__", ".zig-cache",
    "zig-cache", "zig-out", "zig-pkg", "graphify-out", ".pnpm-store", "vendor",
    ".turbo", "DerivedData", "Pods", ".swiftpm", "storybook-static",
    ".mypy_cache", ".ruff_cache", ".pytest_cache",
})  # fmt: skip
TEXT_EXT = frozenset({
    ".go", ".py", ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".rs", ".swift",
    ".zig", ".proto", ".sh", ".sql", ".css", ".ex", ".exs", ".md", ".toml",
    ".yaml", ".yml", ".json", ".html", ".c", ".h", ".cpp", ".txt",
})  # fmt: skip
# One 2.2 GB ML training-text file otherwise swamps the code it shares the tree
# with and turns a code-search prior into an English-prose prior.
FILE_CAP = 4 << 20

SCALE = 65535
"""`density[b] = round(P(b) * SCALE)`, unclamped. 65535 is the widest scale a
`u16` cell holds without saturating, and saturation is the defect this table
exists to not have. It also keeps `prefilter.probability_scale` -- and so the
stride bar every skip is judged against -- expressible in the same `u16`."""


def census(root: pathlib.Path) -> tuple[list[int], int, int]:
    """Byte counts over the tree's text files, plus (files, bytes) consumed."""
    counts = [0] * 256
    singles = [bytes([b]) for b in range(256)]
    files = total = 0
    stack = [root]
    paths: list[pathlib.Path] = []
    while stack:
        try:
            entries = list(stack.pop().iterdir())
        except OSError:
            continue
        for e in entries:
            if e.is_symlink():
                continue
            if e.is_dir():
                if e.name not in SKIP_DIRS:
                    stack.append(e)
            elif e.suffix in TEXT_EXT:
                paths.append(e)
    for p in sorted(paths):
        try:
            blob = p.read_bytes()
        except OSError:
            continue
        if len(blob) > FILE_CAP or b"\x00" in blob[:4096]:
            continue
        files += 1
        total += len(blob)
        for b in range(256):
            counts[b] += blob.count(singles[b])
    return counts, files, total


def scaled(counts: list[int], total: int) -> list[int]:
    """`round(P * SCALE)`, with no ceiling. Half-up rather than banker's, so a
    cell is never rounded toward its neighbor's value."""
    return [(c * 2 * SCALE + total) // (2 * total) for c in counts]


def emit(table: list[int], files: int, total: int) -> str:
    """The whole declaration, already in `zig fmt` canonical form: per-column
    padding computed the way the formatter computes it, and an ASCII legend
    above each row that carries printable bytes so the ordering can be checked
    by eye (a legend on its own line keeps the formatter's column alignment,
    where a trailing comment collapses it)."""
    width = [max(len(str(table[r * 16 + c])) for r in range(16)) for c in range(16)]
    rows = []
    for base in range(0, 256, 16):
        if 0x20 <= base < 0x80:
            glyphs = "".join(
                "_" if c == 0x20 else chr(c) if 0x21 <= c <= 0x7E else "."
                for c in range(base, base + 16)
            )
            rows.append(f"    // {base:02x}  {glyphs}")
        cells = [
            str(v) + "," + " " * (width[c] - len(str(v)) + 1)
            for c, v in enumerate(table[base : base + 16])
        ]
        rows.append("    " + "".join(cells).rstrip())
    body = "\n".join(rows)
    return f"""/// Per-byte corpus probability as `round(P * {SCALE})`, UNCLAMPED. Measured over
/// {total / 1e6:.0f} MB of the source tree ({files:,} text files; see
/// `tools/build_rarity_table.py` for the exact walk). Regenerate with that
/// script and review the diff — never widen, floor, or ceiling a cell by hand.
/// Rows are 16 bytes wide; the legend marks the printable span, `_` for space.
pub const density = [256]u16{{
{body}
}};"""


def report(counts: list[int], table: list[int], files: int, total: int) -> str:
    printable = list(range(0x20, 0x7F))
    out = [f"corpus: {files} files, {total / 1e6:.1f} MB, scale {SCALE}"]

    # Ordering must be monotone in true frequency, and the cells that decide a
    # lowercase identifier must not tie. Collisions are counted only between
    # bytes whose true counts DIFFER -- equal counts are a real tie, not a
    # representation failure.
    def collisions(cells: list[int], among: list[int]) -> int:
        n = 0
        for i, a in enumerate(among):
            for b in among[i + 1 :]:
                if cells[a] == cells[b] and counts[a] != counts[b]:
                    n += 1
        return n

    # The old representation applied to THIS census, not the table that shipped
    # under it -- a counterfactual, so the two rows differ only in width and
    # scale. (The shipped `u8/32768` table's own census was worse still: 441
    # printable and 190 lowercase collisions, 30 cells on the ceiling.)
    old = [min(255, round(counts[b] / total * 32768)) for b in range(256)]
    lower = list(range(ord("a"), ord("z") + 1))
    for name, cells in (("u8/32768 (old repr)", old), (f"u16/{SCALE} (emitted)", table)):
        top = max(cells)
        out.append(
            f"{name:>21}: printable collisions {collisions(cells, printable):5}"
            f" | lowercase collisions {collisions(cells, lower):3}"
            f" | at ceiling {sum(1 for b in printable if cells[b] == top):3}"
            f" | zero cells {sum(1 for b in printable if cells[b] == 0):3}"
        )

    # Monotonicity: sorting by cell must not invert any pair of true counts.
    order = sorted(range(256), key=lambda b: (table[b], counts[b]))
    inversions = sum(
        1
        for i in range(len(order) - 1)
        if table[order[i]] < table[order[i + 1]] and counts[order[i]] > counts[order[i + 1]]
    )
    out.append(f"{'monotonicity':>16}: {inversions} inversions over all 256 cells")

    def show(bs: list[int]) -> str:
        return "  ".join(f"{chr(b) if b != 0x20 else 'SP'}={table[b]}" for b in bs)

    seen = [b for b in printable if counts[b] > 0]
    seen.sort(key=lambda b: counts[b])
    out.append("  20 rarest printable: " + show(seen[:20]))
    out.append("20 commonest printable: " + show(seen[-20:][::-1]))
    out.append(
        "   single-probe cohort: "
        + show([b for b in printable if 0 < table[b] <= round(48 / 32768 * SCALE)])
    )
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=pathlib.Path, default=ROOT)
    ap.add_argument("--report", action="store_true", help="census diagnostics, not the table")
    args = ap.parse_args()

    counts, files, total = census(args.root)
    if total == 0:
        print("no corpus under {args.root}", file=sys.stderr)
        return 1
    table = scaled(counts, total)
    print(report(counts, table, files, total) if args.report else emit(table, files, total))
    return 0


if __name__ == "__main__":
    sys.exit(main())
