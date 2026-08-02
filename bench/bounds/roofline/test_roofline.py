import importlib.util
import tempfile
import unittest
from pathlib import Path

# Load the sibling report.py under a unique module name: three report.py modules
# now live under bounds/, and a bare `import report` would collide in sys.modules
# with dominance/evaluate/report.py under pytest's prepend import mode.
_spec = importlib.util.spec_from_file_location(
    "roofline_report", Path(__file__).resolve().parent / "report.py"
)
roofline_report = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(roofline_report)


def fixture(scan_gbps: float, *, ladder: bool = True) -> dict:
    roof = {
        "machine": "test",
        "zig": "test",
        "clock": {"ghz": 4.0, "measured": True, "source": "measured", "meter": "test"},
        "derived_cyc_per_byte": {
            "basis": "measured clock GHz ÷ measured tier GB/s",
            "ghz": 4.0,
            "dram_ceiling": 0.04,
            "l2_ceiling": 0.0267,
        },
        "corpus_mib": 512,
        "tiers": [
            {"name": "L1", "gbps": 200},
            {"name": "L2", "gbps": 150},
            {"name": "DRAM", "gbps": 100},
        ],
        "gist_scan": [
            {
                "needle": "absent",
                "kind": "full-scan (0 matches, pure streaming)",
                "gbps": scan_gbps,
            }
        ],
    }
    if ladder:
        roof["matched_ladder"] = [
            {"name": "matched dual-window control", "gbps": 50},
            {"name": "production contiguous", "gbps": 45},
        ]
    return roof


class DenominatorTest(unittest.TestCase):
    """The ladder's denominator is the corpus-sized roof, never the DRAM tier.

    Guards the recorded defect: dividing a scan rung by the 512 MiB
    uniform-random tier folds kernel, working-set size, and byte content into
    one "headroom" number. The two roofs are deliberately far apart here, so a
    regression to the wrong divisor flips the verdict rather than nudging it.
    """

    def test_corpus_sized_roof_is_the_divisor_when_present(self) -> None:
        roof = fixture(60)
        roof["roof_gbps"] = 70.0  # DRAM tier is 100 — the wrong divisor reads 60%
        report = roofline_report.render(roof, [], None)

        self.assertIn("86% of the 70.0 GB/s", report)
        self.assertIn("near the measured roof", report)
        self.assertIn("corpus-sized roof", report)

    def test_legacy_artifact_without_a_roof_keeps_the_old_divisor(self) -> None:
        report = roofline_report.render(fixture(35), [], None)

        self.assertIn("35% of the 100.0 GB/s", report)
        self.assertIn("DRAM roof", report)

    def test_roof_rung_is_not_read_as_the_matched_control(self) -> None:
        roof = fixture(60)
        roof["roof_gbps"] = 70.0
        roof["matched_ladder"] = [
            {"name": "corpus-sized STREAM roof", "gbps": 70},
            {"name": "matched gate control", "gbps": 50},
            {"name": "production contiguous", "gbps": 45},
        ]
        report = roofline_report.render(roof, [], None)

        # The control column normalizes by the control (50), so the control is
        # 100% of itself. Reading ladder[0] would print 71% there instead.
        self.assertIn("| matched gate control | 50.0 | 71% | 100% |", report)
        self.assertIn("| production contiguous | 45.0 | 64% | 90% |", report)

    def test_roof_rung_cannot_make_the_ladder_look_binding(self) -> None:
        ladder = [
            {"name": "corpus-sized STREAM roof", "gbps": 70},
            {"name": "matched gate control", "gbps": 50},
            {"name": "production contiguous", "gbps": 60},
        ]
        # Production outruns the control: the ladder is inverted and must say so
        # instead of pointing at the roof rung it can obviously never outrun.
        self.assertIn("non-binding here", roofline_report.localize(ladder, 65.0))


