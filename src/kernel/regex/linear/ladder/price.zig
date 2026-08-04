//! gist — the ladder's PRICE PLANE: every number the auction bids with, in one
//! file, each one an arithmetic consequence of a kernel a bench timed alone.
//!
//! `rungs.zig` runs a real auction — each machine that can represent the pattern
//! publishes a `Cost`, the cheapest wins, and the fallback bids like everyone
//! else. That STRUCTURE was never the weak part. The NUMBERS were: per-rung
//! literals transcribed out of bench prose (`4_400`, `9_000 + ops/8`,
//! `0.40 × 30_000`), which made four claims the code could not keep.
//!
//!   1. **A DFA is a DFA.** `30_000` flat priced a nine-state machine and a
//!      nine-thousand-state machine identically. The walk is one loop-carried
//!      dependent load, so its cost is a LATENCY, and which cache answers that
//!      load is the entire per-pattern variance.
//!   2. **A candidate costs one byte.** `30_000 / stride` says verifying one
//!      prefilter hit costs exactly what walking one byte densely costs. That is
//!      an artifact of dividing the only number in scope, not a measurement.
//!   3. **A fallback that is not a DFA still prices as one.** A pattern the
//!      powerset declined falls to the lazy DFA or the Pike VM, both of which
//!      are far dearer than 3 cyc/B — so a challenger that would win easily was
//!      being held to the wrong bar and stood down.
//!   4. **A sieve costs 0.40 × a DFA whatever it fronts.** A ratio measured
//!      against one machine, then applied to three.
//!
//! So the numbers move here and change KIND. A `Calibration` carries only
//! quantities a bench can time in isolation — one dependent table load, one
//! Parabix stripe op, one Sheng step — and each machine's price becomes a
//! function of features it already computes about itself. Nothing in this file
//! measures a *pattern*; it measures a *machine*, and then evaluates that
//! measurement on this pattern's shape. That is the whole difference between an
//! auction whose bids are constants and one whose bids are priced.
//!
//! ## What keeps it honest
//!
//! Two mechanisms, and neither is prose:
//!
//! * `zig build ladder-price` re-times every coefficient below and fails when
//!   one has drifted outside its band — the same ratchet discipline as a lint
//!   baseline, so a number cannot rot in place.
//! * the same step measures every representable machine per pattern and reports
//!   the auction's **regret**: measured time of the machine it picked over
//!   measured time of the best one available. A model can be wrong in a way no
//!   coefficient check catches; regret is the property that actually matters,
//!   and it is gated.
//!
//! ## Cross-machine policy
//!
//! Absolute cycle counts are machine-specific, and `contract/performance_evidence.toml`
//! already fixes the rule: never gate absolute latency across machines. A target
//! with no minted calibration therefore gets `unmeasured`, whose `measured` flag
//! is false — and a vector rung requires that flag before it may bid, so an
//! unported kernel declines for a stated reason instead of bidding a number
//! nobody produced.

const std = @import("std");
const builtin = @import("builtin");
const lanes = @import("../../../scan/lanes.zig");
const plane = @import("../parabix/plane.zig");
const admit = @import("../parabix/admit.zig");

/// The auction's unit: one count is 10⁻⁴ cycles per byte, so `10_000` reads as
/// 1.00 cyc/B. The dense byte-class walk's measured 3.0 lands on 30_000 — the
/// literal this plane replaced, now derived instead of transcribed.
pub const unit: f64 = 10_000;

/// Cycles per byte in `unit`s, saturating rather than wrapping: an absurd
/// feature vector must read as "ruinously expensive", never as cheap.
pub fn perByte(cyc: f64) u32 {
    if (!(cyc > 0)) return 0; // also catches NaN
    return if (cyc * unit >= std.math.maxInt(u32)) std.math.maxInt(u32) else @intFromFloat(@round(cyc * unit));
}

/// What a candidate machine costs. `scan` is the price of the hot loop and
/// decides the auction; `compile` is the one-off build, in CYCLES, and breaks a
/// scan tie. Keeping the two dimensions in separate fields rather than blending
/// them is deliberate: gist compiles a pattern once and scans a corpus with it,
/// so a machine may never buy scan throughput by claiming a cheap build.
pub const Cost = struct {
    scan: u32,
    compile: u32 = 0,

    pub fn lessThan(a: Cost, b: Cost) bool {
        return a.scan < b.scan or (a.scan == b.scan and a.compile < b.compile);
    }

    pub fn cycPerByte(self: Cost) f64 {
        return @as(f64, @floatFromInt(self.scan)) / unit;
    }
};

/// Which haystack grain a sieve is being priced at. A whole-buffer pre-pass runs
/// a different kernel from a per-line one (`sheng.survivesDoc` advances four
/// lines at once), so it is a different measured number, not the same one over
/// a longer haystack.
pub const Grain = enum { line, doc };

/// The line and document lengths every per-line model is amortized over. One
/// definition, because the sieve's survival arithmetic and an anchored walk's
/// per-line cost are the same assumption wearing two hats, and two copies of it
/// could disagree. `sieve.zig` re-exports these rather than restating them.
pub const nominal_line: f64 = 64;
pub const nominal_doc: f64 = 4096;

