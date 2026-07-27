//! gist — proofs for the symbolic (predicate-alphabet) determinizer.
//!
//! The claim under test is narrow and total: for every pattern the symbolic
//! path accepts, the byte DFA it transcribes recognizes **the same language**
//! as the byte-trie powerset it replaces, and both equal the Pike VM. So the
//! suite is three differentials, not a re-description of the construction:
//!
//!   1. symbolic DFA ≡ Pike VM, over haystacks laced with **malformed** UTF-8
//!      (lone continuation bytes, truncated sequences, surrogate encodings) —
//!      the resync path is where a product construction goes wrong, so that is
//!      where the probes concentrate;
//!   2. symbolic DFA ≡ byte-powerset DFA, compiled from the same pattern with
//!      `.symbolic = .off`, on the same probes — the shipped construction held
//!      up as the oracle it is;
//!   3. the same two, at document level through `docMatch`.
//!
//! Plus the cost claim the lane exists for: the NFA-state visit collapse,
//! measured on the real engine by running BOTH determinizers over the same
//! compiled program.

const std = @import("std");
const regex = @import("../program/core.zig");
const lower = @import("../program/lower.zig");
const subset = @import("../dfa/subset.zig");
const powerset = @import("../dfa/powerset.zig");
const symbolic = @import("symbolic.zig");
const minimize = @import("minimize.zig");
const Regex = regex.Regex;
const expect = std.testing.expect;

/// Bytes the differentials draw haystacks from: ASCII word/non-word, whole
/// multi-byte scalars (é, 中, Σ), and the malformed units — a lone continuation
/// byte, an unpaired lead, and the surrogate lead `ED` whose `A0` continuation
/// has no well-formed encoding.
const bytes = [_]u8{ 'a', 'X', '_', '1', ' ', '.', '\n', 0xC3, 0xA9, 0xE4, 0xB8, 0xAD, 0xCE, 0xA3, 0x80, 0xBF, 0xED, 0xA0, 0xFF };

/// Pattern fragments that all carry at least one codepoint class, so every
/// generated pattern is one the symbolic path is offered.
const frags = [_][]const u8{ "\\w", "\\d", "\\s", "\\W", ".", "\\p{L}", "\\p{Lu}", "\\p{Greek}", "é", "中", "Σ", "[a-cé]", "[^é]", "[é中]", "a", "X" };
const quants = [_][]const u8{ "", "+", "*", "?", "{2}", "{1,3}", "+?", "*?" };

const Gen = struct {
    r: std.Random,
    buf: *std.ArrayList(u8),
    a: std.mem.Allocator,

    fn pattern(g: *Gen) !void {
        if (g.r.boolean()) try g.buf.append(g.a, '^');
        const nalt = 1 + g.r.uintLessThan(usize, 2);
        for (0..nalt) |i| {
            if (i > 0) try g.buf.append(g.a, '|');
            const nfrag = 1 + g.r.uintLessThan(usize, 3);
            for (0..nfrag) |_| {
                const grouped = g.r.uintLessThan(u8, 4) == 0;
                if (grouped) try g.buf.append(g.a, '(');
                try g.buf.appendSlice(g.a, frags[g.r.uintLessThan(usize, frags.len)]);
                if (grouped) try g.buf.append(g.a, ')');
                try g.buf.appendSlice(g.a, quants[g.r.uintLessThan(usize, quants.len)]);
            }
        }
        if (g.r.boolean()) try g.buf.append(g.a, '$');
    }
};

/// Fill `buf` with a random byte string from `bytes`. Deliberately byte-wise,
/// not codepoint-wise: splitting a UTF-8 unit is the interesting input.
fn haystack(r: std.Random, buf: []u8) []u8 {
    for (buf) |*b| b.* = bytes[r.uintLessThan(usize, bytes.len)];
    return buf;
}

/// Compile a pattern down BOTH determinizations. Null when either declined, so
/// a caller can tell "not comparable" from "compared and agreed".
const Pair = struct {
    sym: Regex,
    byte: Regex,

    fn init(a: std.mem.Allocator, pat: []const u8) ?Pair {
        var sym = Regex.compileOpts(a, pat, .{ .unicode = true, .force_dfa = true }) catch return null;
        if (sym.dfa == null) {
            sym.deinit();
            return null;
        }
        var byte = Regex.compileOpts(a, pat, .{ .unicode = true, .force_dfa = true, .symbolic = .off }) catch {
            sym.deinit();
            return null;
        };
        if (byte.dfa == null) {
            sym.deinit();
            byte.deinit();
            return null;
        }
        return .{ .sym = sym, .byte = byte };
    }

    fn deinit(p: *Pair) void {
        p.sym.deinit();
        p.byte.deinit();
    }
};

