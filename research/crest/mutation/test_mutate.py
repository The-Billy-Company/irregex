"""Unit tests for deterministic CREST mutant generation and classification."""

from __future__ import annotations

import json
import tempfile
import unittest
from dataclasses import asdict, replace
from pathlib import Path

from mutate import (
    MUTATIONS,
    CommandResult,
    InvalidMutation,
    Mutation,
    classify,
    generate_mutant,
    render_report,
    verify_report,
)

from contract import (
    ASSERTION_EXIT,
    EVIDENCE_PREFIX,
    PANIC_EXIT,
    ReportDrift,
    SourceIdentity,
    ToolchainIdentity,
    catalog_digest,
    copy_repo,
    expected_test_name,
    snapshot_digest,
)


def fixture(**overrides: object) -> Mutation:
    values = {
        "name": "fixture",
        "path": "src/kernel/math/crest.zig",
        "needle": "old",
        "replacement": "new",
        "test_filter": "focused test",
        "test_path": "src/kernel/math/crest_test.zig",
    }
    values.update(overrides)
    return Mutation(**values)


def provenance(**overrides: object) -> SourceIdentity:
    values = {
        "commit": "a" * 40,
        "git_tree": "b" * 40,
        "working_tree": "dirty",
        "dirty_tree_sha256": "c" * 64,
        "source_snapshot_sha256": "d" * 64,
        "mutation_catalog_sha256": catalog_digest(asdict(mutation) for mutation in MUTATIONS),
        "toolchain": ToolchainIdentity("0.16.0", "test-target", "e" * 64),
    }
    values.update(overrides)
    return SourceIdentity(**values)


def test_result(
    mutation: Mutation,
    status: str,
    returncode: int,
    detail: str | None = None,
    *,
    selected: str | None = None,
) -> CommandResult:
    name = selected or expected_test_name(mutation.test_path, mutation.test_filter)
    lines = [
        f"{EVIDENCE_PREFIX}selected\t{name}",
        f"{EVIDENCE_PREFIX}{status}\t{name}" + (f"\t{detail}" if detail else ""),
    ]
    return CommandResult(returncode, stderr="\n".join(lines) + "\n")


class MutationGenerationTest(unittest.TestCase):
    def test_exact_site_is_replaced_once(self) -> None:
        mutation = fixture()
        source = "before old after"
        mutant, sites = generate_mutant(source, mutation)
        self.assertEqual(mutant, "before new after")
        self.assertEqual(sites, 1)
        self.assertEqual(source, "before old after")

    def test_missing_and_ambiguous_sites_are_invalid(self) -> None:
        mutation = fixture()
        for source in ("none", "old and old"):
            with self.subTest(source=source), self.assertRaises(InvalidMutation):
                generate_mutant(source, mutation)

    def test_declared_multi_site_mutation_replaces_every_site(self) -> None:
        mutation = fixture(expected_sites=2, replace_all=True)
        mutant, sites = generate_mutant("old then old", mutation)
        self.assertEqual(mutant, "new then new")
        self.assertEqual(sites, 2)

    def test_catalog_is_unique_and_confined_to_crest_implementation(self) -> None:
        allowed = {
            "src/kernel/math/crest.zig",
            "src/kernel/regex/analysis/swell.zig",
            "src/corpus/index/crest/columnar.zig",
            "src/corpus/index/crest/sidecar.zig",
        }
        test_paths = {
            "src/kernel/math/crest_test.zig",
            "src/kernel/regex/analysis/swell_test.zig",
            "src/corpus/index/crest/sidecar_test.zig",
        }
        self.assertEqual(len({mutation.name for mutation in MUTATIONS}), len(MUTATIONS))
        self.assertTrue(MUTATIONS)
        self.assertLessEqual({mutation.path for mutation in MUTATIONS}, allowed)
        self.assertLessEqual({mutation.test_path for mutation in MUTATIONS}, test_paths)


