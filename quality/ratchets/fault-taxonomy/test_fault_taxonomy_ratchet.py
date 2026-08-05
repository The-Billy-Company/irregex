"""Detector proofs for zig-fault-taxonomy — what it must catch, and must not.

The adverse cases are the ones that decide whether the ratchet survives contact:
a false positive gets its baseline lifted, which defeats it entirely. So each
exclusion (test vocabulary, private control flow, consuming positions) is pinned
against a *live* production shape taken from the tree, not a toy.
"""

import re
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fault_taxonomy_ratchet import (  # noqa: E402
    _scan_one,
    count_undeclared,
    declared_members,
)

DECLARED = frozenset({"Corrupt", "Truncated", "OutOfMemory", "Unsupported", "GenerationMismatch"})

FAULT_ZIG = Path(__file__).resolve().parents[3] / "src" / "fault.zig"
DOMAIN_SET = re.compile(r"pub const \w+ = error\{([^}]*)\}", re.S)


def source_members() -> frozenset[str]:
    """Every member of every domain set in `src/fault.zig` — the taxonomy itself."""
    body = FAULT_ZIG.read_text(encoding="utf-8")
    return frozenset(
        name.strip() for row in DOMAIN_SET.findall(body) for name in row.split(",") if name.strip()
    )


def total(src: str, declared: frozenset[str] = DECLARED) -> int:
    return count_undeclared(src, declared).total


