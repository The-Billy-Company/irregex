"""Machine evidence and source-provenance contract for CREST mutation reports."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import stat
import subprocess
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

EVIDENCE_PREFIX = "CREST_MUTATION_TEST_V1\t"
ASSERTION_EXIT = 101
PANIC_EXIT = 102
_IGNORED = {
    ".git",
    ".local",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    ".venv",
    ".zig-cache",
    "__pycache__",
    "node_modules",
    "target",
    "zig-out",
}
EvidenceStatus = Literal["passed", "assertion_failed", "panicked", "invalid"]


@dataclass(frozen=True)
class Mutation:
    name: str
    path: str
    needle: str
    replacement: str
    test_filter: str
    test_path: str
    expected_sites: int = 1
    replace_all: bool = False


MUTATIONS = (
    Mutation(
        "columnar-threshold-direction",
        "src/corpus/index/crest/columnar.zig",
        "if (failures[offset] & failed == 0 and slot < requirement[logical])",
        "if (failures[offset] & failed == 0 and slot > requirement[logical])",
        "columnar retain equals allocation-free document pruning",
        "src/corpus/index/crest/sidecar_test.zig",
    ),
    Mutation(
        "nullable-certificate",
        "src/kernel/regex/analysis/swell.zig",
        "        var out = epsilon();\n"
        "        out.only_c_cert = p.only_c_cert;\n"
        "        return out;",
        "        return p;",
        "optional profiles preserve only-class certificates without joining separators",
        "src/kernel/regex/analysis/swell_test.zig",
    ),
    Mutation(
        "rank-order",
        "src/kernel/math/crest.zig",
        "        if (candidate > out[i]) {",
        "        if (candidate < out[i]) {",
        "rank-four spectrum keeps the longest disjoint maximal runs",
        "src/kernel/math/crest_test.zig",
    ),
    Mutation(
        "ranked-exact-threshold",
        "src/kernel/math/crest.zig",
        "                    clears = clears and doc[i] >= requirement[i];",
        "                    clears = clears and doc[i] > requirement[i];",
        "bounded Pareto compiler preserves disjoint alternatives",
        "src/kernel/regex/analysis/swell_test.zig",
    ),
    Mutation(
        "reversed-subset",
        "src/kernel/regex/analysis/swell.zig",
        "                shared &= crest.membership[b];",
        "                shared |= crest.membership[b];",
        "forced-crest: class repetition is the whole point",
        "src/kernel/regex/analysis/swell_test.zig",
    ),
    Mutation(
        "saturating-document-join",
        "src/kernel/math/crest.zig",
        "            .best = @max(@max(a.best, b.best), a.trail +| b.lead),",
        "            .best = @max(@max(a.best, b.best), a.trail + b.lead),",
        "cutting the document into pieces rejoins to the same answer",
        "src/kernel/math/crest_test.zig",
    ),
    Mutation(
        "saturating-query-add",
        "src/kernel/regex/analysis/swell.zig",
        "fn satAdd(a: u16, b: u16) u16 {\n"
        "    return @intCast(@min(@as(u32, a) + @as(u32, b), std.math.maxInt(u16)));\n"
        "}",
        "fn satAdd(a: u16, b: u16) u16 {\n    return a + b;\n}",
        "sieve decision + saturation monotonicity",
        "src/kernel/regex/analysis/swell_test.zig",
    ),
    Mutation(
        "schema-saturation-binding",
        "src/kernel/math/crest.zig",
        '        "saturation-cap/u16le\\x00" ++ le16(saturation_cap) ++\n',
        "",
        "semantic hash binds cap, interpretation, and full membership table",
        "src/kernel/math/crest_test.zig",
    ),
    Mutation(
        "sidecar-binding-check",
        "src/corpus/index/crest/sidecar.zig",
        "    if (!std.mem.eql(u8, bytes[Offset.semantic_hash..Offset.dictionary_hash], &expected.binding.semantic_hash) or\n"
        "        !std.mem.eql(u8, bytes[Offset.dictionary_hash..Offset.build_id], &expected.binding.dictionary_hash) or\n"
        "        !std.mem.eql(u8, bytes[Offset.build_id..Offset.padding], &expected.binding.build_id)) return null;\n",
        "",
        "decode refuses foreign identity shape and damage",
        "src/corpus/index/crest/sidecar_test.zig",
    ),
    Mutation(
        "sidecar-overflow-lookup",
        "src/corpus/index/crest/sidecar.zig",
        "        if (compact < base_saturation) return compact;",
        "        if (compact <= base_saturation) return compact;",
        "sparse overflow preserves saturated and long runs",
        "src/corpus/index/crest/sidecar_test.zig",
    ),
    Mutation(
        "utf8-continuation-hold",
        "src/kernel/math/crest.zig",
        "        const hold = isContinuation(@intCast(b));",
        "        const hold = isContinuation(@intCast(b)) and false;",
        "the scan is the byte-at-a-time definition, exactly",
        "src/kernel/math/crest_test.zig",
    ),
)


class ReportDrift(ValueError):
    """A report no longer describes the checkout or mutation catalog."""


class SnapshotChanged(RuntimeError):
    """The live checkout changed while its isolated snapshot was being copied."""


@dataclass(frozen=True)
class ToolchainIdentity:
    zig_version: str
    target: str
    executable_sha256: str

    def as_json(self) -> dict[str, str]:
        return {
            "executable_sha256": self.executable_sha256,
            "target": self.target,
            "zig_version": self.zig_version,
        }


@dataclass(frozen=True)
class SourceIdentity:
    commit: str
    git_tree: str
    working_tree: Literal["clean", "dirty"]
    dirty_tree_sha256: str | None
    source_snapshot_sha256: str
    mutation_catalog_sha256: str
    toolchain: ToolchainIdentity

    def as_json(self) -> dict[str, object]:
        return {
            "commit": self.commit,
            "dirty_tree_sha256": self.dirty_tree_sha256,
            "git_tree": self.git_tree,
            "mutation_catalog_sha256": self.mutation_catalog_sha256,
            "source_snapshot_sha256": self.source_snapshot_sha256,
            "toolchain": self.toolchain.as_json(),
            "working_tree": self.working_tree,
        }


@dataclass(frozen=True)
class TestEvidence:
    status: EvidenceStatus
    reason: str


@dataclass(frozen=True)
class _GitState:
    commit: str
    tree: str
    status: bytes


def expected_test_name(test_path: str, test_name: str) -> str:
    module = test_path.removesuffix(".zig").replace("/", ".")
    return f"{module}.test.{test_name}"


def machine_evidence(stderr: str) -> tuple[str, ...]:
    return tuple(line for line in stderr.splitlines() if line.startswith(EVIDENCE_PREFIX))


def test_evidence(
    test_path: str,
    test_name: str,
    returncode: int,
    stderr: str,
) -> TestEvidence:
    """Validate the dedicated runner's exact-test terminal record."""
    expected = expected_test_name(test_path, test_name)
    records = [line.removeprefix(EVIDENCE_PREFIX).split("\t") for line in machine_evidence(stderr)]
    if len(records) != 2 or records[0] != ["selected", expected]:
        return TestEvidence("invalid", "test_evidence")
    terminal = records[1]
    if terminal == ["passed", expected] and returncode == 0:
        return TestEvidence("passed", "test_passed")
    if (
        len(terminal) == 3
        and terminal[:2] == ["failed", expected]
        and terminal[2].startswith("Test")
        and returncode == ASSERTION_EXIT
    ):
        return TestEvidence("assertion_failed", "named_test_assertion_failed")
    if terminal == ["panicked", expected] and returncode == PANIC_EXIT:
        return TestEvidence("panicked", "named_test_panicked")
    return TestEvidence("invalid", "runner_failure")