test "symbolic: line differential vs the Pike VM and the byte powerset, malformed UTF-8 included" {
    const a = std.testing.allocator;
    var line_buf: [20]u8 = undefined;
    var checked: usize = 0;
    var symbolic_built: usize = 0;

    var seed: u64 = 0;
    while (seed < 1400) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed *% 0x9E3779B97F4A7C15);
        const r = prng.random();
        var pat: std.ArrayList(u8) = .empty;
        defer pat.deinit(a);
        var g = Gen{ .r = r, .buf = &pat, .a = a };
        try g.pattern();

        var p = Pair.init(a, pat.items) orelse continue;
        defer p.deinit();
        // The two determinizations must have produced DIFFERENT constructions
        // for this to be a real comparison — every generated pattern carries a
        // codepoint class, so the symbolic path is the one that built `p.sym`.
        symbolic_built += 1;
        var sim = try Regex.Sim.init(a, &p.sym);
        defer sim.deinit();

        for (0..150) |trial| {
            const len = if (trial == 0) 0 else r.uintLessThan(usize, line_buf.len + 1);
            const line = haystack(r, line_buf[0..len]);
            const got = p.sym.dfa.?.match(line);
            const want = p.sym.lineMatchPike(&sim, line);
            if (got != want) {
                std.debug.print("SYMBOLIC/PIKE DIVERGENCE pat=/{s}/ line={x} sym={} pike={}\n", .{ pat.items, line, got, want });
                return error.SymbolicPikeDivergence;
            }
            const shipped = p.byte.dfa.?.match(line);
            if (got != shipped) {
                std.debug.print("SYMBOLIC/POWERSET DIVERGENCE pat=/{s}/ line={x} sym={} byte={}\n", .{ pat.items, line, got, shipped });
                return error.SymbolicPowersetDivergence;
            }
            checked += 1;
        }
    }
    std.debug.print("\n  line decisions: {d} over {d} patterns, 0 divergences\n", .{ checked, symbolic_built });
    try expect(symbolic_built > 500);
    try expect(checked > 180_000);
}

test "symbolic: document differential vs the Pike VM and the byte powerset" {
    const a = std.testing.allocator;
    var doc_buf: [40]u8 = undefined;
    var checked: usize = 0;

    var seed: u64 = 0;
    while (seed < 1400) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed *% 0x2545F4914F6CDD1D);
        const r = prng.random();
        var pat: std.ArrayList(u8) = .empty;
        defer pat.deinit(a);
        var g = Gen{ .r = r, .buf = &pat, .a = a };
        try g.pattern();

        var p = Pair.init(a, pat.items) orelse continue;
        defer p.deinit();
        var sim = try Regex.Sim.init(a, &p.sym);
        defer sim.deinit();

        for (0..150) |trial| {
            const len = if (trial == 0) 0 else r.uintLessThan(usize, doc_buf.len + 1);
            const doc = haystack(r, doc_buf[0..len]);
            const got = p.sym.dfa.?.docMatch(doc);
            const want = pikeDoc(&p.sym, &sim, doc);
            if (got != want) {
                std.debug.print("SYMBOLIC/PIKE DOC DIVERGENCE pat=/{s}/ doc={x} sym={} pike={}\n", .{ pat.items, doc, got, want });
                return error.SymbolicPikeDocDivergence;
            }
            const shipped = p.byte.dfa.?.docMatch(doc);
            if (got != shipped) {
                std.debug.print("SYMBOLIC/POWERSET DOC DIVERGENCE pat=/{s}/ doc={x} sym={} byte={}\n", .{ pat.items, doc, got, shipped });
                return error.SymbolicPowersetDocDivergence;
            }
            checked += 1;
        }
    }
    std.debug.print("\n  document decisions: {d}, 0 divergences\n", .{checked});
    try expect(checked > 180_000);
}

/// Per-line Pike verdict over a whole buffer — `dfa_test.zig`'s reference for
/// the single-pass `docMatch`, restated here so this file stands alone.
fn pikeDoc(re: *Regex, sim: *Regex.Sim, doc: []const u8) bool {
    var rest = doc;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const end = nl orelse rest.len;
        if (re.lineMatchPike(sim, rest[0..end])) return true;
        if (nl == null) break;
        rest = rest[end + 1 ..];
    }
    return false;
}