class ProvenanceTest(unittest.TestCase):
    """No cycles/byte figure may reach the certificate off an unmeasured clock.

    Guards the recorded defect: `dram_cyc_per_byte_ceiling` shipped for months
    computed from a hardcoded 4.4 GHz, beside a `ghz_source` sibling reading
    `assumed (no PMU)` that this reporter never read. Each test names one way
    the figure could come back.
    """

    def test_an_unmeasured_clock_publishes_no_cycles_per_byte(self) -> None:
        roof = fixture(60)
        roof["clock"] = {
            "ghz": None,
            "measured": False,
            "source": "assumed (no PMU — no cycle counter opened)",
            "meter": "wall-clock only",
        }
        roof.pop("derived_cyc_per_byte")
        report = roofline_report.render(roof, [], None)

        self.assertIn("not measured on this host", report)
        self.assertIn("cycles/byte ceiling: _withheld", report)
        self.assertNotIn("cyc/byte**", report)
        # The GB/s half is frequency-free, so it must still be published.
        self.assertIn("100.0 GB/s", report)

    def test_a_stale_flat_ghz_key_cannot_resurrect_the_ceiling(self) -> None:
        # An artifact still on disk from before the nesting. Reading `ghz` off
        # the top level is exactly the mistake, so the reporter must not.
        roof = fixture(60)
        del roof["clock"]
        roof["ghz"], roof["ghz_source"] = 4.4, "assumed (no PMU)"
        roof["dram_cyc_per_byte_ceiling"] = 0.0431
        report = roofline_report.render(roof, [], None)

        self.assertIn("artifact predates the clock record", report)
        self.assertNotIn("0.0431", report)
        self.assertNotIn("4.400", report)

    def test_a_measured_clock_still_publishes_with_its_basis(self) -> None:
        report = roofline_report.render(fixture(60), [], None)

        self.assertIn("4.000 GHz measured here", report)
        self.assertIn("0.0400 cyc/byte", report)
        self.assertIn("measured clock GHz ÷ measured tier GB/s", report)

    def test_static_llvm_mca_cycles_are_not_converted_without_a_clock(self) -> None:
        # A modeled cycle count times a guessed frequency reads as a measured
        # bandwidth; two inferences deep is one too many to print as "≈N GB/s".
        roof = fixture(60)
        roof["clock"] = {"ghz": None, "measured": False, "source": "assumed", "meter": "none"}
        roof.pop("derived_cyc_per_byte")
        bound = roofline_report.ComputeBound([("znver4", 0.081, None)])
        report = roofline_report.render(roof, [], bound)

        self.assertIn("0.081 cyc/byte", report)
        self.assertNotIn("(≈", report)  # the "≈N GB/s" translation of a modeled cycle
        self.assertIn("modeled by llvm-mca", report)
        self.assertIn("measured no clock to convert them with", report)


class RooflineReportTest(unittest.TestCase):
    def test_sub_threshold_result_cannot_claim_saturation(self) -> None:
        report = roofline_report.render(fixture(35), [], None)

        self.assertIn("material headroom remains", report)
        self.assertIn("does **not** certify DRAM saturation", report)
        self.assertNotIn("memory-bandwidth-bound", report)

    def test_near_roof_result_still_requires_bottleneck_evidence(self) -> None:
        report = roofline_report.render(fixture(85), [], None)

        self.assertIn("near the measured roof", report)
        self.assertIn("Bottleneck attribution still requires", report)
        self.assertIn("not a universal optimality proof", report)

    def test_splice_retires_legacy_summary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            certificate = Path(directory) / "CERTIFICATE.md"
            certificate.write_text(
                "# Certificate\n\n"
                f"{roofline_report.LEGACY_SUMMARY}\n\n"
                "## Layer C — roofline (hardware ceiling)\n\nold verdict\n\n"
                f"{roofline_report.MACRO_HEADER}\n"
            )

            roofline_report.splice(certificate, "## Layer C — roofline (measured headroom)\n\nnew")
            result = certificate.read_text()

        self.assertNotIn(roofline_report.LEGACY_SUMMARY, result)
        self.assertIn(roofline_report.SUMMARY, result)
        self.assertIn("measured headroom", result)
        self.assertNotIn("old verdict", result)


if __name__ == "__main__":
    unittest.main()
