"""Fail-closed proofs for the cross-binding gate (`exported` / `audit` / waivers).

The gate's whole value is that it fails on the drift that actually happened, so
these are written as the historical gaps: Go without the windowed plane, Rust
with a cancellation field and no way to fill it, a new plane landing in one
binding. If a change makes the gate pass those, the gate is decoration.
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check import audit, contract_faults, declared, exported, mentioned  # noqa: E402

# A header that declares everything, so header drift never confounds a
# binding-coverage assertion. The one test that is about the header says so.
WHOLE = "int32_t irgx_compile(); int32_t irgx_munch_scan(); void irgx_cancel_free();"


def contract(bindings=("go", "rust"), waived=None):
    return {
        "bindings": {
            b: {"sources": f"bindings/{b}", "suffix": ".x", "why": "because"} for b in bindings
        },
        "waived": {b: dict(rows) for b, rows in (waived or {}).items()},
    }


class ExtractTest(unittest.TestCase):
    def test_only_export_fn_is_the_abi(self) -> None:
        # A `pub fn` is Zig-internal and produces no C symbol; only `export fn`
        # is a promise to a linker, which is why the authority is this and not
        # the header a human maintains beside it.
        src = "pub fn helper() void {}\nexport fn irgx_compile() i32 {}\n"
        self.assertEqual(exported(src), {"irgx_compile"})

    def test_an_indented_export_still_counts(self) -> None:
        # Exports live inside `comptime` blocks in places; the linker does not
        # care about the indentation and neither may the extractor.
        self.assertEqual(exported("    export fn irgx_free() void {}\n"), {"irgx_free"})

    def test_a_mention_in_any_language_is_coverage(self) -> None:
        # cgo, ctypes and `extern "C"` spell a call three ways and all three
        # name the symbol — which is what makes one text rule serve all of them.
        # Type names come along (`irgx_cancel` here) and are harmless: the gate
        # only ever asks about names the ABI exports, and a type is not one.
        self.assertEqual(mentioned(["st := C.irgx_compile(p)"], ".go"), {"irgx_compile"})
        self.assertEqual(
            mentioned(["lib.irgx_munch_scan.restype = ctypes.c_int32"], ".py"),
            {"irgx_munch_scan"},
        )
        self.assertEqual(
            mentioned(["pub fn irgx_cancel_new(out: *mut *mut irgx_cancel) -> i32;"], ".rs"),
            {"irgx_cancel_new", "irgx_cancel"},
        )

    def test_prose_about_a_symbol_is_not_coverage(self) -> None:
        # The false pass this gate would otherwise hand itself. `sys.rs` really
        # does carry a sentence explaining why `irgx_find_all` is not declared,
        # and reading it as a binding would excuse the very gap it describes. A
        # deliberate omission belongs in [waived], where a reviewer sees it.
        self.assertEqual(mentioned(["// irgx_find_all is deliberately absent"], ".rs"), set())
        self.assertEqual(mentioned(["/* irgx_find_all is absent */"], ".rs"), set())
        self.assertEqual(mentioned(["# irgx_find_all is absent"], ".py"), set())

    def test_the_cgo_preamble_is_code_and_not_prose(self) -> None:
        # The inverse false failure, and a real one: cgo's preamble is SPELLED as
        # a block comment and compiled as C, and it is the only place Go's
        # binding calls the engine — every call goes through a static shim there
        # so the fault read stays on the pinned thread. Blanking it reported Go,
        # which reaches the whole ABI, as reaching none of it.
        go = '/*\n#include "irgx.h"\nstatic int32_t go_c(void) { return irgx_compile(); }\n*/\nimport "C"\n'
        self.assertEqual(mentioned([go], ".go"), {"irgx_compile"})
        # Only the block `import "C"` follows is compiled, so Go prose is prose.
        self.assertEqual(mentioned(["/* irgx_compile is absent */\nfunc f() {}"], ".go"), set())

    def test_the_header_is_read_the_same_way(self) -> None:
        self.assertEqual(declared("void irgx_free(irgx_regex *re);"), {"irgx_free", "irgx_regex"})


class CoverageTest(unittest.TestCase):
    def test_a_new_plane_in_one_binding_only_is_the_drift_this_gate_exists_for(self) -> None:
        # Exactly what happened: munch landed in Rust and the other two bindings
        # stayed silently blind to it.
        drift = audit(
            {"irgx_compile", "irgx_munch_scan"},
            WHOLE,
            {"go": {"irgx_compile"}, "rust": {"irgx_compile", "irgx_munch_scan"}},
            contract(),
        )
        self.assertEqual(len(drift), 1)
        self.assertIn("go: `irgx_munch_scan`", drift[0])

    def test_a_type_bound_without_its_constructors_does_not_count(self) -> None:
        # Rust's real bug: it named the opaque `irgx_cancel` type and threaded a
        # pointer to it through its own request struct, so the surface looked
        # present while the three functions that make one were never bound. The
        # gate judges the symbols the ABI exports, which a type name is not.
        drift = audit(
            {"irgx_cancel_free"},
            WHOLE,
            {"rust": {"irgx_cancel"}},
            contract(bindings=("rust",)),
        )
        self.assertEqual(len(drift), 1)
        self.assertIn("irgx_cancel_free", drift[0])

    def test_parity_is_clean_when_every_binding_reaches_everything(self) -> None:
        self.assertEqual(
            audit(
                {"irgx_compile"},
                WHOLE,
                {"go": {"irgx_compile"}, "rust": {"irgx_compile"}},
                contract(),
            ),
            [],
        )

    def test_an_exported_symbol_no_header_declares_is_unreachable(self) -> None:
        drift = audit({"irgx_secret"}, WHOLE, {}, contract(bindings=()))
        self.assertEqual(len(drift), 1)
        self.assertIn("no C host", drift[0])


class WaiverTest(unittest.TestCase):
    def test_a_waiver_excuses_the_gap_it_names(self) -> None:
        self.assertEqual(
            audit(
                {"irgx_compile", "irgx_munch_scan"},
                WHOLE,
                {"go": {"irgx_compile"}},
                contract(bindings=("go",), waived={"go": {"irgx_munch_scan": {"why": "b"}}}),
            ),
            [],
        )

    def test_a_waiver_for_a_symbol_the_binding_does_bind_is_stale(self) -> None:
        # A waiver kept past its gap reads as a live design decision, which is
        # how a reviewer learns to skim the block.
        drift = audit(
            {"irgx_compile"},
            WHOLE,
            {"go": {"irgx_compile"}},
            contract(bindings=("go",), waived={"go": {"irgx_compile": {"why": "b"}}}),
        )
        self.assertEqual(len(drift), 1)
        self.assertIn("does bind it", drift[0])

    def test_a_waiver_for_a_symbol_the_abi_dropped_is_stale(self) -> None:
        drift = audit(
            {"irgx_compile"},
            WHOLE,
            {"go": {"irgx_compile"}},
            contract(bindings=("go",), waived={"go": {"irgx_gone": {"why": "b"}}}),
        )
        self.assertEqual(len(drift), 1)
        self.assertIn("no longer exports", drift[0])

    def test_a_waiver_without_a_why_is_a_contract_fault(self) -> None:
        c = contract(bindings=("go",), waived={"go": {"irgx_x": {"why": "  "}}})
        self.assertTrue(any("no `why`" in f for f in contract_faults(c)))

    def test_a_waiver_for_an_unknown_binding_is_a_contract_fault(self) -> None:
        c = contract(bindings=("go",), waived={"elixir": {"irgx_x": {"why": "b"}}})
        self.assertTrue(any("not a binding" in f for f in contract_faults(c)))

    def test_a_binding_row_missing_a_field_is_a_contract_fault(self) -> None:
        c = contract(bindings=("go",))
        del c["bindings"]["go"]["sources"]
        self.assertTrue(any("no `sources`" in f for f in contract_faults(c)))


class ShippedArchiveTest(unittest.TestCase):
    """The second lane: a binding that ships the engine must ship a current one."""

    def test_an_archive_behind_the_engine_fails_and_says_how_to_rebuild(self) -> None:
        # Exactly what happened, and it reached the linker rather than a gate:
        # the munch plane landed, the committed archives stayed a release behind,
        # and the default `go test` path died on undefined symbols while the
        # source-built path was green.
        drift = audit(
            {"irgx_compile", "irgx_munch_scan"},
            WHOLE,
            {"go": {"irgx_compile", "irgx_munch_scan"}},
            contract(bindings=("go",)),
            {"go": {"libirgx_darwin_arm64.a": {"irgx_compile"}}},
        )
        self.assertEqual(len(drift), 1)
        self.assertIn("libirgx_darwin_arm64.a", drift[0])
        self.assertIn("irgx_munch_scan", drift[0])
        self.assertIn("vendor_libraries.py", drift[0])

    def test_the_binding_being_correct_does_not_excuse_a_stale_archive(self) -> None:
        # The two lanes are independent, which is the whole point: Go's sources
        # named every munch symbol perfectly while the bytes it ships had none of
        # them, so a source-only gate passed the broken build.
        source_clean = {"go": {"irgx_compile", "irgx_munch_scan"}}
        self.assertEqual(
            audit({"irgx_compile", "irgx_munch_scan"}, WHOLE, source_clean, contract(("go",))),
            [],
        )
        self.assertEqual(
            len(
                audit(
                    {"irgx_compile", "irgx_munch_scan"},
                    WHOLE,
                    source_clean,
                    contract(("go",)),
                    {"go": {"libirgx_linux_amd64.a": {"irgx_compile"}}},
                )
            ),
            1,
        )

    def test_a_waiver_does_not_reach_the_archive_lane(self) -> None:
        # A waiver says what the HOST does instead; an archive is not a host, it
        # is the engine, and the engine either compiled the plane in or is old.
        # Letting a waiver excuse a missing symbol here would mean Rust's
        # `irgx_slate_len` waiver could hide a whole stale build.
        drift = audit(
            {"irgx_compile", "irgx_slate_len"},
            WHOLE + " int32_t irgx_slate_len();",
            {"go": {"irgx_compile"}},
            contract(bindings=("go",), waived={"go": {"irgx_slate_len": {"why": "a field"}}}),
            {"go": {"libirgx_darwin_arm64.a": {"irgx_compile"}}},
        )
        self.assertEqual(len(drift), 1)
        self.assertIn("irgx_slate_len", drift[0])

    def test_a_current_archive_is_silent(self) -> None:
        self.assertEqual(
            audit(
                {"irgx_compile"},
                WHOLE,
                {"go": {"irgx_compile"}},
                contract(bindings=("go",)),
                {"go": {"libirgx_darwin_arm64.a": {"irgx_compile", "irgx_extra"}}},
            ),
            [],
        )

    def test_one_archive_is_reported_once_however_many_symbols_it_lacks(self) -> None:
        # A stale archive is one fact and one command, not ninety findings.
        abi = {f"irgx_s{n}" for n in range(9)}
        drift = audit(
            abi,
            " ".join(f"void {s}();" for s in abi),
            {"go": abi},
            contract(bindings=("go",)),
            {"go": {"libirgx_darwin_arm64.a": set()}},
        )
        self.assertEqual(len(drift), 1)
        self.assertIn("missing 9 ABI symbol(s)", drift[0])
        self.assertIn("+5 more", drift[0])

    def test_an_archives_glob_matching_nothing_is_a_contract_fault(self) -> None:
        # The lane's own false pass: rename the archives and a silent glob reads
        # none of them and approves everything.
        c = contract(bindings=("go",))
        c["bindings"]["go"]["archives"] = "bindings/go/libirgx_nope_*.a"
        self.assertTrue(any("matches no file" in f for f in contract_faults(c)))

    def test_a_scan_of_bytes_holding_no_symbols_finds_none(self) -> None:
        # The negative control the fixtures above assume: the reader answers from
        # the bytes it was given, so an empty answer is possible at all.
        from check import carried  # noqa: PLC0415

        self.assertEqual(carried(b"\x7fELF\x00\x00 no symbols in here \x00"), set())

    def test_the_real_committed_archives_carry_the_real_abi(self) -> None:
        # The lane wired to the tree rather than to a fixture, so a rename of the
        # archives, or a new export nobody re-vendored for, is caught here and
        # not at somebody's linker. One archive per platform the matrix declares.
        from check import EXPORTS, archives_of  # noqa: PLC0415

        abi = exported(EXPORTS.read_text(encoding="utf-8"))
        found = archives_of({"archives": "bindings/go/libirgx_*.a"})
        self.assertEqual(len(found), 6, "the vendor matrix declares six platforms")
        for name, names in sorted(found.items()):
            self.assertEqual(abi - names, set(), f"{name} is behind the engine")


if __name__ == "__main__":
    unittest.main()