/// Every quantity the models below multiply, and nothing else. Each field is
/// one kernel timed ALONE, so a field can be re-measured without re-deriving
/// any other — which is what makes the verify step a per-coefficient check
/// rather than a whole-model refit.
pub const Calibration = struct {
    /// The silicon that produced these numbers, and when. A measured value with
    /// no machine beside it is an anecdote.
    machine: []const u8,
    minted: []const u8,

    /// WHICH build this row speaks for: the byte-permute class its numbers were
    /// measured over (`lanes.Isa`). This is a claim about every core that
    /// compiles to these arms, not only the one in `machine` — a wider claim
    /// than the measurement, taken deliberately.
    ///
    /// The narrow alternative was tried first and is what this replaced. Rows
    /// used to be claimed by CPU MODEL NAME, which meant a row spoke only for
    /// the silicon it was minted on and every other core fell to `unmeasured`.
    /// That reads as caution and is not: the published manylinux wheel declares
    /// an x86-64-v2 floor, so its model name is `x86_64_v2`, so it matched no
    /// row, so it shipped the SSSE3 composition and the Parabix transposition
    /// COMPILED IN and never let either bid. The thing most people install had
    /// the kernels and refused to use them, and nothing failed to say so.
    ///
    /// Keyed on the permute because that is the axis the coefficients actually
    /// vary on, and it varies hugely: the Parabix transposition is the dearer
    /// half by 5x under `pshufb` and at parity under `tbl`, since `tbl` does in
    /// one instruction what SSSE3 spends a sequence on. Two cores in the same
    /// class differ too, but by far less than two classes do, and `verify` is
    /// what reports it when a given machine disagrees with its class.
    ///
    /// The permute is also the narrowest thing a row can honestly be keyed on
    /// that is still wide enough to cover a stranger. ARCHITECTURE was the
    /// first attempt and is far too wide: every AArch64 target read the Apple
    /// row, so Graviton, Ampere, a Windows-on-Arm laptop and a Raspberry Pi all
    /// bid an M4 Max's numbers. That is not a conservative approximation, since
    /// the auction is a comparison BETWEEN two of these numbers - importing a
    /// foreign row keeps the ratios of a machine nobody is running, and the
    /// rung that wins is whichever one Apple happens to be relatively good at.
    /// Model name was the second attempt and is too narrow, for the reason
    /// above. The permute is the property the ratios are a function of.
    isa: lanes.Isa,

    /// Did anyone actually measure this target? A vector rung must see `true`
    /// before it bids: the alternative is a rung arming on a hoped-for number,
    /// which is a latency bug rather than a slow path.
    measured: bool = true,

    /// The byte-class DFA's dependent-load step, per byte of document.
    ///
    /// **One number, and the residency sweep is why.** This started as three —
    /// a resident step, a spilled step, and the table size where a walk crosses
    /// from one to the other — on the reasonable-sounding theory that a table too
    /// big for L1 walks slower. The sweep that was built to fit that curve
    /// refuted it: on this host a **1.4 MB** table walks at 1.18 cyc/B and a
    /// **216-byte** table walks at 1.18, and the whole 6-point spread (1.02–1.21)
    /// tracks automaton shape rather than footprint.
    ///
    /// It could not have been otherwise, which is the more useful half. The step
    /// is one dependent load from `table[state * stride + class[byte]]`, so the
    /// working set is the rows a haystack actually VISITS times the classes it
    /// actually uses — never the table's total size. A pattern with 1795 states
    /// cycles through a handful of them on real text. `table_bytes` is not a weak
    /// predictor of this cost; it is not a predictor of it, and a blend over it
    /// was arithmetic dressing a quantity that does not determine the answer.
    ///
    /// So the model prices what it can defend and the bench keeps the evidence:
    /// `mint` still walks the footprint sweep, still prints every row, and says
    /// so if a host ever shows the knee this one doesn't.
    dfa_step: f64,

    /// The SAME walk, restricted to one line at a time. `docMatch` carries four
    /// lines in lockstep so four dependent chains overlap; `lineMatch` gets one
    /// line and cannot. This is not a modeling nuance — it is a real ~1.24×
    /// here, and it is the one axis of the walk's cost that measurement DID
    /// confirm, where footprint was refuted. `dfa_step` is measured on the
    /// document kernel because that is what the auction dispatches, and the
    /// quotient of these two is how a per-LINE comparison is put on the same
    /// footing. See `atGrain` — a sieve arming condition that weighed its
    /// single-chain line kernel against a four-chain document price concluded the
    /// pre-pass could never pay.
    dfa_line: f64,

    /// The first-byte SIMD skip, per byte SCANNED (not per byte matched).
    skip_scan: f64,
    /// Cycles to verify one candidate the skip surfaced, end to end. Priced
    /// per candidate rather than per byte, because that is what a stride is a
    /// count of.
    skip_verify: f64,

    /// An ANCHORED walk, which is not a walk at all: `^` seeds only at a line
    /// start, so after a few bytes the state is dead and the engine scans for
    /// the next `\n` with SIMD. Two numbers, separated by measuring the same
    /// kernel over two line widths: what the terminator hunt costs per byte,
    /// and what one line's short verification costs. The regret gate found this
    /// axis missing — an anchored pattern was bid as a dense walk at 2.98 and
    /// measures 0.31, so composition won an auction it lost by 2.8× in fact.
    anchor_scan: f64,
    anchor_line: f64,

    /// The SIMD scans that sit ABOVE the ladder in `verdict.zig` and can decide a
    /// pattern outright: the class-run kernel's block membership, and the literal
    /// engine's exact set. All are per byte at classification bandwidth, which is
    /// a different order of machine from a byte-at-a-time walk — and that is the
    /// point, because when one of them answers it is the incumbent and a walk's
    /// price is a phantom.
    ///
    /// Measured because the ladder used to have no way to say this at all.
    /// `[0-9]{40,}` is a pure class run decided here, and every rung was bidding
    /// against an eager DFA at 1.32 cyc/B — so a sieve at 0.72 "won" against a
    /// machine eight times cheaper than the quote and armed in front of a kernel
    /// that had already finished.
    ///
    /// FOUR numbers rather than two, because each kernel has two block
    /// classifiers and they are not the same machine: a class of ≤4 contiguous
    /// ranges takes two-compare lanes where a wider one takes truffle nibble
    /// tables, and one needle takes a single SIMD scan where a set takes a Teddy
    /// bucket pass. The regret gate is what forced the split — `Qzxjvw` settles
    /// on one literal, measured 0.04 cyc/B, and a single `settle_literal` minted
    /// on a three-needle alternation quoted it at 0.47. It won its row anyway, so
    /// no regret showed; but `selected_cost` is the divisor in the sieve's
    /// survival inequality, and a 12× overstatement there is a sieve arming in
    /// front of a kernel it cannot beat.
    ///
    /// The literal split is 7.1× and self-evident. The class split is only 1.22×
    /// — narrower than the table-residency spread this file REFUSED to model, and
    /// narrower than the parked-walk axis it refused too. It is kept anyway
    /// because the two refusals were of *estimators*: a residency curve and a
    /// start-state stillness both needed a new analytical quantity, with its own
    /// error, to decide which side of a boundary a pattern fell on. This needs
    /// nothing — the kernel already carries its backend tag, so the split is a
    /// direct read of a fact the machine states about itself. Free accuracy is
    /// kept; modeled accuracy has to earn its error bar.
    settle_class_ranges: f64,
    settle_class_nibbles: f64,
    settle_literal_one: f64,
    settle_literal_many: f64,

    /// The lazy DFA's step: the same chase plus a per-transition cache probe
    /// and the amortized cost of discovering states on demand.
    lazy_step: f64,
    /// The Pike VM's step — a thread list per byte. Dear, and the reason a
    /// challenger facing this fallback should be measured against it and not
    /// against a DFA the pattern never got.
    pike_step: f64,

    /// Composition, by transformation width, plus what the 512-row
    /// end-of-line index adds per byte.
    compose16: f64,
    compose32: f64,
    compose_eol: f64,

    /// Parabix, as the two costs it actually is: the transposition every
    /// admitted program pays identically (`parabix_base`, cyc/B), and one stripe
    /// vector op of the class circuits and marker chains built on top of it
    /// (`parabix_op`).
    ///
    /// The single-slope model that preceded this folded `admit.transpose_ops`
    /// into the variable count, which is only harmless where the transposition
    /// costs about what a marker op costs. It does on NEON (the fitted intercept
    /// lands within 1.2× of what the slope alone would predict); it does not on
    /// SSSE3, where there is no `tbl` and the same transposition prices at ~6.4×
    /// a marker op. Charging that as if it scaled with the pattern under-priced
    /// dense programs and over-priced sparse ones by 29%, which is how
    /// `\b[a-z]{4}[0-9]{4}` came to be handed to a walk measuring 2.26 cyc/B
    /// over a parabix program measuring 1.55 — the mis-pick `regret` caught.
    ///
    /// This intercept is MEASURED, and is the opposite of the `9_000 + ops/8`
    /// literal the coefficient replaced: that one was a constant nobody
    /// produced, dominating every small program. Both halves come out of one
    /// least-squares fit over a slate spanning both op mixes.
    parabix_base: f64,
    parabix_op: f64,

    /// The Sheng quotient step, indexed by conjunct count minus one, at each
    /// grain. Four numbers because there are four kernels
    /// (`survives1`/`survives2` × line/doc), not one number scaled by hope.
    sieve_line: [2]f64,
    sieve_doc: [2]f64,

    /// Build cost, for the `compile` tiebreak: cycles per table byte written,
    /// and cycles per marker instruction lowered.
    build_per_table_byte: f64,
    build_per_instr: f64,

    /// Does this row describe the kernels this build compiled? One equality
    /// against `lanes.isa`, which is the same comptime feature read that chose
    /// the arms — so a row is selected by the property its numbers are actually
    /// a function of.
    pub fn fitsBuild(self: Calibration) bool {
        return self.isa == lanes.isa;
    }
};

