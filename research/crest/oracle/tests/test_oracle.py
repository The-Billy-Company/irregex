"""Adversarial and finite-language differentials for the exact CREST oracle."""

from __future__ import annotations

import io
import itertools
import json
import re
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from research.crest.oracle.contract import (
    CONTRACT_PATH,
    EXPECTED_CLASS_ORDER,
    SUPPORTED_BUDGETS,
    SUPPORTED_RANKS,
    ContractError,
    load_contract,
)
from research.crest.oracle.export_zig import (
    _projections,
    generate,
    selected_cases,
)
from research.crest.oracle.export_zig import (
    main as export_zig,
)
from research.crest.oracle.fixtures import A, B, finite_asts, render
from research.crest.oracle.nfa import accepts_word, compile_nfa
from research.crest.oracle.oracle import (
    CONTRACT,
    NAMED_PREDICATES,
    analyze,
    analyze_order_statistic,
    main,
    parse_ranges,
)
from research.crest.oracle.syntax import (
    EmptyLanguage,
    PatternRefusal,
    PatternSyntaxError,
    ResourceLimitExceeded,
    parse,
)

C = ord("c")
REPOSITORY = Path(__file__).resolve().parents[4]
PRODUCTION_CREST = REPOSITORY / "src/kernel/math/crest.zig"
ORACLE_CLI = Path(__file__).resolve().parents[1] / "oracle.py"
ORACLE_CASES = REPOSITORY / "src/kernel/regex/analysis/oracle_cases.gen.zig"
REFUSAL_BEARING_PATTERNS = (
    "^a",
    "a$",
    r"\bword",
    r"(?=a)a",
    r"(?<=a)a",
    r"(a)\1",
    r"\p{L}",
)


def ranked_run(word: bytes, predicate: frozenset[int], rank: int) -> int:
    """Independent direct run-order statistic, padded with zero."""
    runs: list[int] = []
    current = 0
    for byte in word:
        if byte in predicate:
            current += 1
        elif current:
            runs.append(current)
            current = 0
    if current:
        runs.append(current)
    runs.sort(reverse=True)
    return runs[rank - 1] if rank <= len(runs) else 0


# Tiny test-only finite regex AST. It shares no parser, NFA, or monitor types.
def language(node: tuple) -> frozenset[bytes]:
    kind, *fields = node
    if kind == "eps":
        return frozenset({b""})
    if kind == "atom":
        return frozenset(bytes([byte]) for byte in fields[0])
    if kind == "cat":
        left, right = map(language, fields)
        return frozenset(prefix + suffix for prefix in left for suffix in right)
    if kind == "alt":
        return language(fields[0]) | language(fields[1])
    if kind == "rep":
        child, minimum, maximum = fields
        words = language(child)
        out: set[bytes] = set()
        power = {b""}
        for count in range(maximum + 1):
            if count >= minimum:
                out.update(power)
            power = {prefix + suffix for prefix in power for suffix in words}
        return frozenset(out)
    raise AssertionError(f"unknown test AST {kind}")


def run_cli(*arguments: str) -> tuple[int, str, dict]:
    output = io.StringIO()
    with redirect_stdout(output):
        code = main(arguments)
    rendered = output.getvalue()
    return code, rendered, json.loads(rendered)


def assert_class_language(
    test: unittest.TestCase, pattern: str, expected: frozenset[int]
) -> None:
    machine = compile_nfa(parse(pattern))
    for byte in range(256):
        test.assertEqual(
            byte in expected, accepts_word(machine, bytes([byte])), (pattern, byte)
        )


def project_pattern(pattern: str, member: int, nonmember: int) -> str:
    """Encode quotient bytes as syntax-neutral hexadecimal literals."""
    replacements = {"a": f"\\x{member:02x}", "b": f"\\x{nonmember:02x}"}
    return "".join(replacements.get(character, character) for character in pattern)


