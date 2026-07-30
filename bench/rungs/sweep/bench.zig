//! Sweep rung — per-consumer proof that the fused fabric beats the recursion it
//! would replace, question by question, before any of it is transferred.
//!
//! The `ast` package claims to answer, in one pass, what `analysis.zig` and
//! `parabix/admit.zig` answer in one recursive walk each. A claim like that
//! decomposes: the fabric can win the pipeline (four questions, one build) while
//! losing any single question (one build to answer one question), and the only
//! way to know which consumer is which is to race them separately. So every row
//! here reports BOTH columns, and the verdict is per consumer, not per package.
//!
//! Both arms are PRODUCTION code reached through `regex.zig`'s seal — the
//! baseline walkers via `regex_analysis` / `regex_parabix`, the fabric via
//! `regex_ast`. A bench that reconstructed either arm would be racing a copy.
//!
//! Answers are compared before times are published. A question whose two arms
//! disagree on ANY pattern is reported as a divergence and its timing is
//! withheld — a faster wrong answer is not a result. `--strict` makes the first
//! divergence fatal.
//!
//! Usage:
//!   sweep-rung [--patterns FILE] [--reps N] [--inner N] [--json] [--strict]

const std = @import("std");
const gist = @import("irregex");

const syn = gist.regex_syntax;
const ana = gist.regex_analysis;
const parabix = gist.regex_parabix;
const ast = gist.regex_ast;
const Span = gist.assay.Span;

/// The consumers under test: every question the fabric claims to subsume that
/// has a live recursive answer today to be raced against.
const Question = enum {
    /// `analysis.literalInfo(...).best` — the mandatory literal the trigram
    /// prefilter plans on.
    best,
    /// `analysis.requiredAny` — the alternation cover set. Quadratic today: it
    /// calls `literalInfo` at every node it descends through.
    cover,
    /// `analysis.startsAnchored` — whether every match begins at a line start.
    anchored,
    /// `parabix.starHeight` — the bit-parallel rung's admission gate.
    star_height,

    fn label(self: Question) []const u8 {
        return switch (self) {
            .best => "best (literalInfo)",
            .cover => "cover (requiredAny)",
            .anchored => "anchored (startsAnchored)",
            .star_height => "star_height (admit)",
        };
    }
};

const question_count = @typeInfo(Question).@"enum".fields.len;

/// Length of a cover's shortest literal — what its selectivity is bounded by.
fn weakest(set: []const []const u8) usize {
    if (set.len == 0) return 0;
    var min: usize = std.math.maxInt(usize);
    for (set) |lit| min = @min(min, lit.len);
    return min;
}

/// What one question answered, in a shape the two arms can be compared in
/// without either arm knowing it is being compared.
const Answer = union(enum) {
    bytes: []const u8,
    set: ?[]const []const u8,
    flag: bool,
    count: u32,

    fn eql(a: Answer, b: Answer) bool {
        return switch (a) {
            .bytes => |x| b == .bytes and std.mem.eql(u8, x, b.bytes),
            .flag => |x| b == .flag and x == b.flag,
            .count => |x| b == .count and x == b.count,
            .set => |x| {
                if (b != .set) return false;
                const y = b.set orelse return x == null;
                const xs = x orelse return false;
                if (xs.len != y.len) return false;
                for (xs, y) |p, q| if (!std.mem.eql(u8, p, q)) return false;
                return true;
            },
        };
    }

    /// Where `self` (the fabric) sits relative to `was` (the walker) on that
    /// question's own quality order.
    ///
    /// Interning and the algebra both rewrite the shape — dedup, re-association,
    /// class merging, closure collapse — and every rewrite preserves the
    /// LANGUAGE while potentially exposing more than the parser's bracketing
    /// did. So "differs" is not one verdict but two: a longer mandatory literal,
    /// a more selective cover, a newly-provable anchor, or a lower star height
    /// are gains, and anything moving the other way is a fault the transfer must
    /// not carry. (That a gain is SOUND — the longer literal really is mandatory
    /// — is the language oracle's job in `ast_test.zig`; this only classifies.)
    fn versus(self: Answer, was: Answer) enum { same, better, worse } {
        if (self.eql(was)) return .same;
        return switch (self) {
            // A longer mandatory literal is a more selective prefilter.
            .bytes => |x| if (x.len > was.bytes.len) .better else .worse,
            // Anchoring is knowledge: proving it where the walker could not
            // turns a full scan into a line-start scan.
            .flag => |x| if (x and !was.flag) .better else .worse,
            // Star height gates the bit-parallel rung at ≤ 1, so down is up.
            .count => |x| if (x < was.count) .better else .worse,
            // A cover is worth its WEAKEST literal, and having one at all beats
            // having none.
            .set => |maybe| blk: {
                const now = maybe orelse break :blk .worse;
                const before = was.set orelse break :blk .better;
                break :blk if (weakest(now) > weakest(before)) .better else .worse;
            },
        };
    }

    fn write(self: Answer, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        switch (self) {
            .bytes => |s| try out.print(gpa, "\"{s}\"", .{s}),
            .flag => |f| try out.appendSlice(gpa, if (f) "true" else "false"),
            .count => |c| try out.print(gpa, "{d}", .{c}),
            .set => |maybe| {
                const s = maybe orelse return out.appendSlice(gpa, "none");
                try out.append(gpa, '{');
                for (s, 0..) |lit, i| try out.print(gpa, "{s}{s}", .{ if (i == 0) "" else ",", lit });
                try out.append(gpa, '}');
            },
        }
    }
};

