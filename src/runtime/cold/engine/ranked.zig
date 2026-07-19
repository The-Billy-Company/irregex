//! gist `--rank` — the definition-first ranked view, gist's one output shape
//! ripgrep can't express.
//!
//! `gist <pattern>` (and `gist rg`) answer WHERE a pattern appears, ripgrep-
//! identically (`run.zig`). `--rank` answers WHICH of those hits matters most:
//! it cold-loads the persisted trigram index, resolves the candidate set (the
//! same `fresh.candidates` widening the read-elision path uses — driven by the
//! compiled regex's required literal / alternation cover, not the raw argv
//! bytes), extracts a few per-file ranking features in a parallel read pass,
//! fuses them with the weighted RRF kernel in `rank/rank.zig`, and prints the
//! top-K as `path:line [kind] ×count line` — a symbol's DEFINITION outranking
//! its call sites, codegen demoted. When persistence is unavailable, the caller
//! feeds the same ranker from the live walk instead.
//!
//! Pattern semantics match the line engine: the caller compiles via
//! `combinePatterns` + `Regex.compileOpts`, so alternations (`foo|bar`),
//! wildcards (`claim.*job`), `-F`/`-i`/`-x`, and multi-`-e` OR all rank the
//! same hits the unranked search would emit. Positional PATH roots gate the
//! candidate set the same way a scoped walk would.

const std = @import("std");
const corpus_mod = @import("../../../../runtime/corpus/corpus.zig");
const fresh = @import("../../../../index/trigrams/fresh.zig");
const persist = @import("../../../../index/trigrams/persist.zig");
const Regex = @import("../../../../search/match/regex/linear/core.zig").Regex;
const mirror = @import("../../../../search/rank/mirror.zig");
const signals = @import("../../../../search/rank/signals.zig");
const rank_mod = @import("../../../../search/rank/rank.zig");
const gl = @import("../../../../runtime/scope/glob.zig");
const query_mod = @import("../../../../search/match/query.zig");
const args_mod = @import("../argv/args.zig");
const Dir = std.Io.Dir;

const Doc = rank_mod.Doc;
pub const LiveFile = struct { path: []const u8, bytes: []const u8 };

const Source = union(enum) {
    disk: []const []const u8,
    memory: []const LiveFile,

    fn path(self: Source, id: u32) []const u8 {
        return switch (self) {
            .disk => |paths| paths[id],
            .memory => |files| files[id].path,
        };
    }
};

const nowNs = args_mod.nowNs;
const ms = args_mod.ms;

/// Slash COUNT (not walker depth — `run.zig`'s `pathDepth` is slashes+1):
/// a shallow-path prior for the ranked view, u16 to pack the score row.
fn pathDepth(path: []const u8) u16 {
    var d: u16 = 0;
    for (path) |c| if (c == '/') {
        d +%= 1;
    };
    return d;
}

fn underAnyRoot(path: []const u8, roots: []const []const u8) bool {
    if (roots.len == 0) return true;
    // Shared boundary rule (`scope/glob.zig::underRoot` after `normalizeRoot`):
    // exact file hit, or a directory prefix ending at `/` (so `services` never
    // admits `services_old`). The extra trim folds a lone `/` root to
    // match-all, as this call site always has.
    for (roots) |r| if (gl.underRoot(path, std.mem.trimEnd(u8, gl.normalizeRoot(r), "/"))) return true;
    return false;
}

/// Sound trigram prefilter for the compiled regex — the engine-shared rule
/// (`engine/query.zig::regexPrefilter`), minus any prefilter when the fold is
/// caseless (the trigram index is case-exact, so pruning would be unsound).
fn rankFilters(re: *const Regex, caseless: bool, one: *[1][]const u8) []const []const u8 {
    if (caseless) return &.{};
    return query_mod.regexPrefilter(re, one);
}

/// Does this matching line define the symbol? Prefer the analyzer's required
/// literal; otherwise try each alternation branch that actually appears.
fn lineDefines(line: []const u8, re: *const Regex) bool {
    if (re.required.len > 0) return signals.definesNeedle(line, re.required);
    for (re.alts) |alt| {
        if (std.mem.indexOf(u8, line, alt) != null and signals.definesNeedle(line, alt)) return true;
    }
    return false;
}