/// Minted on this machine by `zig build ladder-price -- mint`, verified by
/// `-- verify`. Every field is one row of that run's output; none is a rounded
/// quotation of a README.
pub const neon: Calibration = .{
    .machine = "Apple M4 Max (aarch64-macos)",
    .minted = "2026-08-04",
    .isa = .neon,
    .dfa_step = 1.584,
    .dfa_line = 1.473,
    .skip_scan = 0.050,
    .skip_verify = 9.545,
    .anchor_scan = 0.057,
    .anchor_line = 29.566,
    .settle_class_ranges = 0.150,
    .settle_class_nibbles = 0.170,
    .settle_literal_one = 0.047,
    .settle_literal_many = 0.520,
    .lazy_step = 10.550,
    .pike_step = 27.921,
    .compose16 = 0.474,
    .compose32 = 0.887,
    .compose_eol = 0.483,
    .parabix_base = 0.492,
    .parabix_op = 0.543,
    .sieve_line = .{ 1.304, 0.000 },
    .sieve_doc = .{ 0.777, 0.000 },
    .build_per_table_byte = 1.974,
    .build_per_instr = 641.996,
};

/// Minted on the i5-13500 (Raptor Lake, Debian 12) by the same command, pinned
/// to the performance-core class — a hybrid part whose P-cores run at 4.8 GHz
/// and E-cores at 3.5, so a row taken without that pin describes neither.
///
/// `compose32` and `build_per_table_byte` are the two rows to read carefully.
/// The first is **zero because there is no 32-lane machine here**: the 32-lane
/// composition needs `TBL`'s two-register form, which has no SSSE3 counterpart,
/// so `lanes.widest` caps at 16 and `Compose.lowerFor` declines the width before
/// it allocates. It is not an unmeasured coefficient, it is a machine that
/// cannot be built, and `zeroCoefficientsAreUnbuildableMachines` below is what
/// holds those two claims together.
pub const avx: Calibration = .{
    .machine = "Intel Core i5-13500 (x86_64-linux)",
    .minted = "2026-08-04",
    .isa = .avx,
    .dfa_step = 2.001,
    .dfa_line = 5.196,
    .skip_scan = 0.069,
    .skip_verify = 36.478,
    .anchor_scan = 0.075,
    .anchor_line = 41.357,
    .settle_class_ranges = 0.339,
    .settle_class_nibbles = 0.235,
    .settle_literal_one = 0.075,
    .settle_literal_many = 0.619,
    .lazy_step = 12.365,
    .pike_step = 93.836,
    .compose16 = 0.854,
    .compose32 = 0.000,
    .compose_eol = 1.008,
    .parabix_base = 1.208,
    .parabix_op = 0.223,
    .sieve_line = .{ 1.568, 0.000 },
    .sieve_doc = .{ 1.031, 0.000 },
    .build_per_table_byte = 3.051,
    .build_per_instr = 881.457,
};

