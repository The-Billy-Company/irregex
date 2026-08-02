#!/usr/bin/env python3
"""gist roofline — Layer C synthesis + CERTIFICATE.md splicer (measured headroom).

The roofline model (Williams, Waterman & Patterson, "Roofline: An Insightful
Visual Performance Model for Multicore Architectures", CACM 2009) bounds a
kernel's throughput by min(peak compute, peak memory-bandwidth x arithmetic
intensity). That roof is an upper bound, not evidence that an operating point
well below it is bandwidth-saturated. This report preserves that distinction.

This reads two measured artifacts and writes a verdict that is beyond reproach:
  * `roofline.json`  — this machine's achievable single-core read bandwidth per
                       cache tier (from `bench/bounds/roofline/bandwidth.zig`), the
                       hardware upper bound.
  * `matched_ladder` — dual-window control, production on contiguous DRAM, and
                       production over corpus documents; these localize the gap.
  * `certify.csv`    — Layer A's per-class measured operating point (bytes crunched
                       + median ns), from which gist's achieved GB/s is derived.
Optionally `portcert.json` (Layer B) supplies the **compute ceiling** for the
full two-ceiling picture; absent, the section notes memory-ceiling-only.

It splices a `## Layer C — roofline (hardware ceiling)` section into
`.gist/CERTIFICATE.md`, replacing any existing one (heading → next
`## Layer`/EOF), mirroring `certify/certify_stats.py`. stdlib only, fail-closed.
"""

# This file emits the certificate's Layer-C markdown, which intentionally carries
# math/typography glyphs (mult-sign, division-sign, en/em dashes, middot) that
# ruff's ambiguous-unicode rules flag; the glyphs are the certificate's contract,
# so silence them file-wide (same posture as other long-running report scripts
# ignore RUF001/002/003 for intentional glyphs).
# ruff: noqa: RUF001

import argparse
import json
import re
from dataclasses import dataclass
from pathlib import Path

LAYER_C_HEADER = "## Layer C — roofline (measured headroom)"
# certify_stats.py rewrites this section to EOF, so a fresh Layer C is inserted
# *before* it (not appended) to survive a later macroscopic re-splice.
MACRO_HEADER = "## Layer A — macroscopic dominance over ripgrep"
LEGACY_MACRO_HEADER = "## Layer A — macroscopic dominance vs the field"
LEGACY_SUMMARY = (
    "- **Layer C — roofline.** cycles/byte sits on the hardware ceiling (memory\n"
    "  bandwidth or compute), so no implementation on this chip can go faster."
)
SUMMARY = (
    "- **Layer C — roofline headroom.** measures distance from the pure-read roof and "
    "decomposes it with matched controls when present. It reports near-roof placement "
    "only at or above 80%; otherwise it reports optimization headroom."
)
# Anchor the shared cert dir at the repo root (computed from this file's location:
# bench/bounds/roofline/report.py → repo root
# from any CWD — the zig steps and port/mca.sh already resolve the repo root, and
# `.gist` always lives there. A `--out-dir` override still wins.
OUT_DIR = Path(__file__).resolve().parents[3] / ".gist"

# Apple M-series shared P-cluster L2 — a candidate set larger than this spills to
# DRAM, so an apparent rate above the DRAM ceiling on a >L2 working set is a
# tell-tale early-exit (the scan short-circuited before reading all the bytes).
L2_BYTES = 16 * 1024 * 1024


@dataclass
class ClassPoint:
    """ClassPoint value object."""

    name: str
    bytes: int
    median_ns: float
    cyc_per_byte: float
    ipc: float

    @property
    def gbps(self) -> float:  # bytes/ns == GB/s
        """Return float for gbps."""
        return self.bytes / self.median_ns if self.median_ns > 0 else 0.0


def load_certify(path: Path) -> list[ClassPoint]:
    """Parse Layer A's tab-separated certify.csv into per-class operating points."""
    lines = path.read_text().splitlines()
    header = lines[0].split("\t")
    col = {name: i for i, name in enumerate(header)}
    pts = []
    for ln in lines[1:]:
        if not ln.strip():
            continue
        f = ln.split("\t")
        pts.append(
            ClassPoint(
                name=f[col["class"]],
                bytes=int(f[col["bytes"]]),
                median_ns=float(f[col["median_ns"]]),
                cyc_per_byte=float(f[col["cyc_per_byte"]]),
                ipc=float(f[col["ipc"]]),
            )
        )
    return pts


