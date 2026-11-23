# Copyright (c) 2026 The Billy Company
# pyright: strict
"""Check company copyright headers; --fix inserts notices without changing licenses."""

from __future__ import annotations

import argparse
import dataclasses
import datetime
import fnmatch
import hashlib
import json
import os
import pathlib
import re
import shlex
import shutil
import stat
import subprocess
import sys
import typing


@dataclasses.dataclass(frozen=True)
class Style:
    """Comment syntax used to recognize and insert source notices."""

    line: bytes
    blocks: tuple[tuple[bytes, bytes], ...] = ()

    def notice(self, year: int) -> bytes:
        """Render a company notice in this language's comment syntax."""
        text = f"Copyright (c) {year} The Billy Company".encode("ascii")
        if self.line:
            return self.line + b" " + text
        opening, closing = self.blocks[0]
        return opening + b" " + text + b" " + closing


SLASH = Style(b"//", ((b"/*", b"*/"),))
HASH = Style(b"#")
DASH = Style(b"--", ((b"/-", b"-/"), (b"{-", b"-}")))
BLOCK = Style(b"", ((b"/*", b"*/"),))
STYLES: dict[str, Style] = {
    **dict.fromkeys(
        (
            ".c",
            ".cc",
            ".cpp",
            ".cxx",
            ".h",
            ".hh",
            ".hpp",
            ".hxx",
            ".m",
            ".mm",
            ".js",
            ".jsx",
            ".mjs",
            ".cjs",
            ".ts",
            ".tsx",
            ".mts",
            ".cts",
            ".rs",
            ".go",
            ".swift",
            ".zig",
            ".zon",
            ".mojom",
            ".java",
            ".kt",
            ".kts",
            ".cs",
            ".scala",
            ".dart",
            ".metal",
            ".glsl",
            ".vert",
            ".frag",
            ".proto",
            ".v",
            ".sv",
            ".scss",
            ".sass",
            ".less",
            ".php",
        ),
        SLASH,
    ),
    **dict.fromkeys(
        (
            ".py",
            ".pyi",
            ".sh",
            ".bash",
            ".zsh",
            ".fish",
            ".rb",
            ".r",
            ".pl",
            ".pm",
            ".ex",
            ".exs",
            ".jl",
            ".ps1",
            ".psm1",
            ".awk",
            ".gql",
            ".graphql",
            ".cmake",
            ".mk",
            ".gn",
            ".gni",
            ".podspec",
            ".rake",
            ".tcl",
        ),
        HASH,
    ),
    **dict.fromkeys((".lean", ".lua", ".hs", ".sql", ".applescript"), DASH),
    **dict.fromkeys((".css", ".s"), BLOCK),
    **dict.fromkeys((".scm", ".lisp", ".el", ".clj", ".cljs", ".asm"), Style(b";")),
    **dict.fromkeys((".html", ".htm", ".vue", ".svelte"), Style(b"", ((b"<!--", b"-->"),))),
    **dict.fromkeys((".ml", ".mli"), Style(b"", ((b"(*", b"*)"),))),
    ".vim": Style(b'"'),
    ".erl": Style(b"%"),
    ".hrl": Style(b"%"),
}
YEAR = rb"\d{4}(?:[ \t]*[-,][ \t]*\d{4})*"
OWNER = rb"The Billy Company\b"
COPYRIGHT = re.compile(
    rb"(?:(?:\bcopyright[ \t]*(?:\(c\)|\xc2\xa9)?|\xc2\xa9)[ \t]*"
    + YEAR
    + rb"[ \t]+"
    + OWNER
    + rb"|\bspdx-filecopyrighttext:[ \t]*(?:\xc2\xa9[ \t]*)?(?:"
    + YEAR
    + rb"[ \t]+)?"
    + OWNER
    + rb")",
    re.IGNORECASE,
)
ENCODING = re.compile(rb"^[ \t]*#.*?coding[:=][ \t]*[-\w.]+")
BOM = b"\xef\xbb\xbf"


@dataclasses.dataclass(frozen=True)
class Exclusion:
    """A reviewed ownership or generated-source exception."""

    path: str
    reason: str
    sha256: str | None = None


@dataclasses.dataclass(frozen=True)
class JsonObject:
    """A parsed JSON object with explicitly typed field values."""

    fields: tuple[tuple[str, object], ...]


def json_object(pairs: list[tuple[str, object]]) -> JsonObject:
    """Preserve typed JSON fields and reject duplicate keys."""
    if len({key for key, _ in pairs}) != len(pairs):
        message = "duplicate JSON key"
        raise ValueError(message)
    return JsonObject(tuple(pairs))


def object_list(value: object) -> typing.TypeGuard[list[object]]:
    """Narrow JSON arrays without granting their contents extra guarantees."""
    return isinstance(value, list)


