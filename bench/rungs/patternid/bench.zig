//! PatternID — does attribution-in-the-key cost states?
//!
//! The one number that gates the PatternID design; attribution, overlapping
//! matches, and an end-only HalfMatch stream are one mechanism seen three ways,
//! so all three ride on this ratio. The design scan measured it at 1.017-1.121
//! over six slates - worst on the slate built deliberately to collide - and
//! passed.
//!
//! The plan is to make a fused pattern-set DFA carry *which* patterns
//! matched, by widening the trailing word of the determinizer's state key from a
//! match flag to a 64-pattern bitmask. That word already exists and is already
//! allocated, so the key costs nothing. What it might cost is STATES: two subsets
//! that agree on their NFA consume-set but disagree on which pattern terminals
//! they passed through are one state today and two states after. If that
//! refinement multiplies out, `powerset.zig`'s `max_states` budget declines the
//! build and the whole idea degrades to today's behavior — correct, but not
//! faster.
//!
//! So this rung determinizes the SAME union NFA twice, changing exactly one line:
//! whether the key's last word holds the mask or `mask != 0`. Everything else —
//! the closure, the worklist, the seeding, the byte loop — is shared, because two
//! transcriptions would be measuring their own difference rather than the one
//! under test.
//!
//! **This is a measurement rig, not the engine.** It steps all 256 bytes instead
//! of byte classes, and resolves zero-width assertions at a fixed interior gap.
//! Both arms do, identically, so the RATIO is honest even where the absolute
//! count differs from what `powerset.zig` would build. The ratio is the claim.
//!
//! The union is built at the program layer, which is also what the real change
//! does: N `.match` terminals are pushed first, so a terminal's NFA index IS its
//! pattern ordinal and no payload or side table is needed. `slate/patterns.zig`
//! fuses by concatenating pattern TEXT and re-parsing, which is exactly why it
//! cannot attribute today.
//!
//! Four sections, and only the first is the gate:
//!   1. state-count cost of the mask-in-key refinement (the gate);
//!   2. overlapping ends, named — the `foo|foofoo|foofoofoo` probe;
//!   3. attribution priced against the N confirms it would replace;
//!   4. determinization COST, which nothing above prices. This one guards
//!      `subset.Subset.seeds`: the unanchored re-seed is loop-invariant across
//!      every transition, and hoisting it is worth 1.3-2.3x on the union builds.
//!      It carries its own control — an ANCHORED pattern never re-seeds, so its
//!      row must not move — and reports which engine the visit budget actually
//!      chose, because a cheaper closure can spend its savings getting further
//!      before declining, which reads as "no change" while being a regression.

const std = @import("std");
const gist = @import("irregex");

const syntax = gist.regex_syntax;
const State = syntax.State;
const Regex = gist.regex.Regex;

// ── slates ──────────────────────────────────────────────────────────────────
// Shapes the agent workload actually runs: bare identifiers (what a renamer and
// the trust lints classify), and regex bodies with shared structure, which is
// where subsets collide and therefore where refinement can bite.

const Slate = struct { name: []const u8, pats: []const []const u8 };

