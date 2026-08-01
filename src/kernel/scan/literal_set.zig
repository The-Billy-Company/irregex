//! Compiled literal-set dispatcher.
//!
//! One literal uses the rare-byte SIMD memmem kernel, eligible sets through 64
//! use grouped Teddy, and larger sets use sparse Aho–Corasick. `Authority` is
//! carried in every result: an exact pure-literal set may decide presence,
//! while an alternation cover may only nominate a regex-engine candidate.

const std = @import("std");
const simd = @import("simd.zig");
const teddy_mod = @import("teddy.zig");
const aho_mod = @import("aho.zig");

pub const Authority = enum { exact, candidate };

pub const Presence = union(Authority) {
    exact: bool,
    candidate: bool,
};

pub const Position = union(Authority) {
    exact: ?usize,
    candidate: ?usize,
};

/// The one-needle strategy carries its anchor decision, because `build` runs once
/// per query while `findRaw` runs once per haystack — the pair is a property of
/// the needle, so pricing it inside the scan re-derived the identical answer for
/// every body in the corpus.
const Single = struct {
    needle: []const u8,
    plan: ?simd.Plan,
};

const Strategy = union(enum) {
    none,
    single: Single,
    teddy: teddy_mod.Teddy,
    sparse: aho_mod.Aho,
    fallback: []const []const u8,
};

pub const BuildError = aho_mod.BuildError;

/// Immutable dispatch plan. The one/Teddy/fallback strategies borrow `needles`;
/// sparse Aho owns its compiled graph and no longer needs the source literals.
pub const LiteralSet = struct {
    authority: Authority,
    strategy: Strategy,

    pub fn build(
        allocator: std.mem.Allocator,
        needles: []const []const u8,
        authority: Authority,
    ) BuildError!LiteralSet {
        if (needles.len == 0) return .{ .authority = authority, .strategy = .none };
        if (needles.len == 1) return .{ .authority = authority, .strategy = .{ .single = .{
            .needle = needles[0],
            .plan = simd.planFor(needles[0]),
        } } };
        if (needles.len <= teddy_mod.max_buckets) {
            if (teddy_mod.Teddy.init(needles)) |teddy|
                return .{ .authority = authority, .strategy = .{ .teddy = teddy } };
            return .{ .authority = authority, .strategy = .{ .fallback = needles } };
        }
        return .{ .authority = authority, .strategy = .{ .sparse = try aho_mod.Aho.build(allocator, needles) } };
    }

    pub fn deinit(self: *LiteralSet) void {
        switch (self.strategy) {
            .sparse => |*sparse| sparse.deinit(),
            else => {},
        }
        self.* = undefined;
    }

    /// One needle, or several. Same authority either way and the same answer, but
    /// a single scan for one byte-anchored needle and a Teddy bucket pass over a
    /// set are different machines at materially different throughputs — so a
    /// caller pricing this kernel has to be able to tell them apart. `.none`
    /// answers with `one` because it is the degenerate single scan: nothing to
    /// find, nothing to bucket.
    pub fn arity(self: *const LiteralSet) enum { one, many } {
        return switch (self.strategy) {
            .none, .single => .one,
            .teddy, .sparse, .fallback => .many,
        };
    }

    /// Presence with its proof authority attached. Callers must switch the tag:
    /// `.exact` may bypass the regex engine; `.candidate` never may.
    pub fn presence(self: *const LiteralSet, hay: []const u8) Presence {
        const hit = self.findRaw(hay, 0) != null;
        return switch (self.authority) {
            .exact => .{ .exact = hit },
            .candidate => .{ .candidate = hit },
        };
    }

    /// Leftmost occurrence with the same explicit authority distinction.
    pub fn find(self: *const LiteralSet, hay: []const u8, from: usize) Position {
        const position = self.findRaw(hay, from);
        return switch (self.authority) {
            .exact => .{ .exact = position },
            .candidate => .{ .candidate = position },
        };
    }

    /// `find`, with the one-needle anchor decision priced on `hay` instead of on
    /// the shipped rarity table. For a WHOLE document only, and once per document:
    /// `build` runs per query, so the plan it carries describes the corpus the
    /// table was fitted to, not this body. On a body whose local alphabet inverts
    /// that table the chosen pair can be two locally-dense bytes, which turns the
    /// block filter into "verify nearly every position" — measured at 70 ms vs
    /// 4 ms over 200 MB on such a buffer.
    ///
    /// Deliberately a fused verb rather than an `on(hay)` that hands back a
    /// re-planned copy: a copy is only trivially safe for `.single`, while `.sparse`
    /// owns a compiled graph, so a returned value would be a struct nobody may
    /// `deinit` and everybody may forget that about. Nothing escapes here.
    ///
    /// Only the one-needle strategy has a pair to choose; Teddy and Aho anchor each
    /// needle on its own bytes, so they route to `find` unchanged.
    pub fn findOn(self: *const LiteralSet, hay: []const u8, from: usize) Position {
        const single = switch (self.strategy) {
            .single => |one| one,
            else => return self.find(hay, from),
        };
        const position = if (simd.planOn(hay, single.needle)) |p|
            simd.indexOfPosWith(hay, from, single.needle, p)
        else
            simd.indexOfPos(hay, from, single.needle);
        return switch (self.authority) {
            .exact => .{ .exact = position },
            .candidate => .{ .candidate = position },
        };
    }

    fn findRaw(self: *const LiteralSet, hay: []const u8, from: usize) ?usize {
        return switch (self.strategy) {
            .none => null,
            .single => |one| if (one.plan) |p|
                simd.indexOfPosWith(hay, from, one.needle, p)
            else
                simd.indexOfPos(hay, from, one.needle),
            .teddy => |teddy| teddy.find(hay, from),
            .sparse => |*sparse| sparse.find(hay, from),
            .fallback => |needles| scalarLeftmost(hay, from, needles),
        };
    }
};

