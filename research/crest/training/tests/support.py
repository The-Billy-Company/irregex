"""Synthetic CREST trace packages with no private corpus material."""

from __future__ import annotations

import hashlib
import json
import zipfile
from pathlib import Path


def row(index: int, pattern: str, *, unicode: bool = True) -> dict[str, object]:
    return {
        "call_key": f"{index:024x}",
        "caseless": False,
        "pattern": pattern,
        "session_key": f"{index:020x}",
        "source_tool": "irregex",
        "timestamp": f"2026-01-{index + 1:02d}T00:00:00Z",
        "unicode": unicode,
    }


def jsonl(rows: list[dict[str, object]]) -> bytes:
    return b"".join(
        json.dumps(item, sort_keys=True, separators=(",", ":")).encode() + b"\n" for item in rows
    )


class TraceFixture:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.trace = root / "data/entireio_trace_v1"
        self.trace.mkdir(parents=True)
        self.rows = {
            "train": [
                row(1, "[A-Z]+"),
                row(2, "[A-Z][0-9]"),
                row(3, "x x"),
            ],
            "validation": [row(4, "[A-Z]{2}"), row(5, "x")],
            "test": [row(6, "SEALED_TEST")],
            "excluded_cross_boundary": [row(7, "SEALED_EXCLUDED")],
        }
        self.manifest_document: dict[str, object] = {
            "schema": "crest-query-trace-split-v1",
            "sha256": {},
            "counts": {},
        }
        for role in self.rows:
            self.write_partition(role, rewrite_package=False)
        self.write_manifest()
        self.write_checksums()

    @property
    def settings(self) -> dict[str, object]:
        return {
            "schema": "crest-validation-settings-v1",
            "settings": [
                {"name": "predicate-prefix-1", "predicate_k": 1},
                {"name": "predicate-prefix-2", "predicate_k": 2},
            ],
        }

    def write_manifest(self) -> None:
        (self.trace / "manifest.json").write_text(
            json.dumps(self.manifest_document, indent=2, sort_keys=True) + "\n"
        )

    def write_checksums(self) -> None:
        paths = sorted(
            path
            for path in self.root.rglob("*")
            if path.is_file() and path.name != "CHECKSUMS.sha256"
        )
        (self.root / "CHECKSUMS.sha256").write_text(
            "".join(
                f"{hashlib.sha256(path.read_bytes()).hexdigest()}  "
                f"{path.relative_to(self.root).as_posix()}\n"
                for path in paths
            )
        )

    def write_partition(self, role: str, *, rewrite_package: bool = True) -> None:
        rows = self.rows[role]
        raw = jsonl(rows)
        filename = f"{role}.jsonl"
        (self.trace / filename).write_bytes(raw)
        hashes = self.manifest_document["sha256"]
        counts = self.manifest_document["counts"]
        assert isinstance(hashes, dict) and isinstance(counts, dict)
        hashes[filename] = hashlib.sha256(raw).hexdigest()
        counts[role] = {
            "calls": len(rows),
            "sessions": len({item["session_key"] for item in rows}),
            "distinct_patterns": len({item["pattern"] for item in rows}),
        }
        if rewrite_package:
            self.write_manifest()
            self.write_checksums()

    def archive(self, destination: Path) -> Path:
        with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(item for item in self.root.rglob("*") if item.is_file()):
                archive.write(path, f"synthetic-v1/{path.relative_to(self.root).as_posix()}")
        return destination
