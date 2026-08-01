"""Fail-closed proofs for the zig-dup detector (`extract_fn_bodies` + grouping)."""

import sys
import unittest
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dup_helper_ratchet import extract_fn_bodies  # noqa: E402

# A substantial body: > 40 non-space chars, 4 statement `;`.
SUBSTANTIAL = (
    "    const a = std.mem.trim(u8, input, whitespace);\n"
    "    const b = try alloc.dupe(u8, a);\n"
    "    counter += b.len;\n"
    "    return b;\n"
)


def _dup_counts(sources: dict[str, str]) -> dict[str, int]:
    """Mirror scan()'s cross-file grouping over in-memory {file: text}."""
    by_body: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    for rel, text in sources.items():
        for fn in extract_fn_bodies(text, where=rel):
            by_body[fn.normalized][rel] += 1
    out: dict[str, int] = defaultdict(int)
    for body_files in by_body.values():
        if len(body_files) < 2:
            continue
        for rel, n in body_files.items():
            out[rel] += n
    return dict(out)


class DupHelperTest(unittest.TestCase):
    def test_identical_substantial_bodies_across_two_files_flagged(self) -> None:
        a = f"fn helperA(input: []const u8) ![]u8 {{\n{SUBSTANTIAL}}}\n"
        b = f"pub fn helperB(input: []const u8) ![]u8 {{\n{SUBSTANTIAL}}}\n"
        self.assertEqual(_dup_counts({"a.zig": a, "b.zig": b}), {"a.zig": 1, "b.zig": 1})

    def test_near_identical_bodies_not_flagged(self) -> None:
        a = f"fn helper(input: []const u8) ![]u8 {{\n{SUBSTANTIAL}}}\n"
        b = a.replace("counter += b.len;", "counter += b.len + 1;")
        self.assertEqual(_dup_counts({"a.zig": a, "b.zig": b}), {})

    def test_single_unique_def_not_flagged(self) -> None:
        a = f"fn helper(input: []const u8) ![]u8 {{\n{SUBSTANTIAL}}}\n"
        self.assertEqual(_dup_counts({"a.zig": a}), {})

    def test_identical_bodies_under_size_threshold_not_flagged(self) -> None:
        tiny = "fn tiny(x: u8) u8 {\n    return x + 1;\n}\n"
        self.assertEqual(_dup_counts({"a.zig": tiny, "b.zig": tiny}), {})

    def test_dup_allow_marked_copy_not_flagged(self) -> None:
        a = f"fn helper(input: []const u8) ![]u8 {{\n{SUBSTANTIAL}}}\n"
        b = (
            "// dup-allow: deliberate twin — kept in lockstep by the parity test\n"
            f"fn helper(input: []const u8) ![]u8 {{\n{SUBSTANTIAL}}}\n"
        )
        self.assertEqual(_dup_counts({"a.zig": a, "b.zig": b}), {})

    def test_same_file_duplicates_not_flagged(self) -> None:
        one = f"fn h1(input: []const u8) ![]u8 {{\n{SUBSTANTIAL}}}\n"
        two = f"fn h2(input: []const u8) ![]u8 {{\n{SUBSTANTIAL}}}\n"
        self.assertEqual(_dup_counts({"a.zig": one + two}), {})

    def test_string_content_differences_stay_distinct(self) -> None:
        # The `{}` is Python's placeholder, not Zig's: the two bodies end up
        # identical apart from the text inside one string literal.
        base = (
            "fn fail(msg: []const u8) noreturn {{\n"
            '    std.debug.print("{}", .{{msg}});\n'
            "    telemetry.flush();\n"
            "    audit.record(msg);\n"
            "    std.process.exit(2);\n"
            "}}\n"
        )
        a = base.format("oom error one padded")
        b = base.format("disk error two padded")
        self.assertEqual(_dup_counts({"a.zig": a, "b.zig": b}), {})

    def test_comment_only_differences_still_flagged(self) -> None:
        a = f"fn helper(input: []const u8) ![]u8 {{\n{SUBSTANTIAL}}}\n"
        b = f"fn helper(input: []const u8) ![]u8 {{\n    // extra note\n{SUBSTANTIAL}}}\n"
        self.assertEqual(_dup_counts({"a.zig": a, "b.zig": b}), {"a.zig": 1, "b.zig": 1})

    def test_unbalanced_braces_fail_closed(self) -> None:
        broken = f"fn helper(input: []const u8) ![]u8 {{\n{SUBSTANTIAL}"  # no closing }
        with self.assertRaises(SystemExit):
            extract_fn_bodies(broken, where="broken.zig")

    def test_braces_inside_strings_do_not_confuse_matching(self) -> None:
        a = (
            "fn helper(input: []const u8) ![]u8 {\n"
            '    const tmpl = "closing } and opening { inside a string";\n'
            f"{SUBSTANTIAL}}}\n"
        )
        self.assertEqual([f.name for f in extract_fn_bodies(a)], ["helper"])


if __name__ == "__main__":
    unittest.main()
