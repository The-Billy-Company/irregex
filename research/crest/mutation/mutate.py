#!/usr/bin/env python3
"""Classify corpus-independent CREST mutants in an isolated irregex copy."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
from collections import Counter
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Literal

from contract import (
    MUTATIONS,
    Mutation,
    ReportDrift,
    SourceIdentity,
    capture_source,
    catalog_digest,
    machine_evidence,
    test_evidence,
    verify_provenance,
)

REPO = Path(__file__).resolve().parents[3]
Classification = Literal["killed", "survived", "invalid"]
ClassificationSource = Literal["focused_test", "precondition"]


class InvalidMutation(ValueError):
    """The source no longer contains the mutation site exactly as declared."""


@dataclass(frozen=True)
class CommandResult:
    returncode: int | None
    timed_out: bool = False
    stdout: str = ""
    stderr: str = ""


@dataclass(frozen=True)
class Outcome:
    mutation: Mutation
    classification: Classification
    reason: str
    sites: int
    compile_returncode: int | None = None
    compile_timed_out: bool | None = None
    test_returncode: int | None = None
    test_timed_out: bool | None = None
    test_evidence: str | None = None
    machine_evidence: tuple[str, ...] = ()
    classification_source: ClassificationSource = "precondition"

    def as_json(self) -> dict[str, object]:
        return {
            "classification": self.classification,
            "classification_source": self.classification_source,
            "compile_returncode": self.compile_returncode,
            "compile_timed_out": self.compile_timed_out,
            "machine_evidence": list(self.machine_evidence),
            "name": self.mutation.name,
            "path": self.mutation.path,
            "reason": self.reason,
            "sites": self.sites,
            "test_evidence": self.test_evidence,
            "test_filter": self.mutation.test_filter,
            "test_path": self.mutation.test_path,
            "test_returncode": self.test_returncode,
            "test_timed_out": self.test_timed_out,
        }


@dataclass(frozen=True)
class SuiteResult:
    outcomes: list[Outcome]
    provenance: SourceIdentity


def generate_mutant(source: str, mutation: Mutation) -> tuple[str, int]:
    """Apply one declared mutation, refusing ambiguous or drifted sites."""
    sites = source.count(mutation.needle)
    expected = mutation.expected_sites
    if sites != expected:
        raise InvalidMutation(
            f"{mutation.name}: expected {expected} mutation site(s), found {sites}"
        )
    limit = -1 if mutation.replace_all else 1
    return source.replace(mutation.needle, mutation.replacement, limit), sites


def classify(
    mutation: Mutation,
    sites: int,
    compile_result: CommandResult,
    test_result: CommandResult | None,
    *,
    validate_sites: bool = True,
) -> Outcome:
    """Require a linked binary and exact machine evidence for behavioral kills."""
    evidence_lines = machine_evidence(test_result.stderr) if test_result else ()

    def outcome(
        classification: Classification,
        reason: str,
        evidence_status: str | None = None,
    ) -> Outcome:
        return Outcome(
            mutation,
            classification,
            reason,
            sites,
            compile_returncode=compile_result.returncode,
            compile_timed_out=compile_result.timed_out,
            test_returncode=test_result.returncode if test_result else None,
            test_timed_out=test_result.timed_out if test_result else None,
            test_evidence=evidence_status,
            machine_evidence=evidence_lines,
            classification_source="focused_test",
        )

    if validate_sites and sites != mutation.expected_sites:
        return outcome("invalid", "mutation_site_count")
    if compile_result.timed_out:
        return outcome("invalid", "compile_timeout")
    if compile_result.returncode is not None and compile_result.returncode < 0:
        return outcome("invalid", "compile_signal")
    if compile_result.returncode != 0:
        return outcome("invalid", "compile_or_link_failed")
    if test_result is None:
        return outcome("invalid", "test_not_run")
    if test_result.timed_out:
        return outcome("invalid", "test_timeout")
    if test_result.returncode is None or test_result.returncode < 0:
        return outcome("invalid", "test_signal")
    evidence = test_evidence(
        mutation.test_path,
        mutation.test_filter,
        test_result.returncode,
        test_result.stderr,
    )
    classification: Classification = {
        "passed": "survived",
        "assertion_failed": "killed",
        "panicked": "killed",
        "invalid": "invalid",
    }[evidence.status]
    return outcome(classification, evidence.reason, evidence.status)


def render_report(outcomes: list[Outcome], provenance: SourceIdentity) -> str:
    """Return stable, path-independent JSON."""
    counts = Counter(outcome.classification for outcome in outcomes)
    eligible = counts["killed"] + counts["survived"]
    payload = {
        "mutants": [
            outcome.as_json()
            for outcome in sorted(outcomes, key=lambda item: item.mutation.name)
        ],
        "provenance": provenance.as_json(),
        "schema_version": 3,
        "suite": "irregex-crest-corpus-independent",
        "summary": {
            "eligible": eligible,
            "invalid": counts["invalid"],
            "killed": counts["killed"],
            "survived": counts["survived"],
            "total": len(outcomes),
        },
    }
    return json.dumps(payload, indent=2, sort_keys=True) + "\n"


def verify_report(report: dict[str, object], provenance: SourceIdentity) -> None:
    if (
        report.get("schema_version") != 3
        or report.get("suite") != "irregex-crest-corpus-independent"
    ):
        raise ReportDrift("unsupported mutation report schema")
    verify_provenance(report, provenance)
    mutants = report.get("mutants")
    if not isinstance(mutants, list):
        raise ReportDrift("mutation report has no mutant catalog")
    expected = {mutation.name: mutation for mutation in MUTATIONS}
    seen: set[str] = set()
    classifications: list[Classification] = []
    for mutant in mutants:
        if not isinstance(mutant, dict) or not isinstance(mutant.get("name"), str):
            raise ReportDrift("mutation report contains a malformed mutant")
        name = mutant["name"]
        mutation = expected.get(name)
        if mutation is None or name in seen:
            raise ReportDrift("mutation report catalog does not match the harness")
        seen.add(name)
        source = mutant.get("classification_source")
        if source == "precondition":
            reason = mutant.get("reason")
            allowed = reason in {
                "mutation_site",
                "path_escape",
                "publication_failed",
                "publication_timeout",
            } or (isinstance(reason, str) and reason.startswith("baseline_"))
            recomputed = Outcome(mutation, "invalid", str(reason), 0)
            if not allowed or mutant != recomputed.as_json():
                raise ReportDrift(f"{name}: invalid precondition outcome")
        elif source == "focused_test":
            sites = mutant.get("sites")
            compile_code = mutant.get("compile_returncode")
            compile_timeout = mutant.get("compile_timed_out")
            test_code = mutant.get("test_returncode")
            test_timeout = mutant.get("test_timed_out")
            records = mutant.get("machine_evidence")
            codes = (compile_code, test_code)
            if (
                type(sites) is not int
                or any(code is not None and type(code) is not int for code in codes)
                or type(compile_timeout) is not bool
                or test_timeout is not None
                and type(test_timeout) is not bool
                or not isinstance(records, list)
                or any(not isinstance(record, str) for record in records)
            ):
                raise ReportDrift(f"{name}: malformed execution evidence")
            compile_result = CommandResult(compile_code, timed_out=compile_timeout)
            test_result = (
                None
                if test_timeout is None
                else CommandResult(
                    test_code,
                    timed_out=test_timeout,
                    stderr="\n".join(records),
                )
            )
            recomputed = classify(mutation, sites, compile_result, test_result)
            if mutant != recomputed.as_json():
                raise ReportDrift(f"{name}: outcome disagrees with machine evidence")
        else:
            raise ReportDrift(f"{name}: unknown classification source")
        classifications.append(recomputed.classification)
    if seen != set(expected):
        raise ReportDrift("mutation report catalog does not match the harness")
    counts = Counter(classifications)
    summary = {
        "eligible": counts["killed"] + counts["survived"],
        "invalid": counts["invalid"],
        "killed": counts["killed"],
        "survived": counts["survived"],
        "total": len(mutants),
    }
    if (
        set(counts) > {"killed", "survived", "invalid"}
        or report.get("summary") != summary
    ):
        raise ReportDrift("mutation report summary is inconsistent")


def find_zig() -> str:
    if found := shutil.which("zig"):
        return found
    if mise := shutil.which("mise"):
        result = subprocess.run(
            [mise, "which", "zig"],
            capture_output=True,
            check=False,
            text=True,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    raise RuntimeError("Zig is unavailable; install the toolchain with mise")


def run_command(argv: list[str], cwd: Path, timeout: float) -> CommandResult:
    process = subprocess.Popen(
        argv,
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
        text=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        stdout, stderr = process.communicate()
        return CommandResult(
            None,
            timed_out=True,
            stdout=stdout,
            stderr=stderr,
        )
    return CommandResult(process.returncode, stdout=stdout, stderr=stderr)


def diagnostic(label: str, result: CommandResult, verbose: bool) -> None:
    if not verbose or (result.returncode == 0 and not result.timed_out):
        return
    print(f"\n[{label}]", file=sys.stderr)
    if result.stdout:
        print(result.stdout, file=sys.stderr)
    if result.stderr:
        print(result.stderr, file=sys.stderr)


def invalid_all(reason: str) -> list[Outcome]:
    return [Outcome(mutation, "invalid", reason, 0) for mutation in MUTATIONS]


def compile_test_command(
    executable: str,
    workspace: Path,
    mutation: Mutation,
) -> tuple[list[str], Path]:
    """Compile and link exactly one focused test without executing it."""
    runner = workspace / ".crest-mutation-test.zig"
    runner.write_text(f'comptime {{ _ = @import("{mutation.test_path}"); }}\n')
    binary = workspace / ".crest-mutation-test-bin"
    binary.unlink(missing_ok=True)
    return [
        executable,
        "test",
        "--test-no-exec",
        f"-femit-bin={binary.name}",
        "--test-runner",
        "research/crest/mutation/runner.zig",
        "--dep",
        "build_options",
        f"-Mroot={runner.name}",
        "-Mbuild_options=research/crest/mutation/build_options.zig",
        "-lc",
        "--test-filter",
        mutation.test_filter,
    ], binary


def run_focused_test(
    executable: str,
    workspace: Path,
    mutation: Mutation,
    timeout: float,
) -> tuple[CommandResult, CommandResult | None]:
    command, binary = compile_test_command(executable, workspace, mutation)
    compiled = run_command(command, workspace, timeout)
    if compiled.timed_out or compiled.returncode != 0:
        return compiled, None
    return compiled, run_command([str(binary)], workspace, timeout)


def run_suite(
    repo: Path,
    executable: str,
    timeout: float,
    publication: bool,
    verbose: bool,
) -> SuiteResult:
    with tempfile.TemporaryDirectory(prefix="irregex-crest-mutation-") as raw:
        workspace = Path(raw) / "irregex"
        provenance = capture_source(
            repo,
            workspace,
            executable,
            catalog_digest(asdict(mutation) for mutation in MUTATIONS),
        )

        if publication:
            result = run_command([executable, "build", "test"], workspace, timeout)
            diagnostic("publication baseline", result, verbose)
            if result.timed_out:
                return SuiteResult(invalid_all("publication_timeout"), provenance)
            if result.returncode != 0:
                return SuiteResult(invalid_all("publication_failed"), provenance)

        baselines: dict[
            tuple[str, str], tuple[CommandResult, CommandResult | None]
        ] = {}
        for mutation in MUTATIONS:
            key = (mutation.test_path, mutation.test_filter)
            if key in baselines:
                continue
            compiled, tested = run_focused_test(
                executable, workspace, mutation, timeout
            )
            baselines[key] = compiled, tested
            diagnostic(f"baseline compile: {mutation.test_filter}", compiled, verbose)
            if tested is not None:
                diagnostic(f"baseline test: {mutation.test_filter}", tested, verbose)

        outcomes: list[Outcome] = []
        for mutation in MUTATIONS:
            baseline_compile, baseline_test = baselines[
                (mutation.test_path, mutation.test_filter)
            ]
            baseline = classify(
                mutation,
                0,
                baseline_compile,
                baseline_test,
                validate_sites=False,
            )
            if baseline.classification != "survived":
                outcomes.append(
                    Outcome(
                        mutation,
                        "invalid",
                        f"baseline_{baseline.reason}",
                        0,
                    )
                )
                continue

            path = (workspace / mutation.path).resolve()
            if workspace.resolve() not in path.parents:
                outcomes.append(Outcome(mutation, "invalid", "path_escape", 0))
                continue
            try:
                original = path.read_text()
                mutant, sites = generate_mutant(original, mutation)
            except (InvalidMutation, OSError):
                outcomes.append(Outcome(mutation, "invalid", "mutation_site", 0))
                continue

            path.write_text(mutant)
            try:
                compiled, tested = run_focused_test(
                    executable, workspace, mutation, timeout
                )
                diagnostic(f"compile: {mutation.name}", compiled, verbose)
                if tested is not None:
                    diagnostic(f"test: {mutation.name}", tested, verbose)
                outcomes.append(classify(mutation, sites, compiled, tested))
            finally:
                path.write_text(original)
        return SuiteResult(outcomes, provenance)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--verify",
        type=Path,
        help="reject a saved report unless its source, catalog, and toolchain match",
    )
    parser.add_argument(
        "--publication",
        action="store_true",
        help="run the complete Zig suite in the isolated copy before mutation analysis",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=600,
        help="per-command timeout in seconds (default: 600)",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="send failing command output to stderr; stdout remains deterministic JSON",
    )
    args = parser.parse_args()

    try:
        executable = find_zig()
        if args.verify:
            with tempfile.TemporaryDirectory(
                prefix="irregex-crest-mutation-verify-"
            ) as raw:
                provenance = capture_source(
                    REPO,
                    Path(raw) / "irregex",
                    executable,
                    catalog_digest(asdict(mutation) for mutation in MUTATIONS),
                )
            report = json.loads(args.verify.read_text())
            verify_report(report, provenance)
            print("CREST mutation report verified")
            return 0
        suite = run_suite(
            REPO,
            executable,
            args.timeout,
            args.publication,
            args.verbose,
        )
    except (json.JSONDecodeError, OSError, ReportDrift, RuntimeError) as error:
        print(f"CREST mutation harness failed: {error}", file=sys.stderr)
        return 2
    sys.stdout.write(render_report(suite.outcomes, suite.provenance))
    return int(any(outcome.classification != "killed" for outcome in suite.outcomes))


if __name__ == "__main__":
    raise SystemExit(main())
