//! The writ: everything the argv patterns decide, decided once.
//!
//! A `Writ` is what an invocation's patterns COMPILE TO. Handed the effective
//! pattern and the parsed options, it resolves the engine arm, both literal
//! gates, the trigram prefilters, the crest sieve, and whether binary detection
//! is live — with every eligibility guard already applied INSIDE. Callers read
//! fields; they never re-derive one.
//!
//! That distinction is the whole point. The obvious shape here is a context
//! struct: a bag of parameters threaded through the pipeline to shorten
//! signatures. That would be a shallow module — it carries, but computes
//! nothing, so every caller still reaches in and re-spells the guard it cares
//! about, which is precisely the state this replaced. `run` used to build the
//! prefilters and then re-guard them a second time on its own line, because the
//! knowledge of when pruning is legal lived in neither place completely.
//!
//! A `Writ` computes. `filters` is empty when index elision is inadmissible;
//! `file_needle` is null when a mode must read every body. There is no
//! "remember to also check" left for a caller to forget, which is what makes
//! adding an output mode a one-line change in `gate.zig` instead of a hunt
//! through five call sites where missing one returns a wrong answer with a
//! clean exit code.

const std = @import("std");
const args = @import("../argv/args.zig");
const arm = @import("arm.zig");
const crest = @import("../../../kernel/math/crest.zig");
const gate = @import("gate.zig");
const query_mod = @import("../../../kernel/query/query.zig");
const simd = @import("../../../kernel/scan/simd.zig");

const Matcher = @import("../../../kernel/regex/regex.zig").Matcher;
const Opts = args.Opts;
const oom = @import("../../../surface/cli/outcome.zig").oom;

/// Is binary detection live for this run? `-a`/`--text` treats every byte as
/// text, `--binary` opts into searching binary files, and `--null-data` makes
/// NUL a record separator rather than a binary signal — any of the three and
/// the detector stands down.
///
/// One owner, because this was spelled seven different ways across four files
/// in three different arities, and two of those spellings were only equivalent
/// by an unstated coupling to a caller's eligibility check.
pub fn binaryDetect(o: Opts) bool {
    return !o.text and !o.binary and !o.null_data;
}

/// One invocation's patterns, compiled: the engine arm plus every derived
/// prefilter, each already stood down where it would be unsound.
pub const Writ = struct {
    /// The resolved engine arm. Owned — `deinit` releases it.
    re: Matcher,
    /// The backend actually chosen (an `--engine auto` pattern may have
    /// escalated), not the one requested.
    is_pcre: bool,
    /// Required-literal SIMD gate for skipping a regex run on a line that
    /// cannot match. Null when no sound literal exists.
    line_needle: ?simd.Gate,
    /// The same gate applied to a whole body — null whenever this run's output
    /// mode must read every file regardless (`gate.mayDropFileUnread`).
    file_needle: ?simd.Gate,
    /// Trigram prefilters for index elision; empty when elision is
    /// inadmissible (`gate.mayElideByIndex`).
    filters: []const []const u8,
    /// The conjunctive cover — the CNF plan the index evaluates in place of the
    /// flat OR of `filters`, or null to use those filters unchanged. Strictly
    /// stronger where present and always declinable, so `filters` stays the
    /// fallback rather than being superseded (`gate.winnow`).
    plan: ?[]const query_mod.CoverPlan,
    /// The crest sieve's forced swell — ĝ per top-level alternative; the empty
    /// swell when it must not elide.
    sieve: crest.Swell,
    /// Whether the binary detector runs on each file.
    binary_detect: bool,

    /// Compile `eff` under `o` into the run's writ. `gpa` owns the engine arm;
    /// `a` is the run arena backing the prefilter slices, which live as long as
    /// the invocation. `transforming` is the ingest pipeline's verdict
    /// (`-z`/`--pre`/`-E`): it searches rewritten bytes, so the on-disk index
    /// artifacts cannot speak about them.
    pub fn compile(gpa: std.mem.Allocator, a: std.mem.Allocator, o: Opts, eff: []const u8, transforming: bool) Writ {
        var re = arm.buildMatcher(gpa, eff, o);
        const line_needle = gate.requiredLiteralGate(a, o, eff, &re);
        // Arena-owned rather than caller-stack-owned: a one-element prefilter
        // slice points AT this cell, so it has to outlive `compile`'s frame.
        const one = a.create([1][]const u8) catch oom();
        // One parse for both index-prunings — the plan and the swell are each a
        // linear walk over the same AST, and cold used to pay `lower.parse`
        // twice to read them.
        const w = gate.winnow(a, o, eff, &re, transforming);
        return .{
            .re = re,
            .is_pcre = std.meta.activeTag(re) == .pcre,
            .line_needle = line_needle,
            .file_needle = gate.wholeFileLiteralGate(o, line_needle),
            .filters = gate.trigramFilter(a, o, eff, &re, one, transforming),
            .plan = w.plan,
            .sieve = w.sieve,
            .binary_detect = binaryDetect(o),
        };
    }

    pub fn deinit(self: *Writ) void {
        self.re.deinit();
    }
};