/// The same silicon at the x86-64-v2 floor, where `shuffle` takes its legacy
/// `pshufb` arm because the binary has no AVX to encode `vpshufb` with. Minted
/// with `-Dcpu=x86_64_v2` on the Raptor Lake box, so the CORE is held fixed and
/// the only difference from `avx` above is the permute encoding - which is the
/// point, since that is the axis a class is keyed on.
///
/// This is the row the published manylinux wheel selects, and the reason the
/// class exists as its own row rather than borrowing `avx`'s numbers. It is not
/// a rescaling of them: `compose_eol` is 40% dearer under the legacy encoding,
/// and the Parabix halves come out almost inverted (a cheap transposition and
/// dear marker ops, against `avx`'s dear transposition and cheap ops).
///
/// A real v2-only part is older than this core, so these numbers describe a
/// modern CPU executing a conservative build - which is the case that actually
/// ships, not a hypothetical Nehalem.
pub const ssse3: Calibration = .{
    .machine = "Intel Core i5-13500 at the x86-64-v2 floor (x86_64-linux)",
    .minted = "2026-08-04",
    .isa = .ssse3,
    .dfa_step = 1.924,
    .dfa_line = 5.172,
    .skip_scan = 0.082,
    .skip_verify = 24.664,
    .anchor_scan = 0.098,
    .anchor_line = 30.473,
    .settle_class_ranges = 0.309,
    .settle_class_nibbles = 0.259,
    .settle_literal_one = 0.074,
    .settle_literal_many = 0.609,
    .lazy_step = 12.297,
    .pike_step = 86.669,
    .compose16 = 0.848,
    .compose32 = 0.000,
    .compose_eol = 1.418,
    .parabix_base = 0.514,
    .parabix_op = 1.092,
    .sieve_line = .{ 1.743, 0.000 },
    .sieve_doc = .{ 1.160, 0.000 },
    .build_per_table_byte = 3.048,
    .build_per_instr = 871.991,
};

/// No calibration exists for this target. The values are Apple-arm64's, present
/// only so the arithmetic below is total — but `measured = false`, which is what
/// every vector rung consults before bidding. So on an unported target the
/// auction degenerates to exactly what it always was there: one bidder, the
/// fallback, and a unit that cancels.
pub const unmeasured: Calibration = blk: {
    var c = neon;
    c.machine = "no calibration minted for this permute class";
    c.minted = "-";
    c.measured = false;
    // Its `isa` is inherited and meaningless: this row is not in `minted`, so
    // it is only ever FALLEN TO by the `else` and never selected by a match.
    break :blk c;
};

/// Every calibration that has been minted, in the order they are consulted.
/// Adding a target is one row here plus its `isa`, and nothing else in this
/// file changes — which is the property the arch switch did not have, where a
/// new row also meant a new arm and a judgment about what the `else` should now
/// mean.
const minted = [_]Calibration{ neon, avx, ssse3 };

/// The calibration in force: the minted row for this build's permute class, and
/// `unmeasured` when none exists.
///
/// Selected on the PERMUTE rather than the architecture or the part number,
/// because that is what the kernels were compiled from and what their ratios
/// are a function of. See `Calibration.isa` for the two spellings this
/// replaced. A build with no byte permute at all lands on `.portable` and
/// matches nothing, which is correct: there is no vector kernel there to price.
pub const active: Calibration = for (minted) |c| {
    if (c.fitsBuild()) break c;
} else unmeasured;

/// May a rung whose throughput claim rests on measured silicon bid at all? The
/// capability predicates (`lanes.widest`, `plane.vectorized`) answer "does the
/// kernel exist here"; this answers "did anyone time it here", and both must
/// hold. Porting a kernel to a new target is therefore two steps that cannot be
/// confused: make it compile, then mint its calibration.
///
/// The conjunction is taken once, in `rungs.zig` (`compose_armable`,
/// `parabix_armable`), which is the file that does the bidding — a kernel asking
/// this question itself would have to import the plane that prices it.
pub const calibrated: bool = active.measured;

/// WHICH byte-at-a-time automaton is doing the walking. All three retire one
/// byte per step and differ only in what a step costs, which is why they are one
/// axis rather than three machines: the eager DFA chases a built table, the lazy
/// one probes a cache and sometimes builds a row, the Pike VM carries a thread
/// list. Getting this wrong is how a challenger ends up compared against an
/// automaton its pattern never received.
pub const Walk = enum { eager, lazy, pike };