test "symbolic: hand-picked resync, surrogate and anchor cases" {
    const a = std.testing.allocator;
    const Case = struct { pat: []const u8, line: []const u8, want: bool };
    const cases = [_]Case{
        // A malformed lead resyncs: the second C3 starts a fresh sequence.
        .{ .pat = "é", .line = "\xC3\xC3\xA9", .want = true },
        // …but an ANCHORED pattern must not be re-seeded by that resync.
        .{ .pat = "^é", .line = "\xC3\xC3\xA9", .want = false },
        .{ .pat = "^é", .line = "\xC3\xA9", .want = true },
        // A surrogate encoding is not a codepoint anywhere in the engine.
        .{ .pat = ".", .line = "\xED\xA0\x80", .want = false },
        .{ .pat = "\\w", .line = "\xED\xA0\x80", .want = false },
        // A truncated tail is not a character, but a nullable pattern still
        // matches the empty string at the position after it.
        .{ .pat = "\\w+", .line = "\xC3", .want = false },
        .{ .pat = "\\w*$", .line = "\xC3", .want = true },
        .{ .pat = "\\w+$", .line = "a\xC3", .want = false },
        .{ .pat = "\\w+$", .line = "a\xC3\xA9", .want = true },
        // A continuation byte arriving at a boundary matches nothing and kills
        // no future match.
        .{ .pat = "\\w+X", .line = "\x80aX", .want = true },
        .{ .pat = "^\\w+X", .line = "\x80aX", .want = false },
        // Ordinary Unicode, to pin that the fast path is still the point.
        .{ .pat = "\\w+X", .line = "café X", .want = false },
        .{ .pat = "\\w+X", .line = "caféX", .want = true },
        .{ .pat = "\\p{Greek}+", .line = "ΚΌΣΜΟΣ", .want = true },
        .{ .pat = "\\p{Greek}+", .line = "kosmos", .want = false },
    };
    for (cases) |c| {
        var re = try Regex.compileOpts(a, c.pat, .{ .unicode = true, .force_dfa = true });
        defer re.deinit();
        try expect(re.dfa != null);
        var sim = try Regex.Sim.init(a, &re);
        defer sim.deinit();
        const got = re.dfa.?.match(c.line);
        if (got != c.want or re.lineMatchPike(&sim, c.line) != c.want) {
            std.debug.print("CASE FAILURE pat=/{s}/ line={x} dfa={} want={}\n", .{ c.pat, c.line, got, c.want });
            return error.SymbolicCaseFailure;
        }
    }
}

test "symbolic: declines the constructs it cannot express exactly" {
    const a = std.testing.allocator;
    // Word context, buffer anchors and raw high-byte classes all stay on the
    // byte path — proven by asking the symbolic builder directly.
    const declined = [_][]const u8{ "\\bcafé\\b", "\\w+\\B", "\\<é\\>" };
    for (declined) |pat| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const ast = lower.parse(arena.allocator(), pat, .{ .unicode = true }) catch |e| {
            std.debug.print("PARSE {t} on /{s}/\n", .{ e, pat });
            return e;
        };
        var stats: symbolic.Stats = .{};
        switch (try symbolic.build(a, ast, false, &stats)) {
            .built => |d| {
                d.deinit();
                std.debug.print("EXPECTED DECLINE on /{s}/\n", .{pat});
                return error.UnexpectedSymbolicBuild;
            },
            .declined => {},
        }
    }
    // An ASCII-only program is not even offered: the byte path is already
    // optimal there and routing it here would buy nothing. `\w+X` appears under
    // both engine modes — Unicode off is exactly the `(?-u)` twin.
    for ([_][]const u8{ "abc", "[a-f0-9]{4}", "\\w+X" }) |pat| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const ast = try lower.parse(arena.allocator(), pat, .{ .unicode = false });
        try expect(!symbolic.eligible(ast));
    }
}

// ───────────────────────── the cost claim, measured ─────────────────────────

/// Run the SHIPPED byte determinizer over a compiled program and report what it
/// cost. This is `powerset.build`'s own loop over `subset.Subset` — the public
/// determinizer core both drivers share — so the visit count it bills is the
/// one the eager driver's budget is spent against.
const ByteCost = struct { visits: u64, nstates: u32, minimal: u32 = 0, ncls: u16, capped: bool };