class ContractBindingTests(unittest.TestCase):
    def test_projection_matches_current_production_class_and_q_b_order(self) -> None:
        self.assertIsNotNone(CONTRACT)
        assert CONTRACT is not None
        source = PRODUCTION_CREST.read_text(encoding="utf-8")
        class_body = re.search(
            r"pub const Class = enum\(u8\) \{(?P<body>.*?)\n\};",
            source,
            re.DOTALL,
        )
        self.assertIsNotNone(class_body)
        production_order = tuple(
            re.findall(
                r"^\s+([a-z][a-z_]*)\s*(?:=\s*\d+)?\s*,\s*$",
                class_body.group("body"),
                re.MULTILINE,
            )
        )
        self.assertEqual(EXPECTED_CLASS_ORDER, production_order)
        self.assertEqual(production_order, CONTRACT.class_order)
        self.assertIn("pub const supported_ranks = [_]u8{ 1, 2, 4 };", source)
        self.assertIn("pub const supported_budgets = [_]u8{ 1, 2, 4, 8 };", source)
        self.assertEqual(SUPPORTED_RANKS, CONTRACT.supported_ranks)
        self.assertEqual(SUPPORTED_BUDGETS, CONTRACT.supported_budgets)

    def test_frozen_predicates_cover_all_current_byte_classes(self) -> None:
        self.assertEqual(EXPECTED_CLASS_ORDER, tuple(NAMED_PREDICATES))
        self.assertEqual(frozenset(range(48, 58)), NAMED_PREDICATES["digit"])
        self.assertEqual(frozenset({9, 10, 11, 12, 13, 32}), NAMED_PREDICATES["space"])
        self.assertEqual(frozenset(map(ord, "\"'")), NAMED_PREDICATES["quote"])
        self.assertEqual(frozenset(map(ord, "/\\")), NAMED_PREDICATES["slash"])
        self.assertIn(ord("."), NAMED_PREDICATES["punct"])
        self.assertNotIn(ord("_"), NAMED_PREDICATES["punct"])

    def test_policy_class_or_range_drift_invalidates_projection(self) -> None:
        source = CONTRACT_PATH.read_text(encoding="utf-8")
        mutations = (
            source.replace(
                'oracle_assertions = "refuse"', 'oracle_assertions = "erase"'
            ),
            source.replace(
                "supported_ranks = [ 1, 2, 4 ]", "supported_ranks = [ 1, 4 ]"
            ),
            source.replace(
                "supported_budgets = [ 1, 2, 4, 8 ]", "supported_budgets = [ 1, 2, 8 ]"
            ),
            source.replace('ranges = [ "22", "27" ]', 'ranges = [ "22" ]'),
            source.replace('  "quote",\n  "lparen",', '  "lparen",\n  "quote",'),
        )
        for index, mutation in enumerate(mutations):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as directory:
                self.assertNotEqual(source, mutation)
                path = Path(directory) / "contract.toml"
                path.write_text(mutation, encoding="utf-8")
                with self.assertRaises(ContractError):
                    load_contract(path)


