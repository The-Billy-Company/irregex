#!/usr/bin/env python3
"""Adversarial verification tests for CREST release evidence."""

from __future__ import annotations

import hashlib
import io
import json
from collections.abc import Callable
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

import monograph
import verify


HERE = Path(__file__).resolve().parent
CONTRACT = HERE.parents[2] / "contract/crest_evidence.toml"


def _write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _source_bytes(path: str) -> bytes:
    return f"# Pinned source: {path}\n".encode()


def _write_archive(path: Path, repo: Path, commit: str, source_paths: list[str]) -> None:
    subprocess.run(
        [
            "git",
            "-C",
            str(repo),
            "archive",
            "--format=tar",
            "--prefix=crest-source/",
            f"--output={path}",
            commit,
            "--",
            *source_paths,
        ],
        check=True,
    )


def _rewrite_archive(
    path: Path,
    mutate: Callable[
        [tarfile.TarInfo, bytes | None],
        tuple[tarfile.TarInfo, bytes | None],
    ],
    *,
    commit: str | None = None,
) -> None:
    with tarfile.open(path, "r:") as source:
        headers = dict(source.pax_headers)
        entries = [
            (member, source.extractfile(member).read() if member.isfile() else None)
            for member in source.getmembers()
        ]
    if commit is not None:
        headers["comment"] = commit
    with tempfile.NamedTemporaryFile(suffix=".tar", delete=False) as target:
        replacement = Path(target.name)
    try:
        with tarfile.open(
            replacement,
            "w",
            format=tarfile.PAX_FORMAT,
            pax_headers=headers,
        ) as archive:
            for member, payload in entries:
                member, payload = mutate(member, payload)
                archive.addfile(member, io.BytesIO(payload) if payload is not None else None)
        replacement.replace(path)
    finally:
        replacement.unlink(missing_ok=True)


def _init_repo(path: Path, source_paths: list[str]) -> str:
    subprocess.run(["git", "init", "-q", str(path)], check=True)
    for source_path in source_paths:
        destination = path / source_path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(_source_bytes(source_path))
    payload = path / "payload.bin"
    payload.write_bytes(b"trusted payload\n")
    payload.chmod(0o755)
    subprocess.run(["git", "-C", str(path), "add", "."], check=True)
    subprocess.run(
        [
            "git",
            "-C",
            str(path),
            "-c",
            "user.name=CREST Test",
            "-c",
            "user.email=crest@example.invalid",
            "commit",
            "-q",
            "-m",
            "fixture",
        ],
        check=True,
    )
    return subprocess.check_output(
        ["git", "-C", str(path), "rev-parse", "HEAD"], text=True
    ).strip()


def _write_monograph(
    package: Path,
    manifest: dict[str, object],
    source_paths: list[str],
    run: dict,
) -> None:
    zero = "0" * 64
    template = f"""# CREST release monograph

## Revision and artifact identity
- Source commit: `{manifest["source_commit"]}`
- Source archive SHA-256: `{manifest["source_archive_sha256"]}`
- Benchmark artifact SHA-256: `{manifest["benchmark_artifact_sha256"]}`
- Test artifact SHA-256: `{manifest["test_artifact_sha256"]}`
- Monograph SHA-256 (canonical content): `{zero}`

## Hash contract
Canonical bytes normalize this field; the full-file hash is detached.

{monograph.measured_table(run)}
"""
    for source_path in source_paths:
        text = _source_bytes(source_path).decode().rstrip()
        template += (
            f"\n<!-- begin git show {manifest['source_commit']}:{source_path} -->\n"
            f"{text}\n"
            f"<!-- end git show {manifest['source_commit']}:{source_path} -->\n"
        )
    canonical = _sha(template.encode())
    path = package / monograph.MONOGRAPH
    path.write_text(template.replace(zero, canonical, 1))
    (package / monograph.DETACHED).write_text(
        f"{verify.sha256_file(path)}  {monograph.MONOGRAPH}\n"
    )


def _seal(package: Path, contract: dict, manifest: dict[str, object]) -> None:
    manifest["files"] = {
        name: verify.sha256_file(package / name)
        for name in contract["artifacts"]["payload_required"]
    }
    _write_json(package / verify.MANIFEST, manifest)
    (package / verify.DETACHED).write_text(
        f"{verify.sha256_file(package / verify.MANIFEST)}  {verify.MANIFEST}\n"
    )


