//! Soundness + reachability for the conjunctive cover (`cover.zig`).
//!
//! Keeps the public `query.cover*` re-exports and `cover.atomCount` textually
//! referenced so zig-dead cannot treat a landed planner as unused, and asserts
//! the one-literal / multi-run cases the prefilter already proves.

const std = @import("std");
const cover = @import("cover.zig");
const query = @import("query.zig");
const regex = @import("../regex/regex.zig");
const lower = regex.lower;
const Regex = regex.Regex;

const t = std.testing;

// ── soundness: matched ⇒ never pruned ────────────────────────────────────────
//
// The only property a prefilter may not get wrong. A plan is a NECESSARY
// condition, so every document the real matcher accepts must satisfy every
// clause; a single matched-but-not-admitted document is a filter that silently
// loses results. Proven the way the Sliver and Sieve theorems are
// (`../../../corpus/index/trigrams/sliver_test.zig`, `../regex/analysis/swell_test.zig`):
// by running the production matcher over an exhaustively enumerated document
// space, never by arguing about the lowering.

/// Does `doc` hold every trigram of `lit`? Precisely what a plan asks of a
/// candidate — deliberately weaker than `contains`, because a plan that needed
/// real containment would claim more than a trigram index can prove.
fn holdsTrigrams(doc: []const u8, lit: []const u8) bool {
    if (lit.len < 3) return true; // below the floor the index proves nothing
    for (0..lit.len - 2) |i| {
        if (std.mem.indexOf(u8, doc, lit[i..][0..3]) == null) return false;
    }
    return true;
}

/// Evaluate a plan as `trigram.Index.queryPlan` does, but over one document's
/// bytes: AND over clauses, OR over atoms, AND over an atom's literals.
fn admits(plan: []const cover.Clause, doc: []const u8) bool {
    for (plan) |clause| {
        const any = for (clause) |atom| {
            const all = for (atom) |lit| {
                if (!holdsTrigrams(doc, lit)) break false;
            } else true;
            if (all) break true;
        } else false;
        if (!any) return false;
    }
    return true;
}

/// Every string over `alphabet` up to `max_len`, checked against the real
/// matcher. Prints the witness on failure — an unsound plan is a finding.
fn proveSound(pattern: []const u8, alphabet: []const u8, max_len: usize) !void {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // No plan ⇒ nothing is pruned ⇒ trivially sound.
    const plan = cover.planSource(arena, pattern, .{}, .{}) orelse return;

    var re = try Regex.compile(t.allocator, pattern);
    defer re.deinit();
    var sim = try Regex.Sim.init(t.allocator, &re);
    defer sim.deinit();

    var buf: [8]u8 = undefined;
    for (0..max_len + 1) |len| {
        for (0..std.math.pow(usize, alphabet.len, len)) |counter| {
            var n = counter;
            for (0..len) |i| {
                buf[i] = alphabet[n % alphabet.len];
                n /= alphabet.len;
            }
            const doc = buf[0..len];
            if (!re.docMatch(&sim, doc) or admits(plan, doc)) continue;
            std.debug.print("UNSOUND: /{s}/ matches \"{s}\" but the plan prunes it\n", .{ pattern, doc });
            return error.PlanElidesMatch;
        }
    }
}

test "cover: matched ⇒ admitted, brute-forced over the real matcher" {
    // One pattern per lowering path: a class choice point, an alternation
    // cross-product, a repetition head/tail, a star that may vanish, an anchor,
    // a nested alternation, and a literal below the trigram floor.
    try proveSound("ab\\sc", "abc \t", 6);
    try proveSound("a(b|c)d", "abcd", 6);
    try proveSound("ab+cd", "abcd", 6);
    try proveSound("ab*cde", "abcde", 6);
    try proveSound("^abc\\s", "abc \t", 6);
    try proveSound("a[bc]d|xyz", "abcdxyz", 5);
    try proveSound("ab", "ab", 4);
}

