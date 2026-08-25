"""Replacement-template parsing for :func:`irgx.sub` and :func:`irgx.subn`.

A template is compiled once per ``sub`` call and rendered once per match, so a
substitution over ten thousand matches parses ``\\g<name>`` once. Group
references are resolved against the pattern at compile time, which is what makes
a misspelled name an error before the first replacement rather than a silent
empty string on every one.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

from ._abi import error

if TYPE_CHECKING:
    from ._match import Match
    from ._pattern import Pattern

# `re`'s template escapes. Note `\b` is a backspace here, not a word boundary:
# a template is not a pattern, and this is the one place the two vocabularies
# collide. Keeping `re`'s meaning is the lesser surprise, since a template
# written for `re` must not silently change meaning here.
_ESCAPES = {
    "a": "\a",
    "b": "\b",
    "f": "\f",
    "n": "\n",
    "r": "\r",
    "t": "\t",
    "v": "\v",
    "\\": "\\",
}

_DIGITS = "0123456789"


class Template:
    """A parsed replacement: literal chunks interleaved with group numbers."""

    __slots__ = ("_as_bytes", "_constant", "_parts")

    def __init__(self, parts: list[str | int], as_bytes: bool) -> None:
        self._parts = parts
        self._as_bytes = as_bytes
        # A template with no group reference renders the same text for every
        # match, so the whole substitution is the subject cut at each span with
        # one constant between the pieces - an answer the engine's own spans
        # settle without a `Match` ever existing. Rendered once here so the
        # caller can ask whether that shortcut applies by reading a slot.
        # `None` means "depends on the match"; the empty replacement is a real
        # constant and must not be confused with it.
        self._constant: Any = (
            None
            if any(type(part) is int for part in parts)
            else (b"" if as_bytes else "").join(
                part.encode("latin-1") if as_bytes else part  # type: ignore[union-attr]
                for part in parts
            )
        )

    @property
    def constant(self) -> Any:
        """The text every match renders to, or ``None`` when a group decides it."""
        return self._constant

    def render(self, match: Match) -> Any:
        pieces = []
        for part in self._parts:
            if isinstance(part, int):
                found = match[part]
                # `re` renders a group the match did not enter as empty rather
                # than refusing, because `(a)|(b)` templates rely on it.
                if found is None:
                    continue
                pieces.append(found)
            else:
                pieces.append(part.encode("latin-1") if self._as_bytes else part)
        if self._as_bytes:
            return b"".join(pieces)
        return "".join(pieces)


def compile_template(template: str | bytes, pattern: Pattern) -> Template:
    """Parse ``template`` against ``pattern``, resolving every group reference."""
    as_bytes = isinstance(template, bytes | bytearray)
    if as_bytes != pattern.is_bytes:
        wanted = "bytes" if pattern.is_bytes else "str"
        raise TypeError(f"the replacement template must be {wanted}, like the pattern")
    # Round-tripping bytes through latin-1 is lossless for every byte value, so
    # one parser serves both domains and the bytes path stays byte-exact.
    text = bytes(template).decode("latin-1") if as_bytes else template

    parts: list[str | int] = []
    literal: list[str] = []
    index = 0
    size = len(text)

    def flush() -> None:
        if literal:
            parts.append("".join(literal))
            literal.clear()

    def use(number: int, spelled: str) -> None:
        if number > pattern.groups:
            raise error(
                f"invalid group reference {spelled!r} in the replacement template: "
                f"the pattern declares {pattern.groups} group(s)"
            )
        flush()
        parts.append(number)

    while index < size:
        char = text[index]
        if char != "\\":
            literal.append(char)
            index += 1
            continue
        index += 1
        if index >= size:
            raise error("the replacement template ends with a trailing backslash")
        char = text[index]
        index += 1
        if char == "g":
            if index >= size or text[index] != "<":
                raise error("missing '<' after '\\g' in the replacement template")
            close = text.find(">", index)
            if close < 0:
                raise error("missing '>' after '\\g<' in the replacement template")
            name = text[index + 1 : close]
            index = close + 1
            if not name:
                raise error("missing group name in '\\g<>' in the replacement template")
            if name.isdigit():
                use(int(name), f"\\g<{name}>")
            else:
                number = pattern.groupindex.get(name)
                if number is None:
                    raise error(f"unknown group name {name!r} in the replacement template")
                use(number, f"\\g<{name}>")
            continue
        if char in _DIGITS:
            digits = char
            # Two digits at most, `re`'s rule, so `\1` followed by a literal 0
            # is spelled `\g<1>0` in both libraries.
            if char != "0" and index < size and text[index] in _DIGITS:
                digits += text[index]
                index += 1
            if digits[0] == "0":
                literal.append(chr(int(digits, 8)))
                continue
            use(int(digits), f"\\{digits}")
            continue
        if char in _ESCAPES:
            literal.append(_ESCAPES[char])
            continue
        if char.isascii() and char.isalpha():
            raise error(f"bad escape '\\{char}' in the replacement template")
        literal.append(char)

    flush()
    return Template(parts, as_bytes)
