//! gist `--rank` — the definition-first ranked view, gist's one output shape
//! ripgrep can't express.
//!
//! `gist <pattern>` (and `gist rg`) answer WHERE a literal appears, ripgrep-
//! identically (`run.zig`). `--rank` answers WHICH of those hits matters most:
//! it cold-loads the persisted trigram index, resolves the candidate set (the
//! same `fresh.candidates` widening the read-elision path uses), extracts a few
//! per-file ranking features in a parallel read pass, fuses them with the
//! weighted RRF kernel in `rank/rank.zig`, and prints the top-K as
//! `path:line [kind] ×count line` — a symbol's DEFINITION outranking its call
//! sites, codegen demoted. It requires an index (that's the structure the
//! ranking reads); without one there's nothing to rank.
//!
//! This is the sole surviving home of the ranked drivers (hoisted out of the
//! former `commands/search/drivers.zig` when the two engines merged): the raw
//! blocking-syscall parallel read + RRF fusion, unchanged, addressed now by the
//! unified engine's `--rank` flag instead of the deleted `search --show ranked`.

const std = @import("std");
const corpus_mod = @import("../../corpus/corpus.zig");
const fresh = @import("../../corpus/fresh.zig");
const simd = @import("../../scan/simd.zig");
const persist = @import("../../index/persist.zig");
const signals = @import("../../rank/signals.zig");
const rank_mod = @import("../../rank/rank.zig");
const Dir = std.Io.Dir;

const Doc = rank_mod.Doc;

