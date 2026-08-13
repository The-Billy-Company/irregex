# bench/bounds/port — Layer B (port-optimality: static bound + measured on this machine)

Layer B of [irregex's Dominance-and-Fit Certificate](../README.md#dominance-and-fit-certificate-layers-al),
one of the seven layers this package mints itself. Layer B proves *why the
hot loop can't be beaten on this instruction sequence* — in two legs: a
**static** `llvm-mca` microarchitectural bound (port pressure / reciprocal
throughput) over reference cores, and **Layer B′**, the same hot-loop probes
run natively on *this* machine under the PMU, so the certificate can carry a
measured-here cycles/byte instead of only a cross-machine cross-check.

## What It Is

- **`mca.sh`** cross-compiles every probe to two reference
  microarchitectures, runs `llvm-mca`, writes `portcert.csv`/`portcert.json`,
  and splices the certificate.

- **`report.py`** renders the `## Layer B` markdown section (the static leg
  plus the Layer B′ measured subsection) from `portcert.json` and
  `portbound.json`, and splices it into the mint's working
  `CERTIFICATE.md` (the artifact home by default, or `$<prefix>DIR`).
  [`mint.sh`](../../certificate/mint/mint.sh) copies the finished file into
  the committed
  [`bench/certificate/artifact/`](../../certificate/artifact/) snapshot only
  when asked (`CERT_PUBLISH_DIR=...`).

- **`measure.zig`** is **Layer B′** — `portbound` times the same
  drift-guarded probes natively under the PMU
  (`bench/apparatus/harness/pmu.zig`), writing `portbound.json` (measured
  cyc/byte plus cyc/step; fail-closed without root).

- **`probes/simd_contains.zig`** is a byte-faithful copy of the hot loop in
  [`../../../src/kernel/scan/simd.zig`](../../../src/kernel/scan/simd.zig)'s
  `contains` — throughput-bound.

- **`probes/dfa_step.zig`** is the **classed** DFA recurrence —
  `s = trans_in[s + class[b]]`, 3 loads/byte, the layout every non-document
  DFA consumer still walks — latency-bound.

- **`probes/dfa_mirror.zig`** is the **byte-indexed** recurrence —
  `s = trans_in[s + b]` over the `Dfa.Wide` mirror that
  [`../../../src/kernel/regex/linear/dfa/dfa.zig`](../../../src/kernel/regex/linear/dfa/dfa.zig)'s
  `docMatch` steps, 2 loads/byte — latency-bound.

- **`probes_test.zig`** is the drift guard — it asserts each probe is
  bit-identical to the real production function it copies, over adversarial
  random inputs (`zig build test`).

**Why cross-compiled reference cores, not this machine.** This dev box is
Apple Silicon, and LLVM ships **no real scheduling model for any Apple CPU** —
every core from the A7 to the M4 is modeled as the 2013 "Cyclone"
([LLVM issue #63698](https://github.com/llvm/llvm-project/issues/63698)). So
`llvm-mca -mcpu=apple-m4` would be fabricated precision. Layer B instead
bounds against two cores LLVM **does** model precisely, cross-compiled by Zig
with zero fuss: `znver4` (AMD Zen 4) and `neoverse-v2` (Arm Neoverse V2 — the
core behind AWS Graviton4 / Google Axion).

**Throughput-bound vs latency-bound.** `simd_contains`'s iterations are
independent (only the loop counter carries), so its `Block RThroughput` **is**
the real floor — no scheduling of those vector ops on that core runs faster.
Both DFA probes are **latency-bound pointer chases**: the transition is a
loop-carried dependency, so their true floor is the recurrence latency (the
dependent-load chain), which `llvm-mca` reports as higher than the port-pressure
`Block RThroughput` shown in the table — the certificate names this explicitly
rather than quoting the more flattering throughput number as if it were the DFA's
real ceiling.

**Why two DFA probes, and what the pair actually showed.** The automaton carries
its transitions in two layouts, and `docMatch` steps the byte-indexed mirror
while every other consumer steps the classed tables, so bounding one would leave
the other undescribed. Running both was also the cheapest way to ask *what kind*
of win the mirror is — and the answer was not the obvious one:

- **Measured (Layer B′), the two are a wash** — the classed and mirrored rows
  land within a percent of each other, well inside run-to-run spread, so
  deleting a load per byte bought nothing here. The two rows are what say so;
  read them out of your own `portbound.json` rather than from here. This bullet
  used to quote a fixed pair of ns/step figures, and by the time anyone checked
  they were off by more than 3× against the artifact on disk — the same probes
  re-timed on a different working set. The wash is the durable finding; the
  digits were a snapshot of one run pretending to be the claim.
- **Because the deleted load was never on the critical path.** `class[b]`
  depends on the document byte, not on `s`, so it issues early and retires
  under the transition load's latency. The loop-carried chain is
  `s`→`add`→`trans_in[…]` in both layouts, and it is the same length in both.

So the mirror's ~1.28× in `bench/rungs/automata -- burst` is a **port-pressure**
win, not a latency win: it only cashes out when the walk has several independent
chains in flight to saturate the load ports, which is exactly why `docMatch`
bursts four lines in lockstep and why leaving the scalar and anchored walks on
the classed tables costs nothing. A single-chain probe is the right instrument
for saying so, and it is the reason the burst rung and this bound disagree
without either being wrong.

**A region-capture caveat, visible in the two `.region.s` files.** The `sim
cyc/it` column is not comparable between these two probes. In the classed
region the state register is *read but never written* inside the markers (the
compiler keeps `s` live in a register assigned outside them), so `llvm-mca` sees
no loop-carried edge and simulates the body as freely pipelineable — ~1.2
cyc/it, which is a port-pressure number wearing a latency label. The mirrored
region happens to keep `s` in a register both written and read inside the
markers, so its ~5–6 cyc/it is the real dependent-load recurrence. Read
`Block RThroughput` for the port bound and the measured Layer B′ column for the
recurrence; treat `sim cyc/it` as per-probe, not cross-probe.

## Drift Guard, Not a Duplicate

The probes are **byte-faithful copies**, not the production functions
themselves — `llvm-mca` needs a standalone, zero-host-package-dependency object to
disassemble, and the markers that bracket the measured region (`# LLVM-MCA-
BEGIN/END`) have to live inside the loop body so LLVM's loop rotation/cloning
can't strand them, which the production code has no reason to carry.
`probes_test.zig` is what keeps a copy honest: it feeds identical inputs to
**both** the probe and the real `simd.contains` / `Dfa.docMatch` and
asserts bit-identical verdicts over thousands of adversarial random cases —
deliberately not an oracle test (the reference is the real production path,
not a re-derivation), so a silent divergence between the probe and the
production loop fails `zig build test` loudly instead of shipping a stale
certificate.

## Layer B′ — Port Bound, Measured On This Machine

The static leg is honest about its gap: it bounds _reference_ cores because
LLVM models no Apple core (below). `measure.zig` closes the gap empirically —
it runs the **same drift-guarded probe functions** as timed kernels on this
machine, over cache-resident, guaranteed-miss inputs (the steady-state hot
loop; ports bind, memory never does), and reports:

- `simd_contains` — measured **cycles/byte** (throughput probe), with the
  unmarked production `simd.contains` timed alongside as a marker-overhead
  cross-check (the probe figure is a conservative upper bound);
- `dfa_step` — measured **cycles/step** of the classed transition recurrence
  `s = trans_in[s + class[b]]` (latency probe, 1 byte per step);
- `dfa_mirror` — the same recurrence over the byte-indexed mirror,
  `s = trans_in[s + b]`, so the delta between the two rows prices the load the
  mirror folds away rather than asserting it.

Provenance is stamped in `portbound.json` and the spliced section: CPU brand
(`machdep.cpu.brand_string`), the P-core note (USER_INTERACTIVE QoS request
plus the _measured_ effective GHz, which itself tells a P-core from an
E-core), and the PMU source. **Fail-closed:** when no cycle counter opens the
run records wall-clock ns only and the certificate says _"cycles/byte:
cross-checked (reference cores), NOT measured on this machine"_ — it never
converts wall-clock to cycles via an assumed frequency. The report names the
meter that refused rather than asserting a cause; it used to say "kperf needs
root", which reads an unprivileged refusal as a `sudo` problem and sends the
operator up a rung that cannot help. **Root is not what buys cycles here:**
`pmu.zig`'s unprivileged `thread_selfcounts` tier supplies retired cycles and
instructions to a plain `zig build portbound`, and root only adds kperf's
configurable events, which this lane never requests.

## How to Run

Run the static leg first, then optionally the on-machine measured leg.

```bash
cd <irregex-repo-root>
bench/bounds/port/mca.sh                # static leg: portcert.csv/.json + splice Layer B (+B′ if present)
ITERS=200 bench/bounds/port/mca.sh      # more llvm-mca simulation iterations

# Layer B′ — measured on this machine (unprivileged: thread_selfcounts):
zig build -Doptimize=ReleaseFast portbound   # measures cycles; no sudo needed
sudo zig-out/bin/portbound              # only adds kperf's configurable events
bench/bounds/port/mca.sh                     # re-splice: the measured subsection lands in the cert
```

The runner resolves its artifact directory against the CWD, so stay at the repo
root. `portbound.json`'s `meter` field names which tier produced the numbers —
that is what to read before believing a cycles/byte figure, and what to read
when there isn't one.

`CERT_OUT=/path/to/bundle` targets an isolated certificate directory; otherwise
the script uses the repo's own artifact home.

Install `llvm-mca` opt-in with `brew install llvm` (lands at
`$(brew --prefix llvm)/bin/llvm-mca`). Missing `llvm-mca` or `zig` degrades to
a documented skip (exit 0), never a failure — mirroring `bench/apparatus/harness/pmu.zig`'s
"never fail the run" discipline; `portbound` degrades the same way
(wall-clock + a loud NOT-measured label instead of a crash).

## Prior Art

- **LLVM `llvm-mca`** is the static machine-code analyzer this layer drives;
  see the [LLVM `llvm-mca` documentation](https://llvm.org/docs/CommandGuide/llvm-mca.html)
  for the reciprocal-throughput / port-pressure model it implements.
- **[LLVM issue #63698](https://github.com/llvm/llvm-project/issues/63698)**
  is the reason this layer targets `znver4`/`neoverse-v2` instead of an
  Apple-Silicon `-mcpu`: no real scheduling model exists for any Apple core.
- The sibling face package's `bench/apparatus/harness/certify.zig` (Layer A)
  supplies the measured cycles/byte this layer's static bound is checked
  against.