// ── the two arms ─────────────────────────────────────────────────────────────

/// The incumbent: one recursive walk over the parser's own tree, per question,
/// exactly as the compile path calls it today.
fn walk(arena: std.mem.Allocator, node: *syn.Node, q: Question) !Answer {
    return switch (q) {
        .best => .{ .bytes = (try ana.literalInfo(arena, node)).best },
        .cover => .{ .set = try ana.requiredAny(arena, node) },
        .anchored => .{ .flag = ana.startsAnchored(node) },
        .star_height => .{ .count = parabix.starHeight(node) },
    };
}

/// The challenger, isolated: build the fabric and read ONE question off it.
/// This is the honest cost for a consumer that asks nothing else.
fn solo(gpa: std.mem.Allocator, arena: std.mem.Allocator, node: *syn.Node, q: Question) !Answer {
    var a = try ast.analyze(gpa, arena, node, .{});
    defer a.deinit();
    return read(&a, arena, q);
}

/// Which allocator owns the DAG and the fact array.
///
/// Not a tuning knob but a design question the transfer has to answer: the
/// graph's lifetime is the compile's, and the compile already holds an arena
/// for the parse tree. A general-purpose allocator charges a per-call price
/// about twenty times over for a graph this size, so where the storage comes
/// from can decide a consumer's verdict on its own.
const Owner = enum { gpa, arena };

fn read(a: *const ast.Ast, arena: std.mem.Allocator, q: Question) !Answer {
    return switch (q) {
        .best => .{ .bytes = a.root().lit.best },
        .cover => .{ .set = try a.cover(arena) },
        .anchored => .{ .flag = a.root().anchored },
        .star_height => .{ .count = a.root().star_height },
    };
}

/// The challenger, fused: one build, every question — what the compile path
/// would actually pay once the transfer is complete.
fn fused(gpa: std.mem.Allocator, arena: std.mem.Allocator, node: *syn.Node, out: *[question_count]Answer) !void {
    var a = try ast.analyze(gpa, arena, node, .{});
    defer a.deinit();
    for (std.enums.values(Question)) |q| out[@intFromEnum(q)] = try read(&a, arena, q);
}

/// Every walker the pipeline runs today, on one tree — the sum the fused arm
/// has to beat to be worth transferring as a bundle.
fn allWalks(arena: std.mem.Allocator, node: *syn.Node, out: *[question_count]Answer) !void {
    for (std.enums.values(Question)) |q| out[@intFromEnum(q)] = try walk(arena, node, q);
}

// ── timing ───────────────────────────────────────────────────────────────────