/// WHICH kernel above the ladder settled the pattern, at the grain its own
/// throughput varies on. One role: each is a SIMD block scan `verdict.zig`
/// consults before the tier, and each can be *authoritative* rather than merely
/// a prefilter — an `.exact` literal set IS the pattern, and a newline-free
/// byte-exact class run decides any buffer. When either holds, the ladder is not
/// outbid; it is unreachable.
///
/// Each tag names a `settle_<tag>` coefficient above, and `price` maps them with
/// an `inline else` — so a fifth settling kernel cannot be added without its
/// measurement, which is the invariant that got lost when this was a bool.
pub const Settle = enum { class_ranges, class_nibbles, literal_one, literal_many };

/// One candidate machine, described by exactly the features that move its
/// price. Every field is something the machine already knows about itself at
/// admission time — no rung computes anything new in order to be priced.
pub const Machine = union(enum) {
    /// A byte-at-a-time walk, optionally behind a first-byte SIMD skip.
    /// `stride == 0` is the dense walk; anything else is the skip's own
    /// published expectation of how far it advances per candidate it surfaces,
    /// so a weak skip prices itself out with no special case anywhere.
    /// `anchored` is the second, independent acceleration: `^` means the walk
    /// only ever seeds at a line start, which is a per-LINE cost rather than a
    /// per-byte one.
    walk: struct { kind: Walk, stride: u16 = 0, anchored: bool = false },
    /// A SIMD kernel above the ladder that decides the pattern outright. Not a
    /// bidder — nothing below it runs — but it is the machine a bench asking
    /// "what answers, and what does that cost per byte?" must be told about.
    settle: Settle,
    /// Transformation composition (`shuffle/`).
    compose: struct { width: lanes.Width, eol: bool, table_bytes: usize },
    /// Bit-parallel marker propagation (`parabix/`).
    parabix: struct { stripe_ops: usize, instrs: u8 },
};

/// What this machine costs on this pattern. The one entry point, so two
/// candidates cannot be priced down two different code paths and then compared.
pub fn price(m: Machine) Cost {
    const c = active;
    return switch (m) {
        .walk => |w| .{ .scan = perByte(walk(w.kind, w.stride, w.anchored)) },
        .settle => |s| .{ .scan = perByte(switch (s) {
            inline else => |tag| @field(c, "settle_" ++ @tagName(tag)),
        }) },
        .compose => |x| .{
            .scan = perByte(switch (x.width) {
                .lanes16 => c.compose16,
                .lanes32 => c.compose32,
            } + if (x.eol) c.compose_eol else 0),
            .compile = build(c.build_per_table_byte * @as(f64, @floatFromInt(x.table_bytes))),
        },
        .parabix => |p| .{
            .scan = perByte(c.parabix_base + c.parabix_op *
                @as(f64, @floatFromInt(p.stripe_ops -| admit.transpose_ops)) /
                @as(f64, @floatFromInt(plane.stripe_width))),
            .compile = build(c.build_per_instr * @as(f64, @floatFromInt(p.instrs))),
        },
    };
}

/// Per-byte cost of a byte-at-a-time walk — dense, skipped, anchored, or both.
///
/// Unskipped and unanchored it is one step per byte. The two accelerations are
/// independent descriptions of the same walk, and each one is an upper bound on
/// what it costs, so where both apply the price is the cheaper: a walk cannot be
/// slower than either true description of it.
///
///   * **Skipped.** The skip scans cheaply and pays for verification once per
///     stride — and the verification is the SAME walk, so its measured
///     per-candidate cost scales by how dear this walker's step is against the
///     eager one's. That scaling is what lets one measured `skip_verify` cover a
///     skip in front of any of the three walkers.
///   * **Anchored.** `^` seeds only at a line start, so the engine spends its
///     bytes hunting terminators and its lines on a short verification. Scaled
///     the same way, for the same reason.
///
/// A walk is NOT discounted for parking in its start state, and the sweep that
/// asked is why. `[0-9]{40,}` measures 0.35 cyc/B against a dense walk's 1.32,
/// which looks like a state that never moves and re-reads one L1-hot row — but a
/// probe built to park a real walk (`[0-9]{4}` over a digit-free haystack, every
/// byte re-entering the start row) measured **1.14**, a 1.16× discount, inside
/// the same band the footprint sweep declines to fit. The recurrence is a
/// dependent LOAD, and its latency is the cost whichever row it reads. The 0.35
/// was a different machine entirely: the class-run kernel, which decides that
/// pattern above the ladder and is now named as such. See `Machine.sieve`.
fn walk(kind: Walk, stride: u16, anchored: bool) f64 {
    const c = active;
    const step = switch (kind) {
        .eager => c.dfa_step,
        .lazy => c.lazy_step,
        .pike => c.pike_step,
    };
    const dearness = step / c.dfa_step;
    var cost = step;
    if (stride != 0) cost = @min(cost, c.skip_scan + c.skip_verify * dearness / @as(f64, @floatFromInt(stride)));
    if (anchored) cost = @min(cost, c.anchor_scan + c.anchor_line * dearness / nominal_line);
    return cost;
}

fn build(cyc: f64) u32 {
    return if (cyc >= std.math.maxInt(u32)) std.math.maxInt(u32) else @intFromFloat(@round(@max(cyc, 0)));
}