const slates = [_]Slate{
    .{ .name = "lit-3", .pats = &.{ "WalletService", "billing_check", "grant" } },
    .{ .name = "lit-8", .pats = &.{
        "WalletService", "billing_check", "grant",     "pgxpool",
        "JetStream",     "Cedar",         "substrate", "invalidations",
    } },
    .{ .name = "lit-18", .pats = &.{
        "WalletService", "billing_check", "grant",          "pgxpool",
        "JetStream",     "Cedar",         "substrate",      "invalidations",
        "atelier",       "sandbox",       "benchmarkatron", "vagus",
        "archivist",     "vmstack",       "kompressor",     "organelle",
        "entrain",       "principia",
    } },
    // Shared prefixes and suffixes: the adversarial case for subset collision.
    .{ .name = "kin-8", .pats = &.{
        "store_wallet_grant", "store_wallet_debit", "store_wallet_hold",
        "store_ledger_grant", "store_ledger_debit", "store_ledger_hold",
        "store_audit_grant",  "store_audit_debit",
    } },
    .{ .name = "re-6", .pats = &.{
        "pgxpool\\.\\w+", "func \\w+Handler", "[A-Z][a-z]+Service",
        "\\d{3}-\\d{4}",  "TODO|FIXME|XXX",   "err != nil",
    } },
    .{ .name = "re-12", .pats = &.{
        "pgxpool\\.\\w+", "func \\w+Handler",  "[A-Z][a-z]+Service",
        "\\d{3}-\\d{4}",  "TODO|FIXME|XXX",    "err != nil",
        "context\\.\\w+", "make\\(\\[\\]\\w+", "\\w+_test\\.go",
        "panic\\(",       "\\.unwrap\\(\\)",   "@import\\(",
    } },
};

// ── bitset helpers ──────────────────────────────────────────────────────────

fn words(n: usize) usize {
    return (n + 63) / 64;
}
fn bitGet(v: []const u64, i: usize) bool {
    return v[i >> 6] & (@as(u64, 1) << @intCast(i & 63)) != 0;
}
fn bitSet(v: []u64, i: usize) void {
    v[i >> 6] |= @as(u64, 1) << @intCast(i & 63);
}

// ── the union program ───────────────────────────────────────────────────────

const Union = struct {
    states: []State,
    start: u32,
    npat: u32,

    fn deinit(u: *Union, gpa: std.mem.Allocator) void {
        gpa.free(u.states);
    }
};

/// An out-edge of arm `i`, rewritten into union coordinates. `lower.zig` pushes
/// the match terminal first, so index 0 in an arm's own program means "match" and
/// is redirected to that arm's dedicated terminal; everything else shifts by the
/// arm's offset.
fn remap(x: u32, off: u32, term: u32) u32 {
    return if (x == 0) term else x + off;
}

fn shift(st: State, off: u32, term: u32) State {
    return switch (st) {
        .consume => |c| .{ .consume = .{ .set = c.set, .out = remap(c.out, off, term) } },
        .split => |s| .{ .split = .{ .a = remap(s.a, off, term), .b = remap(s.b, off, term) } },
        .assert_start => |o| .{ .assert_start = remap(o, off, term) },
        .assert_end => |o| .{ .assert_end = remap(o, off, term) },
        .assert_word => |w| .{ .assert_word = .{ .mask = w.mask, .out = remap(w.out, off, term) } },
        .assert_buf_start => |o| .{ .assert_buf_start = remap(o, off, term) },
        .assert_buf_end => |o| .{ .assert_buf_end = remap(o, off, term) },
        .match => .match,
    };
}

/// Compile each pattern on its own and splice the programs into one union NFA:
/// `npat` match terminals at indices `0..npat-1`, then each arm's states, then a
/// split chain rooted at the last split. Terminal index == pattern ordinal, which
/// is the whole trick — the determinizer reads the ordinal straight off the state
/// id it is already holding.
fn buildUnion(gpa: std.mem.Allocator, pats: []const []const u8) !Union {
    var out: std.ArrayList(State) = .empty;
    errdefer out.deinit(gpa);

    for (0..pats.len) |_| try out.append(gpa, .match);

    const arm_start = try gpa.alloc(u32, pats.len);
    defer gpa.free(arm_start);

    for (pats, 0..) |p, i| {
        var re = try Regex.compile(gpa, p);
        defer re.deinit();
        // `lower.zig` pushes the match terminal before lowering the AST.
        if (re.states.len == 0 or re.states[0] != .match) return error.UnexpectedProgramLayout;

        // Arm states 1.. land at `out.items.len`, so an old index x maps to
        // x + off with off = len - 1.
        const off: u32 = @intCast(out.items.len - 1);
        const term: u32 = @intCast(i);
        for (re.states[1..]) |st| try out.append(gpa, shift(st, off, term));
        arm_start[i] = remap(re.start, off, term);
    }

    var root = arm_start[pats.len - 1];
    var k: usize = pats.len - 1;
    while (k > 0) : (k -= 1) {
        try out.append(gpa, .{ .split = .{ .a = arm_start[k - 1], .b = root } });
        root = @intCast(out.items.len - 1);
    }

    return .{ .states = try out.toOwnedSlice(gpa), .start = root, .npat = @intCast(pats.len) };
}

