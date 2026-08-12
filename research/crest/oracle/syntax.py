"""Independent parser for irregex's consuming byte-regex subset."""

from __future__ import annotations

from dataclasses import dataclass

BYTE_ALPHABET = frozenset(range(256))
DIGIT = frozenset(range(ord("0"), ord("9") + 1))
LOWER = frozenset(range(ord("a"), ord("z") + 1))
UPPER = frozenset(range(ord("A"), ord("Z") + 1))
WORD = DIGIT | LOWER | UPPER | {ord("_")}
SPACE = frozenset(map(ord, " \t\n\r\v\f"))

MAX_PATTERN_CHARS = 4096
MAX_REPEAT = 1000
MAX_GROUP_DEPTH = 128


class OracleError(Exception):
    """Base class for deterministic, fail-closed oracle errors."""

    code = "oracle.error"

    def __init__(
        self,
        message: str,
        *,
        position: int | None = None,
        construct: str | None = None,
    ):
        super().__init__(message)
        self.position = position
        self.construct = construct

    def as_dict(self) -> dict[str, object]:
        out: dict[str, object] = {"code": self.code, "message": str(self)}
        if self.position is not None:
            out["position"] = self.position
        if self.construct is not None:
            out["construct"] = self.construct
        return out


class PatternRefusal(OracleError):
    """The pattern requests semantics outside the exact consuming oracle."""

    code = "oracle.pattern_refused"


class PatternSyntaxError(OracleError):
    """The pattern is malformed in the oracle's documented grammar."""

    code = "oracle.pattern_syntax"


class ResourceLimitExceeded(OracleError):
    """Exact evaluation crossed a declared capacity ceiling."""

    code = "oracle.resource_limit"


class EmptyLanguage(OracleError):
    """The language is empty, so its minimum run statistic is undefined."""

    code = "oracle.empty_language"


@dataclass(frozen=True, slots=True)
class Epsilon:
    pass


@dataclass(frozen=True, slots=True)
class Atom:
    bytes: frozenset[int]


@dataclass(frozen=True, slots=True)
class Concat:
    parts: tuple[Node, ...]


@dataclass(frozen=True, slots=True)
class Alternate:
    branches: tuple[Node, ...]


@dataclass(frozen=True, slots=True)
class Repeat:
    child: Node
    minimum: int
    maximum: int | None


type Node = Epsilon | Atom | Concat | Alternate | Repeat


def _byte_range(low: str, high: str) -> frozenset[int]:
    return frozenset(range(ord(low), ord(high) + 1))


POSIX_CLASSES: dict[str, frozenset[int]] = {
    "alnum": DIGIT | LOWER | UPPER,
    "alpha": LOWER | UPPER,
    "ascii": frozenset(range(0x80)),
    "blank": frozenset(map(ord, "\t ")),
    "cntrl": frozenset(range(0x20)) | {0x7F},
    "digit": DIGIT,
    "graph": frozenset(range(0x21, 0x7F)),
    "lower": LOWER,
    "print": frozenset(range(0x20, 0x7F)),
    "punct": (
        _byte_range("!", "/")
        | _byte_range(":", "@")
        | _byte_range("[", "`")
        | _byte_range("{", "~")
    ),
    "space": SPACE,
    "upper": UPPER,
    "word": WORD,
    "xdigit": DIGIT | _byte_range("A", "F") | _byte_range("a", "f"),
}


def parse(pattern: str) -> Node:
    """Parse one consuming irregex byte regex or raise a typed refusal."""
    try:
        return _Parser(pattern).parse()
    except RecursionError as error:
        raise ResourceLimitExceeded(
            "pattern nesting exceeded the exact parser's recursion limit",
            construct="group nesting",
        ) from error