def _write_csv(path: Path, run: dict) -> None:
    lines = [
        "# corpus_files\tcorpus_mib",
        "# 1\t0.0",
        "query\tpattern\tcaseless\tunicode\tfiles\trun_survivors\tcnt_survivors\trun_prune_pct\tcnt_prune_pct\thits\tfull_ms\tsieve_ms\tspeedup",
    ]
    for query in run["queries"]:
        diff = query["differential"]
        lines.append(
            "\t".join(
                (
                    query["label"],
                    query["pattern"],
                    str(query["caseless"]).lower(),
                    str(query["unicode"]).lower(),
                    str(query["files"]),
                    str(query["run_survivors"]),
                    str(query["cnt_survivors"]),
                    f"{(1 - diff['survivors'] / query['files']) * 100:.2f}",
                    f"{(1 - query['cnt_survivors'] / query['files']) * 100:.2f}",
                    str(query["hits"]),
                    f"{query['full_ns'] / 1_000_000:.3f}",
                    f"{query['sieve_ns'] / 1_000_000:.3f}",
                    f"{query['full_ns'] / query['sieve_ns']:.3f}",
                )
            )
        )
    path.write_text("\n".join(lines) + "\n")


def _fixture(package: Path, repo: Path, commit: str) -> tuple[dict, dict[str, object]]:
    contract = verify.load_contract(CONTRACT)
    bench = contract["benchmark"]
    corpus = b"path\tsize_bytes\tsha256\nfixture.txt\t1\t" + _sha(b"x").encode() + b"\n"
    (package / "corpus-manifest.tsv").write_bytes(corpus)

    fixed = []
    for case in contract["fixed_regression"]:
        fixed.append(
            {
                "pattern": case["pattern"],
                "document": case["document"],
                "expected_match": case["matched"],
                "matched": case["matched"],
                "expected_pruned": case["pruned"],
                "pruned": case["pruned"],
                "expected_digit_threshold": case["digit_threshold"],
                "digit_threshold": case["digit_threshold"],
                "passed": True,
            }
        )
    queries = []
    for expected in bench["query"]:
        queries.append(
            {
                "label": expected["label"],
                "pattern": expected["pattern"],
                "caseless": expected["caseless"],
                "unicode": expected["unicode"],
                "ghat": [0] * 8,
                "files": 1,
                "run_survivors": 1,
                "cnt_survivors": 1,
                "hits": 0,
                "full_ns": 1,
                "sieve_ns": 1,
                "differential": {
                    "matched": 0,
                    "sieve_hits": 0,
                    "survivors": 1,
                    "pruned_files": 0,
                    "matched_and_pruned": 0,
                },
                "full_samples_ns": [1] * bench["runs"],
                "sieve_samples_ns": [1] * bench["runs"],
            }
        )
    checks = bench["random_patterns_per_mode"] * bench["random_files_per_pattern"]
    mask = bench["caseless_seed_mask"]
    random = {
        mode: {
            "unicode": unicode,
            "caseless": caseless,
            "seed": seed,
            "patterns": bench["random_patterns_per_mode"],
            "checks": checks,
            "matches": 0,
            "pruned": 0,
            "violations": 0,
        }
        for mode, unicode, caseless, seed in (
            ("ascii", False, False, bench["ascii_seed"]),
            ("unicode", True, False, bench["unicode_seed"]),
            ("caseless_ascii", False, True, bench["ascii_seed"] ^ mask),
            ("caseless_unicode", True, True, bench["unicode_seed"] ^ mask),
        )
    }
    run = {
        "schema_version": contract["meta"]["schema_version"],
        "artifact_kind": contract["meta"]["artifact_kind"],
        "config": {
            "runs": bench["runs"],
            "warmup": bench["warmup"],
            "timing_clock": bench["timing_clock"],
            "aggregation": bench["aggregation"],
        },
        "engine": {"abi_version": 2, "architecture": "test", "zig_version": "test"},
        "corpus": {
            "roots": ["."],
            "file_count": 1,
            "total_bytes": 1,
            "manifest_file": "corpus-manifest.tsv",
            "manifest_sha256": _sha(corpus),
        },
        "seeds": {
            "ascii": bench["ascii_seed"],
            "unicode": bench["unicode_seed"],
            "caseless_mask": mask,
        },
        "fixed_regression": fixed,
        "queries": queries,
        "randomized_soundness": random,
        "violations": 0,
        "passed": True,
    }
    _write_json(package / "crest-run.json", run)
    _write_csv(package / "crest.csv", run)
    (package / "benchmark-transcript.txt").write_text("benchmark passed\n")
    (package / "test-transcript.txt").write_text("tests passed\n")
    _write_archive(
        package / "source.tar",
        repo,
        commit,
        contract["paths"]["source_archive_paths"],
    )
    (package / "source-commit.txt").write_text(f"{commit}\n")
    test_artifact = {
        "schema_version": contract["meta"]["schema_version"],
        "source_commit": commit,
        "label": "test",
        "argv": contract["commands"]["test"],
        "cwd": contract["commands"]["cwd"],
        "exit_code": 0,
        "transcript": "test-transcript.txt",
        "transcript_sha256": verify.sha256_file(package / "test-transcript.txt"),
    }
    _write_json(package / "test-artifact.json", test_artifact)
    machine = {key: "test" for key in contract["machine"]["required_keys"]}
    machine.update(
        {
            "logical_cpu_count": 1,
            "memory_bytes": None,
            "memory_bytes_note": "fixture has no host memory",
            "power": None,
            "power_note": "fixture has no power source",
            "storage": {"total_bytes": 1},
            "cache_condition": {"warmup_runs": bench["warmup"]},
        }
    )
    _write_json(package / "machine.json", machine)
    _write_json(
        package / "command-log.json",
        {
            "schema_version": contract["meta"]["schema_version"],
            "source_commit": commit,
            "commands": [
                {
                    "label": "benchmark",
                    "argv": [
                        part.format(runs=bench["runs"], warmup=bench["warmup"])
                        for part in contract["commands"]["benchmark"]
                    ],
                    "cwd": contract["commands"]["cwd"],
                    "exit_code": 0,
                    "transcript": "benchmark-transcript.txt",
                    "transcript_sha256": verify.sha256_file(package / "benchmark-transcript.txt"),
                },
                {
                    "label": "test",
                    "argv": contract["commands"]["test"],
                    "cwd": contract["commands"]["cwd"],
                    "exit_code": 0,
                    "transcript": "test-transcript.txt",
                    "transcript_sha256": verify.sha256_file(package / "test-transcript.txt"),
                },
                {
                    "label": "source_archive",
                    "argv": [
                        "git",
                        "archive",
                        "--format=tar",
                        "--prefix=crest-source/",
                        "--output=source.tar",
                        commit,
                        "--",
                        *contract["paths"]["source_archive_paths"],
                    ],
                    "exit_code": 0,
                },
            ],
        },
    )
    manifest: dict[str, object] = {
        "schema_version": contract["meta"]["schema_version"],
        "artifact_kind": contract["meta"]["artifact_kind"],
        "source_commit": commit,
        "source_archive_sha256": verify.sha256_file(package / "source.tar"),
        "benchmark_artifact_sha256": verify.sha256_file(package / "crest-run.json"),
        "test_artifact_sha256": verify.sha256_file(package / "test-artifact.json"),
        "corpus_manifest_sha256": verify.sha256_file(package / "corpus-manifest.tsv"),
        "matcher_results": {
            "fixed_regression": fixed,
            "randomized_soundness": random,
            "violations": 0,
            "passed": True,
        },
    }
    _write_monograph(package, manifest, contract["paths"]["monograph_sources"], run)
    _seal(package, contract, manifest)
    return contract, manifest