// ── the determinizer under test ─────────────────────────────────────────────

const Key = struct {
    buf: []const u64,
    fn hash(_: Key, k: []const u64) u64 {
        return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(k));
    }
    fn eql(_: Key, a: []const u64, b: []const u64) bool {
        return std.mem.eql(u64, a, b);
    }
};
const Ctx = struct {
    pub fn hash(_: Ctx, k: []const u64) u64 {
        return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(k));
    }
    pub fn eql(_: Ctx, a: []const u64, b: []const u64) bool {
        return std.mem.eql(u64, a, b);
    }
};
const Map = std.HashMap([]const u64, u32, Ctx, std.hash_map.default_max_load_percentage);

const Det = struct {
    gpa: std.mem.Allocator,
    states: []const State,
    start: u32,
    nw: usize,
    /// The one line under test: mask in the key, or just its non-emptiness.
    attribute: bool,

    map: Map,
    keys: std.ArrayList([]u64) = .empty,
    sets: std.ArrayList([]u64) = .empty,

    visited: []u64,
    out: []u64,
    stack: []u32,
    key: []u64,
    sp: usize = 0,

    /// Attribution evidence, not cost: every distinct non-empty mask the walk
    /// produced, and their union. A run whose union is not `(1<<npat)-1` has a
    /// pattern the automaton can never name, which would make the state-count
    /// ratio beside the point.
    masks: std.AutoHashMapUnmanaged(u64, void) = .empty,
    mask_union: u64 = 0,

    fn init(gpa: std.mem.Allocator, u: Union, attribute: bool) !Det {
        const nw = words(u.states.len);
        return .{
            .gpa = gpa,
            .states = u.states,
            .start = u.start,
            .nw = nw,
            .attribute = attribute,
            .map = Map.init(gpa),
            .visited = try gpa.alloc(u64, nw),
            .out = try gpa.alloc(u64, nw),
            .stack = try gpa.alloc(u32, u.states.len),
            .key = try gpa.alloc(u64, nw + 1),
        };
    }

    fn deinit(d: *Det) void {
        d.masks.deinit(d.gpa);
        d.map.deinit();
        for (d.keys.items) |k| d.gpa.free(k);
        d.keys.deinit(d.gpa);
        for (d.sets.items) |s| d.gpa.free(s);
        d.sets.deinit(d.gpa);
        d.gpa.free(d.visited);
        d.gpa.free(d.out);
        d.gpa.free(d.stack);
        d.gpa.free(d.key);
    }

    fn pushIf(d: *Det, st: u32) void {
        if (bitGet(d.visited, st)) return;
        bitSet(d.visited, st);
        d.stack[d.sp] = st;
        d.sp += 1;
    }

    /// Epsilon-close the stack into `d.out`, returning the pattern mask. This is
    /// the line the whole spike turns on: a `.match` state contributes
    /// `1 << st`, and `st` is the ordinal because the terminals were pushed
    /// first. Assertions resolve at a fixed interior gap (see the module note).
    fn close(d: *Det) u64 {
        var mask: u64 = 0;
        while (d.sp > 0) {
            d.sp -= 1;
            const st = d.stack[d.sp];
            switch (d.states[st]) {
                .consume => bitSet(d.out, st),
                .split => |s| {
                    d.pushIf(s.a);
                    d.pushIf(s.b);
                },
                .match => mask |= @as(u64, 1) << @intCast(st),
                .assert_word => |w| d.pushIf(w.out),
                else => {},
            }
        }
        return mask;
    }

    fn reset(d: *Det) void {
        @memset(d.visited, 0);
        @memset(d.out, 0);
        d.sp = 0;
    }

    fn intern(d: *Det, mask: u64) !struct { id: u32, is_new: bool } {
        if (mask != 0) {
            try d.masks.put(d.gpa, mask, {});
            d.mask_union |= mask;
        }
        @memcpy(d.key[0..d.nw], d.out);
        d.key[d.nw] = if (d.attribute) mask else @intFromBool(mask != 0);
        if (d.map.get(d.key)) |id| return .{ .id = id, .is_new = false };
        const k = try d.gpa.dupe(u64, d.key);
        const s = try d.gpa.dupe(u64, d.out);
        const id: u32 = @intCast(d.keys.items.len);
        try d.map.put(k, id);
        try d.keys.append(d.gpa, k);
        try d.sets.append(d.gpa, s);
        return .{ .id = id, .is_new = true };
    }

    /// Run to fixpoint over all 256 bytes, unanchored (the start state is
    /// re-seeded on every step, as `subset.step` does). Returns the state count.
    fn run(d: *Det) !u32 {
        var work: std.ArrayList(u32) = .empty;
        defer work.deinit(d.gpa);

        d.reset();
        d.pushIf(d.start);
        const m0 = d.close();
        const r0 = try d.intern(m0);
        try work.append(d.gpa, r0.id);

        while (work.pop()) |id| {
            const from = d.sets.items[id];
            var b: u16 = 0;
            while (b < 256) : (b += 1) {
                d.reset();
                var wi: usize = 0;
                while (wi < d.nw) : (wi += 1) {
                    var w = from[wi];
                    while (w != 0) {
                        const bit = @ctz(w);
                        w &= w - 1;
                        const st: u32 = @intCast(wi * 64 + bit);
                        if (d.states[st].consume.set.has(@intCast(b)))
                            d.pushIf(d.states[st].consume.out);
                    }
                }
                d.pushIf(d.start); // unanchored
                const mask = d.close();
                const r = try d.intern(mask);
                if (r.is_new) try work.append(d.gpa, r.id);
            }
        }
        return @intCast(d.keys.items.len);
    }
};