class ContractTest(unittest.TestCase):
    def test_reads_the_live_contract_block(self) -> None:
        members = declared_members()
        # Each domain's list is exactly the matching `pub const` error set in
        # src/fault.zig, so the claim is asserted against that source rather than
        # against a total somebody has to bump by hand whenever a fault is minted
        # — a number nobody can check is how a contract drifts from its code.
        # Then spot-check the collapse target and the two spellings it replaced.
        self.assertEqual(source_members(), members)
        self.assertTrue(members, "src/fault.zig parsed to nothing — the reader is broken")
        self.assertIn("Corrupt", members)
        self.assertNotIn("BadFormat", members)
        self.assertNotIn("CorruptIndex", members)

    def test_missing_contract_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as td, self.assertRaises(SystemExit):
            declared_members(Path(td) / "absent.toml")

    def test_contract_without_the_block_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "c.toml"
            p.write_text("[exit_codes]\nok = { code = 0 }\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                declared_members(p)


class CaughtTest(unittest.TestCase):
    def test_undeclared_set_member_counted(self) -> None:
        self.assertEqual(1, total("pub const LoadError = error{ BadFormat, OutOfMemory };\n"))

    def test_undeclared_return_counted(self) -> None:
        self.assertEqual(1, total("fn load() !void {\n    return error.CorruptIndex;\n}\n"))

    def test_synonym_on_a_prong_right_hand_side_counted(self) -> None:
        # The api.zig shape: the LHS is handled, the RHS mints a second spelling.
        src = (
            "fn map(e: anyerror) !void {\n"
            "    return switch (e) {\n"
            "        error.Corrupt => error.BadFormat,\n"
            "    };\n"
            "}\n"
        )
        self.assertEqual(1, total(src))

    def test_two_prongs_do_not_mask_the_value_between_them(self) -> None:
        # `error.BadFormat,\n error.Truncated =>` reads like a prong label list;
        # the `=>` before it proves BadFormat is a value, and it must still count.
        src = (
            "fn map(e: anyerror) !void {\n"
            "    return switch (e) {\n"
            "        error.Corrupt => error.BadFormat,\n"
            "        error.Truncated => error.Corrupt,\n"
            "    };\n"
            "}\n"
        )
        self.assertEqual(1, total(src))

    def test_inline_set_in_a_private_signature_still_counted(self) -> None:
        # An inferred error set carries it out of the file, so `fn` privacy is
        # not the same warrant a named private `const` set carries.
        self.assertEqual(1, total("fn walk() error{ NeedFull, OutOfMemory }!void {}\n"))

    def test_per_name_breakdown_is_reported(self) -> None:
        src = "pub const E = error{ BadFrame, BadOpcode, OutOfMemory };\n"
        self.assertEqual(
            {"BadFrame": 1, "BadOpcode": 1},
            dict(count_undeclared(src, DECLARED).by_pattern),
        )


class ExcludedTest(unittest.TestCase):
    def test_declared_members_are_clean(self) -> None:
        src = (
            "pub const P = error{ Corrupt, Truncated };\n"
            "fn f() !void {\n    return error.Corrupt;\n}\n"
        )
        self.assertEqual(0, total(src))

    def test_private_named_const_set_is_control_flow(self) -> None:
        # The PCRE2 shadow rewriter's model shape.
        src = (
            "const Err = error{ Bail, OutOfMemory };\n"
            "fn rewrite() Err!void {\n"
            "    if (true) return error.Bail;\n"
            "}\n"
        )
        self.assertEqual(0, total(src))

    def test_a_public_declaration_defeats_the_private_exemption(self) -> None:
        src = (
            "const Err = error{ Bail };\n"
            "pub const Public = error{ Bail };\n"
            "fn f() !void {\n    return error.Bail;\n}\n"
        )
        self.assertEqual(3, total(src))

    def test_private_name_referenced_from_elsewhere_is_not_exempt(self) -> None:
        # Same source minus the private declaration: the name is now leaking in
        # from another module and must be counted.
        self.assertEqual(1, total("fn f() !void {\n    return error.Bail;\n}\n"))

    def test_switch_prong_label_is_consuming(self) -> None:
        src = (
            "fn read() void {\n"
            "    r.next() catch |e| switch (e) {\n"
            "        error.EndOfStream => {},\n"
            "        else => {},\n"
            "    };\n"
            "}\n"
        )
        self.assertEqual(0, total(src))

    def test_multi_label_prong_is_consuming(self) -> None:
        src = (
            "fn read(e: anyerror) void {\n"
            "    switch (e) {\n"
            "        error.EndOfStream, error.BrokenPipe => {},\n"
            "        else => {},\n"
            "    }\n"
            "}\n"
        )
        self.assertEqual(0, total(src))

    def test_comparison_operand_is_consuming(self) -> None:
        self.assertEqual(
            0, total("fn f(e: anyerror) bool {\n    return e == error.EndOfStream;\n}\n")
        )

    def test_inline_test_block_vocabulary_excluded(self) -> None:
        src = (
            'test "round-trip" {\n'
            "    if (!ok) return error.SkipZigTest;\n"
            "    return error.TestUnexpectedResult;\n"
            "}\n"
        )
        self.assertEqual(0, total(src))

    def test_std_testing_sentinels_excluded_outside_a_test_block(self) -> None:
        # shadow.zig's live shape: a test helper sits beside the tests it serves,
        # in a production file, with no block enclosing it.
        src = (
            "fn expectShadow(pattern: []const u8, want: ?[]const u8) !void {\n"
            "    try t.expectEqualStrings(want orelse return error.TestUnexpectedResult, g);\n"
            "}\n"
        )
        self.assertEqual(0, total(src))

    def test_testing_prefix_exemption_cannot_launder_a_fault_name(self) -> None:
        # `Test` must be followed by a capital — no real fault name qualifies.
        self.assertEqual(2, total("pub const E = error{ Testable, BadFormat };\n"))

    def test_code_after_an_inline_test_block_still_counted(self) -> None:
        src = (
            'test "x" {\n    return error.SkipZigTest;\n}\n'
            "fn f() !void {\n    return error.BadFormat;\n}\n"
        )
        self.assertEqual(1, total(src))

    def test_comment_and_string_mentions_are_prose(self) -> None:
        src = (
            "//! `error.BadFormat` and `error.CorruptIndex` collapse into Corrupt.\n"
            "fn f() void {\n"
            '    const s = "error.CorruptIndex";\n'
            "    _ = s;\n"
            "}\n"
        )
        self.assertEqual(0, total(src))


class StdErrorSetTest(unittest.TestCase):
    """`return error.X` into a std error set — the exclusion, and its fences.

    The exclusion is sound only because the Zig compiler rejects a `return` of
    a name outside the function's declared set, so every adverse case below is
    an arrangement where that guarantee does *not* hold and the name must still
    be counted.
    """

    IMPORT = 'const std = @import("std");\n'
    ALIAS = "pub const MapError = std.posix.MMapError;\n"

    def src(self, *parts: str) -> str:
        return self.IMPORT + self.ALIAS + "".join(parts)

    # ── the shape this exists for ────────────────────────────────────────
    def test_portal_ntmap_shape_excluded(self) -> None:
        # portal.zig's live Windows arm: `MapError` is `std.posix.MMapError`,
        # so these three names are std's, restated because the declared set
        # obliges it — the POSIX arm returns the identical names from inside
        # `std.posix.mmap`, where nothing counts them either.
        src = self.src(
            "fn ntMap(h: Handle, len: usize) MapError!Mapping {\n"
            "    switch (status) {\n"
            "        .INVALID_FILE_FOR_SECTION => return error.MemoryMappingNotSupported,\n"
            "        .CONFLICTING_ADDRESSES => return error.MappingAlreadyExists,\n"
            "        .SECTION_PROTECTION => return error.PermissionDenied,\n"
            "        else => {},\n"
            "    }\n"
            "}\n"
        )
        self.assertEqual(0, total(src))

    def test_unaliased_std_path_excluded(self) -> None:
        src = self.IMPORT + (
            "fn m() std.posix.MMapError!void {\n    return error.PermissionDenied;\n}\n"
        )
        self.assertEqual(0, total(src))

    def test_head_alias_resolves(self) -> None:
        # `const posix = std.posix;` — the same fact spelled one level up.
        src = self.IMPORT + (
            "const posix = std.posix;\n"
            "fn m() posix.MMapError!void {\n    return error.PermissionDenied;\n}\n"
        )
        self.assertEqual(0, total(src))

    # ── the exclusion is per function, not per file ──────────────────────
    def test_a_sibling_function_in_the_same_file_is_still_checked(self) -> None:
        # The whole-file-amnesty failure mode: one legitimately excluded
        # std-set function must not cover a new spelling accreting beside it.
        src = self.src(
            "fn m() MapError!void {\n    return error.PermissionDenied;\n}\n",
            "fn load() LoadError!void {\n    return error.BadFormat;\n}\n",
        )
        self.assertEqual(1, total(src))

    def test_nested_fn_cannot_shelter_under_its_parent(self) -> None:
        # Judged innermost-first, so wrapping new vocabulary in a closure
        # inside a std-set body buys nothing.
        src = self.src(
            "fn m() MapError!void {\n"
            "    const S = struct {\n"
            "        fn inner() !void {\n            return error.BadFormat;\n        }\n"
            "    };\n"
            "    _ = S;\n"
            "    return error.PermissionDenied;\n"
            "}\n"
        )
        self.assertEqual(1, total(src))

    def test_inferred_error_set_is_never_excluded(self) -> None:
        # `!void` infers its set from whatever the body returns — the opposite
        # of a closed vocabulary, so the compiler proves nothing here.
        src = self.src("fn m() !void {\n    return error.BadFormat;\n}\n")
        self.assertEqual(1, total(src))

    # ── gaming vectors ───────────────────────────────────────────────────
    def test_a_private_set_named_like_the_alias_is_not_std(self) -> None:
        src = self.IMPORT + (
            "pub const MapError = error{ BadFormat };\n"
            "fn m() MapError!void {\n    return error.BadFormat;\n}\n"
        )
        self.assertEqual(2, total(src))

    def test_rebinding_the_alias_anywhere_defeats_it(self) -> None:
        # A second `const MapError = …` in an inner scope shadows the file-scope
        # one, and nothing textual can say which binding a signature saw — so an
        # ambiguously-bound name resolves to nothing rather than to std.
        src = self.src(
            "fn m() MapError!void {\n"
            "    const MapError = shim.MapError;\n"
            "    _ = MapError;\n"
            "    return error.Sneaky;\n"
            "}\n"
        )
        self.assertEqual(1, total(src))

    def test_a_union_with_a_private_set_is_not_a_std_set(self) -> None:
        # `std.posix.MMapError || error{ Sneaky }` would admit a private name
        # into a signature that still reads as std's.
        src = self.IMPORT + (
            "pub const MapError = std.posix.MMapError || error{ Sneaky };\n"
            "fn m() MapError!void {\n    return error.Sneaky;\n}\n"
        )
        self.assertEqual(2, total(src))

    def test_std_rebound_to_a_local_module_stands_the_rule_down(self) -> None:
        src = (
            'const std = @import("shim.zig");\n'
            "pub const MapError = std.posix.MMapError;\n"
            "fn m() MapError!void {\n    return error.Sneaky;\n}\n"
        )
        self.assertEqual(1, total(src))

    def test_one_bad_std_binding_stands_the_whole_file_down(self) -> None:
        # A second, inner `std` shadows the real one for part of the file, and
        # nothing textual says which part — so any file that binds `std` to
        # something other than std loses the rule outright.
        src = self.src(
            "fn m() MapError!void {\n"
            '    const std = @import("shim.zig");\n'
            "    _ = std;\n"
            "    return error.Sneaky;\n"
            "}\n"
        )
        self.assertEqual(1, total(src))

    def test_a_file_that_never_binds_std_gets_no_exclusion(self) -> None:
        src = (
            "pub const MapError = std.posix.MMapError;\n"
            "fn m() MapError!void {\n    return error.Sneaky;\n}\n"
        )
        self.assertEqual(1, total(src))

    def test_an_alias_cycle_terminates_without_excluding(self) -> None:
        src = self.IMPORT + (
            "const A = B;\nconst B = A;\nfn m() A!void {\n    return error.BadFormat;\n}\n"
        )
        self.assertEqual(1, total(src))

    # ── only the position the compiler checks ────────────────────────────
    def test_a_value_that_is_not_returned_is_still_counted(self) -> None:
        # Bound to a local, so it is never coerced into the declared set.
        src = self.src(
            "fn m() MapError!void {\n"
            "    const e = error.BadFormat;\n"
            "    _ = e;\n"
            "    return error.PermissionDenied;\n"
            "}\n"
        )
        self.assertEqual(1, total(src))

    def test_a_set_declared_inside_a_std_set_body_is_still_counted(self) -> None:
        # A declaration is not a `return`, so the enclosing signature says
        # nothing about it — this one escapes the file and must be counted.
        src = self.src(
            "fn m() MapError!void {\n"
            "    const S = struct {\n        pub const E = error{ BadFormat };\n    };\n"
            "    _ = S;\n"
            "    return error.PermissionDenied;\n"
            "}\n"
        )
        self.assertEqual(1, total(src))

    # ── parsing fences: neither shape declares a body ────────────────────
    def test_a_function_typed_parameter_is_not_an_enclosing_body(self) -> None:
        src = self.src(
            "fn take(comptime f: fn (u8) MapError!void) !void {\n"
            "    _ = f;\n"
            "    return error.BadFormat;\n"
            "}\n"
        )
        self.assertEqual(1, total(src))

    def test_a_prototype_is_not_an_enclosing_body(self) -> None:
        src = self.src(
            "pub const Mapper = fn (u8) MapError!void;\n"
            "fn g() !void {\n    return error.BadFormat;\n}\n"
        )
        self.assertEqual(1, total(src))


class ScanOneTest(unittest.TestCase):
    def test_generated_header_skipped(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "x.zig"
            p.write_text(
                "// Code generated by tool. DO NOT EDIT.\npub const E = error{ BadFormat };\n",
                encoding="utf-8",
            )
            self.assertIsNone(_scan_one(p, DECLARED))

    def test_unreadable_file_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "x.zig"
            p.write_bytes(b"\xff\xfe\x00bad utf8 \xff")
            with self.assertRaises(SystemExit):
                _scan_one(p, DECLARED)


if __name__ == "__main__":
    unittest.main()