class _Parser:
    def __init__(self, pattern: str):
        self.pattern = pattern
        self.i = 0
        self.group_depth = 0

    def parse(self) -> Node:
        if len(self.pattern) > MAX_PATTERN_CHARS:
            raise ResourceLimitExceeded(
                f"pattern exceeds {MAX_PATTERN_CHARS} characters",
                construct="pattern",
            )
        node = self._alternation()
        if self.i != len(self.pattern):
            raise PatternSyntaxError("unexpected closing delimiter", position=self.i)
        return node

    def _alternation(self) -> Node:
        branches = [self._concatenation()]
        while self._peek() == "|":
            self.i += 1
            branches.append(self._concatenation())
        return branches[0] if len(branches) == 1 else Alternate(tuple(branches))

    def _concatenation(self) -> Node:
        parts: list[Node] = []
        while (ch := self._peek()) is not None and ch not in "|)":
            parts.append(self._quantified())
        if not parts:
            return Epsilon()
        return parts[0] if len(parts) == 1 else Concat(tuple(parts))

    def _quantified(self) -> Node:
        child = self._atom()
        while (ch := self._peek()) in ("?", "*", "+", "{"):
            position = self.i
            if ch == "?":
                self.i += 1
                child = Repeat(child, 0, 1)
            elif ch == "*":
                self.i += 1
                child = Repeat(child, 0, None)
            elif ch == "+":
                self.i += 1
                child = Repeat(child, 1, None)
            else:
                child = self._bounded(child)

            # A trailing '?' changes match priority, never the language.
            if self._peek() == "?":
                self.i += 1
            if self.i == position:
                raise AssertionError("quantifier parser made no progress")
        return child

    def _bounded(self, child: Node) -> Node:
        start = self.i
        end = self.pattern.find("}", start + 1)
        if end < 0:
            raise PatternSyntaxError("unterminated bounded repetition", position=start)
        body = self.pattern[start + 1 : end]
        self.i = end + 1
        if "," not in body:
            if not _is_decimal(body):
                raise PatternSyntaxError("expected {m}, {m,n}, or {m,}", position=start)
            minimum = maximum = int(body)
        else:
            fields = body.split(",")
            if len(fields) != 2 or not _is_decimal(fields[0]):
                raise PatternSyntaxError("expected {m,n} or {m,}", position=start)
            minimum = int(fields[0])
            if fields[1] == "":
                maximum = None
            elif _is_decimal(fields[1]):
                maximum = int(fields[1])
            else:
                raise PatternSyntaxError("repetition bound is not an integer", position=start)
        if maximum is not None and minimum > maximum:
            raise PatternSyntaxError("repetition lower bound exceeds upper bound", position=start)
        largest = minimum if maximum is None else maximum
        if largest > MAX_REPEAT:
            raise ResourceLimitExceeded(
                f"repetition bound exceeds exact-oracle limit {MAX_REPEAT}",
                position=start,
                construct="bounded repetition",
            )
        return Repeat(child, minimum, maximum)

    def _atom(self) -> Node:
        position = self.i
        ch = self._take()
        if ch is None:
            raise PatternSyntaxError("expected an atom", position=position)
        if ch == "(":
            return self._group(position)
        if ch == "[":
            return Atom(self._byte_class(position))
        if ch == ".":
            return Atom(BYTE_ALPHABET - {ord("\n")})
        if ch == "\\":
            return Atom(self._escape(position, in_class=False))
        if ch in "^$":
            raise PatternRefusal(
                "zero-width assertions are never erased by the exact oracle",
                position=position,
                construct=f"anchor {ch}",
            )
        if ch in "*+?{":
            raise PatternSyntaxError("quantifier has no preceding atom", position=position)
        return Atom(self._literal_byte(ch, position))

    def _group(self, position: int) -> Node:
        if self._peek() == "?":
            self.i += 1
            extension = self._take()
            if extension == ":":
                pass
            elif extension in ("=", "!"):
                raise PatternRefusal(
                    "lookahead is assertion-bearing and cannot enter the consuming oracle",
                    position=position,
                    construct="lookahead",
                )
            elif extension == "P":
                if self._peek() == "=":
                    raise PatternRefusal(
                        "named backreferences are not regular byte-language constructs",
                        position=position,
                        construct="named backreference",
                    )
                if self._take() != "<":
                    self._unsupported_group(position)
                self._group_name(position)
            elif extension == "<":
                if self._peek() in ("=", "!"):
                    raise PatternRefusal(
                        "lookbehind is assertion-bearing and cannot enter the consuming oracle",
                        position=position,
                        construct="lookbehind",
                    )
                self._group_name(position)
            else:
                self._unsupported_group(position)
        elif self._peek() == "*":
            raise PatternRefusal(
                "PCRE control groups are outside irregex's consuming byte grammar",
                position=position,
                construct="PCRE group verb",
            )
        if self.group_depth >= MAX_GROUP_DEPTH:
            raise ResourceLimitExceeded(
                f"group nesting exceeds exact-oracle limit {MAX_GROUP_DEPTH}",
                position=position,
                construct="group nesting",
            )
        self.group_depth += 1
        try:
            child = self._alternation()
        finally:
            self.group_depth -= 1
        if self._peek() != ")":
            raise PatternSyntaxError("unterminated group", position=position)
        self.i += 1
        return child

    def _unsupported_group(self, position: int) -> None:
        construct = self.pattern[position : min(len(self.pattern), position + 5)]
        raise PatternRefusal(
            "group extension is outside the exact consuming byte grammar",
            position=position,
            construct=construct,
        )

    def _group_name(self, position: int) -> None:
        end = self.pattern.find(">", self.i)
        if end < 0:
            raise PatternSyntaxError("unterminated named group", position=position)
        self.i = end + 1

    def _byte_class(self, position: int) -> frozenset[int]:
        negated = self._peek() == "^"
        if negated:
            self.i += 1
        values: set[int] = set()
        first = True
        while True:
            ch = self._peek()
            if ch is None:
                raise PatternSyntaxError("unterminated byte class", position=position)
            if ch == "]" and not first:
                self.i += 1
                result = BYTE_ALPHABET - values if negated else frozenset(values)
                return result - {ord("\n")} if negated else result
            if self.pattern[self.i : self.i + 2] in ("&&", "--", "~~"):
                raise PatternRefusal(
                    "class set operations are outside the exact byte-class grammar",
                    position=self.i,
                    construct="class set operation",
                )
            if ch == "[":
                if self.pattern[self.i : self.i + 2] == "[:":
                    posix = self._maybe_posix()
                    if posix is not None:
                        values.update(posix)
                        first = False
                        continue
                raise PatternRefusal(
                    "nested byte classes are outside the exact byte-class grammar",
                    position=self.i,
                    construct="nested byte class",
                )
            first = False
            item = self._class_atom()
            if self._peek() == "-" and self._peek(1) not in (None, "]"):
                dash = self.i
                self.i += 1
                endpoint = self._class_atom()
                if len(item) != 1 or len(endpoint) != 1:
                    raise PatternSyntaxError(
                        "byte-class range endpoints must each denote one byte",
                        position=dash,
                    )
                low = next(iter(item))
                high = next(iter(endpoint))
                if low > high:
                    raise PatternSyntaxError("descending byte-class range", position=dash)
                values.update(range(low, high + 1))
            else:
                values.update(item)

    def _class_atom(self) -> frozenset[int]:
        position = self.i
        ch = self._take()
        if ch == "\\":
            return self._escape(position, in_class=True)
        return self._literal_byte(ch, position)

    def _maybe_posix(self) -> frozenset[int] | None:
        start = self.i
        self.i += 2
        negated = self._peek() == "^"
        if negated:
            self.i += 1
        name_start = self.i
        end = self.pattern.find(":]", name_start)
        if end < 0:
            self.i = start
            return None
        name = self.pattern[name_start:end]
        self.i = end + 2
        values = POSIX_CLASSES.get(name)
        if values is None:
            raise PatternSyntaxError("unknown POSIX byte class", position=start)
        if not negated:
            return values
        return (BYTE_ALPHABET - values) - {ord("\n")}

    def _escape(self, position: int, *, in_class: bool) -> frozenset[int]:
        ch = self._take()
        if ch is None:
            raise PatternSyntaxError("trailing escape", position=position)
        assertions = {"b", "B", "<", ">", "A", "Z", "z", "G", "K"}
        if ch in assertions:
            raise PatternRefusal(
                "assertion escape is outside the consuming oracle",
                position=position,
                construct=f"assertion \\{ch}",
            )
        if ch.isdecimal() or ch in ("g", "k"):
            raise PatternRefusal(
                "numeric and named backreferences are outside regular byte languages",
                position=position,
                construct="backreference",
            )
        if ch == "x":
            return frozenset({self._hex_byte(position)})
        classes = {
            "d": DIGIT,
            "D": BYTE_ALPHABET - DIGIT,
            "w": WORD,
            "W": BYTE_ALPHABET - WORD,
            "s": SPACE,
            "S": BYTE_ALPHABET - SPACE,
        }
        if ch in classes:
            return classes[ch]
        controls = {"a": 7, "t": 9, "n": 10, "v": 11, "f": 12, "r": 13}
        if ch in controls:
            return frozenset({controls[ch]})
        if ch.isalpha():
            location = "byte class" if in_class else "pattern"
            raise PatternRefusal(
                f"unknown or Unicode-sensitive escape in {location}",
                position=position,
                construct=f"escape \\{ch}",
            )
        return self._literal_byte(ch, position)

    def _hex_byte(self, position: int) -> int:
        if self._peek() == "{":
            self.i += 1
            end = self.pattern.find("}", self.i)
            digits = self.pattern[self.i : end] if end >= 0 else ""
            if end < 0 or not digits or any(ch not in _HEX for ch in digits):
                raise PatternSyntaxError("invalid braced hexadecimal escape", position=position)
            self.i = end + 1
        else:
            digits = self.pattern[self.i : self.i + 2]
            if len(digits) != 2 or any(ch not in _HEX for ch in digits):
                raise PatternSyntaxError(
                    "\\x requires two hexadecimal digits or a braced byte",
                    position=position,
                )
            self.i += 2
        value = int(digits, 16)
        if value > 0xFF:
            raise PatternRefusal(
                "the oracle is byte-oriented; hexadecimal value exceeds 0xff",
                position=position,
                construct="non-byte hexadecimal escape",
            )
        return value

    @staticmethod
    def _literal_byte(ch: str | None, position: int) -> frozenset[int]:
        if ch is None:
            raise PatternSyntaxError("expected byte", position=position)
        value = ord(ch)
        if value > 0x7F:
            raise PatternRefusal(
                "non-ASCII source literals are ambiguous; use explicit \\xHH bytes",
                position=position,
                construct="non-ASCII literal",
            )
        return frozenset({value})

    def _peek(self, offset: int = 0) -> str | None:
        index = self.i + offset
        return self.pattern[index] if index < len(self.pattern) else None

    def _take(self) -> str | None:
        ch = self._peek()
        if ch is not None:
            self.i += 1
        return ch


_HEX = frozenset("0123456789abcdefABCDEF")


def _is_decimal(text: str) -> bool:
    return bool(text) and text.isascii() and text.isdigit()
