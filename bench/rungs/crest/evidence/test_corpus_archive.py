"""Corpus-independent tests for the ZIP benchmark adapter."""

from __future__ import annotations

import hashlib
import json
import os
import stat
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

import corpus_archive


class CorpusArchiveTest(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def archive(self, name: str = "corpus.zip") -> Path:
        path = self.root / name
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("dataset/a.txt", "alpha\n")
            archive.writestr("dataset/nested/b.txt", "beta\n")
        return path

    def test_inspection_is_deterministic_and_non_promotable(self) -> None:
        archive = self.archive()
        first = corpus_archive.inspect_archive(archive)
        second = corpus_archive.inspect_archive(archive)
        self.assertEqual(first, second)
        self.assertEqual(first["file_count"], 2)
        self.assertEqual(first["total_bytes"], 11)
        self.assertFalse(first["benchmark_policy"]["promotion_eligible"])
        self.assertTrue(first["benchmark_policy"]["q4_promotion_blocked"])
        self.assertEqual(first["benchmark_policy"]["capable_profiles"], ["q1-b8", "q4-b8"])

    def test_staging_preserves_bytes_and_is_temporary(self) -> None:
        archive = self.archive()
        with corpus_archive.staged_archive(archive) as (root, receipt):
            staged = root / "dataset/nested/b.txt"
            self.assertEqual(staged.read_bytes(), b"beta\n")
            self.assertEqual(staged.stat().st_mode & 0o222, 0)
            path = root
            self.assertEqual(receipt["file_count"], 2)
        self.assertFalse(path.exists())

    def test_traversal_and_case_collision_are_rejected(self) -> None:
        for name, members in (
            ("traversal.zip", {"../escape": b"x", "safe": b"y"}),
            ("collision.zip", {"Data/value": b"x", "data/value": b"y"}),
        ):
            path = self.root / name
            with zipfile.ZipFile(path, "w") as archive:
                for member, payload in members.items():
                    archive.writestr(member, payload)
            with (
                self.subTest(name=name),
                self.assertRaises(corpus_archive.CorpusArchiveError),
            ):
                corpus_archive.inspect_archive(path)

    def test_symlink_member_is_rejected(self) -> None:
        path = self.root / "symlink.zip"
        link = zipfile.ZipInfo("link")
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr(link, "target")
        with self.assertRaises(corpus_archive.CorpusArchiveError):
            corpus_archive.inspect_archive(path)

    def test_symlink_archive_path_is_rejected(self) -> None:
        archive = self.archive()
        link = self.root / "corpus-link.zip"
        link.symlink_to(archive)
        with self.assertRaisesRegex(corpus_archive.CorpusArchiveError, "no-follow"):
            corpus_archive.inspect_archive(link)

    def test_same_name_and_size_swap_cannot_change_staged_archive(self) -> None:
        archive = self.root / "corpus.zip"
        replacement = self.root / "replacement.zip"
        for path, payload in ((archive, b"good"), (replacement, b"evil")):
            with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as bundle:
                bundle.writestr("dataset/value.txt", payload)
        self.assertEqual(archive.stat().st_size, replacement.stat().st_size)
        original_sha256 = corpus_archive.sha256_file(archive)
        inspect = corpus_archive._inspect_zip

        def swap(bundle: zipfile.ZipFile, digest: str):
            receipt = inspect(bundle, digest)
            replacement.replace(archive)
            return receipt

        with (
            mock.patch.object(corpus_archive, "_inspect_zip", side_effect=swap),
            corpus_archive.staged_archive(archive) as (root, receipt),
        ):
            self.assertEqual((root / "dataset/value.txt").read_bytes(), b"good")
            self.assertEqual(receipt["archive_sha256"], original_sha256)
        with zipfile.ZipFile(archive) as bundle:
            self.assertEqual(bundle.read("dataset/value.txt"), b"evil")

    def test_directory_and_zero_byte_member_bomb_is_rejected(self) -> None:
        archive = self.root / "entry-bomb.zip"
        with zipfile.ZipFile(archive, "w") as bundle:
            bundle.writestr("directory/", b"")
            bundle.writestr("empty-a", b"")
            bundle.writestr("empty-b", b"")
        with (
            mock.patch.object(corpus_archive, "MAX_ARCHIVE_MEMBERS", 2),
            mock.patch.object(corpus_archive.zipfile, "ZipFile") as zip_constructor,
            mock.patch.object(
                corpus_archive,
                "_safe_path",
                side_effect=AssertionError("member state was materialized"),
            ),
            self.assertRaisesRegex(
                corpus_archive.CorpusArchiveError,
                "member-count",
            ),
        ):
            corpus_archive.inspect_archive(archive)
        zip_constructor.assert_not_called()

    def test_zip64_entry_count_is_rejected_before_zipfile(self) -> None:
        archive = self.archive("zip64-sentinel.zip")
        payload = bytearray(archive.read_bytes())
        eocd = payload.rfind(b"PK\x05\x06")
        self.assertGreaterEqual(eocd, 0)
        payload[eocd + 8 : eocd + 12] = b"\xff\xff\xff\xff"
        archive.write_bytes(payload)
        with (
            mock.patch.object(corpus_archive.zipfile, "ZipFile") as constructor,
            self.assertRaisesRegex(corpus_archive.CorpusArchiveError, "ZIP64"),
        ):
            corpus_archive.inspect_archive(archive)
        constructor.assert_not_called()

    @staticmethod
    def _csv(report: dict) -> str:
        config = report["config"]
        lines = [
            "# profile\trank\tbudget",
            f"# {config['profile']}\t{config['rank']}\t{config['budget']}",
            "# corpus_files\tcorpus_mib",
            "# 1\t0.0",
            "rank\tbudget\tquery\tpattern\tcaseless\tunicode\talternatives\tfiles\trun_survivors\tfold_survivors\tcnt_survivors\trun_prune_pct\tfold_prune_pct\tcnt_prune_pct\thits\tfull_ms\tsieve_ms\tspeedup",
        ]
        for query in report["queries"]:
            differential = query["differential"]
            files = max(query["files"], 1)
            lines.append(
                "\t".join(
                    (
                        str(config["rank"]),
                        str(config["budget"]),
                        query["label"],
                        query["pattern"],
                        str(query["caseless"]).lower(),
                        str(query["unicode"]).lower(),
                        str(len(query["ghat"])),
                        str(query["files"]),
                        str(query["run_survivors"]),
                        str(query["fold_survivors"]),
                        str(query["cnt_survivors"]),
                        f"{(1 - differential['survivors'] / files) * 100:.2f}",
                        f"{(1 - query['fold_survivors'] / files) * 100:.2f}",
                        f"{(1 - query['cnt_survivors'] / files) * 100:.2f}",
                        str(query["hits"]),
                        f"{query['full_ns'] / 1_000_000:.3f}",
                        f"{query['sieve_ns'] / 1_000_000:.3f}",
                        f"{query['full_ns'] / query['sieve_ns']:.3f}",
                    )
                )
            )
        return "\n".join(lines) + "\n"

    def fake_benchmark(
        self,
        *,
        matched_and_pruned: int = 0,
        mutate_report=None,
        mutate_csv=None,
        stale_artifact: str | None = None,
    ):
        calls: list[tuple[list[str], dict[str, str]]] = []

        def run(command, *, env, **_kwargs):
            rank = int(command[command.index("--rank") + 1])
            budget = int(command[command.index("--budget") + 1])
            profile = f"q{rank}-b{budget}"
            output = corpus_archive.EVIDENCE_DIR
            output.mkdir(parents=True, exist_ok=True)
            csv_name = f"crest-{profile}.csv"
            run_name = f"crest-run-{profile}.json"
            paths = (
                output / csv_name,
                output / run_name,
                output / "corpus-manifest.tsv",
            )
            if stale_artifact:
                for path in paths:
                    os.utime(path)
                if stale_artifact == "aggregate_csv":
                    (output / run_name).write_text((output / run_name).read_text() + "\n")
                elif stale_artifact == "run_json":
                    (output / csv_name).write_text(
                        (output / csv_name).read_text() + "# refreshed\n"
                    )
                calls.append((command, env))
                return subprocess.CompletedProcess(command, 0, stdout=b"benchmark passed\n")
            runs = int(command[command.index("--runs") + 1])
            warmup = int(command[command.index("--warmup") + 1])
            payload = b"alpha\n"
            manifest = (
                b"path\tsize_bytes\tsha256\n"
                b"dataset/a.txt\t6\t" + hashlib.sha256(payload).hexdigest().encode() + b"\n"
            )
            (output / "corpus-manifest.tsv").write_bytes(manifest)
            survivors = 1 - matched_and_pruned
            report = {
                "schema_version": 5,
                "artifact_kind": "crest-production-proof",
                "config": {
                    "rank": rank,
                    "budget": budget,
                    "profile": profile,
                    "runs": runs,
                    "warmup": warmup,
                    "timing_clock": "awake-monotonic-nanoseconds",
                    "aggregation": "upper-median",
                },
                "production": {
                    "sidecar_format_version": 6,
                    "builder": "gist.index.crest.buildSpectra",
                    "runtime": "gist.index.crest_runtime.apply",
                    "encoded_bytes": 256,
                    "overflow_entries": 0,
                    "sidecar_q": 4,
                    "query_rank": rank,
                    "validated": True,
                    "planner_calibration": "absent",
                    "planner_coefficients": None,
                    "uncalibrated_policy": "always-sieve",
                },
                "artifacts": {
                    "aggregate_csv": csv_name,
                    "run_json": run_name,
                    "corpus_manifest": "corpus-manifest.tsv",
                },
                "corpus": {
                    "file_count": 1,
                    "total_bytes": len(payload),
                    "manifest_sha256": hashlib.sha256(manifest).hexdigest(),
                },
                "queries": [
                    {
                        "label": "fixture",
                        "pattern": "alpha",
                        "caseless": False,
                        "unicode": False,
                        "ghat": [[0]],
                        "files": 1,
                        "run_survivors": survivors,
                        "fold_survivors": survivors,
                        "cnt_survivors": survivors,
                        "hits": 1,
                        "full_ns": 2_000_000,
                        "sieve_ns": 1_000_000,
                        "differential": {
                            "matched": 1,
                            "sieve_hits": survivors,
                            "survivors": survivors,
                            "pruned_files": matched_and_pruned,
                            "matched_and_pruned": matched_and_pruned,
                        },
                        "planner": {
                            "calibrated": False,
                            "decision_available": False,
                            "ran": True,
                            "reason": "uncalibrated-always-sieve",
                            "touched_columns": 0,
                            "candidate_docs": 0,
                            "scanned_docs": 0,
                            "expected_candidates": 0,
                            "expected_rejected": 0,
                            "direct_cost": 0,
                            "crest_cost": 0,
                            "estimated_savings": 0,
                            "required_savings": 0,
                        },
                        "full_samples_ns": [2_000_000] * runs,
                        "sieve_samples_ns": [1_000_000] * runs,
                    }
                ],
                "violations": matched_and_pruned,
                "passed": matched_and_pruned == 0,
            }
            if mutate_report:
                mutate_report(report)
            csv_text = self._csv(report)
            if mutate_csv:
                csv_text = mutate_csv(csv_text)
            (output / csv_name).write_text(csv_text)
            (output / run_name).write_text(json.dumps(report))
            calls.append((command, env))
            return subprocess.CompletedProcess(command, 0, stdout=b"benchmark passed\n")

        return calls, run

    def test_q1_and_q4_forward_profile_and_share_frozen_manifest(self) -> None:
        archive = self.archive()
        calls, benchmark = self.fake_benchmark()
        receipts = []
        evidence_dir = self.root / ".local/crest-evidence"
        with (
            mock.patch.object(corpus_archive, "REPO", self.root),
            mock.patch.object(corpus_archive, "EVIDENCE_DIR", evidence_dir),
            mock.patch.object(corpus_archive.subprocess, "run", side_effect=benchmark),
        ):
            for rank in (1, 4):
                receipt_path = self.root / f"archive-q{rank}-b8-receipt.json"
                profile = {} if rank == 1 else {"rank": rank, "budget": 8}
                receipts.append(corpus_archive.run(archive, 2, 0, receipt_path, **profile))
                self.assertEqual(json.loads(receipt_path.read_text()), receipts[-1])

        for expected_rank, run_receipt, (argv, environment) in zip(
            (1, 4),
            receipts,
            calls,
            strict=True,
        ):
            self.assertEqual(run_receipt["run"]["profile"], f"q{expected_rank}-b8")
            self.assertEqual(run_receipt["run"]["rank"], expected_rank)
            self.assertEqual(run_receipt["run"]["budget"], 8)
            self.assertIn(f"crest-run-q{expected_rank}-b8.json", json.dumps(run_receipt))
            self.assertEqual(argv[argv.index("--rank") + 1], str(expected_rank))
            self.assertEqual(argv[argv.index("--budget") + 1], "8")
            self.assertFalse(run_receipt["run"]["promotion"]["eligible"])
            self.assertEqual(run_receipt["run"]["promotion"]["q4_blocked"], expected_rank == 4)
            self.assertFalse(Path(environment["GIST_ROOTS"]).exists())
        self.assertEqual(
            receipts[0]["run"]["artifacts"]["corpus_manifest"]["sha256"],
            receipts[1]["run"]["artifacts"]["corpus_manifest"]["sha256"],
        )
        for rank in (1, 4):
            report = json.loads((evidence_dir / f"crest-run-q{rank}-b8.json").read_text())
            self.assertEqual(report["production"]["query_rank"], rank)
            self.assertEqual(report["production"]["sidecar_q"], 4)

    def test_touched_csv_and_json_are_rejected_as_stale(self) -> None:
        archive = self.archive()
        for stale in ("aggregate_csv", "run_json"):
            with self.subTest(stale=stale):
                evidence = self.root / f"evidence-{stale}"
                _, initial = self.fake_benchmark()
                with (
                    mock.patch.object(corpus_archive, "REPO", self.root),
                    mock.patch.object(corpus_archive, "EVIDENCE_DIR", evidence),
                    mock.patch.object(corpus_archive.subprocess, "run", side_effect=initial),
                ):
                    corpus_archive.run(
                        archive,
                        2,
                        0,
                        self.root / f"initial-{stale}.json",
                    )
                _, touched = self.fake_benchmark(stale_artifact=stale)
                with (
                    mock.patch.object(corpus_archive, "REPO", self.root),
                    mock.patch.object(corpus_archive, "EVIDENCE_DIR", evidence),
                    mock.patch.object(corpus_archive.subprocess, "run", side_effect=touched),
                    self.assertRaisesRegex(corpus_archive.CorpusArchiveError, f"stale {stale}"),
                ):
                    corpus_archive.run(
                        archive,
                        2,
                        0,
                        self.root / f"touched-{stale}.json",
                    )

    def test_replace_between_snapshot_hash_and_verify_is_rejected(self) -> None:
        archive = self.archive()
        evidence = self.root / "replacement-race"
        _, benchmark = self.fake_benchmark()
        original_verify = corpus_archive.verify.verify_benchmark_artifacts

        def replace_then_verify(*args, **kwargs):
            original = evidence / "crest-run-q1-b8.json"
            replacement = evidence / "same-profile-replacement.json"
            replacement.write_bytes(original.read_bytes())
            replacement.replace(original)
            return original_verify(*args, **kwargs)

        receipt = self.root / "replacement-race-receipt.json"
        with (
            mock.patch.object(corpus_archive, "REPO", self.root),
            mock.patch.object(corpus_archive, "EVIDENCE_DIR", evidence),
            mock.patch.object(corpus_archive.subprocess, "run", side_effect=benchmark),
            mock.patch.object(
                corpus_archive.verify,
                "verify_benchmark_artifacts",
                side_effect=replace_then_verify,
            ),
            self.assertRaisesRegex(
                corpus_archive.CorpusArchiveError,
                "changed run_json during verification",
            ),
        ):
            corpus_archive.run(archive, 2, 0, receipt)
        self.assertFalse(receipt.exists())

    def test_json_identity_config_names_and_samples_fail_closed(self) -> None:
        cases = (
            (
                "schema",
                lambda report: report.__setitem__("schema_version", 4),
                "schema version",
            ),
            (
                "kind",
                lambda report: report.__setitem__("artifact_kind", "forged"),
                "artifact kind",
            ),
            (
                "runs",
                lambda report: report["config"].__setitem__("runs", 3),
                "config runs",
            ),
            (
                "warmup",
                lambda report: report["config"].__setitem__("warmup", 1),
                "config warmup",
            ),
            (
                "rank",
                lambda report: report["config"].__setitem__("rank", 4),
                "config rank",
            ),
            (
                "budget",
                lambda report: report["config"].__setitem__("budget", 4),
                "config budget",
            ),
            (
                "profile",
                lambda report: report["config"].__setitem__("profile", "q4-b8"),
                "config profile",
            ),
            (
                "samples",
                lambda report: report["queries"][0]["full_samples_ns"].pop(),
                "invalid full_samples_ns",
            ),
            (
                "names",
                lambda report: report["artifacts"].__setitem__(
                    "run_json",
                    "crest-run-q4-b8.json",
                ),
                "artifact names",
            ),
            (
                "sidecar-bytes",
                lambda report: report["production"].__setitem__("encoded_bytes", 0),
                "production encoded_bytes",
            ),
            (
                "sidecar-q",
                lambda report: report["production"].__setitem__("sidecar_q", 1),
                "sidecar_q",
            ),
            (
                "query-rank",
                lambda report: report["production"].__setitem__("query_rank", 4),
                "query_rank",
            ),
            (
                "planner",
                lambda report: report["queries"][0]["planner"].__setitem__(
                    "calibrated",
                    True,
                ),
                "planner observation",
            ),
        )
        archive = self.archive()
        for label, mutate, expected in cases:
            with self.subTest(label=label):
                evidence = self.root / f"invalid-{label}"
                _, benchmark = self.fake_benchmark(mutate_report=mutate)
                with (
                    mock.patch.object(corpus_archive, "REPO", self.root),
                    mock.patch.object(corpus_archive, "EVIDENCE_DIR", evidence),
                    mock.patch.object(corpus_archive.subprocess, "run", side_effect=benchmark),
                    self.assertRaisesRegex(corpus_archive.CorpusArchiveError, expected),
                ):
                    corpus_archive.run(
                        archive,
                        2,
                        0,
                        self.root / f"invalid-{label}.json",
                    )

    def test_boolean_numeric_impostors_fail_closed(self) -> None:
        cases = (
            (
                "rank",
                lambda report: report["config"].__setitem__("rank", True),
                "config rank must be a non-Boolean integer",
            ),
            (
                "budget",
                lambda report: report["config"].__setitem__("budget", False),
                "config budget must be a non-Boolean integer",
            ),
            (
                "runs",
                lambda report: report["config"].__setitem__("runs", True),
                "config runs must be a non-Boolean integer",
            ),
            (
                "warmup",
                lambda report: report["config"].__setitem__("warmup", False),
                "config warmup must be a non-Boolean integer",
            ),
            (
                "sample",
                lambda report: report["queries"][0]["full_samples_ns"].__setitem__(
                    0,
                    True,
                ),
                "invalid full_samples_ns",
            ),
            (
                "query-count",
                lambda report: report["queries"][0].__setitem__(
                    "fold_survivors",
                    True,
                ),
                "invalid matcher differential",
            ),
            (
                "planner-scanned-docs",
                lambda report: report["queries"][0]["planner"].__setitem__(
                    "scanned_docs",
                    True,
                ),
                "planner decision state",
            ),
            (
                "corpus-count",
                lambda report: report["corpus"].__setitem__("file_count", True),
                "run corpus counts",
            ),
            (
                "violations",
                lambda report: report.__setitem__("violations", False),
                "did not pass with zero violations",
            ),
        )
        archive = self.archive()
        for label, mutate, expected in cases:
            with self.subTest(label=label):
                evidence = self.root / f"boolean-{label}"
                _, benchmark = self.fake_benchmark(mutate_report=mutate)
                with (
                    mock.patch.object(corpus_archive, "REPO", self.root),
                    mock.patch.object(corpus_archive, "EVIDENCE_DIR", evidence),
                    mock.patch.object(
                        corpus_archive.subprocess,
                        "run",
                        side_effect=benchmark,
                    ),
                    self.assertRaisesRegex(
                        corpus_archive.CorpusArchiveError,
                        expected,
                    ),
                ):
                    corpus_archive.run(
                        archive,
                        1,
                        0,
                        self.root / f"boolean-{label}.json",
                    )

    def test_csv_json_disagreement_fails_closed(self) -> None:
        archive = self.archive()
        _, benchmark = self.fake_benchmark(
            mutate_csv=lambda text: text.replace(
                "\t1\t2.000\t1.000\t2.000\n",
                "\t0\t2.000\t1.000\t2.000\n",
                1,
            )
        )
        with (
            mock.patch.object(corpus_archive, "REPO", self.root),
            mock.patch.object(
                corpus_archive,
                "EVIDENCE_DIR",
                self.root / "invalid-csv",
            ),
            mock.patch.object(corpus_archive.subprocess, "run", side_effect=benchmark),
            self.assertRaisesRegex(corpus_archive.CorpusArchiveError, "aggregate identity"),
        ):
            corpus_archive.run(
                archive,
                2,
                0,
                self.root / "invalid-csv.json",
            )

    def test_matched_and_pruned_artifact_fails_closed(self) -> None:
        archive = self.archive()
        _, benchmark = self.fake_benchmark(matched_and_pruned=1)
        receipt = self.root / "archive-q4-b8-receipt.json"
        with (
            mock.patch.object(corpus_archive, "REPO", self.root),
            mock.patch.object(
                corpus_archive,
                "EVIDENCE_DIR",
                self.root / ".local/crest-evidence",
            ),
            mock.patch.object(corpus_archive.subprocess, "run", side_effect=benchmark),
            self.assertRaisesRegex(
                corpus_archive.CorpusArchiveError,
                "pruned a matched document",
            ),
        ):
            corpus_archive.run(archive, 1, 0, receipt, rank=4, budget=8)
        self.assertFalse(receipt.exists())


if __name__ == "__main__":
    unittest.main()
