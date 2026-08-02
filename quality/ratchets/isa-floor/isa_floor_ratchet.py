#!/usr/bin/env python3
"""Zig ISA-floor ratchet — inline asm must ask for its feature, not its arch.

LLVM checks every instruction *it* selects against the target's subtarget, and
checks nothing at all inside an ``asm`` block: the template is a string handed
to the assembler, and the assembler will happily encode ``pshufb`` for a target
whose declared floor is SSE2. So an inline-asm arm chosen by architecture —
``switch (builtin.cpu.arch) { .x86_64 => asm ("pshufb …") }`` — compiles
silently, ships inside a wheel tagged for generic x86_64, and faults on the
first machine that took the tag at its word.

The rule is therefore: **an inline asm block must be predicated on the FEATURE
its instruction needs**, via ``builtin.cpu.has(family, feature)``, which is
comptime and costs nothing. Architecture alone is only sufficient when the
instruction is in that architecture's mandatory base ISA, which is what
``BASE_ISA`` below enumerates.

``BASE_ISA`` is deliberately tiny and the check **fails closed**: a mnemonic
nobody has classified needs a guard. Adding an instruction to the exempt set is
a one-line change that says, in review, "this needs no optional feature" — which
is the claim that should be reviewed, rather than assumed by silence.

Matching is comment/string-aware, and reads the mnemonic back out of the
original bytes at the blanked copy's offset — the asm template *is* a string
literal, so it has to survive blanking somewhere.

Scope: ``src/**/*.zig``, excluding ``*_test.zig``, ``*_fuzz.zig``, ``*.gen.zig``,
and generated-header files. Inline ``test "…" { … }`` blocks stay **in** scope,
unlike the sibling ratchets: an illegal instruction is illegal in a test too.

Run via ``python3 quality/ratchets/run.py isa-floor``; refresh with the same
command plus ``--refresh``.
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from _lib import (  # noqa: E402
    FileCount,
    PatternCount,
    code_only,
    head_lines,
    run_count_cli,
    walk_source_files,
)

REPO = Path(__file__).resolve().parents[3]
BASELINE = Path(__file__).resolve().parent / "isa-floor.baseline"

ROOTS = (REPO / "src",)
SKIP_DIR_PARTS = {"zig-out", ".zig-cache", "node_modules", "target"}
SKIP_NAME_SUFFIXES = ("_test.zig", "_fuzz.zig", ".gen.zig")

# Mnemonics in their architecture's MANDATORY base ISA — no optional feature to
# ask about, so selecting on `builtin.cpu.arch` is the whole truth. Grow this
# only for an instruction that is genuinely unconditional on every CPU the
# architecture admits; everything else needs `cpu.has`.
BASE_ISA = frozenset({"add"})

ASM_RE = re.compile(r"\basm\b(?:\s+volatile\b)?\s*\(")
# The mnemonic is the first token of the template string, read from the
# ORIGINAL bytes (the blanked copy has spaces there). `tbl.16b` and `b.eq`
# carry a dot, so it is part of the token and stripped for classification.
TEMPLATE_RE = re.compile(r'\s*"([a-zA-Z][\w.]*)')
FN_DECL_RE = re.compile(r"^[ \t]*(?:pub\s+)?(?:export\s+)?(?:inline\s+)?fn\s+\w+\s*\(", re.MULTILINE)
GUARD_RE = re.compile(r"\bcpu\.has\s*\(")
GENERATED_HEADER_RE = re.compile(r"^\s*//\s*Code generated\b|^\s*//\s*@generated\b", re.IGNORECASE)


def _mnemonic(text: str, after: int) -> str | None:
    """The instruction named by the asm template opening at `after`, if any."""
    m = TEMPLATE_RE.match(text, after)
    # `.16b` is an operand-shape suffix, not a different instruction.
    return m.group(1).split(".")[0].lower() if m else None


def _guarded(code: str, fn_starts: list[int], asm_at: int) -> bool:
    """Does a `cpu.has(` predicate stand between the enclosing `fn` and here?

    The enclosing function is the nearest preceding declaration; anything
    earlier belongs to a different function and cannot guard this one.
    """
    start = next((s for s in reversed(fn_starts) if s < asm_at), 0)
    return GUARD_RE.search(code, start, asm_at) is not None


def count_unguarded(text: str) -> PatternCount:
    """Inline asm blocks in one Zig source that no feature test protects."""
    code = code_only(text)
    fn_starts = [m.start() for m in FN_DECL_RE.finditer(code)]
    unguarded: dict[str, int] = {}
    for m in ASM_RE.finditer(code):
        mnemonic = _mnemonic(text, m.end())
        if mnemonic is None or mnemonic in BASE_ISA:
            continue
        if not _guarded(code, fn_starts, m.start()):
            unguarded[mnemonic] = unguarded.get(mnemonic, 0) + 1
    return PatternCount(unguarded)


def _scan_one(path: Path, repo: Path = REPO) -> FileCount | None:
    # Fail closed: an unreadable source file is an error, never a silent pass.
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise SystemExit(f"isa-floor: cannot scan {path}: {exc}") from exc
    if any(GENERATED_HEADER_RE.match(line) for line in head_lines(text)):
        return None
    detail = count_unguarded(text)
    if detail.total == 0:
        return None
    return FileCount(rel_path=str(path.relative_to(repo)), count=detail.total, detail=detail)


def scan() -> list[FileCount]:
    files = walk_source_files(
        ROOTS,
        exts=frozenset({".zig"}),
        skip_dirs=SKIP_DIR_PARTS,
        skip_name_suffixes=SKIP_NAME_SUFFIXES,
    )
    return [fc for fc in (_scan_one(p) for p in files) if fc]


_HEADER = """\
# zig-isa-floor ratchet baseline — unguarded inline asm per Zig file.
#
# LLVM cannot see inside an `asm` block, so an arm selected by architecture
# emits its instruction whatever the target's declared CPU floor promised —
# `pshufb` (SSSE3) into a baseline x86_64 wheel, say, which then faults on the
# machines that tag was for. Predicate the arm on the feature instead:
#
#     if (comptime builtin.cpu.has(.x86, .ssse3)) return asm ("pshufb …");
#
# Base-ISA mnemonics are exempt by name in the driver's BASE_ISA set; anything
# unclassified needs a guard, so the gate fails closed on a new instruction.
#
# Update rule: monotonically decrease only. Refresh after cleanup:
#     python3 quality/ratchets/run.py isa-floor --refresh
"""

_FIX_HINT = """\
Predicate the asm arm on the feature its instruction needs, not the arch:
  • `builtin.cpu.has(.x86, .ssse3)`     for pshufb and friends
  • `builtin.cpu.has(.aarch64, .neon)`  for tbl / addp / other NEON
A leaf helper with no fallback guards itself and `@compileError`s off-feature.
If the instruction really is in the mandatory base ISA, add its mnemonic to
BASE_ISA in isa_floor_ratchet.py — and say so in review.
"""


def main(argv: list[str] | None = None) -> int:
    return run_count_cli(
        scan=scan,
        baseline_path=BASELINE,
        header=_HEADER,
        label="unguarded inline asm blocks",
        refresh_cmd="python3 quality/ratchets/run.py isa-floor --refresh",
        fix_hint=_FIX_HINT,
        argv=argv,
    )


if __name__ == "__main__":
    sys.exit(main())
