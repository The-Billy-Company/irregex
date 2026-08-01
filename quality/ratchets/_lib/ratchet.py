"""Shared scaffolding for count-based per-file drift ratchets.

Every "per-file count of a debt pattern" gate in this tree — `oom`,
`dup-helper`, `fault-taxonomy`, `assay-bypass` — has the same skeleton:

    1. Scan first-party Zig source for the pattern → list[FileCount].
    2. Read a pinned baseline (one ``<rel_path>=<count>`` line per file).
    3. Diff observed vs baseline → increases / new files / decreases / removed.
    4. Fail on increases + new files (drift); suggest tightening on decreases.
    5. Optional ``--refresh`` to rewrite the baseline + ``--json`` for CI.

This module owns parts 2-5; each ratchet writes only its scanner, its
``_HEADER`` constant, and a ``main()`` wrapper — so the interesting half of a
ratchet is the detector, not the plumbing around it.

Optional per-pattern breakdown — when a ratchet tracks several debt shapes
under one count (`oom` counts two; `fault-taxonomy` counts one per error name),
pass ``PatternCount`` instances on each ``FileCount`` and the failure report
surfaces the split for every offending file.
"""

import argparse
import bisect
import json
import os
import sys
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass, field
from pathlib import Path

# ANSI colors — exported for ratchets that print custom messages alongside the
# shared diff. Empty strings when stdout isn't a TTY (CI logs stay clean).
_IS_TTY = sys.stdout.isatty()
RED = "\033[0;31m" if _IS_TTY else ""
GREEN = "\033[0;32m" if _IS_TTY else ""
YELLOW = "\033[0;33m" if _IS_TTY else ""
DIM = "\033[2m" if _IS_TTY else ""
RESET = "\033[0m" if _IS_TTY else ""


# ── source discovery + scan helpers (shared across the ratchets) ─────────────

_HEAD_SCAN_BYTES = 4096


def head_lines(text: str, n: int = 5) -> list[str]:
    """First ``n`` lines of ``text``, scanning only the head.

    Generated-header sniffs only ever inspect the first handful of lines, so
    ``text.splitlines()[:n]`` over a multi-thousand-line generated table
    materializes every line for nothing. Slicing the head first bounds the work
    to one small allocation while staying equivalent for any real source header
    (the ``// Code generated`` sentinel lives on line 1).
    """
    return text[:_HEAD_SCAN_BYTES].splitlines()[:n]


def walk_source_files(
    roots: Iterable[Path],
    *,
    exts: frozenset[str],
    skip_dirs: Iterable[str] = (),
    skip_name_suffixes: tuple[str, ...] = (),
    keep_name: Callable[[str], bool] | None = None,
) -> list[Path]:
    """Sorted first-party source files under ``roots``, pruning ``skip_dirs``.

    Equivalent to ``root.rglob("*.ext")`` + a parts/suffix filter, but prunes
    skipped directories *in place* during ``os.walk`` so build and vendor trees
    (``zig-out/``, ``.zig-cache/``, ``target/``, …) are never descended into at
    all. That matters here because those trees are far larger than the source
    they sit beside, and statting them buys nothing.

    A file is kept when its extension is in ``exts``, its name does not end with
    any ``skip_name_suffixes``, and ``keep_name(name)`` (when given) is True.
    """
    skip = frozenset(skip_dirs)
    out: list[Path] = []
    for root in roots:
        if not root.exists():
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in skip]
            base = Path(dirpath)
            for name in filenames:
                dot = name.rfind(".")
                if dot < 0 or name[dot:] not in exts:
                    continue
                if skip_name_suffixes and name.endswith(skip_name_suffixes):
                    continue
                if keep_name is not None and not keep_name(name):
                    continue
                out.append(base / name)
    return sorted(out)


