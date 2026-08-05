//! gist bench — the ENGINE CENSUS: for every certificate probe class, which
//! machine actually answers it.
//!
//! The certificate reports what a class COSTS. It cannot report which of the
//! ladder's machines produced that cost, and the two questions come apart
//! exactly where it matters: a class that reads as a modest win may be a class
//! whose accelerator silently declined to arm, and no timing row says so. Every
//! rung declines by being absent (`ladder/rungs.zig`), which is the right
//! failure mode for correctness and the worst one for observability.
//!
//! So this reads `Regex`'s own admission evidence — the same `Admission` the
//! ladder filled at compile time, never a re-derivation — and prints one row per
//! probe: the selected decider, its costed offer against the fallback's, whether
//! a sieve fronted it, and which cheaper reduction (literal set, class run)
//! pre-emptied the tier entirely.
//!
//! Reads only; it arms nothing and changes no answer.

const std = @import("std");
const irregex = @import("irregex");
const probes = @import("probes");

const Regex = irregex.regex.Regex;
const lanes = irregex.regex.compose.lanes;
const sieve_mod = irregex.regex.sieve;

/// The sieve's own account of itself. It is the one rung whose refusal is
/// usually a COST verdict rather than a representability one, and the two want
/// different responses — `unprofitable` names an estimate to re-examine, every
/// other value names a structure that cannot be projected.
const SieveFact = struct {
    decline: []const u8,
    fallthrough: f64,
    line_total: f64,
    doc_total: f64,
    decider: u32,
};

fn sieveFact(gpa: std.mem.Allocator, re: *const Regex, decider_cost: u32) SieveFact {
    const d = re.dfa orelse return .{ .decline = "no-eager-dfa", .fallthrough = 0, .line_total = 0, .doc_total = 0, .decider = decider_cost };
    const r = sieve_mod.Sieve.buildDfa(gpa, d, .{ .decider_cost = decider_cost }, .worth) catch
        return .{ .decline = "oom", .fallthrough = 0, .line_total = 0, .doc_total = 0, .decider = decider_cost };
    var out: SieveFact = .{
        .decline = if (r.decline) |w| @tagName(w) else "-armed-",
        .fallthrough = 0,
        .line_total = 0,
        .doc_total = 0,
        .decider = decider_cost,
    };
    if (r.cost) |c| {
        out.fallthrough = c.fallthrough;
        out.line_total = c.total(.line);
        out.doc_total = c.total(.doc);
    }
    if (r.sieve) |s| s.deinit();
    return out;
}

/// Why `compose` — the widest-armed rung, and the only one with a costed offer
/// far under the dense fallback — was not available for this pattern. Each
/// answer is a different lever: a width refusal is an automaton-size problem, a
/// skippable-start-dwell refusal is a dispatch judgment, and no-DFA is a
/// determinization budget problem no rung can see past.
fn composeDecline(re: *const Regex) []const u8 {
    if (lanes.widest == null) return "no-byte-shuffle";
    const d = re.dfa orelse return if (re.lazy != null) "no-eager-dfa(lazy)" else "no-dfa(pike)";
    if (d.word_ctx) return "word-ctx";
    if (d.isMatch(d.start)) return "start-accepts";
    if (d.start_dwell != null) return "dwell-armed";
    return "width>31";
}

/// One census row: what the ladder chose, and the evidence it chose it on.
const Row = struct {
    class: []const u8,
    pattern: []const u8,
    /// The cheapest reduction that pre-empts the accelerator tier, if any.
    /// These answer above the rungs in `verdict.zig`, so an armed rung behind
    /// one of them is unreachable for that entry point.
    reduction: []const u8,
    selected: []const u8,
    selected_cost: u32,
    fallback_cost: u32,
    sieve: bool,
    stride: u32,
    dfa: []const u8,
    caliper: bool,
    selected_is_compose: bool,
};

/// A `.literal` probe is what the CLI reaches with `-F`, and the CLI escapes it
/// before compiling — so the census must too, or a punctuation needle (`})`)
/// reads as a parse failure rather than as the class it certifies.
fn escaped(gpa: std.mem.Allocator, pat: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    for (pat) |c| {
        if (std.mem.indexOfScalar(u8, "\\^$.[]|()?*+{}", c) != null) try buf.append(gpa, '\\');
        try buf.append(gpa, c);
    }
    return buf.toOwnedSlice(gpa);
}