class ClassificationTest(unittest.TestCase):
    def test_linker_failure_and_compile_timeout_are_invalid(self) -> None:
        mutation = fixture()
        failed = classify(
            mutation,
            1,
            CommandResult(1, stderr="error: ld.lld exited with code 1"),
            None,
        )
        timed_out = classify(mutation, 1, CommandResult(None, timed_out=True), None)
        self.assertEqual(
            (failed.classification, failed.reason),
            ("invalid", "compile_or_link_failed"),
        )
        self.assertEqual(
            (timed_out.classification, timed_out.reason),
            ("invalid", "compile_timeout"),
        )

    def test_named_assertion_and_panic_kill_but_success_survives(self) -> None:
        mutation = fixture()
        assertion = classify(
            mutation,
            1,
            CommandResult(0),
            test_result(
                mutation,
                "failed",
                ASSERTION_EXIT,
                "TestExpectedEqual",
            ),
        )
        panic = classify(
            mutation,
            1,
            CommandResult(0),
            test_result(mutation, "panicked", PANIC_EXIT),
        )
        survived = classify(
            mutation,
            1,
            CommandResult(0),
            test_result(mutation, "passed", 0),
        )
        self.assertEqual(
            (assertion.classification, assertion.reason),
            ("killed", "named_test_assertion_failed"),
        )
        self.assertEqual(
            (panic.classification, panic.reason),
            ("killed", "named_test_panicked"),
        )
        self.assertEqual(
            (survived.classification, survived.reason),
            ("survived", "test_passed"),
        )

    def test_signals_are_invalid_even_with_failure_evidence(self) -> None:
        mutation = fixture()
        compile_signal = classify(mutation, 1, CommandResult(-9), None)
        test_signal = classify(
            mutation,
            1,
            CommandResult(0),
            test_result(
                mutation,
                "failed",
                -6,
                "TestUnexpectedResult",
            ),
        )
        self.assertEqual(
            (compile_signal.classification, compile_signal.reason),
            ("invalid", "compile_signal"),
        )
        self.assertEqual(
            (test_signal.classification, test_signal.reason),
            ("invalid", "test_signal"),
        )

    def test_wrong_test_and_unrelated_process_failures_are_invalid(self) -> None:
        mutation = fixture()
        wrong = classify(
            mutation,
            1,
            CommandResult(0),
            test_result(
                mutation,
                "failed",
                ASSERTION_EXIT,
                "TestUnexpectedResult",
                selected="src.other.test.wrong test",
            ),
        )
        unrelated = classify(
            mutation,
            1,
            CommandResult(0),
            CommandResult(7, stderr="unrelated runner failure"),
        )
        non_assertion = classify(
            mutation,
            1,
            CommandResult(0),
            test_result(mutation, "failed", ASSERTION_EXIT, "OutOfMemory"),
        )
        self.assertEqual((wrong.classification, wrong.reason), ("invalid", "test_evidence"))
        self.assertEqual(
            (unrelated.classification, unrelated.reason),
            ("invalid", "test_evidence"),
        )
        self.assertEqual(
            (non_assertion.classification, non_assertion.reason),
            ("invalid", "runner_failure"),
        )

    def test_test_timeout_is_invalid(self) -> None:
        outcome = classify(
            fixture(),
            1,
            CommandResult(0),
            CommandResult(None, timed_out=True),
        )
        self.assertEqual((outcome.classification, outcome.reason), ("invalid", "test_timeout"))

    def test_report_is_stable_sorted_json(self) -> None:
        zulu_mutation = fixture(name="zulu")
        alpha_mutation = fixture(name="alpha")
        zulu = classify(
            zulu_mutation,
            1,
            CommandResult(0),
            test_result(zulu_mutation, "passed", 0),
        )
        alpha = classify(
            alpha_mutation,
            1,
            CommandResult(0),
            test_result(
                alpha_mutation,
                "failed",
                ASSERTION_EXIT,
                "TestUnexpectedResult",
            ),
        )
        identity = provenance()
        first = render_report([zulu, alpha], identity)
        second = render_report([alpha, zulu], identity)
        self.assertEqual(first, second)
        report = json.loads(first)
        self.assertEqual(
            [mutant["name"] for mutant in report["mutants"]],
            ["alpha", "zulu"],
        )
        self.assertEqual(
            report["summary"],
            {
                "eligible": 2,
                "invalid": 0,
                "killed": 1,
                "survived": 1,
                "total": 2,
            },
        )
        self.assertEqual(report["provenance"], identity.as_json())


