#!/usr/bin/env python3
"""Zig duplicate-helper ratchet — one definition per helper across files.

Freezes the count of copy-pasted helper bodies across the Zig tree — the
parity-bug class where twin engines share a hand-copied helper and a fix
lands in one copy while the other silently keeps the bug. A FINDING is a
normalized ``fn`` body that is byte-identical across ≥ 2 *different*
files; the per-file count is the number of that file's fns whose body also
appears elsewhere. (Duplicates *within* one file are a different smell and
are not counted here.)

Conservative on purpose — only *substantial* bodies participate:

* ≥ 40 normalized non-space characters, AND
* ≥ 3 statement-terminating ``;``

so trivial one-line wrappers (which legitimately recur) never fire.
Normalization strips comments, collapses whitespace runs to single
spaces, and trims; string-literal *content* is preserved, so two bodies
differing only in a message are NOT duplicates. Parsing is a
comment/string-aware brace matcher (a ``{`` inside a string or comment
never opens a body) and fails closed on unbalanced braces.

Opt-out: a fn whose immediately-preceding comment lines contain the
marker ``// dup-allow:`` is exempt — a deliberately-kept identical copy
with a documented reason.

Scope: ``src/**/*.zig``, excluding ``*_test.zig``, ``*.gen.zig``, and
generated-header files.

Run via ``python3 quality/ratchets/run.py dup-helper``; refresh with the
same command plus ``--refresh``.
"""

import re
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from _lib import FileCount, head_lines, run_count_cli, walk_source_files  # noqa: E402

REPO = Path(__file__).resolve().parents[3]
BASELINE = Path(__file__).resolve().parent / "dup-helper.baseline"

ROOTS = (REPO / "src",)
SKIP_DIR_PARTS = {"zig-out", ".zig-cache", "node_modules", "target"}
SKIP_NAME_SUFFIXES = ("_test.zig", ".gen.zig")

MIN_BODY_CHARS = 40  # normalized non-space characters
MIN_SEMIS = 3  # statement-terminating `;` in the normalized body

FN_DECL_RE = re.compile(
    r"^(?:pub\s+)?(?:export\s+)?(?:inline\s+)?fn\s+(\w+)\s*\(",
    re.MULTILINE,
)
GENERATED_HEADER_RE = re.compile(
    r"^\s*//\s*Code generated\b|^\s*//\s*@generated\b",
    re.IGNORECASE,
)
DUP_ALLOW_MARKER = "// dup-allow:"

# One left-to-right token scan: whichever token starts first wins, so a `//`
# inside a string never opens a comment and a quote inside a comment never
# opens a string. Zig `"…"`/`'…'` literals cannot span lines; `\\…` multiline
# -string lines are one token to end of line. Both views below are
# offset-preserving (same length as the original) so spans computed on one
# apply to the other — which is why _lib/zigtext.py's single-view lexer is not
# enough here.
_TOKEN_RE = re.compile(
    r"//[^\n]*|\"(?:\\.|[^\"\\\n])*\"|'(?:\\.|[^'\\\n])*'|^[ \t]*\\\\[^\n]*",
    re.MULTILINE,
)


def _two_views(text: str) -> tuple[str, str]:
    """Return ``(structural, body)`` offset-preserving views of ``text``.

    * structural — comments blanked, string/char/multiline-string *content*
      blanked (delimiters kept): safe to brace/paren-match on.
    * body — only comments blanked: string content survives, so two bodies
      differing only in a literal stay distinct.
    """
    struct_parts: list[str] = []
    body_parts: list[str] = []
    last = 0
    for m in _TOKEN_RE.finditer(text):
        struct_parts.append(text[last : m.start()])
        body_parts.append(text[last : m.start()])
        tok = m.group(0)
        struct_parts.append(" " * len(tok))
        body_parts.append(" " * len(tok) if tok.lstrip().startswith("//") else tok)
        last = m.end()
    struct_parts.append(text[last:])
    body_parts.append(text[last:])
    return "".join(struct_parts), "".join(body_parts)


@dataclass(frozen=True)
class FnBody:
    name: str
    normalized: str  # comment-stripped, whitespace-collapsed body text