@dataclass
class Clock:
    """The core clock, and whether this host produced it.

    Read out of `roofline.json`'s nested `clock` object. There is deliberately no
    top-level `ghz` to fall back on: a flat divisor is what let this report turn
    llvm-mca's static cycles/byte into a "≈N GB/s" compute bound by multiplying an
    assumed 4.4 GHz — including in a published x86_64 bundle, where 4.4 GHz was
    another machine's guess. `ghz` is `None` unless it was measured, so every
    cycles↔GB/s conversion in this file is unreachable without a real clock.
    """

    ghz: float | None
    source: str
    meter: str

    @classmethod
    def read(cls, roof: dict) -> "Clock":
        """Read the nested clock; an artifact predating it reports as unmeasured."""
        c = roof.get("clock")
        if not isinstance(c, dict):
            return cls(None, "absent (artifact predates the clock record)", "?")
        ghz = c.get("ghz")
        measured = bool(c.get("measured")) and isinstance(ghz, int | float)
        return cls(
            float(ghz) if measured else None,
            str(c.get("source", "?")),
            str(c.get("meter", "?")),
        )


@dataclass
class ComputeBound:
    """Layer B's static port bound for the `simd_contains` loop, per reference core.

    Crucially cross-machine: Layer B runs llvm-mca on `znver4`/`neoverse-v2`
    because LLVM ships no Apple-Silicon scheduling model, so these are a
    low-arithmetic-intensity *cross-check*, NOT a same-axis ceiling on this
    roofline. Reported as such — never folded into a min(compute, memory).

    `gbps_at_ghz` is None where the host measured no clock: llvm-mca reports
    cycles, and cycles become bytes/second only through a clock. Modeled cycles
    times a guessed frequency is two inferences deep and reads as a bandwidth.
    """

    cores: list[tuple[str, float, float | None]]  # (uarch, cyc_per_byte, gbps_at_ghz)


def load_compute_ceiling(path: Path, clock: Clock) -> ComputeBound | None:
    """Read Layer B's `simd_contains` port bound (real portcert.json schema), with a schema-tolerant fallback.

    Returns None ⇒ caller notes memory-ceiling-only.

    """
    if not path.exists():
        return None
    try:
        doc = json.loads(path.read_text())
    except (json.JSONDecodeError, OSError):
        return None

    def at_clock(cpb: float) -> float | None:
        return clock.ghz / cpb if clock.ghz and cpb > 0 else None

    cores: list[tuple[str, float, float | None]] = []
    for r in doc.get("results", []):
        cpb = r.get("cyc_per_byte")
        if r.get("probe") == "simd_contains" and isinstance(cpb, int | float) and cpb > 0:
            cores.append((r.get("target_uarch", "?"), float(cpb), at_clock(float(cpb))))
    if cores:
        return ComputeBound(cores)
    # Legacy/flat fallback: an explicit GB/s or a min cyc/byte at top level.
    for k in ("compute_gbps", "peak_gbps"):
        if isinstance(doc.get(k), int | float):
            gbps = float(doc[k])
            cpb = clock.ghz / gbps if clock.ghz and gbps else 0.0
            return ComputeBound([("(reported)", cpb, gbps)])
    for k in ("cyc_per_byte", "min_cyc_per_byte", "static_cyc_per_byte"):
        v = doc.get(k)
        if isinstance(v, int | float) and v > 0:
            return ComputeBound([("(reported)", float(v), at_clock(float(v)))])
    return None


def localize(ladder: list[dict], pure_gbps: float) -> str:
    """Say what the matched ladder attributes the roof gap to — or that it attributes nothing.

    The ladder only localizes a loss when it brackets the corpus point from
    above: each stage strips one production concern, so a descent to the corpus
    scan names the stage that cost the throughput. A corpus scan that outruns
    every matched stage inverts that reading — the controls are then the slow
    path, and citing them as the explanation would assert a descent the numbers
    do not show.
    """
    # The roof rung is the denominator, not a control — including it here would
    # make the ladder read as binding for free, since no scan outruns STREAM.
    stages = [s for s in ladder if "roof" not in s.get("name", "")]
    if not stages:
        return (
            "This older artifact predates the matched ladder; remint Layer C to localize "
            "the gap before making a stronger claim."
        )
    top = max(stages, key=lambda s: float(s.get("gbps", 0.0)))
    top_gbps = float(top.get("gbps", 0.0))
    if pure_gbps > top_gbps > 0:
        return (
            "The matched ladder is **non-binding here** — the corpus scan outruns its fastest "
            f"stage ({top.get('name', '?')}, {top_gbps:.1f} GB/s) by {pure_gbps / top_gbps:.2f}×, "
            "so neither the dual-window load shape nor corpus fragmentation can account for the "
            "remaining gap. The controls are the slower path and need re-examination before "
            "Layer C can attribute the headroom to anything."
        )
    return (
        "The matched ladder shows where throughput falls before corpus fragmentation; "
        "optimize and remeasure those stages before making a stronger claim."
    )