test "cover: matched ⇒ admitted, with `?` read as the finite set {ε, x}" {
    // `x?` is the one repetition with a finite language, so it is the one whose
    // cross-product could elide a match if the ε branch were dropped. Each of
    // these puts the quest somewhere different: mid-run, at a boundary, over a
    // group, over a class, and doubled (where the product is 2×2).
    try proveSound("abc?de", "abcde", 6);
    try proveSound("ab?cde", "abcde", 6);
    try proveSound("a(bc)?de", "abcde", 6);
    try proveSound("ab[cd]?ef", "abcdef", 6);
    try proveSound("ab?cd?ef", "abcdef", 6);
    try proveSound("abcd?", "abcd", 5);
}

test "coverPlanSource: bare literal ≥3 bytes forces one clause" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const lim: query.CoverLimits = .{};
    const plan = query.coverPlanSource(a, "foobar", .{}, lim) orelse
        return error.TestUnexpectedResult;
    try t.expectEqual(@as(usize, 1), plan.len);
    try t.expectEqual(@as(usize, 1), cover.atomCount(plan));
    const typed: query.CoverPlan = plan[0];
    try t.expect(typed.len >= 1);
}

test "coverPlan: parsed node agrees with planSource" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const lim: cover.Limits = .{};
    const opts: cover.Options = .{};
    const from_src = cover.planSource(a, "abcde", opts, lim) orelse
        return error.TestUnexpectedResult;

    const node = try lower.parse(a, "abcde", opts);
    const from_node = (try query.coverPlan(a, node, lim)) orelse
        return error.TestUnexpectedResult;

    try t.expectEqual(from_src.len, from_node.len);
    try t.expectEqual(cover.atomCount(from_src), cover.atomCount(from_node));
}

test "cover: every mandatory run is kept, not just the longest" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p = cover.planSource(a, "alpha\\d+beta\\d+gamma", .{}, .{}).?;
    try t.expectEqual(@as(usize, 3), p.len);
    // Each run is kept AND extended into the digit class beside it — `alpha` is
    // necessary, but `alpha<digit>` is necessary too and strictly rarer, so the
    // clause is the ten-way choice rather than the bare word. The run in the
    // middle is flanked on both sides, hence 10×10.
    const want = [_][]const u8{ "alpha", "beta", "gamma" };
    const atoms = [_]usize{ 10, 100, 10 };
    for (p, want, atoms) |clause, w, n| {
        try t.expectEqual(n, clause.len);
        for (clause) |atom| {
            try t.expectEqual(@as(usize, 1), atom.len);
            try t.expect(std.mem.indexOf(u8, atom[0], w) != null);
            try t.expectEqual(w.len + @as(usize, if (n == 100) 2 else 1), atom[0].len);
        }
    }
}

test "cover: `?` factors a scheme into whole literals, not boundary trigrams" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The measured reason this rule exists (Layer L, `stress-url`). Reading `s?`
    // as opaque stops the run at `http` and admits 35.98% of the corpus; reading
    // it as {ε, s} yields the two full schemes and admits 19.73%. csearch cannot
    // express this — its planner reaches only 3-byte boundary trigrams
    // (`"://" "htt" "ttp" ("p:/" "tp:")|("ps:" "s:/")`, 21.72%).
    const p = cover.planSource(a, "https?://[\\w.]+", .{}, .{}).?;
    // One clause, 2 schemes × 64 identifier bytes, every alternative a whole
    // 8–9 byte literal rather than a 3-byte fragment.
    try t.expectEqual(@as(usize, 1), p.len);
    try t.expectEqual(@as(usize, 128), p[0].len);
    var http: usize = 0;
    var https: usize = 0;
    for (p[0]) |atom| {
        try t.expectEqual(@as(usize, 1), atom.len);
        if (std.mem.startsWith(u8, atom[0], "https://")) https += 1 else if (std.mem.startsWith(u8, atom[0], "http://")) http += 1;
        try t.expect(atom[0].len >= 8);
    }
    try t.expectEqual(@as(usize, 64), http);
    try t.expectEqual(@as(usize, 64), https);
}

test "cover: an unfilterable alternative drops its clause" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect(cover.planSource(a, "panic|0x", .{}, .{}) == null);
    const ok = cover.planSource(a, "return|continue|break", .{}, .{}).?;
    try t.expectEqual(@as(usize, 1), ok.len);
    try t.expectEqual(@as(usize, 3), ok[0].len);
}