fn reductionOf(re: *const Regex) []const u8 {
    if (re.eol_empty) return "eol-empty";
    if (re.literal_scan) |*set| return if (set.authority == .exact) "literal-exact" else "literal-cand";
    if (re.classrun) |*cr| return if (cr.exact or cr.cp != null) "classrun-final" else "classrun-partial";
    return "-";
}

/// The two transition tables' resident size. The DFA's hot loop is a
/// loop-carried dependent load, so which cache level holds this number is the
/// per-byte cost — a table over L1 pays L2 latency on every byte it walks.
fn tableKiB(re: *const Regex) usize {
    const d = re.dfa orelse return 0;
    return (2 * @as(usize, d.nstates) * d.ncls * @sizeOf(u32)) / 1024;
}

fn dfaOf(re: *const Regex) []const u8 {
    if (re.dfa) |d| return if (d.word_ctx) "eager-word" else "eager";
    if (re.lazy != null) return "lazy";
    return "pike";
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    std.debug.print("{s:<19} {s:<24} {s:<17} {s:<9} {s:>8} {s:>8} {s:>6} {s:>7} {s:<11} {s:>7} {s:>7} {s:>5} {s:<18}\n", .{
        "class",  "pattern", "reduction", "selected", "sel_cost", "fb_cost",         "sieve",
        "stride", "dfa",     "caliper",   "nstates",  "ncls",     "compose-decline",
    });
    std.debug.print("{s:-<19} {s:-<24} {s:-<17} {s:-<9} {s:->8} {s:->8} {s:->6} {s:->7} {s:-<11} {s:->7} {s:->7} {s:->5} {s:-<18}\n", .{
        "", "", "", "", "", "", "", "", "", "", "", "", "",
    });
    for (probes.probes) |p| {
        // The production compile: rg's default posture is Unicode-on, which is
        // what every certificate row was measured under.
        const eff = if (p.kind == .literal) try escaped(gpa, p.pattern) else null;
        defer if (eff) |e| gpa.free(e);
        var re = try Regex.compileOpts(gpa, eff orelse p.pattern, .{ .unicode = true });
        defer re.deinit();
        const a = re.rungs.admission;
        const row: Row = .{
            .class = p.class,
            .pattern = p.pattern,
            .reduction = reductionOf(&re),
            .selected = @tagName(a.selected),
            .selected_cost = a.selected_cost.scan,
            .fallback_cost = a.fallback_cost.scan,
            .sieve = a.sieve,
            .stride = if (a.prefilter) |pf| pf.stride else 0,
            .dfa = dfaOf(&re),
            .caliper = re.caliper != null,
            .selected_is_compose = a.selected != .fallback,
        };
        // The same pattern with the predicate-alphabet route pinned OFF. Both
        // constructions produce the same language, so any difference in shape is
        // exactly what `symbolic/` is buying — and a shape difference is what
        // decides whether the rungs above can arm at all.
        var byte_re = try Regex.compileOpts(gpa, eff orelse p.pattern, .{ .unicode = true, .symbolic = .off });
        defer byte_re.deinit();
        const sf = sieveFact(gpa, &re, row.selected_cost);
        std.debug.print("{s:<19} {s:<24} {s:<17} {s:<9} {d:>8} {d:>8} {any:>6} {d:>7} {s:<11} {any:>7} {d:>7} {d:>5} {s:<18}\n", .{
            row.class,                        row.pattern,                   row.reduction,                                             row.selected, row.selected_cost,
            row.fallback_cost,                row.sieve,                     row.stride,                                                row.dfa,      row.caliper,
            if (re.dfa) |d| d.nstates else 0, if (re.dfa) |d| d.ncls else 0, if (row.selected_is_compose) "-" else composeDecline(&re),
        });
        std.debug.print("{s:<19}   ├─ sieve: {s:<20} fallthrough={e:>10.3}  line: {d:>8.0} vs {d:<8}  doc: {d:>8.0}\n", .{
            "", sf.decline, sf.fallthrough, sf.line_total, sf.decider, sf.doc_total,
        });
        std.debug.print("{s:<19}   └─ symbolic=off: {s:<11} nstates={d:<6} ncls={d:<5} table={d:>7} KiB   (auto table={d:>7} KiB)\n", .{
            "",
            dfaOf(&byte_re),
            if (byte_re.dfa) |d| d.nstates else 0,
            if (byte_re.dfa) |d| d.ncls else 0,
            tableKiB(&byte_re),
            tableKiB(&re),
        });
    }
}