def render(roof: dict, pts: list[ClassPoint], compute: ComputeBound | None) -> str:
    """Render generated source artifacts."""
    tiers = {t["name"]: float(t["gbps"]) for t in roof["tiers"]}
    clock = Clock.read(roof)
    dram = tiers.get("DRAM", 0.0)
    # RECORDED DEFECT (2026-07-29): every scan rung used to be divided by
    # `dram` — a 512 MiB uniform-random buffer — so the published headroom
    # folded kernel, working-set size, and byte content into one number. The
    # apparatus now measures STREAM at the corpus's own size over the corpus's
    # own bytes and reports it as `roof_gbps`; that is the only denominator
    # against which a scan rung differs by exactly one thing. `dram` stays as
    # the cache-hierarchy datum it always actually was. Older artifacts have no
    # `roof_gbps`, so they keep the old denominator and read as they did.
    denom = float(roof.get("roof_gbps") or dram)
    denom_label = "corpus-sized roof" if roof.get("roof_gbps") else "DRAM roof"
    ladder = roof.get("matched_ladder", [])
    scans = roof.get("gist_scan", [])
    # The clean streaming point: the absent-needle scan reads every byte (no
    # early exit, no verification). It shares the process and methodology with
    # the roof; absolute values and ratios remain measured, not universal.
    pure = next(
        (s for s in scans if float(s.get("gbps", 0)) > 0 and "0 matches" in s.get("kind", "")),
        None,
    )

    lines: list[str] = [LAYER_C_HEADER, ""]
    lines.append(
        "_The roofline model (Williams, Waterman & Patterson, CACM 2009) supplies an upper "
        "bound: min(peak compute, peak bandwidth × arithmetic intensity). Layer C measures "
        "gist's distance from that bound. It does **not** infer saturation from low arithmetic "
        "intensity. A matched ladder separates raw STREAM bandwidth, the dual-window "
        "load/compare shape, production on contiguous DRAM, and production over corpus "
        "documents._"
    )
    lines.append("")
    lines.append(
        f"- machine: `{roof.get('machine', '?')}` · zig `{roof.get('zig', '?')}` "
        f"· corpus {roof.get('corpus_mib', '?')} MiB"
    )
    lines.append(
        "- **measured memory ceiling (single core, pure read):** "
        + " · ".join(f"{n} **{g:.1f} GB/s**" for n, g in tiers.items())
    )
    # The cycles/byte restatement of the memory ceiling is published only when
    # `bandwidth.zig` measured this host's clock; it withholds the figures
    # otherwise, and this report does not reconstruct them from anything.
    cpb = roof.get("derived_cyc_per_byte")
    cpb = cpb if clock.ghz is not None and isinstance(cpb, dict) else None
    ceiling = float(cpb["dram_ceiling"]) if cpb else None
    if cpb and ceiling is not None and clock.ghz is not None:
        lines.append(f"- clock: **{clock.ghz:.3f} GHz measured here** — {clock.source}")
        lines.append(
            f"- DRAM ceiling in cycles/byte (derived, {cpb.get('basis', 'GHz ÷ GB/s')}): "
            f"**{ceiling:.4f} cyc/byte** — the ideal pure-read floor; search "
            "instructions and load shape can impose lower ceilings"
        )
    else:
        lines.append(
            f"- clock: **not measured on this host** — {clock.source} · meter: {clock.meter}"
        )
        lines.append(
            "- cycles/byte ceiling: _withheld. Every GB/s figure in this section is bytes/ns and "
            "needs no clock; a cycles/byte restatement needs one, and this host produced none, so "
            "Layer C publishes no cycles/byte rather than one divided by a stand-in frequency._"
        )
    if compute:
        bounds = " · ".join(
            f"{u} {cpb_core:.3f} cyc/byte" + (f" (≈{g:.0f} GB/s)" if g is not None else "")
            for u, cpb_core, g in compute.cores
        )
        gbps_note = (
            ""
            if any(g is not None for _, _, g in compute.cores)
            else " No GB/s equivalent is shown: llvm-mca reports cycles, and this host measured "
            "no clock to convert them with."
        )
        lines.append(
            "- **compute bound (Layer B, cross-machine):** the `simd_contains` loop's static "
            f"llvm-mca port bound — {bounds}. These are *reference cores* modeled by llvm-mca, "
            "not observations of any core (LLVM has no Apple-Silicon model), so they are a "
            "low-intensity **cross-check**, not a same-axis ceiling on this "
            f"`{roof.get('machine', '?')}` roofline; they confirm the scan is a tight, "
            "few-cycle/byte port-bound kernel, but do not identify this machine's binding "
            f"bottleneck.{gbps_note}"
        )
    else:
        lines.append(
            "- compute ceiling: _Layer B (`portcert.json`) not present — memory-ceiling-only. "
            "no binding-bottleneck claim is made without a same-machine compute measurement._"
        )
    lines.append("")

    if ladder:
        # By name, not by position: the ladder now leads with its STREAM roof,
        # and normalizing the control column by the roof would silently
        # relabel one rung as another.
        control = float(
            next((s for s in ladder if "control" in s.get("name", "")), ladder[0]).get("gbps", 0.0)
        )
        lines.append("**Matched ceiling ladder** (same process; logical input GB/s):")
        lines.append("")
        lines.append(f"| stage | GB/s | % of {denom_label} | % of matched control |")
        lines.append("|---|--:|--:|--:|")
        for stage in ladder:
            g = float(stage.get("gbps", 0.0))
            lines.append(
                f"| {stage.get('name', '?')} | {g:.1f} "
                f"| {g / denom * 100.0 if denom else 0.0:.0f}% "
                f"| {g / control * 100.0 if control else 0.0:.0f}% |"
            )
        lines.append("")

    # ── gist's corpus operating point (same process, same clock) ──
    if scans:
        lines.append(
            "**gist's SIMD scan on the roofline** "
            "(real `scan/simd.zig` `contains` over the corpus):"
        )
        lines.append("")
        lines.append(f"| scan | GB/s | % of {denom_label} |")
        lines.append("|---|--:|--:|")
        for s in scans:
            g = float(s.get("gbps", 0))
            pct = g / denom * 100.0 if denom > 0 else 0.0
            label = f"{s.get('kind', '?')} (`{s.get('needle', '?')[:8]}…`)"
            lines.append(f"| {label} | {g:.1f} | {pct:.0f}% |")
        lines.append("")

    # ── verdict from the clean full-scan point ──
    if pure:
        pg = float(pure["gbps"])
        frac = pg / denom * 100.0 if denom > 0 else 0.0
        if frac >= 80.0:
            verdict = (
                f"**Verdict — near the measured roof.** The full scan reaches **{pg:.1f} GB/s = "
                f"{frac:.0f}% of the {denom:.1f} GB/s single-core pure-read roof**. At the "
                "pre-registered 80% threshold, little roofline headroom remains. Bottleneck "
                "attribution still requires same-machine counters; this is not a universal "
                "optimality proof."
            )
        else:
            next_step = localize(ladder, pg)
            verdict = (
                f"**Verdict — material headroom remains.** The full scan reaches **{pg:.1f} GB/s = "
                f"{frac:.0f}% of the {denom:.1f} GB/s single-core pure-read roof**. That is below "
                "the pre-registered 80% near-roof threshold, so Layer C does **not** certify "
                f"DRAM saturation, a binding memory bottleneck, or hardware optimality. {next_step}"
            )
        lines.append(verdict)
    else:
        lines.append(
            "**Verdict unavailable.** The clean full-scan operating point was not measured; "
            "Layer C cannot classify the bottleneck."
        )
    lines.append("")

    # ── Layer A per-class end-to-end operating point (as-instructed ingest) ──
    lines.append(
        "<details><summary>Layer A per-class end-to-end operating point "
        "(from certify.csv)</summary>\n"
    )
    lines.append(
        "_These are the **end-to-end** product path (trigram prefilter → candidate verify), so "
        "`bytes ÷ median_ns` conflates early-exit (scan returns on first match) and false-positive "
        "verification — it is the product's per-class latency, **not** a clean streaming "
        "bandwidth (the clean number is the scan table above). Rows marked ⚡ early-exit report "
        f"an apparent rate above the {dram:.0f} GB/s DRAM ceiling on a >LLC working set — "
        "physically impossible to truly stream, i.e. the kernel short-circuited before reading "
        "all candidate bytes._\n"
    )
    lines.append("| class | cand bytes | median | end-to-end GB/s | note |")
    lines.append("|---|--:|--:|--:|:--|")
    for p in sorted(pts, key=lambda x: x.bytes, reverse=True):
        if p.bytes > L2_BYTES and p.gbps > dram:
            note = "⚡ early-exit (partial scan)"
        elif p.bytes <= L2_BYTES:
            note = "cache-resident"
        else:
            note = "full/near-full scan"
        lines.append(
            f"| `{p.name}` | {p.bytes / 1e6:.0f} MB | {p.median_ns / 1e3:.0f} µs "
            f"| {p.gbps:.1f} | {note} |"
        )
    lines.append("\n</details>")

    have_layer_a_cycles = any(p.cyc_per_byte > 0 for p in pts)
    lines.append("")
    if have_layer_a_cycles and ceiling is not None:
        lines.append(
            "_Layer A measured gist's actual cycles/byte (see the microscopic table above); "
            f"compare them to the derived DRAM ceiling of {ceiling:.4f} cyc/byte to quantify "
            "headroom; do not read the bound as saturation._"
        )
    elif have_layer_a_cycles:
        lines.append(
            "> Layer A carries measured cycles/byte but Layer C measured no clock, so there is no "
            "cycles/byte ceiling to compare them against. Re-mint Layer C on a host whose counters "
            "open; the two halves must not be divided by different clocks."
        )
    else:
        lines.append(
            "> Neither layer measured cycles on this host. The **GB/s measurements and ratios are "
            "frequency-free** and stand on their own; no cycles/byte figure is published anywhere "
            "in this section, derived or otherwise."
        )
    lines.append("")
    return "\n".join(lines)