/// What a decider's published per-byte cost becomes at a given grain.
///
/// Every rung is timed on the kernel the auction actually dispatches, and all
/// three of those are DOCUMENT kernels (`Dfa.docMatch`, `Compose.docMatch`,
/// `Parabix.match`). So a bid is a document-grain number, and a comparison at
/// the line grain has to lift it: the walk loses its four-line overlap, and the
/// measured factor is the quotient of the two walk coefficients.
///
/// This is the correction that made the sieve's arithmetic mean something. Its
/// pre-pass has two kernels, one per grain, and the line one is single-chain —
/// so weighing it against a four-chain document price said no pre-pass can ever
/// pay, which is false and was hidden for as long as the decider's price was a
/// constant transcribed from before the walk was widened.
pub fn atGrain(per_byte: f64, grain: Grain) f64 {
    const c = active;
    return switch (grain) {
        .doc => per_byte,
        .line => per_byte * @max(c.dfa_line / c.dfa_step, 1.0),
    };
}

/// A sieve's own per-byte cost at this grain — the number its survival
/// inequality weighs against the decider it would front. Absolute and measured,
/// where the ratio it replaces (0.40 of a dense DFA) silently assumed both what
/// the sieve costs and what it stands in front of.
///
/// A conjunct count nobody minted is priced from the one below it, doubled: a
/// second quotient is a second Sheng step over the same bytes, so twice the first
/// is the sound upper bound. It must never fall through as the struct's zero —
/// a free pre-pass passes every worth test, which is how an unmeasured
/// two-conjunct sieve armed in front of deciders it could not help and reached a
/// whole-buffer pass it had no `nl_reset` license for.
pub fn sievePerByte(conjuncts: u8, grain: Grain) f64 {
    const c = active;
    const row = switch (grain) {
        .line => c.sieve_line,
        .doc => c.sieve_doc,
    };
    const i = @min(@as(usize, @max(conjuncts, 1)) - 1, row.len - 1);
    var j = i;
    while (row[j] == 0 and j > 0) j -= 1;
    if (row[j] == 0) return std.math.inf(f64); // nothing at this grain was ever timed
    return row[j] * std.math.pow(f64, 2.0, @floatFromInt(i - j));
}

/// The sieve's speed against the dense walk, DERIVED rather than declared. It
/// is the shape the sieve's README argues in, and it used to be an independent
/// constant that could disagree with the two numbers it is a ratio of.
pub fn sieveSpeedRatio(conjuncts: u8, grain: Grain) f64 {
    return sievePerByte(conjuncts, grain) / active.dfa_step;
}

/// What a standalone bench should assume it is fronting when no parent named a
/// decider: the dense eager walk over a resident table, which is the machine the
/// sieve was designed against.
pub const dense_default: Cost = price(.{ .walk = .{ .kind = .eager } });

test "the unit is the one the ladder always bid in" {
    // 3.0 cyc/B is the dense walk's measured step and 30_000 was the literal
    // every rung was compared against. If those two ever stop agreeing, one of
    // them moved without the other and every historical figure is unreadable.
    try std.testing.expectEqual(@as(u32, 30_000), perByte(3.0));
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), (Cost{ .scan = 30_000 }).cycPerByte(), 1e-12);
}

test "the walk is not priced by its table's footprint, because footprint does not predict it" {
    // The inverse of the test that used to sit here, and the inversion is the
    // finding: that one asserted a blend over `table_bytes` was monotonic, which
    // it was, of a quantity the sweep then showed does not move the cost. A walk
    // is one dependent load over the rows a haystack VISITS, so a 1.4 MB table
    // and a 216-byte one measured the same 1.18 cyc/B here.
    //
    // Structurally, `Machine.walk` no longer HAS a footprint field, so the way
    // this is held is that a walk's price is a function of its kind and its two
    // accelerations alone — nothing about the table can enter it.
    try std.testing.expectEqual(@as(usize, 3), @typeInfo(@FieldType(Machine, "walk")).@"struct".fields.len);
    inline for (.{ "kind", "stride", "anchored" }) |name|
        try std.testing.expect(@hasField(@FieldType(Machine, "walk"), name));

    // And a compile-time reader gets the measured step itself, not a blend.
    try std.testing.expectApproxEqAbs(active.dfa_step, dense_default.cycPerByte(), unit_epsilon);
}

/// One `Cost.scan` tick, the resolution `perByte` rounds to.
const unit_epsilon = 1.0 / unit;

test "a skip beats a dense walk exactly when its stride earns the verification" {
    const dense = price(.{ .walk = .{ .kind = .eager } });
    // A stride of one is a skip that surfaces every byte: strictly worse than
    // walking, and the price has to say so rather than flattering the skip.
    try std.testing.expect(!price(.{ .walk = .{ .kind = .eager, .stride = 1 } })
        .lessThan(dense));
    // A rare first byte is where the skip is the whole engine.
    try std.testing.expect(price(.{ .walk = .{ .kind = .eager, .stride = 512 } })
        .lessThan(dense));
}

test "the fallbacks are ordered by what they actually are" {
    // Every rung is bid against ONE of these, and the plane this replaced priced
    // all three as the middle one. A challenger facing the Pike VM must see a
    // dearer incumbent than one facing an eager DFA, or it stands down against a
    // machine the pattern never got.
    const eager = price(.{ .walk = .{ .kind = .eager } });
    try std.testing.expect(eager.lessThan(price(.{ .walk = .{ .kind = .lazy } })));
    try std.testing.expect(price(.{ .walk = .{ .kind = .lazy } })
        .lessThan(price(.{ .walk = .{ .kind = .pike } })));
    // A skip in front of a dearer walker is dearer too: one measured
    // per-candidate cost, scaled by the step doing the verifying.
    const skip_eager = price(.{ .walk = .{ .kind = .eager, .stride = 32 } });
    const skip_pike = price(.{ .walk = .{ .kind = .pike, .stride = 32 } });
    try std.testing.expect(skip_eager.lessThan(skip_pike));
}

