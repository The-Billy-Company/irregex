"""Leakage-safe trace loading and conservative exact byte-predicate extraction."""

from __future__ import annotations

import json
import re
from collections.abc import Iterable
from dataclasses import dataclass

from .package import (
    MANIFEST_MEMBER,
    PARTITION_MEMBERS,
    DataPackage,
    IntegrityError,
    SchemaError,
    canonical_json_sha256,
    is_strict_int,
    sha256_bytes,
)

TRACE_FIELDS = frozenset(
    {
        "call_key",
        "session_key",
        "timestamp",
        "pattern",
        "caseless",
        "unicode",
        "source_tool",
    }
)
TRACE_COUNT_FIELDS = frozenset({"calls", "sessions", "distinct_patterns"})
PARTITION_FILENAMES = {
    role: str(member.name) for role, member in PARTITION_MEMBERS.items()
}
HEX_KEY = {
    "call_key": re.compile(r"[0-9a-f]{24}\Z"),
    "session_key": re.compile(r"[0-9a-f]{20}\Z"),
}
EXACT_UNICODE_PROPERTIES = ("Nd", "L", "White_Space")
ASCII_DIGIT = frozenset(range(ord("0"), ord("9") + 1))
ASCII_WORD = frozenset(
    {
        *range(ord("0"), ord("9") + 1),
        *range(ord("A"), ord("Z") + 1),
        *range(ord("a"), ord("z") + 1),
        ord("_"),
    }
)
ASCII_SPACE = frozenset(b"\t\n\v\f\r ")
SHORTHANDS = {"d": ASCII_DIGIT, "w": ASCII_WORD, "s": ASCII_SPACE}
ZERO_WIDTH_ESCAPES = frozenset("AbBZzG")
SIMPLE_ESCAPES = {
    "a": 0x07,
    "f": 0x0C,
    "n": 0x0A,
    "r": 0x0D,
    "t": 0x09,
    "v": 0x0B,
}


@dataclass(frozen=True)
class TraceCounts:
    calls: int
    sessions: int
    distinct_patterns: int


@dataclass(frozen=True)
class TracePartition:
    sha256: str
    counts: TraceCounts


@dataclass(frozen=True)
class TraceManifest:
    document: dict[str, object]
    sha256: str
    dataset_fingerprint: str
    partitions: dict[str, TracePartition]

    def partition(self, role: str) -> TracePartition:
        try:
            return self.partitions[role]
        except KeyError as error:
            raise SchemaError(f"unknown trace partition: {role}") from error

    def partition_sha256(self, role: str) -> str:
        return self.partition(role).sha256


@dataclass(frozen=True)
class Atom:
    branch: int
    ordinal: int
    byte_set: frozenset[int]
    spelling: str


@dataclass(frozen=True)
class NonByteCandidate:
    branch: int
    spelling: str
    reason: str


@dataclass(frozen=True)
class Extraction:
    branch_count: int
    atoms: tuple[Atom, ...]
    non_byte: tuple[NonByteCandidate, ...]