fn nowNs(io: std.Io) i128 {
    return std.Io.Clock.now(.awake, io).nanoseconds;
}
fn ms(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

fn pathDepth(path: []const u8) u16 {
    var d: u16 = 0;
    for (path) |c| if (c == '/') {
        d +%= 1;
    };
    return d;
}

/// One pass over a candidate file's bytes → its ranking features (matching-line
/// count, whether any match is a definition, the best line to surface). Returns
/// null when the needle isn't actually present (a trigram false positive).
fn fileDoc(buf: []const u8, path: []const u8, needle: []const u8, id: u32) ?Doc {
    var line_no: u32 = 0;
    var match_lines: u32 = 0;
    var first: u32 = 0;
    var defline: u32 = 0;
    var it = std.mem.splitScalar(u8, buf, '\n');
    while (it.next()) |line| {
        line_no += 1;
        if (!simd.contains(line, needle)) continue;
        match_lines += 1;
        if (first == 0) first = line_no;
        if (defline == 0 and signals.definesNeedle(line, needle)) defline = line_no;
    }
    const generated = signals.isGenerated(path, buf);
    if (match_lines == 0) {
        if (!simd.contains(buf, needle)) return null; // multi-line needle: keep, surface L1
        return .{ .id = id, .matches = 1, .is_def = false, .best_line = 1, .depth = pathDepth(path), .is_generated = generated };
    }
    return .{
        .id = id,
        .matches = match_lines,
        .is_def = defline != 0,
        .best_line = if (defline != 0) defline else first,
        .depth = pathDepth(path),
        .is_generated = generated,
    };
}

/// Read one file fully into `scratch` (capped); returns bytes read or null.
fn readFileInto(path: []const u8, scratch: []u8) ?usize {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer {
        _ = std.posix.system.close(fd);
    }
    var n: usize = 0;
    while (n < scratch.len) {
        const r = std.posix.read(fd, scratch[n..]) catch break;
        if (r == 0) break;
        n += r;
    }
    return n;
}

/// Below this candidate count the thread-spawn overhead isn't worth it and the
/// read runs inline (mirrors `run.zig`'s `par_threshold`).
const read_par_threshold = 64;

const RankShard = struct {
    paths: []const []const u8,
    ids: []const u32,
    needle: []const u8,
    gpa: std.mem.Allocator,
    out: []Doc,
    n: usize = 0,
    reads: usize = 0,
};
fn rankShard(sh: *RankShard) void {
    const scratch = sh.gpa.alloc(u8, corpus_mod.per_file_cap) catch return;
    defer sh.gpa.free(scratch);
    var w: usize = 0;
    for (sh.ids) |d| {
        const n = readFileInto(sh.paths[d], scratch) orelse continue;
        sh.reads += 1;
        if (fileDoc(scratch[0..n], sh.paths[d], sh.needle, d)) |doc| {
            sh.out[w] = doc;
            w += 1;
        }
    }
    sh.n = w;
}

/// Parallel feature extraction over candidate `ids` — one std.Thread per core,
/// blocking posix reads (the same proven pattern as `run.zig`'s `readCandidates`).
fn parallelRank(gpa: std.mem.Allocator, paths: []const []const u8, ids: []const u32, needle: []const u8, docs: *std.ArrayList(Doc), read_files: *usize) !void {
    const ncpu = std.Thread.getCpuCount() catch 8;
    const nshards = if (ids.len < read_par_threshold) 1 else @min(ids.len, ncpu);
    const shards = try gpa.alloc(RankShard, nshards);
    defer gpa.free(shards);
    const outbuf = try gpa.alloc(Doc, ids.len);
    defer gpa.free(outbuf);
    const per = (ids.len + nshards - 1) / nshards;
    var off: usize = 0;
    for (shards) |*sh| {
        const lo = off;
        const hi = @min(off + per, ids.len);
        off = hi;
        sh.* = .{ .paths = paths, .ids = ids[lo..hi], .needle = needle, .gpa = gpa, .out = outbuf[lo..hi] };
    }
    if (nshards == 1) {
        rankShard(&shards[0]);
    } else {
        const threads = try gpa.alloc(std.Thread, nshards);
        defer gpa.free(threads);
        for (shards, 0..) |*sh, k| threads[k] = try std.Thread.spawn(.{}, rankShard, .{sh});
        for (threads) |t| t.join();
    }
    for (shards) |*sh| {
        try docs.appendSlice(gpa, sh.out[0..sh.n]);
        read_files.* += sh.reads;
    }
}

/// The trimmed, 120-col-capped text of 1-based `line` in `path` — the one line
/// shown per ranked file. Display-only (not benchmarked), so io reads are fine.
fn snippetOf(gpa: std.mem.Allocator, io: std.Io, path: []const u8, line: u32) ![]u8 {
    const data = Dir.cwd().readFileAlloc(io, path, gpa, .limited(corpus_mod.per_file_cap)) catch return gpa.dupe(u8, "");
    defer gpa.free(data);
    var it = std.mem.splitScalar(u8, data, '\n');
    var ln: u32 = 0;
    while (it.next()) |l| {
        ln += 1;
        if (ln == line) {
            const t = std.mem.trim(u8, l, " \t\r");
            return gpa.dupe(u8, t[0..@min(t.len, 120)]);
        }
    }
    return gpa.dupe(u8, "");
}

/// Fresh-process ranked query: cold-load the index, resolve + read candidates,
/// extract per-file features, fuse via the RRF kernel, print the top-K as
/// token-compressed `path:line` + surfaced line. `k` caps the surfaced rows
/// (`--rank[=N]`, default 20). No index ⇒ nothing to rank (silent no-op, the
/// same "an index is the structure this reads" contract the old driver had).
pub fn run(gpa: std.mem.Allocator, io: std.Io, needle: []const u8, k: usize) !void {
    if (needle.len == 0) return;
    const l0 = nowNs(io);
    var p = (try persist.load(gpa, io)) orelse return;
    defer p.deinit();
    const load_ns = nowNs(io) - l0;

    const q0 = nowNs(io);
    const filters = [_][]const u8{needle}; // <3 B ⇒ candidates() seeds every doc
    var cand = try fresh.candidates(gpa, io, &p.idx, &p.paths, &filters, &corpus_mod.default_roots);
    defer cand.deinit();
    var docs: std.ArrayList(Doc) = .empty;
    defer docs.deinit(gpa);
    var read_files: usize = 0;
    try parallelRank(gpa, p.paths.items, cand.ids, needle, &docs, &read_files);

    // The fusion: lexical density + symbol(def) boost + shallow-path + authored
    // (codegen demotion), RRF-fused. null is the external graph-centrality hook.
    const order = try rank_mod.rank(gpa, docs.items, .{}, null);
    defer gpa.free(order);
    const query_ns = nowNs(io) - q0;

    const top = @min(order.len, if (k == 0) 20 else k);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    for (order[0..top], 0..) |di, i| {
        const doc = docs.items[di];
        const path = p.paths.items[doc.id];
        const snip = try snippetOf(gpa, io, path, doc.best_line);
        defer gpa.free(snip);
        const kind = if (doc.is_generated) "gen" else if (doc.is_def) "def" else "use";
        const row = try std.fmt.allocPrint(gpa, "{d:>2}. {s}:{d}  [{s}]  ×{d}  {s}\n", .{
            i + 1, path, doc.best_line, kind, doc.matches, snip,
        });
        defer gpa.free(row);
        try buf.appendSlice(gpa, row);
    }
    corpus_mod.emitStdout(buf.items); // ranked rows → stdout (rg convention)
    std.debug.print("— {d} ranked matches (top {d}) · read {d}/{d} candidates · cold-load {d:.1} ms · rank {d:.1} ms · total {d:.1} ms\n", .{
        docs.items.len, top, read_files, p.paths.items.len, ms(load_ns), ms(query_ns), ms(load_ns + query_ns),
    });
}