/// Walk `hay` as a live subset simulation and report, at every position, the set
/// of patterns whose match ENDS there. That set is the overlapping-search answer
/// and the HalfMatch stream at once: an end offset plus every pattern id that
/// completes at it, with no start and no reverse pass.
///
/// Note what is NOT here. rust-regex needs a resumable `OverlappingState` carried
/// across calls, re-entered once per pattern at a position where several match,
/// and it needs the DFA to have been built in `MatchKind::All` to stop the
/// leftmost-first pruning from hiding the extras. This walk needs none of that:
/// the recognizer subset never prunes, so every pattern alive at a position is
/// already in the set, and the whole set arrives as one `u64`.
/// One reported end: the offset a match completes at, and every pattern that
/// completes there. This IS the HalfMatch — an end and a pattern set, no start.
const End = struct { at: usize, mask: u64 };

fn overlapWalk(d: *Det, hay: []const u8, ends: *std.ArrayList(End), gpa: std.mem.Allocator) !void {
    const cur = try gpa.alloc(u64, d.nw);
    defer gpa.free(cur);

    d.reset();
    d.pushIf(d.start);
    var mask = d.close();
    @memcpy(cur, d.out);
    if (mask != 0) try ends.append(gpa, .{ .at = 0, .mask = mask });

    for (hay, 0..) |byte, i| {
        d.reset();
        for (cur, 0..) |w0, wi| {
            var w = w0;
            while (w != 0) {
                const bit = @ctz(w);
                w &= w - 1;
                const st: u32 = @intCast(wi * 64 + bit);
                if (d.states[st].consume.set.has(byte)) d.pushIf(d.states[st].consume.out);
            }
        }
        d.pushIf(d.start); // unanchored: a new match may begin at every position
        mask = d.close();
        @memcpy(cur, d.out);
        if (mask != 0) try ends.append(gpa, .{ .at = i + 1, .mask = mask });
    }
}