def load_manifest(package: DataPackage) -> TraceManifest:
    package.verify_integrity()
    raw = package.read(MANIFEST_MEMBER)
    try:
        manifest = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SchemaError(f"invalid trace manifest JSON: {error}") from error
    if (
        not isinstance(manifest, dict)
        or manifest.get("schema") != "crest-query-trace-split-v1"
    ):
        raise SchemaError("trace manifest schema must be crest-query-trace-split-v1")
    hashes, counts = manifest.get("sha256"), manifest.get("counts")
    if not isinstance(hashes, dict) or not isinstance(counts, dict):
        raise SchemaError("trace manifest requires sha256 and counts objects")
    partitions: dict[str, TracePartition] = {}
    for role, filename in PARTITION_FILENAMES.items():
        count_key = "excluded_cross_boundary" if role == "excluded" else role
        digest, count = hashes.get(filename), counts.get(count_key)
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise SchemaError(f"trace manifest has no valid digest for {filename}")
        if (
            not isinstance(count, dict)
            or set(count) != TRACE_COUNT_FIELDS
            or not all(is_strict_int(count.get(field)) for field in TRACE_COUNT_FIELDS)
            or any(count[field] < 0 for field in TRACE_COUNT_FIELDS)
            or count["sessions"] > count["calls"]
            or count["distinct_patterns"] > count["calls"]
        ):
            raise SchemaError(f"trace manifest has invalid counts for {role}")
        partitions[role] = TracePartition(
            digest,
            TraceCounts(count["calls"], count["sessions"], count["distinct_patterns"]),
        )
        if digest != package.verified_checksum(PARTITION_MEMBERS[role]):
            raise IntegrityError(
                f"trace manifest digest differs from verified {role} member"
            )
    fingerprint = canonical_json_sha256(
        {
            "schema": "crest-dataset-fingerprint-v1",
            "trace_schema": manifest["schema"],
            "manifest_sha256": sha256_bytes(raw),
            "partitions": {
                role: {
                    "sha256": partition.sha256,
                    "calls": partition.counts.calls,
                    "sessions": partition.counts.sessions,
                    "distinct_patterns": partition.counts.distinct_patterns,
                }
                for role, partition in sorted(partitions.items())
            },
        }
    )
    return TraceManifest(manifest, sha256_bytes(raw), fingerprint, partitions)


def _validate_row(row: object, line_number: int) -> dict[str, object]:
    if not isinstance(row, dict) or set(row) != TRACE_FIELDS:
        raise SchemaError(f"line {line_number}: expected exactly seven trace fields")
    for key, matcher in HEX_KEY.items():
        if not isinstance(row[key], str) or not matcher.fullmatch(row[key]):
            raise SchemaError(f"line {line_number}: invalid {key}")
    if not isinstance(row["timestamp"], str) or not row["timestamp"].endswith("Z"):
        raise SchemaError(f"line {line_number}: timestamp must be a UTC string")
    if not isinstance(row["pattern"], str):
        raise SchemaError(f"line {line_number}: pattern must be a string")
    if not isinstance(row["caseless"], bool) or not isinstance(row["unicode"], bool):
        raise SchemaError(f"line {line_number}: caseless/unicode must be booleans")
    if row["source_tool"] not in {"Grep", "rg", "irregex"}:
        raise SchemaError(
            f"line {line_number}: source_tool is not a supported search trace"
        )
    return row


def load_trace(
    package: DataPackage, role: str, manifest: TraceManifest
) -> list[dict[str, object]]:
    if role not in {"train", "validation"}:
        raise SchemaError("analysis role must be train or validation")
    raw = package.read_partition(role)
    observed, expected = sha256_bytes(raw), manifest.partition_sha256(role)
    if observed != expected:
        raise IntegrityError(
            f"{role} digest mismatch: expected {expected}, got {observed}"
        )
    rows: list[dict[str, object]] = []
    for line_number, line in enumerate(raw.splitlines(keepends=True), 1):
        try:
            row = json.loads(line)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise SchemaError(f"line {line_number}: invalid JSON: {error}") from error
        rows.append(_validate_row(row, line_number))
    expected_counts = manifest.partition(role).counts
    observed_counts = TraceCounts(
        len(rows),
        len({row["session_key"] for row in rows}),
        len({row["pattern"] for row in rows}),
    )
    for label, expected_count, observed_count in (
        ("calls", expected_counts.calls, observed_counts.calls),
        ("sessions", expected_counts.sessions, observed_counts.sessions),
        (
            "distinct patterns",
            expected_counts.distinct_patterns,
            observed_counts.distinct_patterns,
        ),
    ):
        if observed_count != expected_count:
            raise IntegrityError(
                f"{role} {label} count mismatch: expected {expected_count}, got {observed_count}"
            )
    return rows