def splice(cert: Path, section: str) -> None:
    """Replace an existing `## Layer C …` block (→ next `## Layer`/EOF); else insert it *before* the macroscopic Layer A section (which certify_stats.py rewrites to EOF) so a later macro re-splice can't clobber it; else append at EOF."""
    body = section.rstrip() + "\n"
    if not cert.exists():
        cert.write_text("# gist — Dominance-and-Fit Certificate\n\n" + body)
        return
    text = cert.read_text().replace(LEGACY_SUMMARY, SUMMARY)
    m = re.search(r"^## Layer C\b.*$", text, re.MULTILINE)
    if m:
        nxt = re.search(r"^## Layer [A-Z]\b", text[m.end() :], re.MULTILINE)
        end = m.end() + nxt.start() if nxt else len(text)
        new = text[: m.start()].rstrip() + "\n\n" + body + "\n" + text[end:].lstrip("\n")
    elif (
        macro := next(
            (i for header in (MACRO_HEADER, LEGACY_MACRO_HEADER) if (i := text.find(header)) >= 0),
            -1,
        )
    ) != -1:
        new = text[:macro].rstrip() + "\n\n" + body + "\n" + text[macro:]
    else:
        new = text.rstrip() + "\n\n" + body
    cert.write_text(new.rstrip() + "\n")


