"""Fail-closed proofs for the export gate (`exports` / `tiers` / `audit`)."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check import audit, declared, doors, exports, promises, release, schedule, tiers  # noqa: E402


def contract(stable=None, provisional=None, internal=None):
    def rows(names):
        return {n: {"why": "because"} for n in (names or ())}

    return {
        "stable": rows(stable),
        "provisional": rows(provisional),
        "internal": rows(internal),
    }


def zon(version):
    return f'.{{\n    .name = .irregex,\n    .version = "{version}",\n}}\n'


class ExportsTest(unittest.TestCase):
    def test_top_level_const_and_fn_are_both_exports(self) -> None:
        src = 'pub const mark = @import("mark.zig");\npub fn fatal() void {}\n'
        self.assertEqual(exports(src), {"mark", "fatal"})

    def test_indented_pub_is_a_namespaces_own_business(self) -> None:
        # What `deprecated` exposes under its own door is not the root surface.
        src = "pub const deprecated = struct {\n    pub const crest = math.crest;\n};\n"
        self.assertEqual(exports(src), {"deprecated"})

    def test_non_pub_declaration_is_not_an_export(self) -> None:
        src = 'const private = @import("x.zig");\npub const Span = mark.Span;\n'
        self.assertEqual(exports(src), {"Span"})


class TiersTest(unittest.TestCase):
    def test_a_name_in_two_tiers_is_a_contract_fault(self) -> None:
        c = contract(stable=["mark"], provisional=["mark"])
        _, faults = tiers(c)
        self.assertTrue(any("both" in f for f in faults))

    def test_a_row_without_a_why_is_a_contract_fault(self) -> None:
        c = contract(stable=["mark"])
        c["stable"]["mark"] = {"why": "   "}
        _, faults = tiers(c)
        self.assertTrue(any("answers nobody" in f for f in faults))

    def test_a_missing_tier_table_is_a_contract_fault(self) -> None:
        c = contract(stable=["mark"])
        del c["internal"]
        _, faults = tiers(c)
        self.assertTrue(any("[internal]" in f for f in faults))

    def test_an_empty_now_is_a_contract_fault(self) -> None:
        c = contract(internal=["crest"])
        c["internal"]["crest"] = {"why": "retired spelling", "now": ""}
        _, faults = tiers(c)
        self.assertTrue(any("`now` is empty" in f for f in faults))


class AuditTest(unittest.TestCase):
    def test_a_declared_surface_is_clean(self) -> None:
        drift, faults = audit("pub const mark = m;\n", contract(stable=["mark"]))
        self.assertEqual((drift, faults), ([], []))

    def test_a_new_export_with_no_row_is_drift(self) -> None:
        src = "pub const mark = m;\npub const smuggled = s;\n"
        drift, _ = audit(src, contract(stable=["mark"]))
        self.assertTrue(any("smuggled" in d and "undeclared" in d for d in drift))

    def test_a_row_whose_name_left_the_root_is_drift(self) -> None:
        drift, _ = audit("pub const mark = m;\n", contract(stable=["mark", "gone"]))
        self.assertTrue(any("gone" in d and "does not export" in d for d in drift))

    def test_a_retired_spelling_pointing_nowhere_is_drift(self) -> None:
        c = contract(stable=["mark"], internal=["crest"])
        c["internal"]["crest"] = {"why": "retired", "now": "math.crest"}
        drift, _ = audit("pub const mark = m;\npub const crest = c;\n", c)
        self.assertTrue(any("math.crest" in d for d in drift))

    def test_a_retired_spelling_pointing_at_a_live_door_is_clean(self) -> None:
        c = contract(stable=["mark", "math"], internal=["crest"])
        c["internal"]["crest"] = {"why": "retired", "now": "math.crest"}
        src = "pub const mark = m;\npub const math = mm;\npub const crest = c;\n"
        self.assertEqual(audit(src, c), ([], []))

    def test_a_broken_contract_reports_itself_and_not_phantom_drift(self) -> None:
        # Every export looks undeclared when the tables are unreadable; saying so
        # would bury the one fault that caused it.
        c = contract(stable=["mark"])
        del c["stable"]
        drift, faults = audit("pub const mark = m;\n", c)
        self.assertEqual(drift, [])
        self.assertTrue(faults)


class ReleaseTest(unittest.TestCase):
    def test_a_plain_version_parses_to_numbers(self) -> None:
        self.assertEqual(release(zon("1.2.3")), (1, 2, 3))

    def test_a_prerelease_or_build_tag_is_dropped(self) -> None:
        self.assertEqual(release(zon("2.0.0-rc.1")), (2, 0, 0))
        self.assertEqual(release(zon("2.0.0+deadbeef")), (2, 0, 0))

    def test_a_manifest_with_no_version_is_a_fault_not_a_guess(self) -> None:
        with self.assertRaises(ValueError):
            release(".{\n    .name = .irregex,\n}\n")


class ScheduleTest(unittest.TestCase):
    def retired(self, remove_in=None):
        c = contract(stable=["math"], internal=["crest"])
        c["internal"]["crest"] = {"why": "retired", "now": "math.crest"}
        if remove_in is not None:
            c["deprecation"] = {"remove_in": remove_in}
        return c

    def test_a_target_ahead_of_the_live_version_is_clean(self) -> None:
        self.assertEqual(schedule(self.retired("2.0.0"), (1, 0, 0)), [])

    def test_a_target_the_package_already_passed_is_a_fault(self) -> None:
        # The bug this check exists for: 0.5.0 on a package shipping 1.0.0.
        faults = schedule(self.retired("0.5.0"), (1, 0, 0))
        self.assertTrue(any("cannot come" in f for f in faults))

    def test_a_target_equal_to_the_live_version_is_a_fault(self) -> None:
        # Due "at 1.0.0" while 1.0.0 is what shipped means it never came due.
        self.assertTrue(schedule(self.retired("1.0.0"), (1, 0, 0)))

    def test_retired_spellings_with_no_schedule_are_a_fault(self) -> None:
        faults = schedule(self.retired(), (1, 0, 0))
        self.assertTrue(any("remove_in" in f for f in faults))

    def test_an_unparseable_target_is_a_fault_not_a_crash(self) -> None:
        self.assertTrue(schedule(self.retired("someday"), (1, 0, 0)))

    def test_no_retired_spellings_needs_no_schedule(self) -> None:
        self.assertEqual(schedule(contract(stable=["mark"]), (1, 0, 0)), [])

    def test_audit_without_a_manifest_skips_the_schedule(self) -> None:
        # The pure-drift call sites stay usable without a manifest to read.
        c = self.retired("0.5.0")
        src = "pub const crest = c;\npub const math = m;\n"
        self.assertEqual(audit(src, c), ([], []))
        self.assertTrue(audit(src, c, zon("1.0.0"))[1])


class PromisesTest(unittest.TestCase):
    SHIPPED = "pub const regex_dfa = d;\npub const mark = m;\n"
    DROPPED = "pub const mark = m;\n"

    @staticmethod
    def removed(**rows):
        return {**contract(stable=["mark"]), "removed": rows}

    def test_keeping_every_shipped_name_is_clean(self) -> None:
        kept = self.SHIPPED + "pub const regex = r;\n"
        self.assertEqual(promises(self.SHIPPED, kept, self.removed()), [])

    def test_dropping_a_shipped_name_undeclared_is_a_fault(self) -> None:
        faults = promises(self.SHIPPED, self.DROPPED, self.removed())
        self.assertTrue(faults)
        self.assertIn("regex_dfa", faults[0])

    def test_declaring_the_removal_licenses_it(self) -> None:
        rows = self.removed(regex_dfa={"why": "now regex.dfa"})
        self.assertEqual(promises(self.SHIPPED, self.DROPPED, rows), [])

    def test_a_declared_removal_must_say_what_replaced_it(self) -> None:
        # A row with no `why` is the removal recorded and unexplained, which is
        # the state a consumer reading the release notes cannot act on.
        for row in ({"why": "  "}, {}, "regex.dfa"):
            faults = promises(self.SHIPPED, self.DROPPED, self.removed(regex_dfa=row))
            self.assertTrue(any("no `why`" in f for f in faults), row)

    def test_a_row_for_a_name_the_release_never_exported_is_stale(self) -> None:
        # The break already shipped: the released surface does not export it
        # either, so the row is carried forever describing nothing.
        rows = self.removed(long_gone={"why": "left in 0.9"})
        faults = promises(self.SHIPPED, self.SHIPPED, rows)
        self.assertTrue(any("long_gone" in f and "delete" in f for f in faults))

    def test_a_name_kept_only_as_a_retired_alias_still_counts_as_kept(self) -> None:
        # The alias IS the compatibility, so its spelling at the root is enough.
        alias = "pub const mark = m;\npub const regex_dfa = regex.dfa;\n"
        self.assertEqual(promises(self.SHIPPED, alias, self.removed()), [])

    def test_adding_names_is_never_a_break(self) -> None:
        grown = self.SHIPPED + "pub const slate = s;\npub const scan = sc;\n"
        self.assertEqual(promises(self.SHIPPED, grown, self.removed()), [])

    def test_audit_without_a_shipped_surface_skips_the_semver_arm(self) -> None:
        c = contract(stable=["mark"])
        self.assertEqual(audit("pub const mark = m;\n", c, zon("1.0.0")), ([], []))


class DoorTest(unittest.TestCase):
    """The step between the two existing gates: a plane with no way into C.

    Written as the drift that happened. `corpus`, `walk`, `sieve` and `codex`
    were finished, tested, exported to Zig, and reachable from no other language
    for as long as nobody compared these two files.
    """

    HEADER = "int32_t irgx_walk_open(void);\nint32_t irgx_compile(void);\n"

    def with_doors(self, open_doors=None, shut=None, **tiers_):
        c = contract(**tiers_)
        c["door"] = dict(open_doors or {})
        c["door"]["none"] = {n: {"why": "because"} for n in (shut or ())}
        return c

    def tier_of(self, **kwargs):
        return {n: tier for tier, names in kwargs.items() for n in names}

    def test_a_plane_with_no_row_fails(self) -> None:
        # The historical hole, stated: an export nobody asked "and from C?" of.
        c = self.with_doors({"regex": "irgx_compile"}, stable=["regex", "corpus"])
        faults = doors(c, self.tier_of(stable=["regex", "corpus"]), self.HEADER)
        self.assertEqual(len(faults), 1)
        self.assertIn("`corpus`", faults[0])

    def test_a_door_the_header_does_not_declare_fails(self) -> None:
        # A row is only worth having if the symbol it names can be linked.
        c = self.with_doors({"corpus": "irgx_corpus_open"}, stable=["corpus"])
        faults = doors(c, self.tier_of(stable=["corpus"]), self.HEADER)
        self.assertEqual(len(faults), 1)
        self.assertIn("does not", faults[0])

    def test_a_door_named_only_in_a_comment_is_not_a_door(self) -> None:
        # This header carries a paragraph naming the doorless planes. A rule that
        # read prose would take that paragraph as proof they have doors.
        header = "/* irgx_rank_fuse has no C door on purpose. */\nint32_t irgx_compile(void);\n"
        self.assertEqual(declared(header), {"irgx_compile"})
        c = self.with_doors({"rank": "irgx_rank_fuse"}, provisional=["rank"])
        self.assertEqual(len(doors(c, self.tier_of(provisional=["rank"]), header)), 1)

    def test_no_door_without_a_reason_fails(self) -> None:
        c = self.with_doors(shut=["rank"], provisional=["rank"])
        c["door"]["none"]["rank"] = {"why": "  "}
        faults = doors(c, self.tier_of(provisional=["rank"]), self.HEADER)
        self.assertEqual(len(faults), 1)
        self.assertIn("what a C host does instead", faults[0])

    def test_a_name_in_both_tables_fails(self) -> None:
        c = self.with_doors({"regex": "irgx_compile"}, shut=["regex"], stable=["regex"])
        faults = doors(c, self.tier_of(stable=["regex"]), self.HEADER)
        self.assertTrue(any("either has a way in or it does not" in f for f in faults))

    def test_an_internal_name_may_not_answer_here(self) -> None:
        # `inner` promises nothing, so "can C reach it" is nobody's question.
        c = self.with_doors({"inner": "irgx_compile"}, internal=["inner"])
        faults = doors(c, self.tier_of(internal=["inner"]), self.HEADER)
        self.assertEqual(len(faults), 1)
        self.assertIn("promise nothing", faults[0])

    def test_a_row_for_a_name_nothing_exports_fails(self) -> None:
        c = self.with_doors({"crest": "irgx_compile"}, stable=[])
        faults = doors(c, {}, self.HEADER)
        self.assertEqual(len(faults), 1)
        self.assertIn("not a promised export", faults[0])


class LiveSurfaceTest(unittest.TestCase):
    def test_the_committed_root_matches_the_committed_contract(self) -> None:
        # Tier parity and the schedule only; the semver arm is the gate's own
        # run, which needs a release tag this assertion should not depend on.
        import tomllib

        repo = Path(__file__).resolve().parents[2]
        c = tomllib.loads((repo / "contract" / "exports.toml").read_text(encoding="utf-8"))
        src = (repo / "src" / "root.zig").read_text(encoding="utf-8")
        manifest = (repo / "build.zig.zon").read_text(encoding="utf-8")
        header = (repo / "include" / "irgx.h").read_text(encoding="utf-8")
        self.assertEqual(audit(src, c, manifest, None, None, header), ([], []))

    def test_every_promised_plane_answers_for_C(self) -> None:
        # The live wiring of the lane above: 38 promised exports, each either
        # naming a symbol the real header declares or saying why it has none.
        import tomllib

        repo = Path(__file__).resolve().parents[2]
        c = tomllib.loads((repo / "contract" / "exports.toml").read_text(encoding="utf-8"))
        tier_of, _ = tiers(c)
        header = (repo / "include" / "irgx.h").read_text(encoding="utf-8")
        self.assertEqual(doors(c, tier_of, header), [])
        answered = {k for k in c["door"] if k != "none"} | set(c["door"]["none"])
        promised = {n for n, t in tier_of.items() if t in ("stable", "provisional")}
        self.assertEqual(answered, promised)


if __name__ == "__main__":
    unittest.main()
