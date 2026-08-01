#!/usr/bin/env python3
"""Zig OOM-exit ratchet — one canonical ``pub fn oom()``, no inline copies.

The command plane routes out-of-memory through ONE canonical helper
(``pub const oom`` in ``src/surface/cli/outcome.zig``, an alias of
``src/corpus/scope/paths.zig``'s ``allocFailure``). Every other spelling is
drift this ratchet freezes and burns down:

* an inline ``die("oom…")`` outside the canonical ``oom()`` body — the
  exit string/code is duplicated at the call site instead of routed
  through the helper;
* a duplicate non-``pub`` ``fn oom(`` definition — a copy-pasted local
  twin of the canonical helper (the parity-bug class: one copy gets
  fixed, the other silently doesn't).

Matching is comment/string-aware (a ``die("oom`` inside a ``//`` comment,
a ``"…"`` literal, or a ``\\\\`` multiline-string line never counts). The
enclosing function of a ``die("oom`` site is the nearest preceding
``fn NAME(`` declaration line; only ``NAME == oom`` exempts it.

Scope: ``src/**/*.zig``, excluding ``*_test.zig``, ``*.gen.zig``, and
generated-header files.

Run via ``python3 quality/ratchets/run.py oom``; refresh with the same
command plus ``--refresh``.
"""

import bisect
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from _lib import (  # noqa: E402
    FileCount,
    PatternCount,
    head_lines,
    range_membership,
    run_count_cli,
    walk_source_files,
)

REPO = Path(__file__).resolve().parents[3]
BASELINE = Path(__file__).resolve().parent / "oom.baseline"

ROOTS = (REPO / "src",)
SKIP_DIR_PARTS = {"zig-out", ".zig-cache", "node_modules", "target"}
SKIP_NAME_SUFFIXES = ("_test.zig", ".gen.zig")

DIE_OOM_RE = re.compile(r'die\s*\(\s*"oom')
FN_DECL_RE = re.compile(r"^\s*(?:pub\s+)?(?:export\s+)?fn\s+(\w+)\s*\(")
FN_OOM_RE = re.compile(r"^\s*(pub\s+)?(?:export\s+)?fn\s+oom\s*\(")
GENERATED_HEADER_RE = re.compile(
    r"^\s*//\s*Code generated\b|^\s*//\s*@generated\b",
    re.IGNORECASE,
)

# One left-to-right token scan: whichever token starts first wins, so a `//`
# inside a string never opens a comment and a quote inside a comment never
# opens a string. Zig `"…"` / `'…'` literals cannot span lines; `\\…`
# multiline-string lines are blanked whole. Blanking is offset-preserving so
# line numbers survive for the nearest-enclosing-fn scan.
#
# This is _lib/zigtext.py's lexer with one deliberate difference: the `die("oom`
# needle carries its own opening quote, so a string here must survive blanking
# and be rejected by span instead.
_TOKEN_RE = re.compile(r"//[^\n]*|\"(?:\\.|[^\"\\\n])*\"|'(?:\\.|[^'\\\n])*'")
_MULTILINE_STR_RE = re.compile(r"^\s*\\\\.*$", re.MULTILINE)


def _sanitize(text: str) -> tuple[str, list[tuple[int, int]]]:
    """Blank comments + multiline-string lines, offset-preserving.

    Single-line string/char literals stay in place (the ``die("oom``
    needle needs its opening quote) with their spans returned so matches
    *inside* one can be rejected.
    """
    text = _MULTILINE_STR_RE.sub(lambda m: " " * len(m.group(0)), text)
    out: list[str] = []
    string_ranges: list[tuple[int, int]] = []
    last = 0
    for m in _TOKEN_RE.finditer(text):
        out.append(text[last : m.start()])
        tok = m.group(0)
        if tok.startswith("//"):
            out.append(" " * len(tok))
        else:
            out.append(tok)
            string_ranges.append((m.start(), m.end()))
        last = m.end()
    out.append(text[last:])
    return "".join(out), string_ranges


def count_oom(text: str) -> PatternCount:
    """Count the two debt shapes in one Zig source text.

    * inline ``die("oom`` whose nearest enclosing ``fn`` is not ``oom``;
    * non-``pub`` ``fn oom(`` definitions (duplicate local copies).
    """
    sanitized, string_ranges = _sanitize(text)
    in_string = range_membership(string_ranges)
    lines = sanitized.splitlines()
    line_starts: list[int] = []
    off = 0
    for ln in lines:
        line_starts.append(off)
        off += len(ln) + 1

    inline = 0
    for m in DIE_OOM_RE.finditer(sanitized):
        # `die("oom` carries its own quote — reject only a match that STARTS
        # inside an enclosing string literal (i.e. the needle is string text).
        if in_string(m.start()):
            continue
        line_idx = bisect.bisect_right(line_starts, m.start()) - 1
        enclosing = next(
            (fm.group(1) for i in range(line_idx, -1, -1) if (fm := FN_DECL_RE.match(lines[i]))),
            None,
        )
        if enclosing != "oom":
            inline += 1

    dup_defs = sum(1 for ln in lines if (dm := FN_OOM_RE.match(ln)) and not dm.group(1))
    return PatternCount({'inline die("oom")': inline, "non-pub fn oom(": dup_defs})


def _scan_one(path: Path, repo: Path = REPO) -> FileCount | None:
    # Fail closed: an unreadable/undecodable source file is an error, never
    # a silent pass — the ratchet must not report green over unscanned code.
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise SystemExit(f"zig-oom: cannot scan {path}: {exc}") from exc
    if any(GENERATED_HEADER_RE.match(line) for line in head_lines(text)):
        return None
    detail = count_oom(text)
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
# zig-oom ratchet baseline — inline OOM exits per Zig command-plane file.
#
# Tracks `die("oom…")` call sites outside the canonical `pub const oom`
# (src/surface/cli/outcome.zig) plus duplicate non-pub `fn oom(`
# definitions across src/.
#
# Update rule: monotonically decrease only. Refresh after cleanup:
#     python3 quality/ratchets/run.py oom --refresh
"""

_FIX_HINT = """\
Route OOM through the one canonical helper:
  • inline `die("oom…", …)`  → call `oom()` (outcome.zig's `pub const oom`)
  • local `fn oom(` copy     → delete it; import/call the canonical one
"""


def main(argv: list[str] | None = None) -> int:
    return run_count_cli(
        scan=scan,
        baseline_path=BASELINE,
        header=_HEADER,
        label="inline Zig OOM exits",
        refresh_cmd="python3 quality/ratchets/run.py oom --refresh",
        fix_hint=_FIX_HINT,
        argv=argv,
    )


if __name__ == "__main__":
    sys.exit(main())