class SourceBindingTest(unittest.TestCase):
    @staticmethod
    def report(identity: SourceIdentity) -> dict[str, object]:
        outcomes = [
            classify(
                mutation,
                1,
                CommandResult(0),
                test_result(mutation, "passed", 0),
            )
            for mutation in MUTATIONS
        ]
        return json.loads(render_report(outcomes, identity))

    def test_dirty_source_change_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            source = root / "source.zig"
            source.write_text("const answer = 42;\n")
            before = snapshot_digest(root, ("source.zig",))
            source.write_text("const answer = 0;\n")
            after = snapshot_digest(root, ("source.zig",))
        self.assertNotEqual(before, after)

        original = provenance(
            source_snapshot_sha256=before,
            dirty_tree_sha256="1" * 64,
        )
        changed = replace(
            original,
            source_snapshot_sha256=after,
            dirty_tree_sha256="2" * 64,
        )
        with self.assertRaisesRegex(ReportDrift, "provenance"):
            verify_report(self.report(original), changed)

    def test_catalog_drift_is_rejected(self) -> None:
        original = provenance()
        altered_digest = catalog_digest(
            [
                *(asdict(mutation) for mutation in MUTATIONS),
                asdict(fixture(name="new-mutant")),
            ]
        )
        changed = replace(original, mutation_catalog_sha256=altered_digest)
        with self.assertRaisesRegex(ReportDrift, "provenance"):
            verify_report(self.report(original), changed)

    def test_matching_dirty_snapshot_and_catalog_verify(self) -> None:
        identity = provenance()
        verify_report(self.report(identity), identity)

    def test_survivor_to_killed_forgery_is_rejected_with_adjusted_summary(
        self,
    ) -> None:
        identity = provenance()
        report = self.report(identity)
        report["mutants"][0]["classification"] = "killed"
        report["summary"]["killed"] += 1
        report["summary"]["survived"] -= 1
        with self.assertRaisesRegex(ReportDrift, "machine evidence"):
            verify_report(report, identity)

    def test_every_stored_outcome_field_forgery_is_rejected(self) -> None:
        identity = provenance()
        for field, forged in {
            "reason": "named_test_assertion_failed",
            "sites": 99,
            "compile_returncode": 1,
            "compile_timed_out": True,
            "test_returncode": ASSERTION_EXIT,
            "test_timed_out": True,
            "test_evidence": "assertion_failed",
            "machine_evidence": [
                f"{EVIDENCE_PREFIX}selected\tforged",
                f"{EVIDENCE_PREFIX}failed\tforged\tTestUnexpectedResult",
            ],
        }.items():
            with self.subTest(field=field):
                report = self.report(identity)
                report["mutants"][0][field] = forged
                with self.assertRaisesRegex(ReportDrift, "machine evidence"):
                    verify_report(report, identity)


class IsolationTest(unittest.TestCase):
    def test_copy_excludes_worktree_and_build_state(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            source = root / "source"
            source.mkdir()
            source.joinpath("tracked.txt").write_text("tracked")
            for disposable in (".git", ".zig-cache", "zig-out", "__pycache__"):
                source.joinpath(disposable).mkdir()
                source.joinpath(disposable, "state").write_text("discard")
            destination = root / "copy"
            copy_repo(source, destination)
            self.assertEqual(destination.joinpath("tracked.txt").read_text(), "tracked")
            for disposable in (".git", ".zig-cache", "zig-out", "__pycache__"):
                self.assertFalse(destination.joinpath(disposable).exists())

    def test_copy_refuses_destination_inside_source(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            source = Path(raw) / "source"
            source.mkdir()
            with self.assertRaisesRegex(RuntimeError, "outside"):
                copy_repo(source, source / "nested")


if __name__ == "__main__":
    unittest.main()
