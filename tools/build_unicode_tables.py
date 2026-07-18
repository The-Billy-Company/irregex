#!/usr/bin/env python3
r"""Lower the pinned UCD subset in tools/ucd/ into src/kernel/regex/unicode/tables.gen.zig.

gist is a byte automaton; to match Unicode *codepoint* classes it needs compact,
sorted scalar-range tables for the Perl classes (\\w \\d \\s), the simple
case-fold orbits (-i / smart-case), and the \\p{...} general categories + scripts.
This generator is the single source of those tables: it reads the vendored UCD
16.0.0 text files (provenance in tools/ucd/README.md) and emits one generated Zig
module. It is stdlib-only and deterministic, so `make gen-gist-unicode` followed
by a diff is a sound drift gate — the checked-in tables.gen.zig must be exactly
what this script produces from the pinned inputs.

Run: python3 pkg/kernels/irregex/tools/build_unicode_tables.py           # writes the .gen.zig
     python3 pkg/kernels/irregex/tools/build_unicode_tables.py --check   # diff-only (drift gate)
"""

from __future__ import annotations

from pathlib import Path
import sys


UNICODE_VERSION = "16.0.0"
HERE = Path(__file__).resolve().parent
UCD = HERE / "ucd"
OUT = HERE.parent / "src" / "kernel" / "regex" / "unicode" / "tables.gen.zig"

Range = tuple[int, int]


def parse_ranges(path: Path, want: str, col: int = 1) -> list[Range]:
    """Ranges from a `RANGE ; VALUE # comment` UCD file where column `col` == `want`."""
    out: list[Range] = []
    for raw in path.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        fields = [f.strip() for f in line.split(";")]
        if len(fields) <= col or fields[col] != want:
            continue
        lo, _, hi = fields[0].partition("..")
        lo_i = int(lo, 16)
        out.append((lo_i, int(hi, 16) if hi else lo_i))
    return out


def gc_map(path: Path) -> dict[str, list[Range]]:
    """All general-category ranges keyed by the fine two-letter category."""
    cats: dict[str, list[Range]] = {}
    for raw in path.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        rng, cat = (f.strip() for f in line.split(";"))
        lo, _, hi = rng.partition("..")
        lo_i = int(lo, 16)
        cats.setdefault(cat, []).append((lo_i, int(hi, 16) if hi else lo_i))
    return cats


def coalesce(ranges: list[Range]) -> list[Range]:
    """Sort and merge overlapping/adjacent ranges into a minimal sorted set."""
    if not ranges:
        return []
    ranges = sorted(ranges)
    merged = [ranges[0]]
    for lo, hi in ranges[1:]:
        plo, phi = merged[-1]
        if lo <= phi + 1:
            merged[-1] = (plo, max(phi, hi))
        else:
            merged.append((lo, hi))
    return merged


def union(*groups: list[Range]) -> list[Range]:
    """Merge several range lists into one coalesced sorted set."""
    out: list[Range] = []
    for g in groups:
        out.extend(g)
    return coalesce(out)


def fold_orbits(path: Path) -> dict[int, list[int]]:
    """Simple case-fold orbits (CaseFolding C + S) as cp -> sorted other members.

    Group codepoints by their common simple-fold target; every member of a group
    is case-equivalent to every other. Only non-trivial orbits (size >= 2) are
    kept. Full (F) and Turkic (T) mappings are deliberately excluded — gist folds
    with simple (1:1) semantics, matching rust-regex's default.
    """
    groups: dict[int, set[int]] = {}
    for raw in path.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        code, status, mapping = (f.strip() for f in line.split(";")[:3])
        if status not in ("C", "S"):
            continue
        target = int(mapping, 16)
        groups.setdefault(target, {target}).add(int(code, 16))
    orbits: dict[int, list[int]] = {}
    for members in groups.values():
        if len(members) < 2:
            continue
        for m in members:
            orbits[m] = sorted(members - {m})
    return orbits


def fmt_ranges(name: str, ranges: list[Range]) -> str:
    """Render one Zig `pub const <name>: []const Range` table literal."""
    body = ", ".join(f".{{ 0x{lo:X}, 0x{hi:X} }}" for lo, hi in ranges)
    return f"pub const {name}: []const Range = &.{{ {body} }};"