/// One pass over a candidate file's bytes → its ranking features (matching-line
/// count, whether any match is a definition, the best line to surface). Returns
/// null when the regex doesn't actually match (a trigram false positive).
fn fileDoc(buf: []const u8, path: []const u8, re: *const Regex, sim: *Regex.Sim, id: u32) ?Doc {
    var line_no: u32 = 0;
    var match_lines: u32 = 0;
    var first: u32 = 0;
    var defline: u32 = 0;
    var it = std.mem.splitScalar(u8, buf, '\n');
    while (it.next()) |line| {
        line_no += 1;
        if (!re.lineMatch(sim, line)) continue;
        match_lines += 1;
        if (first == 0) first = line_no;
        if (defline == 0 and lineDefines(line, re)) defline = line_no;
    }
    const generated = signals.isGenerated(path, buf);
    const is_mirror = mirror.isPath(path);
    const content_hash = mirror.fingerprint(buf);
    if (match_lines == 0) {
        // Multi-line / whole-buffer match the per-line scan missed: keep the
        // file if the document matcher still fires, surface L1.
        if (!re.docMatch(sim, buf)) return null;
        return .{
            .id = id,
            .matches = 1,
            .is_def = false,
            .best_line = 1,
            .depth = pathDepth(path),
            .is_generated = generated,
            .is_mirror = is_mirror,
            .content_hash = content_hash,
            .content_len = buf.len,
        };
    }
    return .{
        .id = id,
        .matches = match_lines,
        .is_def = defline != 0,
        .best_line = if (defline != 0) defline else first,
        .depth = pathDepth(path),
        .is_generated = generated,
        .is_mirror = is_mirror,
        .content_hash = content_hash,
        .content_len = buf.len,
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
    re: *const Regex,
    gpa: std.mem.Allocator,
    out: []Doc,
    n: usize = 0,
    reads: usize = 0,
};
fn rankShard(sh: *RankShard) void {
    const scratch = sh.gpa.alloc(u8, corpus_mod.per_file_cap) catch return;
    defer sh.gpa.free(scratch);
    // Per-shard Pike scratch — the DFA path ignores it, but lineMatch's Pike
    // fallback needs exclusive Sim state (not thread-safe to share).
    var sim = Regex.Sim.init(sh.gpa, sh.re) catch return;
    defer sim.deinit();
    var w: usize = 0;
    for (sh.ids) |d| {
        const n = readFileInto(sh.paths[d], scratch) orelse continue;
        sh.reads += 1;
        if (fileDoc(scratch[0..n], sh.paths[d], sh.re, &sim, d)) |doc| {
            sh.out[w] = doc;
            w += 1;
        }
    }
    sh.n = w;
}

/// Parallel feature extraction over candidate `ids` — one std.Thread per core,
/// blocking posix reads (the same proven pattern as `run.zig`'s `readCandidates`).
fn parallelRank(gpa: std.mem.Allocator, paths: []const []const u8, ids: []const u32, re: *const Regex, docs: *std.ArrayList(Doc), read_files: *usize) !void {
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
        sh.* = .{ .paths = paths, .ids = ids[lo..hi], .re = re, .gpa = gpa, .out = outbuf[lo..hi] };
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

/// Ranked-row snippet budget — enough for a decl + a little neighborhood, small
/// enough that 20 ranked rows stay cheap in an agent's context window.
const snippet_budget: usize = 120;

/// Byte index ≤ `i` on a UTF-8 boundary (never split a multi-byte scalar).
fn utf8Floor(s: []const u8, i: usize) usize {
    var n = @min(i, s.len);
    while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1;
    return n;
}

/// A ≤`budget`-byte window of `line` that keeps the match span visible.
/// Prefix-only truncation hid matches past column 120 (agents saw `×××…` with
/// the hit token gone — the whole point of surfacing the line). Prefer a
/// window that contains `[sp.start, sp.end)`; fall back to a leading prefix
/// when there is no span or the match itself is wider than the budget.
fn windowAround(line: []const u8, span: ?Regex.Span, budget: usize) []const u8 {
    if (line.len <= budget) return line;
    const sp = span orelse return line[0..budget];
    if (sp.end <= sp.start or sp.start >= line.len) return line[0..budget];
    const end = @min(sp.end, line.len);
    const match_len = end - sp.start;
    if (match_len >= budget) {
        // Match alone fills the budget — show its leading bytes (still the token).
        return line[sp.start..utf8Floor(line, sp.start + budget)];
    }
    // Bias a little left of center so a `fn foo(` / `class Foo` decl keeps its
    // keyword; clamp so the full match stays inside the window.
    const ideal = sp.start -| (budget - match_len) / 3;
    var start = utf8Floor(line, ideal);
    if (start + budget < end) start = utf8Floor(line, end - budget);
    if (start + budget > line.len) start = utf8Floor(line, line.len - budget);
    const cut = utf8Floor(line, start + budget);
    if (cut <= start) return line[start..@min(start + budget, line.len)];
    return line[start..cut];
}

/// First non-empty match span on `line`, or null when the engine can't init /
/// finds nothing (trigram false-positive lines shouldn't reach here, but the
/// snippet path must still degrade to a prefix rather than crash).
fn firstSpan(gpa: std.mem.Allocator, re: *const Regex, line: []const u8) ?Regex.Span {
    var ssim = Regex.SpanSim.init(gpa, re) catch return null;
    defer ssim.deinit();
    var from: usize = 0;
    while (from <= line.len) {
        const sp = re.matchSpan(&ssim, line, from) orelse return null;
        if (sp.end > sp.start) return sp;
        from = sp.start + 1;
    }
    return null;
}

/// The trimmed, match-anchored, 120-col-capped text of 1-based `line` in `path`
/// — the one line shown per ranked file. Display-only (not benchmarked), so
/// io reads are fine. `…` marks a truncated edge so agents can tell the
/// matched token sits in a window, not the raw file prefix.
fn snippetFrom(gpa: std.mem.Allocator, data: []const u8, line: u32, re: *const Regex) ![]u8 {
    var it = std.mem.splitScalar(u8, data, '\n');
    var ln: u32 = 0;
    while (it.next()) |l| {
        ln += 1;
        if (ln != line) continue;
        const t = std.mem.trim(u8, l, " \t\r");
        const sp = firstSpan(gpa, re, t);
        const win = windowAround(t, sp, snippet_budget);
        const off = @intFromPtr(win.ptr) - @intFromPtr(t.ptr);
        const left = off > 0;
        const right = off + win.len < t.len;
        if (!left and !right) return gpa.dupe(u8, win);
        var out: std.ArrayList(u8) = .empty;
        if (left) try out.appendSlice(gpa, "…");
        try out.appendSlice(gpa, win);
        if (right) try out.appendSlice(gpa, "…");
        return out.toOwnedSlice(gpa);
    }
    return gpa.dupe(u8, "");
}

fn snippetOf(gpa: std.mem.Allocator, io: std.Io, source: Source, id: u32, line: u32, re: *const Regex) ![]u8 {
    return switch (source) {
        .memory => |files| snippetFrom(gpa, files[id].bytes, line, re),
        .disk => |paths| blk: {
            const data = Dir.cwd().readFileAlloc(io, paths[id], gpa, .limited(corpus_mod.per_file_cap)) catch return gpa.dupe(u8, "");
            defer gpa.free(data);
            break :blk snippetFrom(gpa, data, line, re);
        },
    };
}

fn emitRanked(gpa: std.mem.Allocator, io: std.Io, re: *const Regex, docs: []const Doc, source: Source, k: usize) !usize {
    const order = try rank_mod.rank(gpa, docs, .{}, null);
    defer gpa.free(order);
    const top = @min(order.len, if (k == 0) 20 else k);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    for (order[0..top], 0..) |di, i| {
        const doc = docs[di];
        const path = source.path(doc.id);
        const snip = try snippetOf(gpa, io, source, doc.id, doc.best_line, re);
        defer gpa.free(snip);
        const kind = if (doc.is_mirror) "mirror" else if (doc.is_generated) "gen" else if (doc.is_def) "def" else "use";
        try buf.print(gpa, "{d:>2}. {s}:{d}  [{s}]  ×{d}  {s}", .{ i + 1, path, doc.best_line, kind, doc.matches, snip });
        if (doc.is_mirror) {
            if (mirror.canonical(Doc, docs, doc)) |canonical| try buf.print(gpa, "  (mirror of {s})", .{source.path(canonical)});
        }
        try buf.append(gpa, '\n');
    }
    corpus_mod.emitStdout(buf.items);
    return top;
}

/// Fresh-process ranked query: cold-load the index, resolve + read candidates
/// for the compiled regex (optionally scoped to PATH roots), extract per-file
/// features, fuse via the RRF kernel, print the top-K as token-compressed
/// `path:line` + surfaced line. `k` caps the surfaced rows (`--rank[=N]`,
/// default 20). Returns null when no complete index is available so the caller
/// can live-rank; otherwise the ranked-match count (0 ⇒ the caller may hint).
/// `caseless` disables the trigram prefilter.
pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    re: *const Regex,
    roots: []const []const u8,
    k: usize,
    caseless: bool,
) !?usize {
    const l0 = nowNs(io);
    var p = (persist.loadQuiet(gpa, io) catch null) orelse return null;
    defer p.deinit();
    const load_ns = nowNs(io) - l0;

    const q0 = nowNs(io);
    var one: [1][]const u8 = undefined;
    const filters = rankFilters(re, caseless, &one);
    var cand = try fresh.candidates(gpa, io, &p.idx, &p.paths, filters, &corpus_mod.default_roots);
    defer cand.deinit();

    // PATH roots gate before the read — without this, `gist pat dir/ --rank`
    // ranks the whole indexed corpus (the bug that flooded agents with
    // out-of-scope hits, or hid in-scope ones behind an empty top-K).
    var scoped: std.ArrayList(u32) = .empty;
    defer scoped.deinit(gpa);
    if (roots.len == 0) {
        try scoped.appendSlice(gpa, cand.ids);
    } else {
        try scoped.ensureTotalCapacity(gpa, cand.ids.len);
        for (cand.ids) |d| {
            if (d >= p.paths.items.len) continue;
            if (underAnyRoot(p.paths.items[d], roots)) scoped.appendAssumeCapacity(d);
        }
    }

    var docs: std.ArrayList(Doc) = .empty;
    defer docs.deinit(gpa);
    var read_files: usize = 0;
    try parallelRank(gpa, p.paths.items, scoped.items, re, &docs, &read_files);

    // The fusion: lexical density + symbol(def) boost + shallow-path + authored
    // (codegen demotion), RRF-fused. null is the external graph-centrality hook.
    const query_ns = nowNs(io) - q0;
    const top = try emitRanked(gpa, io, re, docs.items, .{ .disk = p.paths.items }, k);
    std.debug.print("gist: {d} ranked matches (top {d}) · read {d}/{d} candidates · cold-load {d:.1} ms · rank {d:.1} ms · total {d:.1} ms\n", .{
        docs.items.len, top, read_files, p.paths.items.len, ms(load_ns), ms(query_ns), ms(load_ns + query_ns),
    });
    return docs.items.len;
}

/// Rank bytes already gathered by the rg-compatible live walk. Returns the
/// ranked-match count (0 ⇒ the caller may hint).
pub fn runLive(gpa: std.mem.Allocator, io: std.Io, re: *const Regex, files: []const LiveFile, k: usize) !usize {
    const q0 = nowNs(io);
    var docs: std.ArrayList(Doc) = .empty;
    defer docs.deinit(gpa);
    var sim = try Regex.Sim.init(gpa, re);
    defer sim.deinit();
    for (files, 0..) |file, id| {
        if (fileDoc(file.bytes, file.path, re, &sim, @intCast(id))) |doc| try docs.append(gpa, doc);
    }
    const top = try emitRanked(gpa, io, re, docs.items, .{ .memory = files }, k);
    const query_ns = nowNs(io) - q0;
    std.debug.print("gist: {d} ranked matches (top {d}) · live-scanned {d} files · rank {d:.1} ms\n", .{
        docs.items.len, top, files.len, ms(query_ns),
    });
    return docs.items.len;
}

test "underAnyRoot gates directory prefixes and exact files" {
    const t = std.testing;
    try t.expect(underAnyRoot("services/ai/x.py", &.{"services/ai"}));
    try t.expect(underAnyRoot("services/ai", &.{"services/ai"}));
    try t.expect(underAnyRoot("services/ai/x.py", &.{"./services/ai/"}));
    try t.expect(!underAnyRoot("services/ai_old/x.py", &.{"services/ai"}));
    try t.expect(!underAnyRoot("services/backend/x.go", &.{"services/ai"}));
    try t.expect(underAnyRoot("services/ai/x.py", &.{ "services/backend", "services/ai" }));
    try t.expect(!underAnyRoot("pkg/kernels/irregex/x.zig", &.{ "services/ai", "services/backend" }));
    try t.expect(underAnyRoot("anywhere.go", &.{}));
}

test "fileDoc matches alternation and wildcard regexes, not raw pattern bytes" {
    const t = std.testing;
    const a = t.allocator;

    // The bug: treating `FOO|BAR` as a literal meant zero hits unless a file
    // contained the characters `FOO|BAR`. Ranking must use the compiled engine.
    var re_alt = try Regex.compile(a, "FOO_CLAIM|BAR_CLAIM");
    defer re_alt.deinit();
    var sim_alt = try Regex.Sim.init(a, &re_alt);
    defer sim_alt.deinit();
    const hay_alt =
        \\const x = 1;
        \\fn BAR_CLAIM() void {}
        \\use FOO_CLAIM here
    ;
    const doc_alt = fileDoc(hay_alt, "src/claim.zig", &re_alt, &sim_alt, 7) orelse {
        try t.expect(false); // must match both branches
        return;
    };
    try t.expectEqual(@as(u32, 2), doc_alt.matches);
    try t.expect(doc_alt.is_def);
    try t.expectEqual(@as(u32, 2), doc_alt.best_line);

    var re_wild = try Regex.compile(a, "claim.*job");
    defer re_wild.deinit();
    var sim_wild = try Regex.Sim.init(a, &re_wild);
    defer sim_wild.deinit();
    const hay_wild =
        \\// claim the job via SET NX
        \\const other = 1;
    ;
    const doc_wild = fileDoc(hay_wild, "queue.py", &re_wild, &sim_wild, 3) orelse {
        try t.expect(false); // must match claim…job span
        return;
    };
    try t.expectEqual(@as(u32, 1), doc_wild.matches);
    try t.expectEqual(@as(u32, 1), doc_wild.best_line);

    // No claim…job span at all ⇒ not a match (the old literal path would also
    // miss this; the point is the engine doesn't false-positive on noise).
    try t.expect(fileDoc("no relevant tokens here", "doc.md", &re_wild, &sim_wild, 1) == null);
}

test "rankFilters prefers required literal then alternation cover" {
    const t = std.testing;
    const a = t.allocator;
    var one: [1][]const u8 = undefined;

    var re_lit = try Regex.compile(a, "JOBS_PG_CLAIM");
    defer re_lit.deinit();
    const f_lit = rankFilters(&re_lit, false, &one);
    try t.expectEqual(@as(usize, 1), f_lit.len);
    try t.expectEqualStrings("JOBS_PG_CLAIM", f_lit[0]);

    var re_alt = try Regex.compile(a, "jobs_pg_claim|JOBS_PG_CLAIM");
    defer re_alt.deinit();
    const f_alt = rankFilters(&re_alt, false, &one);
    // No single required ≥3 spanning both branches ⇒ cover set.
    try t.expect(f_alt.len >= 1);
    try t.expectEqual(@as(usize, 0), rankFilters(&re_alt, true, &one).len); // caseless ⇒ no prefilter
}

test "windowAround keeps a late match token inside the budget" {
    const t = std.testing;
    // The bug: a leading 120-byte slice dropped any hit past column 120, so
    // `--rank` printed a line of filler with the matched token gone.
    const pad = "x" ** 130;
    const line = pad ++ "UniqueMangleTokenXYZ" ++ ("y" ** 20);
    const sp = Regex.Span{ .start = 130, .end = 130 + "UniqueMangleTokenXYZ".len };
    const win = windowAround(line, sp, snippet_budget);
    try t.expect(win.len <= snippet_budget);
    try t.expect(std.mem.indexOf(u8, win, "UniqueMangleTokenXYZ") != null);
    // No span ⇒ prefix fallback (legacy behaviour for non-matching lines).
    try t.expectEqualStrings(line[0..snippet_budget], windowAround(line, null, snippet_budget));
    // Short lines pass through untouched.
    try t.expectEqualStrings("short", windowAround("short", sp, snippet_budget));
}