def _body_span(structural: str, sig_end: int, *, where: str) -> tuple[int, int] | None:
    """Locate the ``{ … }`` body starting from the ``(`` at ``sig_end - 1``.

    Returns ``(open, close)`` offsets of the body braces, or ``None`` for a
    body-less declaration (extern prototype: ``;`` before any ``{``).
    Fails closed (SystemExit) on unbalanced parens/braces.
    """
    n = len(structural)
    i = sig_end
    depth = 1  # inside the parameter list's `(`
    while i < n and depth:
        c = structural[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        i += 1
    if depth:
        raise SystemExit(f"zig-dup: unbalanced parens in fn signature at {where}")
    # Past the params: skip the return type (may itself carry parens, e.g.
    # `callconv(.C)`); the body opens at the first top-level `{`, a `;` first
    # means a body-less prototype.
    paren = 0
    while i < n:
        c = structural[i]
        if c == "(":
            paren += 1
        elif c == ")":
            paren -= 1
        elif paren == 0:
            if c == "{":
                break
            if c == ";":
                return None
        i += 1
    else:
        raise SystemExit(f"zig-dup: fn signature never reaches a body at {where}")
    body_open = i
    depth = 1
    i += 1
    while i < n and depth:
        c = structural[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
        i += 1
    if depth:
        raise SystemExit(f"zig-dup: unbalanced braces in fn body at {where}")
    return body_open, i - 1


def _dup_allowed(text: str, decl_start: int) -> bool:
    """True when the comment block immediately above the decl carries the marker."""
    lines_above = text[:decl_start].splitlines()
    for line in reversed(lines_above):
        stripped = line.strip()
        if not stripped.startswith("//"):
            return False
        if DUP_ALLOW_MARKER in stripped:
            return True
    return False


def extract_fn_bodies(text: str, *, where: str = "<memory>") -> list[FnBody]:
    """Container-level fn bodies of one Zig source, normalized + filtered.

    Only *substantial* bodies (≥ ``MIN_BODY_CHARS`` non-space chars, ≥
    ``MIN_SEMIS`` semicolons) survive; ``// dup-allow:``-marked fns are
    dropped here so they can never participate in a duplicate group.
    """
    structural, body_view = _two_views(text)
    out: list[FnBody] = []
    for m in FN_DECL_RE.finditer(structural):
        if _dup_allowed(text, m.start()):
            continue
        span = _body_span(structural, m.end(), where=f"{where}:{m.group(1)}")
        if span is None:
            continue
        body = body_view[span[0] + 1 : span[1]]
        normalized = " ".join(body.split())
        if len(normalized.replace(" ", "")) < MIN_BODY_CHARS:
            continue
        if normalized.count(";") < MIN_SEMIS:
            continue
        out.append(FnBody(name=m.group(1), normalized=normalized))
    return out


def scan() -> list[FileCount]:
    files = walk_source_files(
        ROOTS,
        exts=frozenset({".zig"}),
        skip_dirs=SKIP_DIR_PARTS,
        skip_name_suffixes=SKIP_NAME_SUFFIXES,
    )
    # normalized body → {rel_path: fn-count-in-that-file}
    by_body: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    for path in files:
        # Fail closed: an unreadable source file must never silently pass.
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            raise SystemExit(f"zig-dup: cannot scan {path}: {exc}") from exc
        if any(GENERATED_HEADER_RE.match(line) for line in head_lines(text)):
            continue
        rel = str(path.relative_to(REPO))
        for fn in extract_fn_bodies(text, where=rel):
            by_body[fn.normalized][rel] += 1

    per_file: dict[str, int] = defaultdict(int)
    for body_files in by_body.values():
        if len(body_files) < 2:  # cross-FILE duplication only
            continue
        for rel, n in body_files.items():
            per_file[rel] += n
    return [FileCount(rel_path=rel, count=n) for rel, n in sorted(per_file.items())]


_HEADER = """\
# zig-dup ratchet baseline — cross-file copy-pasted fn bodies per Zig file.
#
# A finding is a normalized (comment-stripped, whitespace-collapsed)
# container-level fn body byte-identical across >= 2 different files under
# src/ — the parity-bug class where one twin is fixed and the other silently
# isn't. Deliberate copies opt out via `// dup-allow:`.
#
# Update rule: monotonically decrease only. Refresh after cleanup:
#     python3 quality/ratchets/run.py dup-helper --refresh
"""

_FIX_HINT = """\
One definition per helper:
  • hoist the shared body into one module and import it from both sites, or
  • if the copy is deliberate, mark it `// dup-allow: <reason>` above the fn
"""


def main(argv: list[str] | None = None) -> int:
    return run_count_cli(
        scan=scan,
        baseline_path=BASELINE,
        header=_HEADER,
        label="cross-file duplicate Zig helpers",
        refresh_cmd="python3 quality/ratchets/run.py dup-helper --refresh",
        fix_hint=_FIX_HINT,
        argv=argv,
    )


if __name__ == "__main__":
    sys.exit(main())