def range_membership(ranges: list[tuple[int, int]]) -> Callable[[int], bool]:
    """Build an ``offset → bool`` "is this offset inside a range" predicate.

    Merges ``ranges`` into a disjoint, sorted set, then answers each query with
    a binary search — O(log n) per lookup instead of the O(n) linear scan an
    ``any(s <= off < e for s, e in ranges)`` closure pays on *every* regex
    match. The merge collapses nested/overlapping spans first, so it is a
    behavior-preserving drop-in for the linear form.
    """
    if not ranges:
        return lambda _off: False
    merged: list[tuple[int, int]] = []
    for s, e in sorted(ranges):
        if merged and s <= merged[-1][1]:
            last_s, last_e = merged[-1]
            merged[-1] = (last_s, max(last_e, e))
        else:
            merged.append((s, e))
    starts = [s for s, _ in merged]
    ends = [e for _, e in merged]

    def contains(off: int) -> bool:
        i = bisect.bisect_right(starts, off) - 1
        return i >= 0 and off < ends[i]

    return contains


@dataclass(frozen=True)
class PatternCount:
    """Per-pattern split for one file's findings (optional)."""

    by_pattern: Mapping[str, int] = field(default_factory=dict)

    @property
    def total(self) -> int:
        return sum(self.by_pattern.values())

    def summary(self) -> str:
        return ", ".join(f"{k}={v}" for k, v in self.by_pattern.items() if v)


@dataclass(frozen=True)
class FileCount:
    rel_path: str
    count: int
    detail: PatternCount | None = None


@dataclass(frozen=True)
class Diff:
    increased: list[tuple[str, int, int]]
    new_files: list[tuple[str, int]]
    decreased: list[tuple[str, int, int]]
    removed: list[str]

    @property
    def has_failures(self) -> bool:
        return bool(self.increased or self.new_files)

    @property
    def has_suggestions(self) -> bool:
        return bool(self.decreased or self.removed)


# ── baseline I/O ───────────────────────────────────────────────────────────


def read_baseline(path: Path) -> dict[str, int]:
    """Parse a ``<rel_path>=<count>`` baseline file; missing → empty map."""
    if not path.exists():
        return {}
    out: dict[str, int] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or "=" not in line:
            continue
        rel, _, count = line.partition("=")
        try:
            out[rel.strip()] = int(count.strip())
        except ValueError:
            continue
    return out


def write_baseline(path: Path, counts: list[FileCount], header: str) -> None:
    """Write a sorted, deterministic baseline file."""
    body = "".join(f"{fc.rel_path}={fc.count}\n" for fc in sorted(counts, key=lambda x: x.rel_path))
    path.write_text(header.rstrip() + "\n\n" + body, encoding="utf-8")


# ── diff ───────────────────────────────────────────────────────────────────


def diff_counts(observed: list[FileCount], baseline: dict[str, int]) -> Diff:
    obs = {fc.rel_path: fc.count for fc in observed}
    increased: list[tuple[str, int, int]] = []
    new_files: list[tuple[str, int]] = []
    decreased: list[tuple[str, int, int]] = []
    removed: list[str] = []

    for path, count in obs.items():
        base = baseline.get(path)
        if base is None:
            new_files.append((path, count))
        elif count > base:
            increased.append((path, base, count))
        elif count < base:
            decreased.append((path, base, count))

    for path in baseline:
        if path not in obs:
            removed.append(path)

    increased.sort()
    new_files.sort()
    decreased.sort()
    removed.sort()
    return Diff(increased=increased, new_files=new_files, decreased=decreased, removed=removed)


# ── reporting ──────────────────────────────────────────────────────────────


def _detail_for(rel: str, observed: list[FileCount]) -> str:
    for fc in observed:
        if fc.rel_path == rel and fc.detail and fc.detail.by_pattern:
            summary = fc.detail.summary()
            if summary:
                return f"  [{summary}]"
    return ""


