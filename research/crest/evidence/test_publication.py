"""Adversarial tests for immutable CREST publication evidence."""

from __future__ import annotations

import copy
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import publication


class PublicationEvidenceTest(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "training-proposal.json").write_text('{"proposal": true}\n')
        self.source_commit = "a" * 40
        self.dataset_fingerprint = "b" * 64
        self.metadata = {
            "captured_at_utc": "2026-08-12T00:00:00Z",
            "toolchain": {"python": "3.14", "git": "2.51", "zig": "0.15"},
            "platform": {
                "hostname": "fixture",
                "os": "fixture",
                "kernel": "fixture",
                "architecture": "fixture",
                "logical_cpu_count": 1,
            },
        }

    def seal(self) -> dict[str, object]:
        return publication.seal(
            self.root,
            source_commit=self.source_commit,
            dataset_fingerprint=self.dataset_fingerprint,
            metadata=copy.deepcopy(self.metadata),
        )

    def write_corpus_artifacts(self) -> dict[str, dict[str, object]]:
        corpus = (
            f"path\tsize_bytes\tsha256\nfixture.txt\t7\t{publication.sha256_bytes(b'fixture')}\n"
        ).encode()
        (self.root / "corpus-manifest.tsv").write_bytes(corpus)
        shared = {
            "schema": publication.CORPUS_SCHEMA,
            "source_commit": self.source_commit,
            "dataset_fingerprint": self.dataset_fingerprint,
            "corpus_manifest_sha256": publication.sha256_bytes(corpus),
            "corpus_file_count": 1,
            "corpus_total_bytes": 7,
            "query_workload_sha256": "c" * 64,
            "query_count": 3,
            "false_negatives": 0,
            "violations": 0,
            "passed": True,
        }
        reports: dict[str, dict[str, object]] = {}
        for name, (artifact_kind, profile) in publication.CORPUS_REPORTS.items():
            report = {
                **shared,
                "artifact_kind": artifact_kind,
                "profile": profile,
            }
            if name == "q1-report.json":
                report.update({"rank": 1, "budget": 8})
            elif name == "q4-report.json":
                report.update({"rank": 4, "budget": 8})
            elif name == "fixed-dictionary-report.json":
                report["dictionary_mode"] = "fixed"
            elif name == "adaptive-dictionary-report.json":
                report["dictionary_mode"] = "adaptive"
            else:
                contract, verifier = publication._semantics._mutation_runtime()
                identity = contract.SourceIdentity(
                    commit=self.source_commit,
                    git_tree="1" * 40,
                    working_tree="dirty",
                    dirty_tree_sha256="d" * 64,
                    source_snapshot_sha256="e" * 64,
                    mutation_catalog_sha256=contract.catalog_digest(
                        vars(mutation) for mutation in contract.MUTATIONS
                    ),
                    toolchain=contract.ToolchainIdentity(
                        zig_version="0.16.0",
                        target="fixture-target",
                        executable_sha256="f" * 64,
                    ),
                )
                outcomes = []
                for mutation in contract.MUTATIONS:
                    test_name = contract.expected_test_name(
                        mutation.test_path,
                        mutation.test_filter,
                    )
                    stderr = (
                        f"{contract.EVIDENCE_PREFIX}selected\t{test_name}\n"
                        f"{contract.EVIDENCE_PREFIX}failed\t{test_name}"
                        "\tTestUnexpectedResult\n"
                    )
                    outcomes.append(
                        verifier.classify(
                            mutation,
                            mutation.expected_sites,
                            verifier.CommandResult(0),
                            verifier.CommandResult(
                                contract.ASSERTION_EXIT,
                                stderr=stderr,
                            ),
                        )
                    )
                report = json.loads(verifier.render_report(outcomes, identity))
            reports[name] = report
            (self.root / name).write_bytes(publication.canonical_bytes(report))
        return reports

    def rewrite_manifest(self, manifest: dict[str, object]) -> None:
        path = self.root / publication.MANIFEST
        path.write_bytes(publication.canonical_bytes(manifest))
        (self.root / publication.DETACHED).write_text(
            f"{publication.sha256_bytes(path.read_bytes())}  {publication.MANIFEST}\n"
        )

    def test_pending_manifest_binds_payload_toolchain_and_platform(self) -> None:
        manifest = self.seal()
        self.assertEqual(manifest["evidence_status"], "corpus_runs_pending")
        self.assertEqual(
            manifest["environment_sha256"],
            publication.sha256_bytes(publication.canonical_bytes(self.metadata)),
        )
        self.assertFalse(manifest["promotion_authorization"]["q4"])
        self.assertFalse(
            manifest["promotion_authorization"]["adaptive_predicate_dictionary"]
        )
        self.assertEqual(publication.verify(self.root), [])

    def test_payload_tamper_fails(self) -> None:
        self.seal()
        (self.root / "training-proposal.json").write_text('{"proposal": false}\n')
        self.assertTrue(
            any(
                "payload hash mismatch" in problem
                for problem in publication.verify(self.root)
            )
        )

    def test_seal_rejects_concurrent_artifact_replacement(self) -> None:
        self.write_corpus_artifacts()
        target = self.root / "q1-report.json"
        replacement = self.root.parent / f"{self.root.name}-q1-replacement"
        replacement.write_bytes(target.read_bytes())
        real_status = publication.corpus_status
        replaced = False

        def replace_before_semantics(*args, **kwargs):
            nonlocal replaced
            if not replaced:
                replaced = True
                os.replace(replacement, target)
            return real_status(*args, **kwargs)

        with (
            mock.patch.object(
                publication,
                "corpus_status",
                side_effect=replace_before_semantics,
            ),
            self.assertRaisesRegex(publication.EvidenceError, "changed during capture"),
        ):
            self.seal()
        self.assertTrue(replaced)

    def test_verify_rejects_concurrent_artifact_replacement(self) -> None:
        self.write_corpus_artifacts()
        self.seal()
        target = self.root / "mutation-report.json"
        replacement = self.root.parent / f"{self.root.name}-mutation-replacement"
        replacement.write_bytes(target.read_bytes())
        real_status = publication.corpus_status
        replaced = False

        def replace_before_semantics(*args, **kwargs):
            nonlocal replaced
            if not replaced:
                replaced = True
                os.replace(replacement, target)
            return real_status(*args, **kwargs)

        with (
            mock.patch.object(
                publication,
                "corpus_status",
                side_effect=replace_before_semantics,
            ),
            self.assertRaisesRegex(publication.EvidenceError, "changed during capture"),
        ):
            publication.verify(self.root)
        self.assertTrue(replaced)

    def test_resealed_environment_tamper_fails_its_immutable_hash(self) -> None:
        self.seal()
        path = self.root / publication.MANIFEST
        manifest = json.loads(path.read_text())
        manifest["environment"]["toolchain"]["zig"] = "forged"
        self.rewrite_manifest(manifest)
        self.assertIn(
            "environment metadata hash mismatch", publication.verify(self.root)
        )

    def test_resealed_automatic_promotion_claim_fails(self) -> None:
        self.seal()
        path = self.root / publication.MANIFEST
        manifest = json.loads(path.read_text())
        manifest["promotion_authorization"]["q4"] = True
        self.rewrite_manifest(manifest)
        self.assertIn(
            "publication manifest contains an automatic promotion claim",
            publication.verify(self.root),
        )

    def test_corpus_completion_requires_semantically_consistent_reports(self) -> None:
        self.write_corpus_artifacts()
        manifest = self.seal()
        self.assertEqual(manifest["evidence_status"], "complete")
        self.assertEqual(manifest["corpus_runs_pending"], [])
        self.assertEqual(manifest["corpus_evidence_errors"], [])
        self.assertFalse(manifest["promotion_authorization"]["q4"])
        self.assertFalse(
            manifest["promotion_authorization"]["adaptive_predicate_dictionary"]
        )
        self.assertEqual(publication.verify(self.root), [])

    def test_arbitrary_required_filenames_remain_semantic_errors(self) -> None:
        for name in publication.CORPUS_REQUIRED:
            (self.root / name).write_bytes(b"arbitrary bytes\n")
        manifest = self.seal()
        self.assertEqual(manifest["evidence_status"], "corpus_runs_error")
        self.assertTrue(manifest["corpus_evidence_errors"])
        self.assertTrue(
            any(
                "corpus evidence invalid" in problem
                for problem in publication.verify(self.root)
            )
        )

    def test_cross_source_dataset_and_profile_reports_are_rejected(self) -> None:
        for field, value in (
            ("source_commit", "9" * 40),
            ("dataset_fingerprint", "8" * 64),
            ("profile", "q4-b8"),
        ):
            with self.subTest(field=field):
                temporary = tempfile.TemporaryDirectory()
                self.addCleanup(temporary.cleanup)
                original = self.root
                self.root = Path(temporary.name)
                (self.root / "training-proposal.json").write_text("{}\n")
                reports = self.write_corpus_artifacts()
                reports["q1-report.json"][field] = value
                (self.root / "q1-report.json").write_bytes(
                    publication.canonical_bytes(reports["q1-report.json"])
                )
                manifest = self.seal()
                self.assertEqual(manifest["evidence_status"], "corpus_runs_error")
                self.assertTrue(
                    any(
                        field in problem
                        for problem in manifest["corpus_evidence_errors"]
                    )
                )
                self.root = original

    def test_nonzero_soundness_and_dictionary_violations_are_rejected(self) -> None:
        reports = self.write_corpus_artifacts()
        reports["q4-report.json"]["false_negatives"] = 1
        reports["adaptive-dictionary-report.json"]["violations"] = 1
        for name in ("q4-report.json", "adaptive-dictionary-report.json"):
            (self.root / name).write_bytes(publication.canonical_bytes(reports[name]))
        manifest = self.seal()
        self.assertEqual(manifest["evidence_status"], "corpus_runs_error")
        self.assertTrue(
            any(
                "q4-report.json" in problem
                for problem in manifest["corpus_evidence_errors"]
            )
        )
        self.assertTrue(
            any(
                "adaptive-dictionary-report.json" in problem
                for problem in manifest["corpus_evidence_errors"]
            )
        )

    def test_surviving_mutants_and_cross_report_drift_are_rejected(self) -> None:
        reports = self.write_corpus_artifacts()
        mutation = reports["mutation-report.json"]
        mutation["mutants"][0]["classification"] = "survived"
        mutation["summary"].update({"killed": 10, "survived": 1})
        reports["fixed-dictionary-report.json"]["query_workload_sha256"] = "0" * 64
        for name in ("mutation-report.json", "fixed-dictionary-report.json"):
            (self.root / name).write_bytes(publication.canonical_bytes(reports[name]))
        manifest = self.seal()
        self.assertEqual(manifest["evidence_status"], "corpus_runs_error")
        self.assertTrue(
            any(
                "native v3 verification failed" in problem
                for problem in manifest["corpus_evidence_errors"]
            )
        )
        self.assertTrue(
            any(
                "workload differs" in problem
                for problem in manifest["corpus_evidence_errors"]
            )
        )

    def test_native_mutation_provenance_is_enforced(self) -> None:
        reports = self.write_corpus_artifacts()
        mutation = reports["mutation-report.json"]
        mutation["provenance"]["commit"] = "9" * 40
        mutation["provenance"]["mutation_catalog_sha256"] = "0" * 64
        (self.root / "mutation-report.json").write_bytes(
            publication.canonical_bytes(mutation)
        )
        manifest = self.seal()
        self.assertEqual(manifest["evidence_status"], "corpus_runs_error")
        errors = manifest["corpus_evidence_errors"]
        self.assertTrue(
            any("provenance commit mismatch" in problem for problem in errors)
        )
        self.assertTrue(any("catalog digest mismatch" in problem for problem in errors))

    def test_v2_mutation_report_is_rejected(self) -> None:
        reports = self.write_corpus_artifacts()
        report = {**reports["mutation-report.json"], "schema_version": 2}
        (self.root / "mutation-report.json").write_bytes(
            publication.canonical_bytes(report)
        )
        manifest = self.seal()
        self.assertEqual(manifest["evidence_status"], "corpus_runs_error")
        self.assertTrue(
            any(
                "unsupported mutation report schema" in problem
                for problem in manifest["corpus_evidence_errors"]
            )
        )

    def test_disconnected_mutation_summary_is_rejected(self) -> None:
        self.write_corpus_artifacts()
        report = {
            "schema": publication.CORPUS_SCHEMA,
            "artifact_kind": "mutation",
            "summary": {
                "eligible": 11,
                "invalid": 0,
                "killed": 11,
                "survived": 0,
                "total": 11,
            },
        }
        (self.root / "mutation-report.json").write_bytes(
            publication.canonical_bytes(report)
        )
        manifest = self.seal()
        self.assertEqual(manifest["evidence_status"], "corpus_runs_error")
        self.assertTrue(
            any(
                "provenance shape is invalid" in problem
                for problem in manifest["corpus_evidence_errors"]
            )
        )

    def test_forged_v3_runner_evidence_is_rejected(self) -> None:
        reports = self.write_corpus_artifacts()
        mutation = reports["mutation-report.json"]
        evidence = mutation["mutants"][0]["machine_evidence"]
        evidence[-1] = evidence[-1].replace("TestUnexpectedResult", "OutOfMemory")
        (self.root / "mutation-report.json").write_bytes(
            publication.canonical_bytes(mutation)
        )
        manifest = self.seal()
        self.assertEqual(manifest["evidence_status"], "corpus_runs_error")
        self.assertTrue(
            any(
                "outcome disagrees with machine evidence" in problem
                for problem in manifest["corpus_evidence_errors"]
            )
        )


if __name__ == "__main__":
    unittest.main()