def _split_top_level(pattern: str) -> list[str]:
    branches: list[str] = []
    start = depth = index = 0
    in_class = escaped = False
    while index < len(pattern):
        char = pattern[index]
        if escaped:
            escaped = False
        elif char == "\\":
            escaped = True
        elif in_class:
            in_class = char != "]"
        elif char == "[":
            in_class = True
        elif char == "(":
            depth += 1
        elif char == ")":
            depth = max(0, depth - 1)
        elif char == "|" and depth == 0:
            branches.append(pattern[start:index])
            start = index + 1
        index += 1
    branches.append(pattern[start:])
    return branches


def _escape_set(
    text: str, index: int, unicode_mode: bool
) -> tuple[frozenset[int] | None, int, str | None]:
    if index + 1 >= len(text):
        return None, index + 1, "trailing_escape"
    code = text[index + 1]
    if code == "x" and index + 3 < len(text):
        token = text[index + 2 : index + 4]
        if re.fullmatch(r"[0-9A-Fa-f]{2}", token):
            value = int(token, 16)
            if not unicode_mode or value < 0x80:
                return frozenset({value}), index + 4, None
            return None, index + 4, "non_ascii_unicode_escape"
    if code in SHORTHANDS:
        if unicode_mode:
            return None, index + 2, "dynamic_unicode_shorthand"
        return SHORTHANDS[code], index + 2, None
    if code in "DWS":
        if unicode_mode:
            return None, index + 2, "dynamic_unicode_shorthand"
        return frozenset(set(range(256)) - SHORTHANDS[code.lower()]), index + 2, None
    if code in ZERO_WIDTH_ESCAPES:
        return frozenset(), index + 2, None
    if code in "pP":
        end = text.find("}", index + 2)
        return None, len(text) if end < 0 else end + 1, "unicode_property"
    if code in SIMPLE_ESCAPES:
        return frozenset({SIMPLE_ESCAPES[code]}), index + 2, None
    if code in "uUN0123456789":
        return None, index + 2, "dynamic_or_backreference_escape"
    if code.isalnum() or code == "_":
        return None, index + 2, "unsupported_escape"
    if ord(code) < 0x80:
        return frozenset({ord(code)}), index + 2, None
    return None, index + 2, "non_ascii_escape"


def _class_set(
    body: str, unicode_mode: bool
) -> tuple[frozenset[int] | None, str | None]:
    if not body:
        return None, "empty_or_malformed_class"
    negated = body.startswith("^")
    if negated:
        body = body[1:]
    if "[:" in body or "&&" in body or "--" in body or "~~" in body:
        return None, "class_algebra_or_posix"
    tokens: list[frozenset[int] | str] = []
    index = 0
    while index < len(body):
        char = body[index]
        if char == "\\":
            value, index, reason = _escape_set(body, index, unicode_mode)
            if reason:
                return None, reason
            if value:
                tokens.append(value)
            continue
        if char == "-":
            tokens.append("-")
        elif ord(char) < 0x80:
            tokens.append(frozenset({ord(char)}))
        else:
            return None, "non_ascii_class_member"
        index += 1
    result: set[int] = set()
    index = 0
    while index < len(tokens):
        if (
            index + 2 < len(tokens)
            and isinstance(tokens[index], frozenset)
            and tokens[index + 1] == "-"
            and isinstance(tokens[index + 2], frozenset)
            and len(tokens[index]) == len(tokens[index + 2]) == 1
        ):
            first, last = next(iter(tokens[index])), next(iter(tokens[index + 2]))
            if first > last:
                return None, "descending_class_range"
            result.update(range(first, last + 1))
            index += 3
            continue
        member = tokens[index]
        result.update({ord("-")} if member == "-" else member)
        index += 1
    if negated:
        if unicode_mode:
            return None, "negated_unicode_class"
        result = set(range(256)) - result
    return frozenset(result), None