fn scalarLeftmost(hay: []const u8, from: usize, needles: []const []const u8) ?usize {
    var best: ?usize = null;
    for (needles) |needle| if (std.mem.indexOfPos(u8, hay, from, needle)) |position| {
        if (best == null or position < best.?) best = position;
    };
    return best;
}

test "authority keeps exact decisions separate from cover nominations" {
    const needles = [_][]const u8{ "alpha", "omega" };
    var exact = try LiteralSet.build(std.testing.allocator, &needles, .exact);
    defer exact.deinit();
    var cover = try LiteralSet.build(std.testing.allocator, &needles, .candidate);
    defer cover.deinit();

    try std.testing.expectEqual(true, exact.presence("__omega").exact);
    try std.testing.expectEqual(true, cover.presence("__omega").candidate);
    try std.testing.expectEqual(@as(?usize, 2), exact.find("__omega", 0).exact);
    try std.testing.expectEqual(@as(?usize, 2), cover.find("__omega", 0).candidate);
}

test "dispatcher boundaries, duplicate literals, empty and short needles" {
    const one = [_][]const u8{"needle"};
    var single = try LiteralSet.build(std.testing.allocator, &one, .exact);
    defer single.deinit();
    try std.testing.expectEqual(@as(?usize, 15), single.find("xxxxxxxxxxxxxxxneedle", 0).exact);

    const eight = [_][]const u8{ "aa0", "aa1", "aa2", "aa3", "aa4", "aa5", "aa6", "seam" };
    var teddy8 = try LiteralSet.build(std.testing.allocator, &eight, .exact);
    defer teddy8.deinit();
    try std.testing.expectEqual(@as(?usize, 15), teddy8.find("xxxxxxxxxxxxxxxseam", 0).exact);

    const sixty_four = comptime literals(64, "t");
    var teddy64 = try LiteralSet.build(std.testing.allocator, &sixty_four, .exact);
    defer teddy64.deinit();
    try std.testing.expectEqual(@as(?usize, 2), teddy64.find("__t0063__", 0).exact);

    const sixty_five = comptime literals(65, "a");
    var aho65 = try LiteralSet.build(std.testing.allocator, &sixty_five, .exact);
    defer aho65.deinit();
    try std.testing.expectEqual(@as(?usize, 2), aho65.find("__a0064__", 0).exact);

    const awkward = [_][]const u8{ "", "x", "xyz", "xyz" };
    var fallback = try LiteralSet.build(std.testing.allocator, &awkward, .exact);
    defer fallback.deinit();
    try std.testing.expectEqual(@as(?usize, 3), fallback.find("abc", 3).exact);
}

test "grouped Teddy rejects dense false candidates and matches scalar reference" {
    const needles = comptime literals(64, "aa");
    var set = try LiteralSet.build(std.testing.allocator, &needles, .exact);
    defer set.deinit();
    const dense = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try std.testing.expectEqual(scalarLeftmost(dense, 0, &needles), set.find(dense, 0).exact);
}

test "dispatcher differential across Teddy and Aho boundaries" {
    const sets = .{
        comptime literals(8, "q"),
        comptime literals(64, "r"),
        comptime literals(65, "s"),
    };
    var prng = std.Random.DefaultPrng.init(0x1a17e2a1);
    const random = prng.random();
    var hay: [257]u8 = undefined;
    inline for (sets) |needles| {
        var set = try LiteralSet.build(std.testing.allocator, &needles, .exact);
        defer set.deinit();
        for (0..128) |_| {
            random.bytes(&hay);
            const chosen = random.uintLessThan(usize, needles.len);
            const at = random.uintLessThan(usize, hay.len - needles[chosen].len + 1);
            if (random.boolean()) @memcpy(hay[at..][0..needles[chosen].len], needles[chosen]);
            const from = random.uintLessThan(usize, hay.len + 1);
            try std.testing.expectEqual(scalarLeftmost(&hay, from, &needles), set.find(&hay, from).exact);
        }
    }
}

fn literals(comptime count: usize, comptime prefix: []const u8) [count][]const u8 {
    @setEvalBranchQuota(1_000_000);
    var out: [count][]const u8 = undefined;
    for (&out, 0..) |*needle, i|
        needle.* = std.fmt.comptimePrint("{s}{d:0>4}", .{ prefix, i });
    return out;
}