def exclusions(root: pathlib.Path) -> tuple[Exclusion, ...]:
    """Validate the repository's reviewed copyright exceptions."""
    path = root / ".copyright.json"
    if not path.exists():
        return ()
    if path.is_symlink():
        message = ".copyright.json must not be a symlink"
        raise ValueError(message)
    value: object = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=json_object)
    if not isinstance(value, JsonObject) or set(dict(value.fields)) != {"exclude"}:
        message = ".copyright.json must contain only an 'exclude' array"
        raise ValueError(message)
    entries = dict(value.fields)["exclude"]
    if not object_list(entries):
        message = "'exclude' must be an array"
        raise ValueError(message)
    result: list[Exclusion] = []
    for item in entries:
        if not isinstance(item, JsonObject) or set(dict(item.fields)) not in (
            {"path", "reason"},
            {"path", "reason", "sha256"},
        ):
            message = "each exclusion needs path, reason, and optional sha256"
            raise ValueError(message)
        fields = dict(item.fields)
        pattern, reason = fields["path"], fields["reason"]
        if not isinstance(pattern, str) or not isinstance(reason, str) or not reason.strip():
            message = "exclusion path and nonempty reason must be strings"
            raise ValueError(message)
        if not pattern or pattern.startswith("/") or ".." in pattern.split("/") or "\\" in pattern:
            message = f"exclusion must be a repository-relative POSIX glob: {pattern!r}"
            raise ValueError(message)
        digest: str | None = None
        if "sha256" in fields:
            raw_digest = fields["sha256"]
            if (
                not isinstance(raw_digest, str)
                or re.fullmatch(r"[0-9a-f]{64}", raw_digest) is None
                or any(character in pattern for character in "*?[]")
            ):
                message = "sha256 must be 64 lowercase hex digits on an exact-file exclusion"
                raise ValueError(message)
            digest = raw_digest
        result.append(Exclusion(pattern, reason, digest))
    return tuple(result)


def source_style(path: pathlib.Path, content: bytes) -> Style | None:
    """Resolve supported source syntax without interpreting its program."""
    suffix = path.suffix.lower()
    if suffix in STYLES:
        return STYLES[suffix]
    if path.name in {"CMakeLists.txt", "Makefile", "GNUmakefile", "Podfile", "Gemfile"}:
        return HASH
    if not suffix and content.removeprefix(BOM).startswith(b"#!"):
        first = content.removeprefix(BOM).splitlines()[0]
        words = shlex.split(first[2:].decode("utf-8"))
        if words and pathlib.PurePosixPath(words[0]).name == "env":
            words = words[1:]
            if words and words[0] == "-S":
                words = words[1:]
        interpreter = pathlib.PurePosixPath(words[0]).name if words else ""
        if interpreter in {"node", "nodejs", "deno", "bun", "swift"}:
            return SLASH
        if interpreter in {
            "sh",
            "bash",
            "zsh",
            "dash",
            "ksh",
            "fish",
            "ruby",
            "perl",
        } or re.fullmatch(r"python(?:[23](?:\.\d+)*)?", interpreter):
            return HASH
        message = f"{path}: unsupported shebang interpreter {interpreter!r}; choose its comment syntax before adding a notice"
        raise ValueError(message)
    return None


def header_comments(content: bytes, style: Style) -> bytes:
    """Read only the initial comments after required language prefixes."""
    cursor = len(BOM) if content.startswith(BOM) else 0
    comments: list[bytes] = []
    if content[cursor:].startswith(b"<?php"):
        cursor += len(b"<?php")
    doctype = re.match(rb"<!doctype\b[^>]*>", content[cursor:], re.IGNORECASE)
    if doctype:
        cursor += doctype.end()
    charset = re.match(rb'@charset\s+"[^"]*"\s*;', content[cursor:], re.IGNORECASE)
    if charset:
        cursor += charset.end()
    if content[cursor:].startswith(b"#!"):
        end = content.find(b"\n", cursor)
        cursor = len(content) if end < 0 else end + 1
    while cursor < len(content):
        while cursor < len(content) and content[cursor] in b" \t\r\n":
            cursor += 1
        if style.line and content[cursor:].startswith(style.line):
            end = content.find(b"\n", cursor)
            end = len(content) if end < 0 else end + 1
            comments.append(content[cursor:end])
            cursor = end
            continue
        block = next((pair for pair in style.blocks if content[cursor:].startswith(pair[0])), None)
        if block is None:
            break
        opening, closing = block
        end = content.find(closing, cursor + len(opening))
        if end < 0:
            message = "unterminated initial block comment"
            raise ValueError(message)
        end += len(closing)
        comments.append(content[cursor:end])
        cursor = end
    return b"\n".join(comments)