test "composition prices its width and its end-of-line index as independent axes" {
    // Each axis is held monotone with the OTHER two fixed, which is the whole
    // claim the model makes. It deliberately does not claim an ordering BETWEEN
    // axes: NEON measures the end-of-line index at 0.483 cyc/B and the lane
    // doubling at 0.413, so `16+eol` is dearer than `32` there and cheaper on a
    // host whose second shuffle is slower. An assertion across the two would be
    // reading one machine's coincidence as a law.
    const compose = struct {
        fn at(width: lanes.Width, eol: bool, table_bytes: usize) Cost {
            return price(.{ .compose = .{ .width = width, .eol = eol, .table_bytes = table_bytes } });
        }
    };
    // Widening lanes costs more — asked only where the wide machine EXISTS.
    // On a host whose byte shuffle is `pshufb`, the 32-lane composition has no
    // counterpart to `TBL`'s two-register form, so `compose32` is a priced hole
    // rather than a cheap machine (see `avx`) and an unconditional
    // ordering here reads that hole as the auction's best bid. The claim is not
    // weakened where it applies; it is asked of the builds it is about, and
    // `zeroCoefficientsAreUnbuildableMachines` is what keeps the skip honest by
    // proving the hole coincides with a machine `lowerFor` refuses to build.
    if (comptime lanes.armed(.lanes32)) {
        inline for (.{ false, true }) |eol|
            try std.testing.expect(compose.at(.lanes16, eol, 4 << 10)
                .lessThan(compose.at(.lanes32, eol, 4 << 10)));
    }
    inline for (.{ lanes.Width.lanes16, .lanes32 }) |w| // indexing line ends costs more
        try std.testing.expect(compose.at(w, false, 4 << 10)
            .lessThan(compose.at(w, true, 4 << 10)));
    inline for (.{ lanes.Width.lanes16, .lanes32 }) |w| // a bigger table costs more to build
        try std.testing.expect(compose.at(w, false, 4 << 10).compile <
            compose.at(w, false, 8 << 10).compile);

    // And the composition this build can actually construct still beats the
    // machine it exists to replace. Pinned at the armed width rather than always
    // at 32 lanes, because on a 16-lane host the 32-lane figure is a hole, which
    // would have made this the easiest assertion in the file exactly where it is
    // the tightest one.
    const armed = comptime lanes.widest orelse .lanes32;
    const eager_walk = price(.{ .walk = .{ .kind = .eager } });
    try std.testing.expect(compose.at(armed, false, 4 << 10).lessThan(eager_walk));

    // Whether the `+eol` form clears that same bar is a MEASUREMENT, and it
    // parts by ISA, so it is pinned as an outcome per class rather than asserted
    // one way. The legacy encoding is why: `compose_eol` is 1.418 there against
    // `avx`'s 1.008 on the same core, while the walk it bids against is slightly
    // cheaper, so `16+eol` prices at 2.266 cyc/B against a 1.924 walk and loses.
    // The bench measures that composition at 2.27 as well and the auction hands
    // the pattern to the fallback at regret 1.00x — the price working, not a
    // rung failing. Asserting a win unconditionally read two rows' agreement as
    // a law, and the only way back to green would have been relaxing whichever
    // row next told the truth.
    const eol_clears = compose.at(armed, true, 4 << 10).lessThan(eager_walk);
    try std.testing.expectEqual(switch (lanes.isa) {
        .neon, .avx => true,
        .ssse3 => false,
        .portable => true, // no compose machine here; `unmeasured` inherits NEON's
    }, eol_clears);
}

test "parabix charges its transposition once and its marker ops by the op" {
    const at = struct {
        fn ops(n: usize) f64 {
            return price(.{ .parabix = .{ .stripe_ops = n, .instrs = 4 } }).cycPerByte();
        }
    };
    // A program that is ALL transposition and no markers pays the floor and
    // nothing else — the property that makes the intercept a measured cost
    // rather than the `9_000 + ops/8` literal it replaced, which charged every
    // program for a constant no kernel produced.
    const floor = at.ops(admit.transpose_ops);
    try std.testing.expectApproxEqAbs(active.parabix_base, floor, 1e-3);

    // Above the floor the price is linear in the marker ops: twice the ops
    // ABOVE the transposition costs twice as much ABOVE the floor. Stated on
    // the variable half because that is the half the pattern controls — the
    // old form asserted it of the TOTAL, which silently claimed the
    // transposition scaled with the pattern too, and over-priced the `\b`
    // shapes by 29% on a host where it is the dearer of the two.
    const one = at.ops(admit.transpose_ops + 512) - floor;
    const two = at.ops(admit.transpose_ops + 1024) - floor;
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), two / one, 1e-3);
    try std.testing.expect(one > 0); // and it is a cost, not a discount

    // A ruinous program must price itself out rather than wrap into a bargain.
    try std.testing.expect(!price(.{ .parabix = .{ .stripe_ops = 1 << 30, .instrs = 24 } })
        .lessThan(price(.{ .walk = .{ .kind = .pike } })));
}

test "an unmeasured target withholds the flag the vector rungs bid on" {
    try std.testing.expect(!unmeasured.measured);
    try std.testing.expect(neon.measured);

    // Calibration is INDEPENDENT of whether the kernel exists — that separation
    // is the whole design (see `calibrated`), and this used to assert the two
    // were equal, which held only by the coincidence that the one calibrated
    // arch was also the only armed one. An SSSE3 host has the 16-lane kernel and
    // no price for it; that is a rung correctly standing down, not a broken
    // invariant, and the equality would have called it one.
    //
    // What must hold is that `calibrated` reports the SELECTED row rather than
    // any row that exists, so a target nobody measured cannot inherit a
    // measurement by being compiled next to one.
    try std.testing.expectEqual(active.measured, calibrated);
    try std.testing.expectEqual(active.fitsBuild() or !active.measured, true);
}

