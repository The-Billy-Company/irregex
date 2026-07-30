//! multipattern — the gist arm of the Hyperscan race, and its own oracle.
//!
//! Links gist's REAL kernel (`@import("irregex")` — `PatternSet` ships inside it
//! at `src/kernel/slate/patterns.zig`) and answers the same question `vscan.c`
//! puts to Vectorscan over byte-identical inputs: **which pattern ids matched
//! which documents**, and how fast.
//!
//! Three modes, all emitting one JSON object on stdout:
//!
//!   --corpus DIR   per-byte throughput over the resident `corpus.bin` blob.
//!                  Only the `docMask` loop is timed; the read happens first.
//!   --paths FILE   the same answer with the read included — gist's kernel doing
//!                  what a scanner must do, so the end-to-end table can separate
//!                  "our kernel is faster per byte" from "our index skips reads".
//!   --verify       the fail-closed contract. Re-derives the whole attribution
//!                  vector with N INDEPENDENT single-pattern `CompiledQuery`
//!                  runs — the same engine the CLI executes, driven one pattern
//!                  at a time with no set machinery at all — and exits non-zero
//!                  on the first disagreement. This is corpus-scale proof of the
//!                  invariant `patterns_test.zig` proves on hand-written docs:
//!                  a set answer IS N single-pattern answers. Timing is never
//!                  published without it (the harness runs `--verify` first).
//!
//! `doc_hits[i]` is the number of documents pattern `i` matched — the same
//! vector `vscan` prints, so equality across the two tools is a diff, not a
//! promise.

const std = @import("std");
const gist = @import("irregex");

const patterns = gist.irregex.patterns;
const query = gist.engine.query;
const Span = gist.assay.Span; // package instrumentation floor: monotonic Span

const Mode = enum { corpus, paths };

const Config = struct {
    mode: Mode = .corpus,
    where: []const u8 = "",
    pats: [][]const u8 = &.{},
    fixed: bool = false,
    icase: bool = false,
    verify: bool = false,
    /// Repeat the timed loop this many times, reporting the FASTEST pass — the
    /// same min-of-runs posture the other lab harnesses use, so one scheduler
    /// hiccup on a box running ~10 coworking agents cannot become the number.
    reps: usize = 3,
};

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("multipattern: " ++ fmt, args);
    std.process.exit(2);
}

fn parse(gpa: std.mem.Allocator, init: std.process.Init) Config {
    var cfg: Config = .{};
    var pats: std.ArrayList([]const u8) = .empty;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip();
    while (it.next()) |a| {
        const value = struct {
            fn f(i: *std.process.Args.Iterator, what: []const u8) []const u8 {
                return i.next() orelse die("{s} needs a value\n", .{what});
            }
        }.f;
        if (std.mem.eql(u8, a, "-e")) {
            pats.append(gpa, value(&it, "-e")) catch die("oom\n", .{});
        } else if (std.mem.eql(u8, a, "--corpus")) {
            cfg.mode = .corpus;
            cfg.where = value(&it, "--corpus");
        } else if (std.mem.eql(u8, a, "--paths")) {
            cfg.mode = .paths;
            cfg.where = value(&it, "--paths");
        } else if (std.mem.eql(u8, a, "--reps")) {
            cfg.reps = std.fmt.parseInt(usize, value(&it, "--reps"), 10) catch die("bad --reps\n", .{});
        } else if (std.mem.eql(u8, a, "-F")) {
            cfg.fixed = true;
        } else if (std.mem.eql(u8, a, "-i")) {
            cfg.icase = true;
        } else if (std.mem.eql(u8, a, "--verify")) {
            cfg.verify = true;
        } else {
            die("unknown flag {s}\n", .{a});
        }
    }
    if (pats.items.len == 0 or cfg.where.len == 0)
        die("usage: multipattern (--corpus DIR | --paths FILE) [-F] [-i] [--verify] -e PAT...\n", .{});
    cfg.pats = pats.toOwnedSlice(gpa) catch die("oom\n", .{});
    return cfg;
}

/// The documents both arms scan, already resident. Owns its backing bytes.
const Docs = struct {
    blob: []u8,
    spans: [][2]usize,
    bytes: usize,

    fn deinit(self: *Docs, gpa: std.mem.Allocator) void {
        gpa.free(self.blob);
        gpa.free(self.spans);
    }

    fn at(self: *const Docs, k: usize) []const u8 {
        return self.blob[self.spans[k][0]..][0..self.spans[k][1]];
    }
};

const cap = 1 << 31;

/// `corpus.bin` + `corpus.idx` as written by `pack.py` — the same two files
/// `vscan --corpus` reads, in the same order.
fn loadBlob(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) !Docs {
    const bin = try std.fmt.allocPrint(gpa, "{s}/corpus.bin", .{dir});
    defer gpa.free(bin);
    const idx = try std.fmt.allocPrint(gpa, "{s}/corpus.idx", .{dir});
    defer gpa.free(idx);
    const blob = try std.Io.Dir.cwd().readFileAlloc(io, bin, gpa, .limited(cap));
    errdefer gpa.free(blob);
    const index = try std.Io.Dir.cwd().readFileAlloc(io, idx, gpa, .limited(cap));
    defer gpa.free(index);

    var spans: std.ArrayList([2]usize) = .empty;
    errdefer spans.deinit(gpa);
    var bytes: usize = 0;
    var lines = std.mem.splitScalar(u8, index, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const off = std.fmt.parseInt(usize, f.next() orelse continue, 10) catch continue;
        const len = std.fmt.parseInt(usize, f.next() orelse continue, 10) catch continue;
        if (off + len > blob.len) continue;
        try spans.append(gpa, .{ off, len });
        bytes += len;
    }
    return .{ .blob = blob, .spans = try spans.toOwnedSlice(gpa), .bytes = bytes };
}