def add_notice(path: pathlib.Path, content: bytes, style: Style, year: int) -> bytes:
    """Insert a missing ownership notice while preserving source bytes."""
    if COPYRIGHT.search(header_comments(content, style)):
        return content
    newline = b"\r\n" if b"\r\n" in content else b"\n"
    bom = BOM if content.startswith(BOM) else b""
    body = content.removeprefix(bom) if bom else content
    opening = re.match(
        rb'(?:<\?php(?=\s|$)|<!doctype\b[^>]*>|@charset\s+"[^"]*"\s*;)',
        body,
        re.IGNORECASE,
    )
    if opening:
        end = opening.end()
        if body[end:].startswith(newline):
            end += len(newline)
        prefix = body[:end]
        if not prefix.endswith((b"\n", b"\r")):
            prefix += newline
        return bom + prefix + style.notice(year) + newline + body[end:]
    lines = body.splitlines(keepends=True)
    index = 1 if lines and lines[0].startswith(b"#!") else 0
    if path.suffix.lower() in {".py", ".pyi", ".rb"}:
        for position, line in enumerate(lines[:2]):
            if ENCODING.match(line) or (
                path.suffix.lower() == ".rb"
                and re.match(rb"^[ \t]*#.*frozen_string_literal:", line)
            ):
                index = max(index, position + 1)
    if path.name == "Package.swift" and lines and lines[0].startswith(b"// swift-tools-version:"):
        index = 1
    # Constraints retain their required blank separation from the Go package.
    if path.suffix.lower() == ".go":
        for position, line in enumerate(lines):
            stripped = line.strip()
            if stripped.startswith((b"//go:build ", b"// +build ")):
                index = position + 1
            elif stripped and not stripped.startswith(b"//"):
                break
        while index < len(lines) and not lines[index].strip():
            index += 1
    prefix = b"".join(lines[:index])
    if prefix and not prefix.endswith((b"\n", b"\r")):
        prefix += newline
    separator = newline if path.suffix.lower() == ".go" else b""
    return bom + prefix + style.notice(year) + newline + separator + b"".join(lines[index:])


def git_executable() -> str:
    """Resolve Git before passing its fixed argument vector to subprocess."""
    executable = shutil.which("git")
    if executable is None:
        message = "git is required on PATH"
        raise OSError(message)
    return str(pathlib.Path(executable).resolve())


def git_files(root: pathlib.Path) -> tuple[str, ...]:
    """Enumerate tracked and new, nonignored paths through Git."""
    result = subprocess.run(  # noqa: S603 -- fixed Git arguments; root is a separate argument
        [
            git_executable(),
            "-C",
            str(root),
            "ls-files",
            "-z",
            "--cached",
            "--others",
            "--exclude-standard",
        ],
        check=True,
        capture_output=True,
        timeout=30,
    )
    return tuple(sorted({os.fsdecode(name) for name in result.stdout.split(b"\0") if name}))


def write_unchanged(path: pathlib.Path, original: bytes, updated: bytes) -> None:
    """Write only when a nonsymlink file still matches its inspection bytes."""
    descriptor = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "r+b") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode) or stream.read() != original:
            message = f"file changed while checking: {path}"
            raise ValueError(message)
        _ = stream.seek(0)
        _ = stream.write(updated)
        _ = stream.truncate()


def check(root: pathlib.Path, fix: bool, year: int) -> tuple[int, int]:
    """Validate all candidates before adding any missing notices."""
    rules = exclusions(root)
    checked = 0
    missing: list[tuple[pathlib.Path, bytes, bytes]] = []
    for name in git_files(root):
        path = root / name
        matched = tuple(rule for rule in rules if fnmatch.fnmatchcase(name, rule.path))
        if path.is_symlink():
            if any(rule.sha256 is not None for rule in matched):
                message = f"digest-locked exclusion became a symlink: {name}"
                raise ValueError(message)
            continue
        if not path.is_file():
            continue
        for rule in matched:
            if rule.sha256 is not None:
                digest = hashlib.sha256(path.read_bytes()).hexdigest()
                if digest != rule.sha256:
                    message = f"{name}: excluded upstream source changed; review ownership and update its sha256 exemption or add an appropriate copyright notice"
                    raise ValueError(message)
        if matched:
            continue
        if (
            path.suffix
            and path.suffix.lower() not in STYLES
            and path.name not in {"CMakeLists.txt", "Makefile", "GNUmakefile", "Podfile", "Gemfile"}
        ):
            continue
        content = path.read_bytes()
        style = source_style(path, content)
        if style is None:
            continue
        checked += 1
        updated = add_notice(path, content, style, year)
        if updated != content:
            missing.append((path, content, updated))
    for path, original, updated in missing:
        if fix:
            write_unchanged(path, original, updated)
        print(f"{'added' if fix else 'missing'}: {path.relative_to(root)}")
    print(
        f"copyright: {checked} source files checked; {len(missing)} {'added' if fix else 'missing'}"
    )
    return checked, len(missing)


def main() -> int:
    """Run the read-only gate or explicit updater."""
    parser = argparse.ArgumentParser(description=__doc__)
    _ = parser.add_argument(
        "--root", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[2]
    )
    _ = parser.add_argument(
        "--fix", action="store_true", help="insert missing notices; preserve licenses"
    )
    _ = parser.add_argument(
        "--year",
        type=int,
        default=datetime.datetime.now().astimezone().year,
        help="year for newly added notices",
    )
    args = parser.parse_args()
    root: pathlib.Path = args.root.resolve()
    if not 1000 <= args.year <= 9999:
        parser.error("--year must have four digits")
    try:
        _, missing = check(root, args.fix, args.year)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"copyright: {error}", file=sys.stderr)
        return 2
    return int(bool(missing) and not args.fix)


if __name__ == "__main__":
    raise SystemExit(main())
