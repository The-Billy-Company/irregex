"""Determinism, leakage, fingerprint, archive-safety, and promotion-gate tests."""

from __future__ import annotations

import copy
import os
import stat
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

from crest_training import package as package_module
from crest_training import source as source_module
from crest_training.package import (
    MAX_PACKAGE_DIRECTORIES,
    MAX_PACKAGE_MEMBERS,
    MAX_ZERO_BYTE_MEMBERS,
    PARTITION_MEMBERS,
    DataPackage,
    InputSafetyError,
    IntegrityError,
)
from crest_training.predicates import ASCII_DIGIT, extract_predicates, load_manifest
from crest_training.proposal import (
    PROMOTION_GATE,
    build_proposal,
    build_validation_report,
)
from support import TraceFixture


class TrainingEvidenceTest(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.fixture = TraceFixture(self.root / "package")
        self.package = DataPackage(self.fixture.root)

    def test_zip_is_consumed_without_extraction(self) -> None:
        archive = self.fixture.archive(self.root / "package.zip")
        before = {path.name for path in self.root.iterdir()}
        package = DataPackage(archive)
        self.assertEqual(package.receipt().source_kind, "zip")
        self.assertEqual(
            package.read_partition("train"),
            self.fixture.trace.joinpath("train.jsonl").read_bytes(),
        )
        self.assertEqual({path.name for path in self.root.iterdir()}, before)

    def test_dataset_fingerprint_is_container_independent_and_content_bound(
        self,
    ) -> None:
        archive = self.fixture.archive(self.root / "package.zip")
        directory_fingerprint = load_manifest(self.package).dataset_fingerprint
        archive_fingerprint = load_manifest(DataPackage(archive)).dataset_fingerprint
        self.assertEqual(directory_fingerprint, archive_fingerprint)

        self.fixture.rows["train"].append(
            {
                **self.fixture.rows["train"][0],
                "call_key": "f" * 24,
                "session_key": "e" * 20,
            }
        )
        self.fixture.write_partition("train")
        self.assertNotEqual(
            load_manifest(DataPackage(self.fixture.root)).dataset_fingerprint,
            directory_fingerprint,
        )

    def test_proposal_is_deterministic_and_training_only(self) -> None:
        opened: list[str] = []
        original = self.package.read

        def audited(member: object) -> bytes:
            opened.append(str(member))
            return original(member)

        with mock.patch.object(self.package, "read", audited):
            first = build_proposal(self.package, 2)
        second = build_proposal(DataPackage(self.fixture.root), 2)
        self.assertEqual(first, second)
        self.assertEqual(
            [record["byte_ranges_hex"] for record in first["proposed_predicates"]],
            [["78"], ["41-5a"]],
        )
        self.assertEqual(
            opened,
            [
                str(PARTITION_MEMBERS["train"].parent / "manifest.json"),
                str(PARTITION_MEMBERS["train"]),
            ],
        )
        self.assertNotIn(str(PARTITION_MEMBERS["validation"]), opened)
        self.assertEqual(first["promotion_gate"], PROMOTION_GATE)

    def test_validation_rejects_call_and_session_overlap(self) -> None:
        proposal = build_proposal(self.package, 2)
        for key in ("call_key", "session_key"):
            fixture = TraceFixture(self.root / key)
            fixture.rows["validation"][0][key] = fixture.rows["train"][0][key]
            fixture.write_partition("validation")
            with self.subTest(key=key), self.assertRaisesRegex(IntegrityError, key):
                package = DataPackage(fixture.root)
                build_validation_report(package, build_proposal(package, 2), fixture.settings)

        report = build_validation_report(self.package, proposal, self.fixture.settings)
        self.assertEqual(report["split_guard"]["call_key_overlap"], 0)
        self.assertEqual(report["split_guard"]["session_key_overlap"], 0)
        self.assertTrue(report["split_guard"]["validation_opened_after_dictionary_frozen"])

    def test_outputs_cannot_claim_q4_or_dictionary_promotion(self) -> None:
        proposal = build_proposal(self.package, 2)
        report = build_validation_report(self.package, proposal, self.fixture.settings)
        for artifact in (proposal, report):
            gate = artifact["promotion_gate"]
            self.assertEqual(gate["status"], "corpus_evidence_required")
            self.assertIs(gate["q4_promotion_eligible"], False)
            self.assertIs(gate["adaptive_dictionary_promotion_eligible"], False)

        forged = copy.deepcopy(proposal)
        forged["promotion_gate"]["q4_promotion_eligible"] = True
        with self.assertRaisesRegex(IntegrityError, "deterministic training reproduction"):
            build_validation_report(self.package, forged, self.fixture.settings)

    def test_sealed_partitions_and_unsafe_archive_members_are_rejected(self) -> None:
        for role in ("test", "excluded"):
            with self.assertRaises(InputSafetyError):
                self.package.read_partition(role)

        traversal = self.root / "traversal.zip"
        with zipfile.ZipFile(traversal, "w") as archive:
            archive.writestr("root/data/entireio_trace_v1/manifest.json", "{}")
            archive.writestr("../escape", "forbidden")
        with self.assertRaises(InputSafetyError):
            DataPackage(traversal)

        symlink = self.root / "symlink.zip"
        link = zipfile.ZipInfo("root/link")
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        with zipfile.ZipFile(symlink, "w") as archive:
            archive.writestr(link, "target")
            archive.writestr("root/data/entireio_trace_v1/manifest.json", "{}")
        with self.assertRaises(InputSafetyError):
            DataPackage(symlink)

    def test_sealed_partitions_are_required_and_stream_verified(self) -> None:
        for role in ("test", "excluded_cross_boundary"):
            with self.subTest(role=role, failure="missing"):
                fixture = TraceFixture(self.root / f"missing-{role}")
                (fixture.trace / f"{role}.jsonl").unlink()
                with self.assertRaisesRegex(IntegrityError, "member sets differ"):
                    DataPackage(fixture.root)
            with self.subTest(role=role, failure="altered"):
                fixture = TraceFixture(self.root / f"altered-{role}")
                with (fixture.trace / f"{role}.jsonl").open("ab") as partition:
                    partition.write(b"tampered\n")
                with self.assertRaisesRegex(IntegrityError, "checksum drift"):
                    DataPackage(fixture.root)

    def test_manifest_cannot_fingerprint_unverified_sealed_bytes(self) -> None:
        fixture = TraceFixture(self.root / "manifest-drift")
        sealed = fixture.trace / "test.jsonl"
        sealed.write_bytes(sealed.read_bytes() + b"changed\n")
        fixture.write_checksums()
        package = DataPackage(fixture.root)
        with self.assertRaisesRegex(IntegrityError, "verified test member"):
            load_manifest(package)

    def test_every_checksum_declaration_is_verified(self) -> None:
        fixture = TraceFixture(self.root / "declared")
        declared = fixture.root / "declared-but-unused.bin"
        declared.write_bytes(b"before")
        fixture.write_checksums()
        declared.write_bytes(b"after")
        with self.assertRaisesRegex(IntegrityError, "declared-but-unused"):
            DataPackage(fixture.root)

    def test_zip_caps_precede_zipfile_state_materialization(self) -> None:
        archive_path = self.root / "member-bomb.zip"
        with zipfile.ZipFile(archive_path, "w") as archive:
            for index in range(MAX_PACKAGE_MEMBERS + 1):
                archive.writestr(f"entry-{index}", b"")
        with (
            mock.patch.object(package_module.zipfile, "ZipFile") as zip_constructor,
            self.assertRaisesRegex(InputSafetyError, "member-count"),
        ):
            DataPackage(archive_path)
        zip_constructor.assert_not_called()

    def test_directory_and_zero_byte_entry_bombs_are_bounded(self) -> None:
        directory_bomb = self.root / "directory-bomb"
        directory_bomb.mkdir()
        for index in range(MAX_PACKAGE_DIRECTORIES + 1):
            (directory_bomb / f"d-{index}").mkdir()
        with self.assertRaisesRegex(InputSafetyError, "directory-entry"):
            DataPackage(directory_bomb)

        zero_bomb = self.root / "zero-bomb"
        zero_bomb.mkdir()
        for index in range(MAX_ZERO_BYTE_MEMBERS + 1):
            (zero_bomb / f"empty-{index}").touch()
        with self.assertRaisesRegex(InputSafetyError, "zero-byte"):
            DataPackage(zero_bomb)

    def test_fifo_source_is_opened_nonblocking_and_rejected(self) -> None:
        fifo = self.root / "package.fifo"
        os.mkfifo(fifo)
        real_open = os.open
        observed: list[int] = []

        def guarded_open(path, flags, *args, **kwargs):
            observed.append(flags)
            if not flags & os.O_NONBLOCK:
                raise AssertionError("FIFO source open would block")
            return real_open(path, flags, *args, **kwargs)

        with (
            mock.patch.object(source_module.os, "open", side_effect=guarded_open),
            self.assertRaises(InputSafetyError),
        ):
            DataPackage(fifo)
        self.assertTrue(observed)
        self.assertTrue(observed[0] & os.O_NONBLOCK)

    def test_no_nofollow_fallback_rejects_symlink_and_inode_race(self) -> None:
        target = self.root / "target.zip"
        target.write_bytes(b"not relevant")
        link = self.root / "link.zip"
        link.symlink_to(target)
        with (
            mock.patch.object(source_module.os, "O_NOFOLLOW", 0),
            self.assertRaises(InputSafetyError),
        ):
            DataPackage(link)

        victim = self.root / "victim.zip"
        victim.write_bytes(b"original")
        real_open = os.open
        swapped = False

        def replace_before_open(path, flags, *args, **kwargs):
            nonlocal swapped
            if not swapped and Path(path) == victim:
                swapped = True
                victim.unlink()
                victim.symlink_to(target)
            return real_open(path, flags, *args, **kwargs)

        with (
            mock.patch.object(source_module.os, "O_NOFOLLOW", 0),
            mock.patch.object(
                source_module.os,
                "open",
                side_effect=replace_before_open,
            ),
            self.assertRaises(InputSafetyError),
        ):
            DataPackage(victim)
        self.assertTrue(swapped)

    def test_directory_member_fifo_replacement_is_nonblocking(self) -> None:
        fixture = TraceFixture(self.root / "fifo-member")
        package = DataPackage(fixture.root)
        target = fixture.trace / "train.jsonl"
        real_open = os.open
        replaced = False

        def replace_with_fifo(path, flags, *args, **kwargs):
            nonlocal replaced
            if not replaced and path == "train.jsonl":
                replaced = True
                target.unlink()
                os.mkfifo(target)
                if not flags & os.O_NONBLOCK:
                    raise AssertionError("member FIFO open would block")
            return real_open(path, flags, *args, **kwargs)

        with (
            mock.patch.object(
                source_module.os,
                "open",
                side_effect=replace_with_fifo,
            ),
            self.assertRaises(InputSafetyError),
        ):
            package.read_partition("train")
        self.assertTrue(replaced)

    def test_fallback_rejects_symlink_component_race(self) -> None:
        fixture = TraceFixture(self.root / "component-race")
        package = DataPackage(fixture.root)
        data = fixture.root / "data"
        original = fixture.root / "data-original"
        outside = self.root / "outside"
        outside.mkdir()
        real_open = os.open
        replaced = False

        def replace_component(path, flags, *args, **kwargs):
            nonlocal replaced
            if not replaced and path == "data":
                replaced = True
                data.rename(original)
                data.symlink_to(outside, target_is_directory=True)
            return real_open(path, flags, *args, **kwargs)

        with (
            mock.patch.object(source_module.os, "O_NOFOLLOW", 0),
            mock.patch.object(
                source_module.os,
                "open",
                side_effect=replace_component,
            ),
            self.assertRaises(InputSafetyError),
        ):
            package.read_partition("train")
        self.assertTrue(replaced)

    def test_unicode_predicates_do_not_alias_to_ascii(self) -> None:
        unicode_digit = extract_predicates(r"\d+", False, True)
        self.assertFalse(unicode_digit.atoms)
        self.assertEqual(
            {candidate.reason for candidate in unicode_digit.non_byte},
            {"dynamic_unicode_shorthand"},
        )
        self.assertEqual(
            [atom.byte_set for atom in extract_predicates(r"\d+", False, False).atoms],
            [ASCII_DIGIT],
        )


if __name__ == "__main__":
    unittest.main()