/// Minimum-of-reps over an inner loop, in nanoseconds per inner iteration.
///
/// Minimum rather than mean on purpose: every sample is the same deterministic
/// work over the same bytes, so the spread is the machine's noise and the
/// fastest observation is the one least contaminated by it. The arena is reset
/// (capacity retained) between iterations, so allocation is charged to both
/// arms and page-faulting is charged to neither.
fn time(io: std.Io, reps: usize, inner: usize, arena: *std.heap.ArenaAllocator, ctx: anytype, comptime body: anytype) !f64 {
    var t = Span.open(io);
    var best: u64 = std.math.maxInt(u64);
    for (0..reps) |_| {
        _ = t.lap(io);
        for (0..inner) |_| {
            _ = arena.reset(.retain_capacity);
            try body(arena.allocator(), ctx);
        }
        best = @min(best, @as(u64, @intCast(@intFromEnum(t.lap(io)))));
    }
    return @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(inner));
}

const Ctx = struct {
    gpa: std.mem.Allocator,
    src: []const u8,
    node: *syn.Node,
    q: Question,
    owner: Owner,

    /// The allocator the graph should be built in for this run.
    fn store(self: Ctx, arena: std.mem.Allocator) std.mem.Allocator {
        return switch (self.owner) {
            .gpa => self.gpa,
            .arena => arena,
        };
    }
};

fn bodyWalk(arena: std.mem.Allocator, ctx: Ctx) !void {
    std.mem.doNotOptimizeAway(try walk(arena, ctx.node, ctx.q));
}
fn bodySolo(arena: std.mem.Allocator, ctx: Ctx) !void {
    std.mem.doNotOptimizeAway(try solo(ctx.store(arena), arena, ctx.node, ctx.q));
}
fn bodyAllWalks(arena: std.mem.Allocator, ctx: Ctx) !void {
    var out: [question_count]Answer = undefined;
    try allWalks(arena, ctx.node, &out);
    std.mem.doNotOptimizeAway(&out);
}
fn bodyFused(arena: std.mem.Allocator, ctx: Ctx) !void {
    var out: [question_count]Answer = undefined;
    try fused(ctx.store(arena), arena, ctx.node, &out);
    std.mem.doNotOptimizeAway(&out);
}

// ── where the build's time actually goes ─────────────────────────────────────
// Three nested arms, each adding one stage, so the differences name the stages:
// hash-consing, then the fused sweep over it, then the algebra between them.
// A bundle that only just wins is a bundle whose stages are worth pricing.

fn bodyParse(arena: std.mem.Allocator, ctx: Ctx) !void {
    var p = syn.Parser{ .src = ctx.src, .arena = arena };
    std.mem.doNotOptimizeAway(try p.parseAlt());
}
fn bodyIntern(arena: std.mem.Allocator, ctx: Ctx) !void {
    const store = ctx.store(arena);
    var i = try ast.intern(store, arena, ctx.node);
    defer i.deinit(store);
    std.mem.doNotOptimizeAway(&i);
}
fn bodyRaw(arena: std.mem.Allocator, ctx: Ctx) !void {
    var a = try ast.analyze(ctx.store(arena), arena, ctx.node, .{ .canonicalize = false });
    defer a.deinit();
    std.mem.doNotOptimizeAway(&a);
}
fn bodyBuild(arena: std.mem.Allocator, ctx: Ctx) !void {
    var a = try ast.analyze(ctx.store(arena), arena, ctx.node, .{});
    defer a.deinit();
    std.mem.doNotOptimizeAway(&a);
}

// ── the corpus ───────────────────────────────────────────────────────────────