def _print_text(d: Diff, label: str, observed: list[FileCount], fix_hint: str | None) -> None:
    if d.increased:
        print(f"{RED}✗{RESET} {len(d.increased)} file(s) accreted {label}:")
        for path, base, obs in d.increased:
            print(f"  {path}: {base} → {obs}{_detail_for(path, observed)}")
    if d.new_files:
        print(
            f"{RED}✗{RESET} {len(d.new_files)} new file(s) using {label} (new code is born clean):"
        )
        for path, obs in d.new_files:
            print(f"  {path}: 0 → {obs}{_detail_for(path, observed)}")
    if d.decreased:
        print(f"{GREEN}↓{RESET} {len(d.decreased)} file(s) shrunk — refresh the baseline:")
        for path, base, obs in d.decreased:
            print(f"  {path}: {base} → {obs}")
    if d.removed:
        print(f"{GREEN}∅{RESET} {len(d.removed)} file(s) cleared {label} — refresh the baseline:")
        for path in d.removed:
            print(f"  {path}")
    if d.has_failures and fix_hint:
        print()
        print(fix_hint)
    if not (d.has_failures or d.has_suggestions):
        print(
            f"{GREEN}✓{RESET} {label}-ratchet OK "
            f"({sum(fc.count for fc in observed)} total in "
            f"{len(observed)} file(s))"
        )


# ── CLI ────────────────────────────────────────────────────────────────────


def run_count_cli(
    *,
    scan: Callable[[], list[FileCount]],
    baseline_path: Path,
    header: str,
    label: str,
    refresh_cmd: str,
    fix_hint: str | None = None,
    argv: list[str] | None = None,
) -> int:
    """Common ratchet CLI — scan, read baseline, diff, print/JSON, refresh.

    ``label`` is the noun used in user-facing messages ("inline Zig OOM exits",
    "undeclared Zig fault names", …). ``refresh_cmd`` is the command we suggest
    when the baseline can be tightened, and it must be a line someone can paste
    from the repository root. ``fix_hint`` is appended on failure, typically a
    2-3 line "how to fix" snippet.

    Exit codes:
        0 — baseline holds, or refresh succeeded, or only suggestions
        1 — at least one new offender (an increase, or a new file)
    """
    ap = argparse.ArgumentParser(
        description=f"{label} count ratchet",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument(
        "--refresh", action="store_true", help="rewrite the baseline from the current scan"
    )
    ap.add_argument(
        "--json", action="store_true", help="machine-readable diff (one JSON object on stdout)"
    )
    args = ap.parse_args(argv)

    observed = scan()

    if args.refresh:
        write_baseline(baseline_path, observed, header)
        if args.json:
            json.dump(
                {
                    "refreshed": True,
                    "files": len(observed),
                    "total": sum(fc.count for fc in observed),
                },
                sys.stdout,
                indent=2,
            )
            sys.stdout.write("\n")
        else:
            print(
                f"{GREEN}✓{RESET} {baseline_path.name} rewritten "
                f"({len(observed)} file(s), {sum(fc.count for fc in observed)} total)"
            )
        return 0

    if not baseline_path.exists():
        print(
            f"{YELLOW}!{RESET} {baseline_path.name} missing — run `{refresh_cmd}` to seed it",
            file=sys.stderr,
        )
        return 1
    baseline = read_baseline(baseline_path)

    d = diff_counts(observed, baseline)

    if args.json:
        json.dump(
            {
                "increased": d.increased,
                "new_files": d.new_files,
                "decreased": d.decreased,
                "removed": d.removed,
                "ok": not d.has_failures,
            },
            sys.stdout,
            indent=2,
        )
        sys.stdout.write("\n")
    else:
        _print_text(d, label, observed, fix_hint)
        if d.has_suggestions and not d.has_failures:
            print(f"\n{DIM}Run `{refresh_cmd}` to tighten the baseline.{RESET}")

    return 1 if d.has_failures else 0