const Run = struct { nstates: u32, distinct_masks: u32, covered: bool };

fn count(gpa: std.mem.Allocator, u: Union, attribute: bool) !Run {
    var d = try Det.init(gpa, u, attribute);
    defer d.deinit();
    const n = try d.run();
    const all: u64 = if (u.npat == 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(u.npat)) - 1;
    return .{
        .nstates = n,
        .distinct_masks = @intCast(d.masks.count()),
        .covered = d.mask_union == all,
    };
}

/// Write to fd 1 directly, as the sibling rungs do: a measurement rung's output
/// is a TSV a join reads, so it must not depend on a buffered writer's teardown.
fn emit(line: []const u8) void {
    var off: usize = 0;
    while (off < line.len) {
        const rc = std.posix.system.write(1, line.ptr + off, line.len - off);
        if (rc <= 0) {
            if (std.posix.errno(rc) == .INTR) continue;
            std.process.exit(1);
        }
        off += @intCast(rc);
    }
}

/// Overlapping-semantics cases. `foo|foofoo|foofoofoo` over `foofoofoo` is the
/// probe rust-regex's All-mode answers with ends 3/6/9 and both greps answer with
/// three non-overlapping `foo`s.
const OverlapCase = struct { name: []const u8, pats: []const []const u8, hay: []const u8 };

const overlap_cases = [_]OverlapCase{
    .{ .name = "foo-nest", .pats = &.{ "foo", "foofoo", "foofoofoo" }, .hay = "foofoofoo" },
    .{ .name = "abc-suffix", .pats = &.{ "c", "bc", "abc" }, .hay = "abc" },
    .{ .name = "kin", .pats = &.{ "ab", "abab", "b" }, .hay = "abab" },
};

