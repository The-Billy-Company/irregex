#!/usr/bin/env python3
"""Revision-bound CREST monograph rendering and verification."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import subprocess


MONOGRAPH = "CREST-MONOGRAPH.md"
DETACHED = "CREST-MONOGRAPH.sha256"
_ZERO_SHA = "0" * 64
_CANONICAL_LINE = re.compile(r"(?m)^- Monograph SHA-256 \(canonical content\): `([0-9a-f]{64})`$")

type _JsonValue = None | bool | int | float | str | list[_JsonValue] | dict[str, _JsonValue]
type _JsonObject = dict[str, _JsonValue]


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git_show(repo: Path, commit: str, path: str) -> str:
    """Read a source document only from the pinned Git object database."""
    try:
        raw = subprocess.check_output(
            ["git", "-C", str(repo), "show", f"{commit}:{path}"],
            stderr=subprocess.PIPE,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        detail = getattr(error, "stderr", b"").decode(errors="replace").strip()
        raise ValueError(f"cannot read pinned source {commit}:{path}: {detail}") from error
    return raw.decode("utf-8")


def measured_table(run: _JsonObject) -> str:
    rows = [
        "| query | pattern | mode | files pruned | hits | full median ms | sieve median ms | speedup |",
        "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    for query in run["queries"]:
        diff = query["differential"]
        full = query["full_ns"] / 1_000_000
        sieve = query["sieve_ns"] / 1_000_000
        speedup = full / sieve if sieve else 0.0
        mode = ("(?i) " if query["caseless"] else "") + (
            "Unicode" if query["unicode"] else "ASCII"
        )
        rows.append(
            f"| {query['label']} | `{query['pattern']}` | {mode} | {diff['pruned_files']} | "
            f"{diff['matched']} | {full:.3f} | {sieve:.3f} | {speedup:.3f}× |"
        )
    return "\n".join(rows)


def render(
    *,
    repo: Path,
    commit: str,
    archive_sha256: str,
    benchmark_sha256: str,
    test_sha256: str,
    run: _JsonObject,
    source_paths: list[str],
) -> tuple[str, str]:
    """Render from pinned source docs plus this package's benchmark JSON only."""
    if not re.fullmatch(r"[0-9a-f]{40,64}", commit):
        raise ValueError("source commit must be a full hexadecimal object id")
    sources = []
    for path in source_paths:
        text = git_show(repo, commit, path)
        sources.append(
            f"## Revision-bound source: `{path}`\n"
            f"<!-- begin git show {commit}:{path} -->\n"
            f"{text.rstrip()}\n"
            f"<!-- end git show {commit}:{path} -->"
        )

    random = run["randomized_soundness"]
    template = f"""# CREST release monograph

This monograph is an evidence view, not an independent source of claims.
Source-level material below is reproduced only from `git show` at the pinned
revision. Measured values are rendered only from this package's
`crest-run.json`.

## Revision and artifact identity
- Source commit: `{commit}`
- Source archive SHA-256: `{archive_sha256}`
- Benchmark artifact SHA-256: `{benchmark_sha256}`
- Test artifact SHA-256: `{test_sha256}`
- Monograph SHA-256 (canonical content): `{_ZERO_SHA}`

## Hash contract
The canonical content digest is SHA-256 over the UTF-8 document with the value
on the `Monograph SHA-256 (canonical content)` line replaced by 64 ASCII zeroes.
That normalization makes the in-document digest reproducible without claiming
an impossible final-file self-hash. `CREST-MONOGRAPH.sha256` is the detached
SHA-256 of the complete final Markdown file, including the canonical digest.

## Measured production proof
- Corpus: {run["corpus"]["file_count"]} files / {run["corpus"]["total_bytes"]} bytes.
- Timing: {run["config"]["runs"]} measured runs after {run["config"]["warmup"]} warmups; {run["config"]["aggregation"]}.
- Randomized matcher differential: {random["ascii"]["checks"]} ASCII checks at seed {random["ascii"]["seed"]}; {random["unicode"]["checks"]} Unicode checks at seed {random["unicode"]["seed"]}; {random["caseless_ascii"]["checks"]} caseless ASCII checks at seed {random["caseless_ascii"]["seed"]}; {random["caseless_unicode"]["checks"]} caseless Unicode checks at seed {random["caseless_unicode"]["seed"]}.
- Soundness result: {run["violations"]} violations; passed = `{str(run["passed"]).lower()}`.

{measured_table(run)}

{"\n\n".join(sources)}
"""
    canonical_sha = sha256_bytes(template.encode())
    final = template.replace(_ZERO_SHA, canonical_sha, 1)
    return final, canonical_sha


def write(
    package: Path,
    *,
    repo: Path,
    commit: str,
    archive_sha256: str,
    benchmark_sha256: str,
    test_sha256: str,
    run: _JsonObject,
    source_paths: list[str],
) -> dict[str, str]:
    text, canonical_sha = render(
        repo=repo,
        commit=commit,
        archive_sha256=archive_sha256,
        benchmark_sha256=benchmark_sha256,
        test_sha256=test_sha256,
        run=run,
        source_paths=source_paths,
    )
    path = package / MONOGRAPH
    path.write_text(text)
    full_sha = sha256_file(path)
    (package / DETACHED).write_text(f"{full_sha}  {MONOGRAPH}\n")
    return {"canonical_sha256": canonical_sha, "full_sha256": full_sha}


def verify(package: Path) -> list[str]:
    problems: list[str] = []
    path, detached = package / MONOGRAPH, package / DETACHED
    if not path.is_file() or not detached.is_file():
        return ["missing monograph or detached monograph hash"]
    text = path.read_text()
    matches = list(_CANONICAL_LINE.finditer(text))
    if len(matches) != 1:
        problems.append("monograph lacks one canonical SHA-256 line")
    else:
        match = matches[0]
        normalized = text[: match.start(1)] + _ZERO_SHA + text[match.end(1) :]
        actual = sha256_bytes(normalized.encode())
        if actual != match.group(1):
            problems.append("monograph canonical content SHA-256 mismatch")
    parts = detached.read_text().strip().split()
    if parts != [sha256_file(path), MONOGRAPH]:
        problems.append("detached monograph SHA-256 mismatch")
    return problems