class ZigExportTests(unittest.TestCase):
    def test_checked_fixture_is_byte_exact_export(self) -> None:
        self.assertEqual(ORACLE_CASES.read_bytes(), generate())

    def test_check_detects_drift_and_write_repairs_it(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "oracle_cases.gen.zig"
            target.write_bytes(b"drift\n")

            errors = io.StringIO()
            with redirect_stderr(errors):
                self.assertEqual(1, export_zig(("--check",), target=target))
            self.assertIn("drift:", errors.getvalue())

            with redirect_stdout(io.StringIO()):
                self.assertEqual(0, export_zig(("--write",), target=target))
            self.assertEqual(generate(), target.read_bytes())

    def test_selected_patterns_are_assertion_free_consuming_regexes(self) -> None:
        assert CONTRACT is not None
        cases = selected_cases()
        projections = _projections(CONTRACT)
        self.assertEqual(32, len(cases))
        self.assertEqual(
            EXPECTED_CLASS_ORDER, tuple(item.predicate for item in projections)
        )
        self.assertEqual(15, len(projections))
        self.assertEqual(480, len(cases) * len(projections))
        for case in cases:
            self.assertNotIn(case.pattern, REFUSAL_BEARING_PATTERNS)
            for projection in projections:
                definition = CONTRACT.predicates[projection.predicate]
                self.assertIn(projection.member, definition.bytes)
                self.assertNotIn(projection.nonmember, definition.bytes)
                pattern = project_pattern(
                    case.pattern, projection.member, projection.nonmember
                )
                with self.subTest(pattern=pattern, predicate=projection.predicate):
                    self.assertIsNotNone(parse(pattern))


class ExactThresholdTests(unittest.TestCase):
    def exact(
        self,
        pattern: str,
        predicate: str | frozenset[int],
        rank: int = 1,
    ) -> int:
        byte_set = (
            NAMED_PREDICATES[predicate] if isinstance(predicate, str) else predicate
        )
        return analyze(pattern, byte_set, rank).threshold

    def test_hand_computed_consuming_grammar(self) -> None:
        cases = (
            ("aaa", frozenset({A}), 3),
            ("aaabaa", frozenset({A}), 3),
            ("[a-c]{2,4}", frozenset({A, B, C}), 2),
            ("[a-c]{2,4}", frozenset({A}), 0),
            ("[^b]{3}", frozenset(range(256)) - {B, ord("\n")}, 3),
            (r"\x61\d{2}", "digit", 2),
            (r"\xff{2}", frozenset({0xFF}), 2),
            (r"[[:xdigit:]]{3}", "hex", 3),
            (".", frozenset(range(256)) - {ord("\n")}, 1),
            ("a{2,4}", frozenset({A}), 2),
            ("a{2,}", frozenset({A}), 2),
            ("a*a", frozenset({A}), 1),
            ("a+a", frozenset({A}), 2),
            ("(?:a|aa)+", frozenset({A}), 1),
            ("(?P<run>a{3})", frozenset({A}), 3),
            ("(?<run>a{3})", frozenset({A}), 3),
            ("a{3,5}?", frozenset({A}), 3),
        )
        for pattern, predicate, expected in cases:
            with self.subTest(pattern=pattern):
                self.assertEqual(expected, self.exact(pattern, predicate))

    def test_reset_epsilon_alternation_and_repetition_adversaries(self) -> None:
        cases = (
            ("aa[^a]aa", 2, "nonmember reset splits the runs"),
            ("aa(?:)aa", 4, "epsilon never resets a run"),
            ("aa(?:b)?aa", 2, "optional separator may be chosen"),
            ("aa(?:a)?aa", 4, "optional member cannot shorten below four"),
            ("aaaa|bb", 0, "alternation may choose a no-a branch"),
            ("aaaa|aab", 2, "alternation takes the lower threshold"),
            ("(?:a{5}|a{9}x)a{5}", 9, "nested alternation correlation"),
            ("(?:a?b)*a{2}", 2, "epsilon cycle and reset cannot overclaim"),
            ("(?:aab)+", 2, "loop boundaries reset after b"),
            ("(?:|b)a{3}", 3, "empty alternative remains neutral"),
        )
        for pattern, expected, reason in cases:
            with self.subTest(pattern=pattern, reason=reason):
                self.assertEqual(expected, self.exact(pattern, frozenset({A})))

    def test_higher_rank_run_spectra(self) -> None:
        cases = (
            ("aabaaabaaaa", 1, 4),
            ("aabaaabaaaa", 2, 3),
            ("aabaaabaaaa", 4, 0),
            ("(?:aab){4}", 4, 2),
            ("(?:a{2}b){3}a{5}", 2, 2),
            ("(?:a{2}b){3}a{5}", 4, 2),
            ("(?:aabaaabaaaa|aaaabaaabaaaa)", 2, 3),
        )
        for pattern, rank, expected in cases:
            with self.subTest(pattern=pattern, rank=rank):
                self.assertEqual(expected, self.exact(pattern, frozenset({A}), rank))

    def test_largest_q_contains_third_order_statistic(self) -> None:
        cases = (
            ("aabaaabaaaa", 2),
            ("aabaaabaaaabaaaaa", 3),
            ("(?:a{2}b){3}a{5}", 2),
            ("(?:a{2}b){2}", 0),
        )
        for pattern, expected in cases:
            with self.subTest(pattern=pattern):
                self.assertEqual(
                    expected,
                    analyze_order_statistic(pattern, {A}, 3).threshold,
                )

    def test_epsilon_language_forces_zero(self) -> None:
        for pattern in ("", "(?:)", "a?", "a*", "a{0,3}", "(?:a|)", "a**"):
            with self.subTest(pattern=pattern):
                self.assertEqual(0, self.exact(pattern, frozenset({A})))

    def test_empty_language_is_typed_not_guessed(self) -> None:
        nonascii = "".join(f"\\x{byte:02x}" for byte in range(0x80, 0x100))
        with self.assertRaises(EmptyLanguage):
            analyze(f"[^[:ascii:]{nonascii}]", {A})

    def test_escaped_singletons_form_specification_derived_ranges(self) -> None:
        assert_class_language(self, r"[\x61-\x63]", frozenset(range(A, C + 1)))
        assert_class_language(self, r"[\x61-c]", frozenset(range(A, C + 1)))
        assert_class_language(self, r"[a-\x63]", frozenset(range(A, C + 1)))
        assert_class_language(self, r"[\--0]", frozenset(range(ord("-"), ord("0") + 1)))

    def test_descending_or_multibyte_range_endpoints_are_rejected(self) -> None:
        for pattern in (
            r"[\x63-\x61]",
            r"[\x63-a]",
            r"[c-\x61]",
            r"[\d-a]",
            r"[a-\d]",
        ):
            with self.subTest(pattern=pattern), self.assertRaises(PatternSyntaxError):
                parse(pattern)

    def test_hyphen_is_literal_at_class_boundaries_or_when_escaped(self) -> None:
        cases = (
            (r"[-\x61]", frozenset(map(ord, "-a"))),
            (r"[\x61-]", frozenset(map(ord, "a-"))),
            (r"[a\-c]", frozenset(map(ord, "a-c"))),
        )
        for pattern, expected in cases:
            with self.subTest(pattern=pattern):
                assert_class_language(self, pattern, expected)


class RefusalTests(unittest.TestCase):
    def test_every_assertion_family_is_explicitly_refused(self) -> None:
        patterns = (
            "^a",
            "a$",
            r"\bword",
            r"\b{start}word",
            r"\Bword",
            r"\<word\>",
            r"\Aword",
            r"word\Z",
            r"word\z",
            r"\Gword",
            r"\Kword",
            r"[\b]",
            "(?=a)a",
            "(?!a)a",
            "(?<=a)a",
            "(?<!a)a",
        )
        for pattern in patterns:
            with (
                self.subTest(pattern=pattern),
                self.assertRaises(PatternRefusal) as caught,
            ):
                analyze(pattern, {A})
            self.assertIsNotNone(caught.exception.construct)

    def test_backreferences_and_unsupported_constructs_are_refused(self) -> None:
        patterns = (
            r"(a)\1",
            r"(a)\g<1>",
            r"(?P<x>a)(?P=x)",
            r"\p{L}",
            r"(?i:a)",
            r"(?-u:a)",
            r"(?>a)",
            r"(*SKIP)(*FAIL)",
            r"[a&&b]",
            r"[a[b]]",
            r"\x{100}",
            "é",
        )
        for pattern in patterns:
            with self.subTest(pattern=pattern), self.assertRaises(PatternRefusal):
                analyze(pattern, {A})

    def test_malformed_patterns_never_return_partial_results(self) -> None:
        for pattern in ("(", "[a", r"\x0", r"\x{}", "a{3,2}", "*a", "a{nope}"):
            with self.subTest(pattern=pattern), self.assertRaises(PatternSyntaxError):
                analyze(pattern, {A})

    def test_resource_limits_are_typed_refusals(self) -> None:
        with self.assertRaises(ResourceLimitExceeded):
            analyze("(" * 129 + "a" + ")" * 129, {A})
        with self.assertRaises(ResourceLimitExceeded):
            analyze("a{1001}", {A})


class IndependentFiniteDifferentialTests(unittest.TestCase):
    def test_exhaustive_small_finite_languages(self) -> None:
        predicates = (
            frozenset(),
            frozenset({A}),
            frozenset({B}),
            frozenset({A, B}),
            frozenset({C}),
        )
        for node in finite_asts():
            expected_language = language(node)
            pattern = render(node)
            machine = compile_nfa(parse(pattern))
            max_length = max(map(len, expected_language))
            for length in range(max_length + 2):
                for word_tuple in itertools.product((A, B), repeat=length):
                    word = bytes(word_tuple)
                    self.assertEqual(
                        word in expected_language,
                        accepts_word(machine, word),
                        ("language", pattern, word),
                    )
            self.assertFalse(accepts_word(machine, b"c" * (max_length + 1)))
            for predicate, rank in itertools.product(predicates, range(1, 5)):
                expected = min(
                    ranked_run(word, predicate, rank) for word in expected_language
                )
                result = (
                    analyze(pattern, predicate, rank)
                    if rank in SUPPORTED_RANKS
                    else analyze_order_statistic(pattern, predicate, rank)
                )
                self.assertEqual(
                    expected,
                    result.threshold,
                    ("threshold", pattern, predicate, rank),
                )


class CLITests(unittest.TestCase):
    def test_contract_predicate_json_is_deterministic(self) -> None:
        first = run_cli("[0-9]{3}", "--predicate", "digit")
        second = run_cli("[0-9]{3}", "--predicate", "digit")
        self.assertEqual(first[1], second[1])
        code, rendered, payload = first
        self.assertEqual(0, code)
        self.assertEqual(sorted(payload), list(payload))
        self.assertEqual(payload, json.loads(rendered))
        self.assertEqual("ok", payload["status"])
        self.assertTrue(payload["exact"])
        self.assertEqual(3, payload["threshold"])
        self.assertEqual(1, payload["rank"])
        self.assertEqual("digit", payload["predicate"]["id"])
        self.assertIsNone(payload["refusal_reason"])
        assert CONTRACT is not None
        self.assertEqual(CONTRACT.sha256, payload["contract"]["sha256"])
        self.assertEqual(15, payload["contract"]["class_count"])
        self.assertEqual([1, 2, 4], payload["contract"]["supported_ranks"])
        self.assertEqual([1, 2, 4, 8], payload["contract"]["supported_budgets"])

    def test_direct_script_output_is_process_deterministic(self) -> None:
        command = (
            sys.executable,
            str(ORACLE_CLI),
            "(?:aaab){2}",
            "--ranges",
            "0x61",
            "--rank",
            "2",
        )
        cwd = tempfile.gettempdir()
        first = subprocess.run(
            command, check=False, capture_output=True, text=True, cwd=cwd
        )
        second = subprocess.run(
            command, check=False, capture_output=True, text=True, cwd=cwd
        )
        self.assertEqual(0, first.returncode)
        self.assertEqual(first.stdout, second.stdout)
        self.assertEqual("", first.stderr)
        self.assertEqual(3, json.loads(first.stdout)["threshold"])

    def test_custom_range_and_supported_higher_ranks(self) -> None:
        self.assertEqual(frozenset(range(65, 91)), parse_ranges("65-90"))
        for pattern, rank, expected in (
            ("(?:aaab){2}", "2", 3),
            ("(?:aaab){4}", "4", 3),
        ):
            code, _, payload = run_cli(
                pattern,
                "--ranges",
                "0x61",
                "--rank",
                rank,
            )
            with self.subTest(rank=rank):
                self.assertEqual(0, code)
                self.assertEqual(expected, payload["threshold"])
                self.assertEqual(int(rank), payload["rank"])
                self.assertIsNone(payload["predicate"]["id"])

    def test_refusal_json_carries_context_and_reason(self) -> None:
        code, _, payload = run_cli(
            "^aaa",
            "--predicate",
            "alpha",
            "--rank",
            "4",
        )
        self.assertEqual(2, code)
        self.assertEqual("refused", payload["status"])
        self.assertFalse(payload["exact"])
        self.assertEqual(4, payload["rank"])
        self.assertEqual("alpha", payload["predicate"]["id"])
        self.assertIsNone(payload["threshold"])
        self.assertIn("zero-width", payload["refusal_reason"])
        self.assertEqual("oracle.pattern_refused", payload["error"]["code"])

    def test_rank_outside_contract_is_an_error(self) -> None:
        code, _, payload = run_cli("a", "--predicate", "alpha", "--rank", "3")
        self.assertEqual(2, code)
        self.assertEqual("error", payload["status"])
        self.assertIsNone(payload["threshold"])
        self.assertIn("1, 2, 4", payload["refusal_reason"])


if __name__ == "__main__":
    unittest.main()