/// Every path in `list` slurped into one arena-backed blob — gist's kernel
/// paying the read a stream scanner cannot elide, so the end-to-end table can
/// price the index separately from the matcher.
fn loadPaths(gpa: std.mem.Allocator, io: std.Io, list_path: []const u8) !Docs {
    const list = try std.Io.Dir.cwd().readFileAlloc(io, list_path, gpa, .limited(cap));
    defer gpa.free(list);
    var blob: std.ArrayList(u8) = .empty;
    errdefer blob.deinit(gpa);
    var spans: std.ArrayList([2]usize) = .empty;
    errdefer spans.deinit(gpa);
    var lines = std.mem.splitScalar(u8, list, '\n');
    while (lines.next()) |path| {
        if (path.len == 0) continue;
        const body = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch continue;
        defer gpa.free(body);
        const head = body[0..@min(body.len, 8192)];
        if (std.mem.indexOfScalar(u8, head, 0) != null) continue; // implicit binary
        try spans.append(gpa, .{ blob.items.len, body.len });
        try blob.appendSlice(gpa, body);
    }
    const bytes = blob.items.len;
    return .{ .blob = try blob.toOwnedSlice(gpa), .spans = try spans.toOwnedSlice(gpa), .bytes = bytes };
}

/// One timed pass of the production answer: `docMask` per document, tallying
/// how many documents each pattern matched.
fn tally(set: *const patterns.PatternSet, sc: *patterns.PatternSet.Scratch, mask: []u64, docs: *const Docs, hits: []u64) void {
    @memset(hits, 0);
    for (0..docs.spans.len) |d| {
        if (!set.docMask(docs.at(d), sc, mask)) continue;
        for (hits, 0..) |*h, p| h.* += @intFromBool(patterns.maskHas(mask, p));
    }
}

/// The independent oracle: N single-pattern `CompiledQuery` runs, no set
/// machinery. Any disagreement with `tally` is a contract violation.
fn oracle(gpa: std.mem.Allocator, cfg: Config, docs: *const Docs, hits: []u64) !void {
    @memset(hits, 0);
    for (cfg.pats, 0..) |p, i| {
        var q = try query.CompiledQuery.compile(gpa, .{ .pattern = p, .fixed = cfg.fixed, .ignore_case = cfg.icase });
        defer q.deinit(gpa);
        var sc = try q.scratch(gpa);
        defer sc.deinit();
        for (0..docs.spans.len) |d| hits[i] += @intFromBool(q.docMatches(docs.at(d), &sc));
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cfg = parse(gpa, init);
    defer gpa.free(cfg.pats);

    var docs = switch (cfg.mode) {
        .corpus => loadBlob(gpa, io, cfg.where),
        .paths => loadPaths(gpa, io, cfg.where),
    } catch |e| die("cannot load {s}: {s}\n", .{ cfg.where, @errorName(e) });
    defer docs.deinit(gpa);
    if (docs.spans.len == 0) die("empty corpus at {s}\n", .{cfg.where});

    const specs = try gpa.alloc(query.Spec, cfg.pats.len);
    defer gpa.free(specs);
    for (cfg.pats, specs) |p, *s| s.* = .{ .pattern = p, .fixed = cfg.fixed, .ignore_case = cfg.icase };

    var t = Span.open(io);
    var set = patterns.PatternSet.compile(gpa, specs) catch |e| die("compile: {s}\n", .{@errorName(e)});
    defer set.deinit(gpa);
    const compile_ns: u64 = @intCast(@intFromEnum(t.read(io)));

    var sc = try set.scratch(gpa);
    defer sc.deinit(gpa);
    const mask = try gpa.alloc(u64, patterns.maskWords(cfg.pats.len));
    defer gpa.free(mask);
    const hits = try gpa.alloc(u64, cfg.pats.len);
    defer gpa.free(hits);

    var best: u64 = std.math.maxInt(u64);
    for (0..@max(cfg.reps, 1)) |_| {
        _ = t.lap(io);
        tally(&set, &sc, mask, &docs, hits);
        best = @min(best, @as(u64, @intCast(@intFromEnum(t.lap(io)))));
    }

    if (cfg.verify) {
        const want = try gpa.alloc(u64, cfg.pats.len);
        defer gpa.free(want);
        try oracle(gpa, cfg, &docs, want);
        for (want, hits, cfg.pats, 0..) |w, got, p, i| {
            if (w == got) continue;
            std.debug.print(
                "ATTRIBUTION MISMATCH pattern[{d}] `{s}`: set says {d} docs, {d} independent searches say {d}\n",
                .{ i, p, got, cfg.pats.len, w },
            );
            std.process.exit(1);
        }
    }

    const secs = @as(f64, @floatFromInt(best)) / 1e9;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.print(gpa, "{{\"tool\":\"gist\",\"patterns\":{d},\"docs\":{d},\"bytes\":{d}," ++
        "\"scan_s\":{d:.6},\"compile_s\":{d:.6},\"gbps\":{d:.4},\"verified\":{s}," ++
        "\"tier\":\"{s}\",\"doc_hits\":[", .{
        cfg.pats.len,
        docs.spans.len,
        docs.bytes,
        secs,
        @as(f64, @floatFromInt(compile_ns)) / 1e9,
        if (secs > 0) @as(f64, @floatFromInt(docs.bytes)) / secs / 1e9 else 0,
        if (cfg.verify) "true" else "false",
        set.tier(),
    });
    for (hits, 0..) |h, i| {
        if (i != 0) try buf.append(gpa, ',');
        try buf.print(gpa, "{d}", .{h});
    }
    try buf.appendSlice(gpa, "]}\n");
    gist.corpus.emitStdout(buf.items);
}