test "a zero coefficient is an unbuildable machine, never a free one" {
    // `price` reads a coefficient and multiplies; nothing in that arithmetic can
    // tell "nobody measured this" from "this costs nothing", so a hole in a row
    // prices as the CHEAPEST bid available and the auction picks it every time.
    // The plane is safe from that only because a coefficient is allowed to be
    // zero exactly where the corresponding machine cannot be constructed — and
    // that is a coincidence between two files until something asserts it.
    //
    // Live case: `avx.compose32 = 0`, because the 32-lane composition
    // needs `TBL`'s two-register form and SSSE3 has no counterpart. Delete the
    // width guard in `Compose.lowerFor` and this test is what fails, rather than
    // an x86 auction quietly awarding every wide pattern to a free machine.
    if (comptime !active.measured) return error.SkipZigTest;

    if (active.compose16 == 0) try std.testing.expect(lanes.widest == null);
    if (active.compose32 == 0) try std.testing.expect(!lanes.armed(.lanes32));
    // Every compose machine writes a table, so a priced width needs a priced build.
    if (active.build_per_table_byte == 0) try std.testing.expect(lanes.widest == null);
    // Parabix needs BOTH halves: a zero slope prices every marker op free, and
    // a zero floor hands out the transposition — the one cost no admitted
    // program escapes — for nothing.
    if (active.parabix_base == 0 or active.parabix_op == 0 or active.build_per_instr == 0)
        try std.testing.expect(!plane.vectorized);

    // And the converse for the width actually armed here: a kernel this build
    // CAN construct must carry a price, or the rung bids nothing against a
    // fallback that bids something.
    if (comptime lanes.widest) |w| {
        try std.testing.expect(switch (w) {
            .lanes16 => active.compose16,
            .lanes32 => active.compose32,
        } > 0);
    }
}

test "a calibration is claimed by permute, so a foreign kernel cannot inherit one" {
    // The bug this pins: `active` selected on `builtin.cpu.arch`, so EVERY
    // AArch64 core read the Apple row. Graviton and Ampere are AArch64 and are
    // not an M4 Max, and the auction compares these numbers against each other
    // — so a foreign row does not merely mis-scale, it re-orders the rungs.
    //
    // A row for a permute this build did not compile is not selected. `.portable`
    // is the case that always exists to test with, since a build that HAS a
    // permute is by construction not portable.
    if (comptime lanes.isa != .portable) try std.testing.expect(!(Calibration{
        .machine = "x",
        .minted = "-",
        .isa = .portable,
        .dfa_step = 1,
        .dfa_line = 1,
        .skip_scan = 1,
        .skip_verify = 1,
        .anchor_scan = 1,
        .anchor_line = 1,
        .settle_class_ranges = 1,
        .settle_class_nibbles = 1,
        .settle_literal_one = 1,
        .settle_literal_many = 1,
        .lazy_step = 1,
        .pike_step = 1,
        .compose16 = 1,
        .compose32 = 1,
        .compose_eol = 1,
        .parabix_base = 1,
        .parabix_op = 1,
        .sieve_line = .{ 1, 0 },
        .sieve_doc = .{ 1, 0 },
        .build_per_table_byte = 1,
        .build_per_instr = 1,
    }).fitsBuild());

    // `unmeasured` is reachable only by falling through, never by matching. Its
    // `isa` is inherited from the row it was copied from, so if it were ever
    // consulted it would claim a class it holds no measurement for.
    inline for (minted) |c| try std.testing.expect(!std.mem.eql(
        u8,
        c.machine,
        unmeasured.machine,
    ));

    // At most one row per class, or `active` silently prefers whichever was
    // listed first and the other is a dead measurement nobody can reach.
    inline for (minted, 0..) |a, i| {
        inline for (minted, 0..) |b, j| {
            if (comptime i < j) try std.testing.expect(a.isa != b.isa);
        }
    }

    // Every class that can BUILD a vector kernel has a row. This is the wheel
    // bug as an assertion: `.ssse3` is the x86-64-v2 floor the published
    // manylinux wheel declares, it compiles the 16-lane composition and the
    // Parabix transposition, and for as long as rows were claimed by part
    // number it matched none of them and bid neither.
    //
    // Read off the enum rather than a list written here, so the next arm added
    // to `shuffle` fails THIS test until it is measured. A hand-kept list would
    // have let a new class ship the way `.ssse3` did — kernels compiled in, no
    // row to price them, silently bidding nothing.
    inline for (@typeInfo(lanes.Isa).@"enum".fields) |f| {
        const k: lanes.Isa = @enumFromInt(f.value);
        if (k == .portable) continue; // no vector kernel to price
        var found = false;
        inline for (minted) |c| {
            if (c.isa == k) found = true;
        }
        if (!found) {
            std.debug.print("permute class .{s} has a kernel and no calibration\n", .{f.name});
            return error.UnmintedPermuteClass;
        }
    }
}

test "the sieve's ratio is a quotient of two measured numbers" {
    for ([_]u8{ 1, 2 }) |n| for ([_]Grain{ .line, .doc }) |g| {
        try std.testing.expectApproxEqAbs(
            sievePerByte(n, g) / active.dfa_step,
            sieveSpeedRatio(n, g),
            1e-12,
        );
    };
    // The document kernel advances four lines at once, so it must price under
    // the per-line one — the distinction the single 0.40 ratio could not make.
    try std.testing.expect(sievePerByte(1, .doc) < sievePerByte(1, .line));
    // And a second conjunct is not free.
    try std.testing.expect(sievePerByte(1, .line) < sievePerByte(2, .line));
}