def _reseal_archive_forgery(
    package: Path,
    contract: dict,
    manifest: dict[str, object],
) -> None:
    manifest["source_archive_sha256"] = verify.sha256_file(package / "source.tar")
    run = json.loads((package / "crest-run.json").read_text())
    _write_monograph(package, manifest, contract["paths"]["monograph_sources"], run)
    _seal(package, contract, manifest)


class EvidenceVerificationTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.package = root / "package"
        self.package.mkdir()
        self.repo = root / "repo"
        contract = verify.load_contract(CONTRACT)
        self.commit = _init_repo(self.repo, contract["paths"]["monograph_sources"])
        self.contract, self.manifest = _fixture(
            self.package,
            self.repo,
            self.commit,
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def problems(self) -> list[str]:
        return verify.verify_package(self.package, CONTRACT, self.repo)

    def test_valid_package_passes(self) -> None:
        self.assertEqual(self.problems(), [])

    def test_tampered_payload_hash_fails(self) -> None:
        (self.package / "crest.csv").write_text("tampered\n")
        self.assertTrue(any("payload SHA-256 mismatch" in problem for problem in self.problems()))

    def test_resealed_revision_tamper_still_fails_archive_binding(self) -> None:
        changed = "b" * 40
        self.manifest["source_commit"] = changed
        (self.package / "source-commit.txt").write_text(f"{changed}\n")
        test = json.loads((self.package / "test-artifact.json").read_text())
        test["source_commit"] = changed
        _write_json(self.package / "test-artifact.json", test)
        self.manifest["test_artifact_sha256"] = verify.sha256_file(
            self.package / "test-artifact.json"
        )
        _seal(self.package, self.contract, self.manifest)
        self.assertTrue(any("archive revision" in problem for problem in self.problems()))

    def test_resealed_source_byte_substitution_fails_git_object_binding(self) -> None:
        def forge(member: tarfile.TarInfo, payload: bytes | None):
            if member.name == "crest-source/payload.bin":
                payload = b"forged payload\n"
                member.size = len(payload)
            return member, payload

        _rewrite_archive(self.package / "source.tar", forge)
        _reseal_archive_forgery(self.package, self.contract, self.manifest)
        self.assertTrue(any("claimed Git object" in problem for problem in self.problems()))

    def test_resealed_source_mode_substitution_fails_git_object_binding(self) -> None:
        def forge(member: tarfile.TarInfo, payload: bytes | None):
            if member.name == "crest-source/payload.bin":
                member.mode = 0o644
            return member, payload

        _rewrite_archive(self.package / "source.tar", forge)
        _reseal_archive_forgery(self.package, self.contract, self.manifest)
        self.assertTrue(any("claimed Git object" in problem for problem in self.problems()))

    def test_resealed_source_path_substitution_fails_git_object_binding(self) -> None:
        def forge(member: tarfile.TarInfo, payload: bytes | None):
            if member.name == "crest-source/payload.bin":
                member.name = "crest-source/payload-renamed.bin"
            return member, payload

        _rewrite_archive(self.package / "source.tar", forge)
        _reseal_archive_forgery(self.package, self.contract, self.manifest)
        self.assertTrue(any("claimed Git object" in problem for problem in self.problems()))

    def test_resealed_commit_substitution_fails_git_object_binding(self) -> None:
        (self.repo / "payload.bin").write_bytes(b"second revision\n")
        subprocess.run(["git", "-C", str(self.repo), "add", "payload.bin"], check=True)
        subprocess.run(
            [
                "git",
                "-C",
                str(self.repo),
                "-c",
                "user.name=CREST Test",
                "-c",
                "user.email=crest@example.invalid",
                "commit",
                "-q",
                "-m",
                "second fixture",
            ],
            check=True,
        )
        changed = subprocess.check_output(
            ["git", "-C", str(self.repo), "rev-parse", "HEAD"], text=True
        ).strip()
        _rewrite_archive(
            self.package / "source.tar",
            lambda member, payload: (member, payload),
            commit=changed,
        )
        self.manifest["source_commit"] = changed
        (self.package / "source-commit.txt").write_text(f"{changed}\n")
        test = json.loads((self.package / "test-artifact.json").read_text())
        test["source_commit"] = changed
        _write_json(self.package / "test-artifact.json", test)
        self.manifest["test_artifact_sha256"] = verify.sha256_file(
            self.package / "test-artifact.json"
        )
        log = json.loads((self.package / "command-log.json").read_text())
        log["source_commit"] = changed
        archive = next(item for item in log["commands"] if item["label"] == "source_archive")
        archive["argv"][archive["argv"].index(self.commit)] = changed
        _write_json(self.package / "command-log.json", log)
        _reseal_archive_forgery(self.package, self.contract, self.manifest)
        self.assertTrue(any("claimed Git object" in problem for problem in self.problems()))

    def test_missing_required_file_fails_closed(self) -> None:
        (self.package / "machine.json").unlink()
        self.assertTrue(any("missing required files" in problem for problem in self.problems()))

    def test_monograph_reads_pinned_revision_not_worktree(self) -> None:
        repo = self.package / "repo"
        repo.mkdir()
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        (repo / "source.md").write_text("# Pinned claim\n")
        subprocess.run(["git", "-C", str(repo), "add", "source.md"], check=True)
        subprocess.run(
            [
                "git",
                "-C",
                str(repo),
                "-c",
                "user.name=CREST Test",
                "-c",
                "user.email=crest@example.invalid",
                "commit",
                "-q",
                "-m",
                "fixture",
            ],
            check=True,
        )
        commit = subprocess.check_output(
            ["git", "-C", str(repo), "rev-parse", "HEAD"], text=True
        ).strip()
        (repo / "source.md").write_text("# Working-tree forgery\n")
        run = json.loads((self.package / "crest-run.json").read_text())
        text, _ = monograph.render(
            repo=repo,
            commit=commit,
            archive_sha256="1" * 64,
            benchmark_sha256="2" * 64,
            test_sha256="3" * 64,
            run=run,
            source_paths=["source.md"],
        )
        self.assertIn("# Pinned claim", text)
        self.assertNotIn("Working-tree forgery", text)


if __name__ == "__main__":
    unittest.main()