/// Patterns chosen for what they do to the two arms' asymptotics, not for
/// prettiness: shallow ones where the fabric's build has nothing to amortize,
/// alternations where the cover walk's quadratic term shows, and bounded
/// repetitions where interning by squaring turns a spine into a logarithm.
const slate = [_][]const u8{
    // Flat and shallow — the fabric's worst case, nothing to share.
    "panic",
    "^func",
    "[0-9]+",
    "err.*nil",
    // Real gist-shaped queries.
    "pgxpool\\.[a-zA-Z_]+",
    "func \\(\\w+ \\*?\\w+\\) \\w+\\(",
    "TODO|FIXME|XXX|HACK",
    "https?://[a-zA-Z0-9./_-]+",
    // Alternations: `requiredAny` recomputes `literalInfo` per branch.
    "panic|fatal|error|warn",
    "alpha|bravo|charlie|delta|echo|foxtrot|golf|hotel",
    "(alpha|bravo)(charlie|delta)(echo|foxtrot)(golf|hotel)",
    "(get|set|has|del)_(user|team|org|role)_(id|name|slug)",
    // Nested groups over a shared body — one subtree, many parents.
    "((abc)|(abc))((abc)|(abc))",
    "(foo(bar(baz(qux))))+",
    // Bounded repetition — the squaring case.
    "a{64}",
    "a{256}",
    "(abc){64}",
    "[a-f0-9]{32}",
    "(\\w+\\s){16}\\w+",
    // Deep concatenation of distinct literals — no sharing, long spine.
    "abcdefghijklmnopqrstuvwxyz0123456789",
    // Star height, the parabix gate's question.
    "(a*b*)*c",
    "((x+)*)+",
};

fn loadPatterns(gpa: std.mem.Allocator, io: std.Io, path: ?[]const u8) ![]const []const u8 {
    const p = path orelse return gpa.dupe([]const u8, &slate);
    const body = try std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(1 << 20));
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len != 0 and trimmed[0] != '#') try out.append(gpa, trimmed);
    }
    return out.toOwnedSlice(gpa);
}

// ── rows ─────────────────────────────────────────────────────────────────────