fn overlapSection(gpa: std.mem.Allocator) !void {
    var buf: [4096]u8 = undefined;
    emit("\ncase\thay\tend\tpatterns\n");

    for (overlap_cases) |c| {
        var u = try buildUnion(gpa, c.pats);
        defer u.deinit(gpa);

        var d = try Det.init(gpa, u, true);
        defer d.deinit();

        var ends: std.ArrayList(End) = .empty;
        defer ends.deinit(gpa);
        try overlapWalk(&d, c.hay, &ends, gpa);

        for (ends.items) |e| {
            // Name the patterns in the mask, so the row is readable as a claim
            // rather than as a number.
            var names: [256]u8 = undefined;
            var n: usize = 0;
            var m = e.mask;
            while (m != 0) {
                const bit = @ctz(m);
                m &= m - 1;
                if (n != 0) {
                    names[n] = ',';
                    n += 1;
                }
                const p = c.pats[bit];
                @memcpy(names[n..][0..p.len], p);
                n += p.len;
            }
            emit(try std.fmt.bufPrint(&buf, "{s}\t{s}\t{d}\t{s}\n", .{ c.name, c.hay, e.at, names[0..n] }));
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var buf: [4096]u8 = undefined;

    emit("slate\tN\tnfa\tbool\tmask\tratio\tsigs\tcovered\n");

    for (slates) |sl| {
        var u = buildUnion(gpa, sl.pats) catch |e| {
            emit(try std.fmt.bufPrint(&buf, "{s}\tSKIP\t{s}\n", .{ sl.name, @errorName(e) }));
            continue;
        };
        defer u.deinit(gpa);

        if (u.npat > 64) return error.SlateTooWide;

        const a = try count(gpa, u, false);
        const b = try count(gpa, u, true);
        const ratio = @as(f64, @floatFromInt(b.nstates)) / @as(f64, @floatFromInt(a.nstates));

        emit(try std.fmt.bufPrint(&buf, "{s}\t{d}\t{d}\t{d}\t{d}\t{d:.3}\t{d}\t{s}\n", .{
            sl.name, u.npat,           u.states.len,                   a.nstates, b.nstates,
            ratio,   b.distinct_masks, if (b.covered) "yes" else "NO",
        }));
    }

    try overlapSection(gpa);
    try speedSection(gpa, init.io);
    try buildSection(gpa, init.io);
    try settleSection(gpa, init.io);
}

// ── Determinization cost ─────────────────────────────────────────────────────
// What it costs to DISCOVER the automaton, which the tables above never price.
// `powerset.build` re-seeds the NFA start inside every unanchored `step`, so the
// start's whole epsilon-closure is re-walked once per (state x class) — and for
// a Unicode class that closure is the ~10^3-state UTF-8 trie. Times the compile
// end-to-end, single patterns and slates, because that walk is the bulk of it.

/// Patterns chosen for the SHAPE of their start closure, which is what the
/// re-seed re-walks: a Unicode class lowers to a large trie reached immediately
/// from the start, a literal reaches one state, and an anchored pattern never
/// re-seeds at all (the control — it must not move).
const build_cases = [_][]const u8{
    "\\w+X", // the module doc's own example: 332 states, ~15 ms
    "\\w+\\d+", // two tries, both live at the start
    "[A-Z][a-z]+ [A-Z][a-z]+", // ASCII classes: small start closure
    "pgxpool\\.\\w+", // literal prefix, trie behind it
    "^\\w+X", // ANCHORED control: no re-seed, so no change is possible
};

fn buildSection(gpa: std.mem.Allocator, io: std.Io) !void {
    var buf: [4096]u8 = undefined;
    emit("\nwhat\treps\tbuild_ms\tper_build_us\tengine\tnstates\n");

    for (build_cases) |p| {
        const reps = 20;
        const sp = gist.assay.Span.open(io);
        for (0..reps) |_| {
            var re = core_mod.Regex.compile(gpa, p) catch continue;
            re.deinit();
        }
        const ns: f64 = @floatFromInt(@intFromEnum(sp.read(io)));

        // Which engine the budget actually handed the pattern to. Time alone
        // cannot say: a cheaper closure can spend its savings getting FURTHER
        // before declining, which reads as "no change" while having moved the
        // pattern from the on-demand driver to the eager one.
        var re = try core_mod.Regex.compile(gpa, p);
        defer re.deinit();
        const engine = if (re.dfa != null) "eager" else if (re.lazy != null) "lazy" else "pike";
        const n: usize = if (re.dfa) |d| d.nstates else 0;

        emit(try std.fmt.bufPrint(&buf, "{s}\t{d}\t{d:.2}\t{d:.1}\t{s}\t{d}\n", .{
            p, reps, ns / 1_000_000.0, ns / 1000.0 / @as(f64, reps), engine, n,
        }));
    }

    for (slates) |sl| {
        if (sl.pats.len > 64) continue;
        const reps = 20;
        const sp = gist.assay.Span.open(io);
        for (0..reps) |_| {
            var ch = (chorus_mod.Chorus.compile(gpa, sl.pats, .{}) catch null) orelse continue;
            ch.deinit();
        }
        const ns: f64 = @floatFromInt(@intFromEnum(sp.read(io)));
        emit(try std.fmt.bufPrint(&buf, "chorus:{s}\t{d}\t{d:.2}\t{d:.1}\n", .{
            sl.name, reps, ns / 1_000_000.0, ns / 1000.0 / @as(f64, reps),
        }));
    }
}

// ── Attribution, priced ──────────────────────────────────────────────────────
// The state-count table above is the COST of putting the mask in the key. This
// is what that cost buys: the same attribution question — which of N patterns
// match this document — answered by one chorus walk versus the N separate
// engine confirms it replaces. Both arms run the production seams (`Chorus`
// and `Regex.lineMatch`) over the same corpus, so the ratio is the real one a
// caller sees, not a microbenchmark of the inner loop.

const chorus_mod = gist.regex_chorus;
const core_mod = gist.regex;
const patterns_mod = gist.irregex.patterns;

/// A synthetic document with the shape the attribution workload actually meets:
/// mostly lines that match nothing, a few that match one pattern. That is the
/// regime where N confirms hurt most, because every miss still costs all N.
fn corpus(gpa: std.mem.Allocator, hits: []const []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        if (i % 37 == 0) {
            try buf.print(gpa, "line {d} mentions {s} here\n", .{ i, hits[i % hits.len] });
        } else {
            try buf.print(gpa, "line {d} is ordinary filler text with no interesting token\n", .{i});
        }
    }
    return buf.toOwnedSlice(gpa);
}

/// What the muster can SETTLE — `slate/muster.zig::coverOf`.
///
/// A settled pattern's literal hit IS its verdict, so the engine confirm behind
/// it never runs. Widening settling from bare literals to the pure-literal
/// EQUIVALENCE set (`TODO|FIXME|XXX`) is therefore a HIT-path saving and nothing
/// else: a document that misses is rejected by the same SIMD roll either way.
/// That is why this section reports hit and miss documents separately — an
/// aggregate would dilute a real win with an arm that provably cannot move, and
/// read as a smaller effect than it is.
///
/// Answers are checked against N independent engines on every row, because a
/// settling widening that is WRONG is also fast.
///
/// Measured here: `alt-6`, whose six patterns are all settle-eligible, goes
/// 3.26 -> 1.67 us/doc on `hit` (1.95x) and 56.1 -> 18.6 us on `late` (3.01x),
/// with `miss` unmoved at 17.6 us as it must be. `re-6` is flat, and that is the
/// honest half of the result: four of its six bodies are classes and quantifiers
/// whose confirms settling cannot remove, and they dominate the row.
fn settleSection(gpa: std.mem.Allocator, io: std.Io) !void {
    var buf: [4096]u8 = undefined;
    emit("\nslate\tN\tsettled\tdoc\tdocmask_ms\tper_doc_us\tagree\n");

    // A slate whose patterns are ALL settle-eligible, so the saving is not
    // hidden behind confirms the widening cannot touch. `re-6`'s four class-and-
    // quantifier bodies dominate its row whatever happens to the other two.
    const alt = Slate{ .name = "alt-6", .pats = &.{
        "TODO|FIXME|XXX",      "panic|unreachable", "err != nil",
        "WalletService|Cedar", "JetStream|NATS",    "pgxpool",
    } };

    for (slates ++ [_]Slate{alt}) |sl| {
        if (sl.pats.len > 64) continue;
        const specs = try gpa.alloc(patterns_mod.Spec, sl.pats.len);
        defer gpa.free(specs);
        for (specs, sl.pats) |*s, p| s.* = .{ .pattern = p, .fixed = false };

        var set = patterns_mod.PatternSet.compile(gpa, specs) catch continue;
        defer set.deinit(gpa);
        var sc = try set.scratch(gpa);
        defer sc.deinit(gpa);
        const mask = try gpa.alloc(u64, patterns_mod.maskWords(specs.len));
        defer gpa.free(mask);

        var settled: usize = 0;
        if (set.muster) |*m| {
            for (0..sl.pats.len) |i| settled += @intFromBool(m.isSettled(i));
        }

        // A hitting document (the corpus these patterns were written for) and a
        // missing one of the same size, so the two paths are priced apart.
        const hit = try corpus(gpa, sl.pats);
        defer gpa.free(hit);
        const miss = try gpa.alloc(u8, hit.len);
        defer gpa.free(miss);
        for (miss, 0..) |*c, i| c.* = "qz"[i % 2];
        // The shape that isolates what settling removes: a long non-matching
        // prefix before the matches. A skipped confirm is a skipped SECOND pass
        // over all of it, where an early hit lets the confirm exit at once and
        // the saving rounds to nothing.
        const late = try std.mem.concat(gpa, u8, &.{ miss, hit });
        defer gpa.free(late);

        for ([_][]const u8{ hit, miss, late }, [_][]const u8{ "hit", "miss", "late" }) |doc, label| {
            const reps = 200;
            const sp = gist.assay.Span.open(io);
            for (0..reps) |_| _ = set.docMask(doc, &sc, mask);
            const ns: f64 = @floatFromInt(@intFromEnum(sp.read(io)));

            // The oracle: N independent single-pattern engines, no set machinery.
            var agree = true;
            for (sl.pats, 0..) |p, i| {
                var re = try core_mod.Regex.compile(gpa, p);
                defer re.deinit();
                var sim = try core_mod.Regex.Sim.init(gpa, &re);
                defer sim.deinit();
                if (re.docMatch(&sim, doc) != patterns_mod.maskHas(mask, i)) agree = false;
            }

            emit(try std.fmt.bufPrint(&buf, "{s}\t{d}\t{d}/{d}\t{s}\t{d:.2}\t{d:.2}\t{s}\n", .{
                sl.name,        sl.pats.len,                  settled,                    sl.pats.len, label,
                ns / 1_000_000, ns / 1000.0 / @as(f64, reps), if (agree) "yes" else "NO",
            }));
        }
    }
}

fn speedSection(gpa: std.mem.Allocator, io: std.Io) !void {
    var buf: [4096]u8 = undefined;
    emit("\nslate\tN\tconfirms_ms\tchorus_ms\tspeedup\tagree\n");

    for (slates) |sl| {
        if (sl.pats.len > 64) continue;
        var ch = (chorus_mod.Chorus.compile(gpa, sl.pats, .{}) catch null) orelse {
            emit(try std.fmt.bufPrint(&buf, "{s}\tDECLINED\n", .{sl.name}));
            continue;
        };
        defer ch.deinit();

        const doc = try corpus(gpa, sl.pats);
        defer gpa.free(doc);

        // Arm A: N separate engines, one confirm per pattern per document.
        const singles = try gpa.alloc(core_mod.Regex, sl.pats.len);
        defer gpa.free(singles);
        const sims = try gpa.alloc(core_mod.Regex.Sim, sl.pats.len);
        defer gpa.free(sims);
        for (singles, sims, sl.pats) |*re, *sim, p| {
            re.* = try core_mod.Regex.compile(gpa, p);
            sim.* = try core_mod.Regex.Sim.init(gpa, re);
        }
        defer for (singles, sims) |*re, *sim| {
            sim.deinit();
            re.deinit();
        };

        const reps = 20;
        var want: u64 = 0;
        const sp_a = gist.assay.Span.open(io);
        for (0..reps) |_| {
            want = 0;
            for (singles, sims, 0..) |*re, *sim, i| {
                if (re.docMatch(sim, doc)) want |= @as(u64, 1) << @intCast(i);
            }
        }
        const confirms: f64 = @floatFromInt(@intFromEnum(sp_a.read(io)));

        // Arm B: one chorus walk, same answer.
        var got: u64 = 0;
        const sp_b = gist.assay.Span.open(io);
        for (0..reps) |_| got = ch.docMask(doc);
        const chorus_ns: f64 = @floatFromInt(@intFromEnum(sp_b.read(io)));

        emit(try std.fmt.bufPrint(&buf, "{s}\t{d}\t{d:.2}\t{d:.2}\t{d:.2}x\t{s}\n", .{
            sl.name,                 sl.pats.len,          confirms / 1_000_000.0,
            chorus_ns / 1_000_000.0, confirms / chorus_ns, if (want == got) "yes" else "NO",
        }));
    }
}
