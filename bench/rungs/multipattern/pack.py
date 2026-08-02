#!/usr/bin/env python3
"""Pack a deterministic in-memory corpus for the multi-pattern per-byte race.

The per-byte race (Layer K, arm 1) is gist's `PatternSet` against Vectorscan
block mode on **the same bytes in the same order**. Anything less is not a race:
two tools that each walk the tree themselves would differ on ignore rules, read
order, and binary sniffing long before either matched a byte.

So one packer owns the corpus, once, and both competitors are pure consumers of
its two artifacts:

    corpus.bin   every document concatenated, no separators
    corpus.idx   one `offset<TAB>length<TAB>path` row per document, in blob order

Documents come from gist's own persisted `paths.list` when it exists (the exact
corpus `gist index` built over — the fairest possible source), else from a walk
of the given roots under the same coarse ignore set. Selection is deterministic:
paths are sorted, then taken in order until the byte budget is reached, so two
runs on one machine pack byte-identical blobs.

stdlib only. Usage:

    python3 pack.py --out DIR [--paths paths.list] [--mib 64] [ROOT...]
"""

import argparse
import os
import sys
from pathlib import Path

# Directories a code-search corpus never contains. Mirrors the `XDIRS` set in
# `gist/bench/dominance/races/field.sh` so a packed corpus and a raced corpus agree.
SKIP = {
    ".git",
    ".hg",
    ".svn",
    "node_modules",
    "target",
    ".venv",
    "venv",
    "__pycache__",
    ".zig-cache",
    "zig-cache",
    "zig-out",
    "dist",
    "dist-types",
    "build",
    ".build",
    "out",
    ".next",
    "coverage",
    ".turbo",
    ".mypy_cache",
    ".ruff_cache",
    ".pytest_cache",
    "Pods",
    "DerivedData",
    ".swiftpm",
    ".local",
    ".cache",
    ".parcel-cache",
    "storybook-static",
    "xcuserdata",
    "derived-out",
    ".pnpm-store",
}
# A per-document ceiling, matching the kernel's own `corpus.per_file_cap`
# posture: one pathological megafile must not become the whole corpus.
DOC_CAP = 1 << 20


def walk(roots: list[Path]) -> list[Path]:
    """Every regular file under `roots`, skipping build output. Sorted."""
    found: list[Path] = []
    for root in roots:
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = sorted(d for d in dirnames if d not in SKIP)
            found += [Path(dirpath) / f for f in sorted(filenames)]
    return sorted(found)


def is_text(blob: bytes) -> bool:
    """gist's own implicit-binary rule: a NUL byte in the head means binary."""
    return b"\x00" not in blob[:8192]


def main() -> int:
    """CLI entry point."""
    ap = argparse.ArgumentParser(
        description="pack a deterministic corpus blob for the multipattern race"
    )
    ap.add_argument("roots", nargs="*", type=Path, help="roots to walk when --paths is absent")
    ap.add_argument(
        "--out", type=Path, required=True, help="output dir for corpus.bin + corpus.idx"
    )
    ap.add_argument(
        "--paths", type=Path, help="gist paths.list (NUL-separated) to use as the corpus"
    )
    ap.add_argument(
        "--base",
        type=Path,
        default=Path("."),
        help="base dir the paths.list entries are relative to",
    )
    ap.add_argument("--mib", type=int, default=64, help="byte budget for the packed blob")
    args = ap.parse_args()

    if args.paths and args.paths.exists():
        raw = args.paths.read_bytes()
        names = [p for p in raw.split(b"\0") if p]
        files = sorted(args.base / p.decode("utf-8", "surrogateescape") for p in names)
    elif args.roots:
        files = walk(args.roots)
    else:
        print("pack: need --paths or at least one ROOT", file=sys.stderr)
        return 2

    args.out.mkdir(parents=True, exist_ok=True)
    budget = args.mib << 20
    blob = args.out / "corpus.bin"
    rows: list[str] = []
    total = 0
    with blob.open("wb") as fh:
        for path in files:
            if total >= budget:
                break
            try:
                body = path.read_bytes()[:DOC_CAP]
            except OSError:
                continue
            if not body or not is_text(body):
                continue
            fh.write(body)
            rows.append(f"{total}\t{len(body)}\t{path}")
            total += len(body)
    (args.out / "corpus.idx").write_text("\n".join(rows) + "\n")
    print(f"packed {len(rows)} docs · {total / (1 << 20):.1f} MiB → {blob}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