/// One consumer's verdict, accumulated over the whole corpus.
const Row = struct {
    q: Question,
    /// Nanoseconds per pattern, summed over the corpus.
    walker_ns: f64 = 0,
    solo_ns: f64 = 0,
    /// Patterns where the canonical shape answered strictly better than the
    /// parse tree could — the algebra paying for itself.
    better: usize = 0,
    /// Patterns where it answered worse. Any of these blocks the transfer.
    worse: usize = 0,
    /// A witness for the first regression, for the report.
    witness: ?[]const u8 = null,

    fn speedup(self: Row) f64 {
        return if (self.solo_ns > 0) self.walker_ns / self.solo_ns else 0;
    }
    /// A consumer is transferable when the fabric never answers worse and, on
    /// its own, is not slower. One that needs the bundle to win is reported as
    /// bundle-only rather than as a win — that is the difference between "move
    /// this call" and "move this call once its neighbours move too".
    fn verdict(self: Row) []const u8 {
        if (self.worse != 0) return "REGRESSES";
        return if (self.speedup() >= 1.0) "transfer" else "bundle-only";
    }
};

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var patterns_path: ?[]const u8 = null;
    var reps: usize = 5;
    var inner: usize = 64;
    var json = false;
    var strict = false;
    var owner: Owner = .arena;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--patterns")) {
            patterns_path = it.next() orelse die("--patterns needs a path\n", .{});
        } else if (std.mem.eql(u8, a, "--reps")) {
            reps = std.fmt.parseInt(usize, it.next() orelse "", 10) catch die("--reps needs a number\n", .{});
        } else if (std.mem.eql(u8, a, "--inner")) {
            inner = std.fmt.parseInt(usize, it.next() orelse "", 10) catch die("--inner needs a number\n", .{});
        } else if (std.mem.eql(u8, a, "--owner")) {
            const v = it.next() orelse die("--owner needs gpa|arena\n", .{});
            owner = std.meta.stringToEnum(Owner, v) orelse die("--owner takes gpa|arena\n", .{});
        } else if (std.mem.eql(u8, a, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, a, "--strict")) {
            strict = true;
        } else die("unknown argument `{s}`\n", .{a});
    }

    const patterns = try loadPatterns(gpa, io, patterns_path);
    defer gpa.free(patterns);
    if (patterns.len == 0) die("no patterns\n", .{});

    var rows: [question_count]Row = undefined;
    for (std.enums.values(Question)) |q| rows[@intFromEnum(q)] = .{ .q = q };
    var walk_all_ns: f64 = 0;
    var fused_ns: f64 = 0;
    // Cumulative cost of each nested build arm — differences name the stages.
    var stage: struct { parse: f64 = 0, intern: f64 = 0, raw: f64 = 0, build: f64 = 0 } = .{};
    var offered: usize = 0;
    var distinct: usize = 0;
    var rewrites: usize = 0;

    // One arena, reused and reset per timed iteration: the allocator's own
    // warm-up is not what either arm is being measured on.
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();

    for (patterns) |src| {
        // The parse is upstream of both arms and paid by both, so it lives
        // outside every timed region and its tree is shared between them.
        var tree_arena = std.heap.ArenaAllocator.init(gpa);
        defer tree_arena.deinit();
        var p = syn.Parser{ .src = src, .arena = tree_arena.allocator() };
        const node = p.parseAlt() catch |e| die("cannot parse `{s}`: {s}\n", .{ src, @errorName(e) });
        if (p.pos != src.len) die("cannot parse `{s}`: trailing input\n", .{src});

        // Shape, for the report: what the walkers pay versus what the sweep does.
        {
            var a = try ast.analyze(gpa, scratch.allocator(), node, .{});
            defer a.deinit();
            offered += a.offered();
            distinct += a.nodes();
            rewrites += a.rewritten.rewrites;
            _ = scratch.reset(.retain_capacity);
        }

        for (std.enums.values(Question)) |q| {
            const row = &rows[@intFromEnum(q)];
            const ctx: Ctx = .{ .gpa = gpa, .src = src, .node = node, .q = q, .owner = owner };

            // Agreement first: a timing published for a question whose arms
            // disagree would be a measurement of two different computations.
            {
                const want = try walk(scratch.allocator(), node, q);
                var a = try ast.analyze(gpa, scratch.allocator(), node, .{});
                defer a.deinit();
                const got = try read(&a, scratch.allocator(), q);
                switch (got.versus(want)) {
                    .same => {},
                    .better => row.better += 1,
                    .worse => {
                        row.worse += 1;
                        if (row.witness == null) row.witness = src;
                    },
                }
                if (got.versus(want) == .worse and strict) {
                    var buf: std.ArrayList(u8) = .empty;
                    try buf.print(gpa, "REGRESSION {s} on `{s}`: walker ", .{ q.label(), src });
                    try want.write(&buf, gpa);
                    try buf.appendSlice(gpa, ", fabric ");
                    try got.write(&buf, gpa);
                    try buf.append(gpa, '\n');
                    std.debug.print("{s}", .{buf.items});
                    std.process.exit(1);
                }
                _ = scratch.reset(.retain_capacity);
            }

            row.walker_ns += try time(io, reps, inner, &scratch, ctx, bodyWalk);
            row.solo_ns += try time(io, reps, inner, &scratch, ctx, bodySolo);
        }

        const bundle: Ctx = .{ .gpa = gpa, .src = src, .node = node, .q = .best, .owner = owner };
        walk_all_ns += try time(io, reps, inner, &scratch, bundle, bodyAllWalks);
        fused_ns += try time(io, reps, inner, &scratch, bundle, bodyFused);
        stage.parse += try time(io, reps, inner, &scratch, bundle, bodyParse);
        stage.intern += try time(io, reps, inner, &scratch, bundle, bodyIntern);
        stage.raw += try time(io, reps, inner, &scratch, bundle, bodyRaw);
        stage.build += try time(io, reps, inner, &scratch, bundle, bodyBuild);
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const bundle_speedup = if (fused_ns > 0) walk_all_ns / fused_ns else 0;
    var regressing: usize = 0;
    for (rows) |r| regressing += @intFromBool(r.worse != 0);

    if (json) {
        try out.print(gpa, "{{\"tool\":\"sweep-rung\",\"patterns\":{d},\"reps\":{d},\"inner\":{d}," ++
            "\"tree_nodes\":{d},\"dag_nodes\":{d},\"rewrites\":{d}," ++
            "\"walk_all_ns\":{d:.1},\"fused_ns\":{d:.1},\"bundle_speedup\":{d:.3},\"consumers\":[", .{
            patterns.len,   reps,     inner,       offered,
            distinct,       rewrites, walk_all_ns, fused_ns,
            bundle_speedup,
        });
        for (rows, 0..) |r, i| {
            try out.print(gpa, "{s}{{\"question\":\"{t}\",\"walker_ns\":{d:.1},\"solo_ns\":{d:.1}," ++
                "\"speedup\":{d:.3},\"better\":{d},\"worse\":{d},\"verdict\":\"{s}\"}}", .{
                if (i == 0) "" else ",", r.q, r.walker_ns, r.solo_ns, r.speedup(), r.better, r.worse, r.verdict(),
            });
        }
        try out.appendSlice(gpa, "]}\n");
    } else {
        try out.print(gpa, "sweep rung — {d} patterns, min of {d}×{d}, graph owned by {t}\n\n", .{ patterns.len, reps, inner, owner });
        try out.print(gpa, "  shape: {d} tree nodes offered -> {d} distinct DAG nodes ({d:.2}x sharing), {d} rewrites\n\n", .{
            offered,
            distinct,
            if (distinct > 0) @as(f64, @floatFromInt(offered)) / @as(f64, @floatFromInt(distinct)) else 1,
            rewrites,
        });
        try out.appendSlice(gpa, "  per consumer, asked alone (build + one read vs one walk)\n");
        try out.print(gpa, "  {s:<28} {s:>12} {s:>12} {s:>9} {s:>7}  {s}\n", .{ "question", "walker ns", "fabric ns", "speedup", "better", "verdict" });
        for (rows) |r| {
            try out.print(gpa, "  {s:<28} {d:>12.0} {d:>12.0} {d:>8.2}x {d:>7}  {s}", .{
                r.q.label(), r.walker_ns, r.solo_ns, r.speedup(), r.better, r.verdict(),
            });
            if (r.witness) |w| try out.print(gpa, " (worse on `{s}`, {d} patterns)", .{ w, r.worse });
            try out.append(gpa, '\n');
        }
        try out.print(gpa, "\n  all {d} together (what the compile path actually asks)\n", .{question_count});
        try out.print(gpa, "  {s:<28} {d:>12.0} {d:>12.0} {d:>8.2}x\n", .{ "every question", walk_all_ns, fused_ns, bundle_speedup });

        // The decision this rung exists to serve. The build is a fixed cost, so
        // the question is never "is this consumer faster" — it is "how many
        // consumers have to move before the build is paid for". Ordering by
        // walker cost descending gives the cheapest route to break-even.
        var order: [question_count]Row = rows;
        std.mem.sort(Row, &order, {}, struct {
            fn gt(_: void, a: Row, b: Row) bool {
                return a.walker_ns > b.walker_ns;
            }
        }.gt);
        try out.print(gpa, "\n  break-even: the fabric costs {d:.0} ns over this corpus\n", .{fused_ns});
        var recovered: f64 = 0;
        for (order, 1..) |r, k| {
            recovered += r.walker_ns;
            try out.print(gpa, "  {d} transferred (+{s:<24}) recovers {d:>8.0} ns  {d:>6.2}x {s}\n", .{
                k,
                r.q.label(),
                recovered,
                recovered / fused_ns,
                if (recovered >= fused_ns) "<- pays for itself here" else "",
            });
        }
        try out.appendSlice(gpa, "\n  where the build's time goes (ns over the corpus)\n");
        try out.print(gpa, "  {s:<28} {d:>12.0}  the compile path pays this either way\n", .{ "parse", stage.parse });
        try out.print(gpa, "  {s:<28} {d:>12.0}\n", .{ "intern", stage.intern });
        try out.print(gpa, "  {s:<28} {d:>12.0}\n", .{ "sweep", stage.raw - stage.intern });
        try out.print(gpa, "  {s:<28} {d:>12.0}\n", .{ "algebra", stage.build - stage.raw });
        try out.print(gpa, "  {s:<28} {d:>12.0}\n", .{ "build, total", stage.build });
    }
    gist.corpus.emitStdout(out.items);
    if (regressing != 0) std.process.exit(1);
}