def _class_end(branch: str, start: int) -> int:
    escaped = False
    for index in range(start + 1, len(branch)):
        char = branch[index]
        if char == "]" and not escaped:
            return index
        escaped = char == "\\" and not escaped
        if char != "\\":
            escaped = False
    return -1


def extract_predicates(pattern: str, caseless: bool, unicode_mode: bool) -> Extraction:
    branches = _split_top_level(pattern)
    if caseless or "(?" in pattern:
        reason = (
            "caseless_fold_semantics"
            if caseless
            else "inline_or_extended_group_semantics"
        )
        return Extraction(
            len(branches),
            (),
            tuple(
                NonByteCandidate(i, branch, reason) for i, branch in enumerate(branches)
            ),
        )
    atoms: list[Atom] = []
    rejected: list[NonByteCandidate] = []
    for branch_index, branch in enumerate(branches):
        index = ordinal = 0
        while index < len(branch):
            char = branch[index]
            if char == "[":
                end = _class_end(branch, index)
                if end < 0:
                    rejected.append(
                        NonByteCandidate(branch_index, branch[index:], "unclosed_class")
                    )
                    break
                spelling = branch[index : end + 1]
                byte_set, reason = _class_set(branch[index + 1 : end], unicode_mode)
                if reason:
                    rejected.append(NonByteCandidate(branch_index, spelling, reason))
                elif byte_set:
                    atoms.append(Atom(branch_index, ordinal, byte_set, spelling))
                    ordinal += 1
                index = end + 1
                continue
            if char == "\\":
                byte_set, end, reason = _escape_set(branch, index, unicode_mode)
                spelling = branch[index:end]
                if reason:
                    rejected.append(NonByteCandidate(branch_index, spelling, reason))
                elif byte_set:
                    atoms.append(Atom(branch_index, ordinal, byte_set, spelling))
                    ordinal += 1
                index = end
                continue
            if char == "{":
                end = branch.find("}", index + 1)
                index = len(branch) if end < 0 else end + 1
                continue
            if char == ".":
                rejected.append(NonByteCandidate(branch_index, char, "dot_semantics"))
            elif char not in "^$*+?()|" and ord(char) < 0x80:
                atoms.append(Atom(branch_index, ordinal, frozenset({ord(char)}), char))
                ordinal += 1
            elif ord(char) >= 0x80:
                rejected.append(
                    NonByteCandidate(branch_index, char, "non_ascii_literal")
                )
            index += 1
    return Extraction(len(branches), tuple(atoms), tuple(rejected))


def trace_extractions(rows: Iterable[dict[str, object]]) -> list[Extraction]:
    return [
        extract_predicates(row["pattern"], row["caseless"], row["unicode"])
        for row in rows
    ]


def encode_byte_set(byte_set: frozenset[int]) -> str:
    bits = sum(1 << value for value in byte_set)
    return bits.to_bytes(32, "little").hex()


def decode_byte_set(encoded: str) -> frozenset[int]:
    if not isinstance(encoded, str) or not re.fullmatch(r"[0-9a-f]{64}", encoded):
        raise SchemaError("predicate bitset must be 32 lowercase hexadecimal bytes")
    bits = int.from_bytes(bytes.fromhex(encoded), "little")
    return frozenset(index for index in range(256) if bits & (1 << index))


def byte_set_digest(byte_set: frozenset[int]) -> str:
    return sha256_bytes(bytes.fromhex(encode_byte_set(byte_set)))


def byte_ranges(byte_set: frozenset[int]) -> list[str]:
    if not byte_set:
        return []
    ordered = sorted(byte_set)
    ranges: list[str] = []
    start = previous = ordered[0]
    for value in [*ordered[1:], None]:
        if value is not None and value == previous + 1:
            previous = value
            continue
        ranges.append(
            f"{start:02x}" if start == previous else f"{start:02x}-{previous:02x}"
        )
        if value is not None:
            start = previous = value
    return ranges
