//! gist cold one-shot CLI — the path that wins the *first* query.
//!
//!   zig build cli -- index            build the index once, persist it to disk
//!   zig build cli -- query <needle>   FRESH process: cold-load the index, then
//!                                     read & verify ONLY the candidate files
//!
//! Why this beats ripgrep on a cold/first query: rg has no index, so every
//! invocation must walk the whole tree and read every byte. gist cold-loads a
//! persisted trigram index (~30 ms), resolves the candidate set in RAM, and
//! then touches disk for *only the candidate files* — for a selective query
//! that is dozens of small files instead of ~16.5k. Subsequent queries in the
//! same session never rebuild. (A <3-byte needle has no trigram filter, so it
//! degenerates to a full read, like rg — the one case we merely match it.)

const std = @import("std");
const gist = @import("gist");
const corpus_mod = @import("corpus.zig");
const simd = @import("simd.zig");
const Index = gist.trigram.Index;
const Dir = std.Io.Dir;

const index_file = corpus_mod.out_dir ++ "/index.gist";
const paths_file = corpus_mod.out_dir ++ "/paths.list";

fn nowNs(io: std.Io) i128 {
    return std.Io.Clock.now(.awake, io).nanoseconds;
}
fn ms(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}
fn cmpStrings(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// One shard of the cold candidate read+verify. Each shard opens & reads its own
/// files with **blocking `std.posix`** (the cold path is IO-bound: rg reads every
/// byte multi-threaded, so a single-threaded gist read was the one place a heavy
/// cold query could lose), then SIMD-verifies in-thread. Reads reuse one scratch
/// buffer capped at `per_file_cap` — the same cap the indexer used, so the cold
/// corpus is byte-identical to the indexed one. Errors on a file are skipped.
///
/// NB: an earlier attempt fanned this out via `Io.Group.concurrent`; measured on
/// the macOS backend it was ~6× *slower* (fiber/scheduling overhead dwarfed the
/// reads). Raw `std.Thread` + blocking syscalls — what `search.zig` already uses
/// — is the proven-fast path; the io event loop is bypassed entirely here.
const ReadShard = struct {
    gpa: std.mem.Allocator,
    paths: []const []const u8,
    ids: []const u32,
    needle: []const u8,
    out: []u32, // private region (≤ ids.len), no contention
    n: usize = 0,
    reads: usize = 0,
};

fn readVerifyShard(sh: *ReadShard) void {
    const scratch = sh.gpa.alloc(u8, corpus_mod.per_file_cap) catch return;
    defer sh.gpa.free(scratch);
    var w: usize = 0;
    for (sh.ids) |d| {
        const fd = std.posix.openat(std.posix.AT.FDCWD, sh.paths[d], .{ .ACCMODE = .RDONLY }, 0) catch continue;
        var n: usize = 0;
        while (n < scratch.len) {
            const r = std.posix.read(fd, scratch[n..]) catch break;
            if (r == 0) break;
            n += r;
        }
        _ = std.posix.system.close(fd);
        sh.reads += 1;
        if (simd.contains(scratch[0..n], sh.needle)) {
            sh.out[w] = d;
            w += 1;
        }
    }
    sh.n = w;
}

/// Read & verify `ids` against `needle`, fanning the file IO across one
/// `std.Thread` per core. Below `read_par_threshold` candidates the spawn
/// overhead isn't worth it and we read inline. Appends matching paths.
const read_par_threshold = 64;

fn parallelRead(gpa: std.mem.Allocator, paths: []const []const u8, ids: []const u32, needle: []const u8, matches: *std.ArrayList([]const u8), read_files: *usize) !void {
    const ncpu = std.Thread.getCpuCount() catch 8;
    const nshards = if (ids.len < read_par_threshold) 1 else @min(ids.len, ncpu);

    const shards = try gpa.alloc(ReadShard, nshards);
    defer gpa.free(shards);
    const outbuf = try gpa.alloc(u32, ids.len);
    defer gpa.free(outbuf);

    const per = (ids.len + nshards - 1) / nshards;
    var off: usize = 0;
    for (shards) |*sh| {
        const lo = off;
        const hi = @min(off + per, ids.len);
        off = hi;
        sh.* = .{ .gpa = gpa, .paths = paths, .ids = ids[lo..hi], .needle = needle, .out = outbuf[lo..hi] };
    }

    if (nshards == 1) {
        readVerifyShard(&shards[0]);
    } else {
        const threads = try gpa.alloc(std.Thread, nshards);
        defer gpa.free(threads);
        for (shards, 0..) |*sh, k| threads[k] = try std.Thread.spawn(.{}, readVerifyShard, .{sh});
        for (threads) |t| t.join();
    }

    for (shards) |*sh| {
        for (sh.out[0..sh.n]) |d| try matches.append(gpa, paths[d]);
        read_files.* += sh.reads;
    }
}

/// Build once, persist the index + the doc→path table (NUL-separated, doc-id
/// order) so a later fresh process can map candidate ids back to files.
pub fn runIndex(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8) !void {
    const t0 = nowNs(io);
    var corpus = try corpus_mod.load(gpa, io, roots);
    defer corpus.deinit();
    var idx = try Index.build(gpa, corpus.docs);
    defer idx.deinit();

    try Dir.cwd().createDirPath(io, corpus_mod.out_dir);
    const blob = try gpa.alloc(u8, idx.serializedSize());
    defer gpa.free(blob);
    _ = idx.writeInto(blob);
    try Dir.cwd().writeFile(io, .{ .sub_path = index_file, .data = blob });

    var pl: std.ArrayList(u8) = .empty;
    defer pl.deinit(gpa);
    for (corpus.paths) |p| {
        try pl.appendSlice(gpa, p);
        try pl.append(gpa, 0);
    }
    try Dir.cwd().writeFile(io, .{ .sub_path = paths_file, .data = pl.items });

    std.debug.print("indexed {d} files · {d:.1} MiB corpus · {d:.1} MiB index · {d:.0} ms → {s}\n", .{
        corpus.docs.len,
        @as(f64, @floatFromInt(corpus.bytes)) / (1 << 20),
        @as(f64, @floatFromInt(blob.len)) / (1 << 20),
        ms(nowNs(io) - t0),
        corpus_mod.out_dir,
    });
}

/// Fresh-process query: cold-load the persisted index, then read & verify only
/// the candidate files. Prints matching paths (sorted) to stderr + a timing
/// breakdown — process wall-time is what the cold head-to-head measures.
pub fn runQuery(gpa: std.mem.Allocator, io: std.Io, needle: []const u8) !void {
    const l0 = nowNs(io);
    const ib = Dir.cwd().readFileAlloc(io, index_file, gpa, .unlimited) catch {
        std.debug.print("no index at {s} — run `zig build cli -- index` first\n", .{index_file});
        return;
    };
    defer gpa.free(ib);
    var idx = try Index.fromBytes(gpa, ib);
    defer idx.deinit();
    const pb = try Dir.cwd().readFileAlloc(io, paths_file, gpa, .unlimited);
    defer gpa.free(pb);
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(gpa);
    var pit = std.mem.splitScalar(u8, pb, 0);
    while (pit.next()) |p| if (p.len > 0) try paths.append(gpa, p);
    const load_ns = nowNs(io) - l0;

    const q0 = nowNs(io);
    var matches: std.ArrayList([]const u8) = .empty;
    defer matches.deinit(gpa);
    var read_files: usize = 0;

    // Resolve a candidate id list: the trigram prefilter when the needle is ≥3
    // bytes, else every doc (a <3-byte needle has no trigram filter ⇒ full read,
    // like rg). Copied into a uniform buffer so one defer frees either path.
    var ids: []u32 = undefined;
    if (idx.queryLiteral(gpa, needle)) |cand| {
        defer gpa.free(cand);
        ids = try gpa.alloc(u32, cand.len);
        @memcpy(ids, cand);
    } else |_| {
        ids = try gpa.alloc(u32, paths.items.len);
        for (ids, 0..) |*x, i| x.* = @intCast(i);
    }
    defer gpa.free(ids);

    try parallelRead(gpa, paths.items, ids, needle, &matches, &read_files);
    const query_ns = nowNs(io) - q0;

    std.mem.sort([]const u8, matches.items, {}, cmpStrings);
    var outbuf: std.ArrayList(u8) = .empty;
    defer outbuf.deinit(gpa);
    for (matches.items) |p| {
        try outbuf.appendSlice(gpa, p);
        try outbuf.append(gpa, '\n');
    }
    std.debug.print("{s}", .{outbuf.items});
    std.debug.print("— {d} matches · read {d}/{d} candidate files · cold-load {d:.1} ms · query {d:.1} ms · total {d:.1} ms\n", .{
        matches.items.len, read_files, paths.items.len, ms(load_ns), ms(query_ns), ms(load_ns + query_ns),
    });
}