def main() -> int:
    """CLI entry point."""
    ap = argparse.ArgumentParser(description="gist Layer C roofline synthesis")
    ap.add_argument("--out-dir", type=Path, default=OUT_DIR)
    ap.add_argument(
        "--roofline", type=Path, help="roofline.json (default: <out-dir>/roofline.json)"
    )
    ap.add_argument("--certify", type=Path, help="certify.csv (default: <out-dir>/certify.csv)")
    ap.add_argument("--portcert", type=Path, help="portcert.json (Layer B, optional)")
    ap.add_argument(
        "--certificate", type=Path, help="CERTIFICATE.md (default: <out-dir>/CERTIFICATE.md)"
    )
    args = ap.parse_args()

    rj = args.roofline or args.out_dir / "roofline.json"
    cc = args.certify or args.out_dir / "certify.csv"
    pc = args.portcert or args.out_dir / "portcert.json"
    cert = args.certificate or args.out_dir / "CERTIFICATE.md"

    if not rj.exists():
        print(f"roofline_report: {rj} missing — run `zig build roofline` first.")
        return 1
    if not cc.exists():
        print(f"roofline_report: {cc} missing — run `zig build certify` first (wall-clock ok).")
        return 1

    roof = json.loads(rj.read_text())
    pts = load_certify(cc)
    if not pts:
        print(f"roofline_report: {cc} has no rows — did certify run?")
        return 1
    compute = load_compute_ceiling(pc, Clock.read(roof))

    section = render(roof, pts, compute)
    splice(cert, section)

    tiers = {t["name"]: float(t["gbps"]) for t in roof["tiers"]}
    print(
        f"wrote Layer C → {cert}  (DRAM {tiers.get('DRAM', 0):.1f} GB/s ceiling · "
        f"{len(pts)} classes · compute ceiling: {'yes' if compute else 'absent'})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
