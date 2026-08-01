"""Telling Zig code from Zig prose.

A textual Zig ratchet is only as trustworthy as its ability to tell the two
apart. `std.debug.print` named in a doc comment is documentation; `error.Corrupt`
quoted in a `//!` header is not a declaration. So `fault-taxonomy` and
`assay-bypass` both scan a *blanked* copy of the source in which every comment,
string literal, char literal, and multiline-string line has become spaces of the
same length — offsets and line numbers survive for reporting, while a needle can
only match real code.

Offset-preserving is the load-bearing property: a match found in the blanked
copy can be read back out of the original bytes at the same index, so a finding
still reports the line it lives on.

``test_block_ranges`` supplies the second shared exclusion. Zig allows inline
``test "…" { … }`` blocks inside an ordinary source file, and a test's error
names (``error.SkipZigTest``) and stderr writes are out of scope for both
ratchets exactly as they are in a sibling ``*_test.zig``.

**On the second copy of this lexer.** The same seventy lines live in `ward.prose`
in the private monorepo, where `ward` judges Zig package structure over the real
`@import` graph. That is a fork boundary rather than drift: the two copies scan
disjoint trees — this one sees only irregex's own `src/`, `ward` sees the Zig
packages that stayed behind — so they can never disagree about the same file. A
shared dependency would buy nothing here and would cost the thing that matters
most about a ratchet, which is that it runs as a bare `python3 <path>` with
nothing installed.
"""

from __future__ import annotations

import re

# One left-to-right token scan: whichever token starts first wins, so a `//`
# inside a string never opens a comment and a quote inside a comment never
# opens a string. Zig `"…"` / `'…'` literals cannot span lines; `\\…`
# multiline-string lines are blanked whole beforehand.
_TOKEN_RE = re.compile(r"//[^\n]*|\"(?:\\.|[^\"\\\n])*\"|'(?:\\.|[^'\\\n])*'")
_MULTILINE_STR_RE = re.compile(r"^[ \t]*\\\\.*$", re.MULTILINE)

# Inline container-scope test block. `test` is a Zig keyword and cannot name a
# variable, so a line-leading `test` up to its opening brace is unambiguous —
# the name (`test "…" {`) is already blanked by the time this runs.
_TEST_DECL_RE = re.compile(r"^[ \t]*test\b[^\n{]*\{", re.MULTILINE)


def code_only(text: str) -> str:
    """`text` with comments and literals blanked to spaces, offset-preserving.

    The result is the same length as the input, with the same newlines in the
    same places, so a match offset maps back to the original file's line.
    """
    text = _MULTILINE_STR_RE.sub(lambda m: " " * len(m.group(0)), text)
    out: list[str] = []
    last = 0
    for m in _TOKEN_RE.finditer(text):
        out.append(text[last : m.start()])
        out.append(" " * len(m.group(0)))
        last = m.end()
    out.append(text[last:])
    return "".join(out)


def test_block_ranges(code: str) -> list[tuple[int, int]]:
    """Half-open offset spans of each inline ``test … { … }`` block in `code`.

    Expects ``code_only`` output: brace counting is only sound once braces
    inside comments and char literals (``'{'``) are gone.
    """
    spans: list[tuple[int, int]] = []
    for m in _TEST_DECL_RE.finditer(code):
        depth, i = 0, m.end() - 1
        while i < len(code):
            ch = code[i]
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        spans.append((m.start(), min(i + 1, len(code))))
    return spans