def catalog_digest(records: Iterable[Mapping[str, object]]) -> str:
    encoded = json.dumps(
        list(records),
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode()
    return hashlib.sha256(encoded).hexdigest()


def _hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1 << 20):
            digest.update(chunk)
    return digest.hexdigest()


def _run(argv: Sequence[str], cwd: Path | None = None) -> bytes:
    result = subprocess.run(argv, cwd=cwd, capture_output=True, check=False)
    if result.returncode != 0:
        detail = result.stderr.decode(errors="replace").strip()
        raise RuntimeError(f"{' '.join(argv)} failed: {detail}")
    return result.stdout


def _git_state(repo: Path) -> _GitState:
    return _GitState(
        _run(("git", "rev-parse", "HEAD"), repo).decode().strip(),
        _run(("git", "rev-parse", "HEAD^{tree}"), repo).decode().strip(),
        _run(
            ("git", "status", "--porcelain=v1", "-z", "--untracked-files=all"),
            repo,
        ),
    )


def _git_paths(repo: Path) -> tuple[str, ...] | None:
    result = subprocess.run(
        ("git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"),
        cwd=repo,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    return tuple(sorted(os.fsdecode(path) for path in result.stdout.split(b"\0") if path))


def _fallback_paths(source: Path) -> tuple[str, ...]:
    paths: list[str] = []
    for path in source.rglob("*"):
        relative = path.relative_to(source)
        if any(part in _IGNORED or part.endswith(".pyc") for part in relative.parts):
            continue
        if path.is_file() or path.is_symlink():
            paths.append(relative.as_posix())
    return tuple(sorted(paths))


def source_paths(source: Path) -> tuple[str, ...]:
    return _git_paths(source) or _fallback_paths(source)


def snapshot_digest(root: Path, paths: Sequence[str]) -> str:
    """Hash path, kind, mode, and bytes for the complete source snapshot."""
    digest = hashlib.sha256(b"irregex-source-snapshot-v1\0")
    for relative in paths:
        encoded = os.fsencode(relative)
        digest.update(len(encoded).to_bytes(8, "big"))
        digest.update(encoded)
        path = root / relative
        try:
            metadata = path.lstat()
        except FileNotFoundError:
            digest.update(b"missing\0")
            continue
        digest.update(stat.S_IMODE(metadata.st_mode).to_bytes(4, "big"))
        if stat.S_ISLNK(metadata.st_mode):
            target = os.fsencode(os.readlink(path))
            digest.update(b"symlink\0")
            digest.update(len(target).to_bytes(8, "big"))
            digest.update(target)
        elif stat.S_ISREG(metadata.st_mode):
            digest.update(b"file\0")
            digest.update(metadata.st_size.to_bytes(8, "big"))
            with path.open("rb") as source:
                while chunk := source.read(1 << 20):
                    digest.update(chunk)
        else:
            raise RuntimeError(f"unsupported source entry: {relative}")
    return digest.hexdigest()


def copy_repo(
    source: Path,
    destination: Path,
    paths: Sequence[str] | None = None,
) -> None:
    source = source.resolve()
    destination = destination.resolve()
    if destination == source or source in destination.parents:
        raise RuntimeError("mutation workspace must be outside the source checkout")
    destination.mkdir(parents=True)
    for relative in paths or source_paths(source):
        origin = source / relative
        target = destination / relative
        if not origin.exists() and not origin.is_symlink():
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        if origin.is_symlink():
            target.symlink_to(os.readlink(origin))
        else:
            shutil.copy2(origin, target)


def toolchain_identity(executable: str) -> ToolchainIdentity:
    path = Path(executable).resolve()
    return ToolchainIdentity(
        zig_version=_run((executable, "version")).decode().strip(),
        target=_run((executable, "cc", "-dumpmachine")).decode().strip(),
        executable_sha256=_hash_file(path),
    )


def capture_source(
    source: Path,
    destination: Path,
    executable: str,
    mutation_catalog_sha256: str,
) -> SourceIdentity:
    """Copy one stable clean-or-dirty checkout and bind its exact bytes."""
    before_state = _git_state(source)
    before_paths = source_paths(source)
    before_digest = snapshot_digest(source, before_paths)
    copy_repo(source, destination, before_paths)
    after_paths = source_paths(source)
    after_digest = snapshot_digest(source, after_paths)
    after_state = _git_state(source)
    copied_digest = snapshot_digest(destination, before_paths)
    if (
        before_state != after_state
        or before_paths != after_paths
        or before_digest != after_digest
        or copied_digest != before_digest
    ):
        raise SnapshotChanged("source changed while mutation snapshot was copied")

    dirty = bool(before_state.status)
    dirty_digest = None
    if dirty:
        digest = hashlib.sha256(b"irregex-dirty-tree-v1\0")
        digest.update(before_state.commit.encode())
        digest.update(b"\0")
        digest.update(before_state.tree.encode())
        digest.update(b"\0")
        digest.update(before_state.status)
        digest.update(b"\0")
        digest.update(bytes.fromhex(copied_digest))
        dirty_digest = digest.hexdigest()
    return SourceIdentity(
        commit=before_state.commit,
        git_tree=before_state.tree,
        working_tree="dirty" if dirty else "clean",
        dirty_tree_sha256=dirty_digest,
        source_snapshot_sha256=copied_digest,
        mutation_catalog_sha256=mutation_catalog_sha256,
        toolchain=toolchain_identity(executable),
    )


def verify_provenance(
    report: Mapping[str, object],
    expected: SourceIdentity,
) -> None:
    actual = report.get("provenance")
    if actual != expected.as_json():
        raise ReportDrift("report provenance does not match the current source snapshot")