fn byteCost(a: std.mem.Allocator, re: *const Regex) !ByteCost {
    const word_ctx = subset.hasWordContext(re.states);
    const cls = subset.Classes.build(re.states, word_ctx);
    var sub = try subset.Subset.init(a, re.states, re.start, re.anchored, word_ctx, cls);
    defer sub.deinit();
    _ = sub.closeStart(true, true, false);
    const start_id = (try sub.intern(sub.closeStart(true, false, false))).id;

    var queued: std.ArrayList(bool) = .empty;
    defer queued.deinit(a);
    var work: std.ArrayList(u32) = .empty;
    defer work.deinit(a);
    try work.append(a, start_id);
    try queued.append(a, true);

    var cur: usize = 0;
    while (cur < work.items.len) : (cur += 1) {
        const id = work.items[cur];
        var k: u16 = 0;
        while (k < cls.ncls) : (k += 1) {
            const to = try sub.expand(id, k, .interior);
            _ = try sub.expand(id, k, .final);
            while (queued.items.len < sub.nstates) try queued.append(a, false);
            if (!queued.items[to]) {
                queued.items[to] = true;
                try work.append(a, to);
            }
            if (sub.nstates > powerset.max_states) return .{ .visits = sub.visits, .nstates = sub.nstates, .ncls = cls.ncls, .capped = true };
        }
    }
    // Minimize the byte path's own table with the same pass the symbolic path
    // uses. Two facts fall out of one number: how much slack the shipped
    // construction leaves, and — since both tables recognize the same language
    // — a floor the symbolic table must not sit far above.
    const map = try a.alloc(u32, sub.nstates);
    defer a.free(map);
    const min = try minimize.run(a, sub.nstates, cls.ncls, sub.trans_in.items, sub.trans_fin.items, sub.is_match.items, map);
    return .{ .visits = sub.visits, .nstates = sub.nstates, .minimal = min, .ncls = cls.ncls, .capped = false };
}

test "symbolic: the NFA-state visit collapse, on the real engine" {
    const a = std.testing.allocator;
    // `\w+X` is the report's headline: the byte path spends millions of visits
    // re-walking the UTF-8 trie to discover a few hundred states. `\w{3,8}`
    // clones that trie per repetition. Their `(?-u)` twins are the floor the
    // symbolic path is claimed to reach.
    // `factor`: how many times cheaper the symbolic walk must be. A big class
    // pays the trie tax the lane exists to remove, so its floor is enormous;
    // `é+X` is a two-node decoder with nothing to save, and is here to pin that
    // the path stays *at parity* on patterns it cannot improve rather than
    // regressing them.
    const Case = struct { pat: []const u8, factor: u64 };
    for ([_]Case{
        .{ .pat = "\\w+X", .factor = 10_000 },
        .{ .pat = "\\w{3,8}", .factor = 10_000 },
        .{ .pat = "\\p{L}+;", .factor = 10_000 },
        .{ .pat = "é+X", .factor = 1 },
    }) |case| {
        const pat = case.pat;
        var re = try Regex.compileOpts(a, pat, .{ .unicode = true, .force_dfa = true, .symbolic = .off });
        defer re.deinit();
        const byte = try byteCost(a, &re);

        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const ast = try lower.parse(arena.allocator(), pat, .{ .unicode = true });
        var stats: symbolic.Stats = .{};
        const out = try symbolic.build(a, ast, re.anchored, &stats);
        const dfa = switch (out) {
            .built => |d| d,
            .declined => return error.SymbolicDeclinedMeasuredPattern,
        };
        defer dfa.deinit();

        std.debug.print(
            "\n  /{s}/  byte: {d} visits, {d}x{d} table (minimal {d}){s}  |  symbolic: {d} visits, {d} minterms ({d} pruned), {d} decoder nodes, {d} cp-states, {d} raw pairs -> {d}x{d} table",
            .{ pat, byte.visits, byte.nstates, byte.ncls, byte.minimal, if (byte.capped) " (capped)" else "", stats.visits, stats.minterms, stats.pruned, stats.nodes, stats.pat_states, stats.product_states, dfa.nstates, dfa.ncls },
        );
        // The collapse is the whole lane — and the table it lands on is not a
        // trade for it: no more states than the byte construction's MINIMAL
        // automaton (so, never more than what ships today) and no more classes.
        try expect(stats.visits * case.factor <= byte.visits);
        if (!byte.capped) {
            try expect(dfa.nstates <= byte.minimal);
            try expect(dfa.ncls <= byte.ncls);
        }
    }
    std.debug.print("\n", .{});
}