def build() -> str:
    """Lower the pinned UCD inputs into the generated Unicode tables module text."""
    gc = {k: coalesce(v) for k, v in gc_map(UCD / "DerivedGeneralCategory.txt").items()}
    alphabetic = coalesce(parse_ranges(UCD / "DerivedCoreProperties.txt", "Alphabetic"))
    white_space = coalesce(parse_ranges(UCD / "PropList.txt", "White_Space"))
    join_control = coalesce(parse_ranges(UCD / "PropList.txt", "Join_Control"))
    scripts: dict[str, list[Range]] = {}
    for raw in (UCD / "Scripts.txt").read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        rng, name = (f.strip() for f in line.split(";"))
        lo, _, hi = rng.partition("..")
        lo_i = int(lo, 16)
        scripts.setdefault(name, []).append((lo_i, int(hi, 16) if hi else lo_i))
    scripts = {k: coalesce(v) for k, v in scripts.items()}

    marks = union(gc.get("Mn", []), gc.get("Mc", []), gc.get("Me", []))
    word = union(alphabetic, marks, gc.get("Nd", []), gc.get("Pc", []), join_control)
    digit = gc.get("Nd", [])
    space = white_space

    # Coarse general-category groups (L, M, N, P, S, Z, C) = union of their fine
    # members present in the data.
    coarse = {c: union(*[v for k, v in gc.items() if k.startswith(c)]) for c in "LMNPSZC"}

    orbits = fold_orbits(UCD / "CaseFolding.txt")
    fold_cps = sorted(orbits)
    fold_members: list[int] = []
    fold_entries: list[tuple[int, int, int]] = []  # cp, off, len
    for cp in fold_cps:
        others = orbits[cp]
        fold_entries.append((cp, len(fold_members), len(others)))
        fold_members.extend(others)

    lines: list[str] = []
    lines.append("//! Code generated by pkg/kernels/irregex/tools/build_unicode_tables.py from the")
    lines.append(f"//! pinned UCD {UNICODE_VERSION} subset in tools/ucd/. DO NOT EDIT — edit the")
    lines.append("//! generator or the vendored UCD inputs and rerun `make gen-gist-unicode`.")
    lines.append("//! The drift gate (`make gen-gist-verify`) re-runs this and diffs the result.")
    lines.append("")
    lines.append(f'pub const unicode_version = "{UNICODE_VERSION}";')
    lines.append("")
    lines.append("/// An inclusive scalar-value range `[lo, hi]`.")
    lines.append("pub const Range = [2]u21;")
    lines.append("")
    lines.append("// ── Perl classes (UTS#18): \\w \\d \\s ──")
    lines.append(fmt_ranges("word", word))
    lines.append(fmt_ranges("digit", digit))
    lines.append(fmt_ranges("space", space))
    lines.append("")
    lines.append("// ── simple case-fold orbits (CaseFolding C+S) ──")
    lines.append("pub const FoldEntry = struct { cp: u21, off: u32, len: u16 };")
    fe = ", ".join(
        f".{{ .cp = 0x{cp:X}, .off = {off}, .len = {ln} }}" for cp, off, ln in fold_entries
    )
    lines.append(f"pub const fold_entries: []const FoldEntry = &.{{ {fe} }};")
    fm = ", ".join(f"0x{m:X}" for m in fold_members)
    lines.append(f"pub const fold_members: []const u21 = &.{{ {fm} }};")
    lines.append("")
    lines.append("// ── \\p{...} general categories (coarse groups + fine categories) ──")
    named: list[tuple[str, str]] = []
    for c in "LMNPSZC":
        ident = f"gc_{c}"
        lines.append(fmt_ranges(ident, coarse[c]))
        named.append((c, ident))
    for cat in sorted(gc):
        ident = f"gc_{cat}"
        lines.append(fmt_ranges(ident, gc[cat]))
        named.append((cat, ident))
    lines.append("")
    lines.append("// ── \\p{Script=...} ──")
    script_named: list[tuple[str, str]] = []
    for name in sorted(scripts):
        ident = f"sc_{name}"
        lines.append(fmt_ranges(ident, scripts[name]))
        script_named.append((name, ident))
    lines.append("")
    lines.append("pub const NamedRanges = struct { name: []const u8, ranges: []const Range };")
    all_named = named + script_named
    body = ", ".join(f'.{{ .name = "{n}", .ranges = {ident} }}' for n, ident in all_named)
    lines.append(f"pub const properties: []const NamedRanges = &.{{ {body} }};")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    """CLI entry: write `tables.gen.zig` or `--check` drift against it."""
    generated = build()
    if "--check" in sys.argv:
        current = OUT.read_text() if OUT.exists() else ""
        if current != generated:
            print(f"DRIFT: {OUT} is stale — run `make gen-gist-unicode`", file=sys.stderr)
            return 1
        print(f"ok: {OUT} matches the pinned UCD {UNICODE_VERSION}")
        return 0
    OUT.write_text(generated)
    print(f"wrote {OUT} ({len(generated)} bytes) from UCD {UNICODE_VERSION}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
