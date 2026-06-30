//! gist cold one-shot CLI — the path that wins the *first* query.
//!
//!   zig build cli -- index            build the index once, persist it to disk
//!   zig build cli -- query <needle>   FRESH process: cold-load the index, then
//!                                     read & verify ONLY the candidate literal
//!   zig build cli -- regex <pattern>  same, but verify with the Thompson NFA
//!                                     (`(?-u)` byte semantics) — prefiltered on
//!                                     the regex's required literal
//!
//! Why this beats ripgrep on a cold/first query: rg has no index, so every
//! invocation must walk the whole tree and read every byte. gist mmaps a
//! persisted trigram index zero-copy (~0.4 ms — the postings alias the mapped
//! pages, faulted in lazily as the binary search probes them, rather than a full
//! read + alloc + memcpy of the 100+ MiB table), resolves the candidate set in
//! RAM, then touches disk for *only the candidate files* — for a selective query
//! that is dozens of small files instead of ~16.5k. Subsequent queries in the
//! same session never rebuild. (A <3-byte needle has no trigram filter, so it
//! degenerates to a full read, like rg — the one case we merely match it.)

const std = @import("std");
const gist = @import("gist");
const corpus_mod = @import("corpus.zig");
const simd = @import("simd.zig");
const fresh = @import("fresh.zig");
const scan = @import("scan.zig");
const signals = @import("signals.zig");
const Index = gist.trigram.Index;
const Regex = gist.regex.Regex;
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
    re: ?*const Regex = null, // null ⇒ literal substring; set ⇒ NFA verify
    out: []u32, // private region (≤ ids.len), no contention
    n: usize = 0,
    reads: usize = 0,
};

fn readVerifyShard(sh: *ReadShard) void {
    const scratch = sh.gpa.alloc(u8, corpus_mod.per_file_cap) catch return;
    defer sh.gpa.free(scratch);
    // A regex shard owns one reusable Pike-sim: the `Regex` is immutable and
    // shared across threads, but the `Sim` scratch is mutable, so it must be
    // per-thread (init once here, reused across this shard's files via gen++).
    var sim: ?Regex.Sim = if (sh.re) |re| (Regex.Sim.init(sh.gpa, re) catch return) else null;
    defer if (sim) |*s| s.deinit();
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
        const hit = if (sh.re) |re| re.docMatch(&sim.?, scratch[0..n]) else simd.contains(scratch[0..n], sh.needle);
        if (hit) {
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

fn parallelRead(gpa: std.mem.Allocator, paths: []const []const u8, ids: []const u32, needle: []const u8, re: ?*const Regex, matches: *std.ArrayList([]const u8), read_files: *usize) !void {
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
        sh.* = .{ .gpa = gpa, .paths = paths, .ids = ids[lo..hi], .needle = needle, .re = re, .out = outbuf[lo..hi] };
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
    // Wall-clock anchor captured BEFORE the read, so any file touched during the
    // build (after its own read) is mtime ≥ anchor ⇒ re-verified next query.
    const built_ns = std.Io.Clock.now(.real, io).nanoseconds;
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
    try fresh.writeAnchor(io, built_ns); // T3 freshness anchor

    std.debug.print("indexed {d} files · {d:.1} MiB corpus · {d:.1} MiB index · {d:.0} ms → {s}\n", .{
        corpus.docs.len,
        @as(f64, @floatFromInt(corpus.bytes)) / (1 << 20),
        @as(f64, @floatFromInt(blob.len)) / (1 << 20),
        ms(nowNs(io) - t0),
        corpus_mod.out_dir,
    });
}

/// A read-only, page-aligned file mapping (zero-copy view of the bytes on disk).
const Mapping = []align(std.heap.page_size_min) const u8;

/// mmap a whole file read-only. The mapping survives the fd close (POSIX), and
/// the OS faults in only the pages actually touched — so "loading" a 100+ MiB
/// index is O(header) instead of a full read-into-heap + alloc + memcpy. This
/// is the cold-load win: the binary search probes a handful of pages (warm in
/// the page cache), not the whole table. A genuinely empty file is rejected
/// (`mmap` can't map zero length, and a 0-byte index is corruption anyway).
fn mmapFile(io: std.Io, path: []const u8) !Mapping {
    const file = try Dir.cwd().openFile(io, path, .{}); // .read_only default
    defer file.close(io);
    const len: usize = @intCast((try file.stat(io)).size);
    if (len == 0) return error.EmptyFile;
    return std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0);
}

/// The cold-loaded index + the doc→path table that maps candidate ids back to
/// files. Both are mmap'd: `idx.postings` aliases into `imap` (borrowed, no
/// copy) and every `paths` slice aliases into `pmap`, so all lifetimes bind to
/// the two mappings and `deinit` simply unmaps them.
pub const Persisted = struct {
    imap: Mapping,
    pmap: Mapping,
    idx: Index,
    paths: std.ArrayList([]const u8),
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Persisted) void {
        self.paths.deinit(self.gpa);
        self.idx.deinit(); // borrowed ⇒ frees nothing
        std.posix.munmap(self.pmap);
        std.posix.munmap(self.imap);
    }
};

/// Cold-load the persisted index + doc→path table by mmap (zero-copy). Returns
/// null (after printing guidance) when no index has been built yet — the one
/// expected miss. Paths are NUL-separated in doc-id order; the list is pre-sized
/// from the NUL count so the split is one allocation.
pub fn loadPersisted(gpa: std.mem.Allocator, io: std.Io) !?Persisted {
    const imap = mmapFile(io, index_file) catch {
        std.debug.print("no index at {s} — run `zig build cli -- index` first\n", .{index_file});
        return null;
    };
    errdefer std.posix.munmap(imap);
    var idx = try Index.fromMappedBytes(imap);
    errdefer idx.deinit();

    const pmap = try mmapFile(io, paths_file);
    errdefer std.posix.munmap(pmap);
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer paths.deinit(gpa);
    try paths.ensureTotalCapacity(gpa, std.mem.count(u8, pmap, &[_]u8{0}) + 1);
    var pit = std.mem.splitScalar(u8, pmap, 0);
    while (pit.next()) |p| if (p.len > 0) paths.appendAssumeCapacity(p);
    return .{ .imap = imap, .pmap = pmap, .idx = idx, .paths = paths, .gpa = gpa };
}

/// Print matching paths (sorted) + the cold timing breakdown — process
/// wall-time is what the cold head-to-head measures.
fn emitMatches(gpa: std.mem.Allocator, matches: *std.ArrayList([]const u8), read_files: usize, total_paths: usize, load_ns: i128, query_ns: i128) !void {
    std.mem.sort([]const u8, matches.items, {}, cmpStrings);
    var outbuf: std.ArrayList(u8) = .empty;
    defer outbuf.deinit(gpa);
    for (matches.items) |p| {
        try outbuf.appendSlice(gpa, p);
        try outbuf.append(gpa, '\n');
    }
    corpus_mod.emitStdout(outbuf.items); // matched paths → stdout (rg convention)
    std.debug.print("— {d} matches · read {d}/{d} candidate files · cold-load {d:.1} ms · query {d:.1} ms · total {d:.1} ms\n", .{
        matches.items.len, read_files, total_paths, ms(load_ns), ms(query_ns), ms(load_ns + query_ns),
    });
}

/// Fresh-process literal query: cold-load the index, then read & verify only the
/// candidate files (exact substring via SIMD `contains`).
pub fn runQuery(gpa: std.mem.Allocator, io: std.Io, needle: []const u8) !void {
    // A <3 B needle has no trigram filter, so the index would seed every doc AND
    // run the corpus-wide freshness stat-walk — two traversals vs rg's one. Skip
    // the index and scan the live tree once (same win as the no-prefilter regex
    // tail; see scan.zig). The live read is inherently fresh.
    if (needle.len < 3) return scan.runLiteralFullScan(gpa, io, needle);

    const l0 = nowNs(io);
    var p = (try loadPersisted(gpa, io)) orelse return;
    defer p.deinit();
    const load_ns = nowNs(io) - l0;

    const q0 = nowNs(io);
    var matches: std.ArrayList([]const u8) = .empty;
    defer matches.deinit(gpa);
    var read_files: usize = 0;

    const filters = [_][]const u8{needle}; // <3 B ⇒ candidates() seeds every doc
    var cand = try fresh.candidates(gpa, io, &p.idx, &p.paths, &filters, &corpus_mod.default_roots);
    defer cand.deinit();
    try parallelRead(gpa, p.paths.items, cand.ids, needle, null, &matches, &read_files);
    const query_ns = nowNs(io) - q0;
    try emitMatches(gpa, &matches, read_files, p.paths.items.len, load_ns, query_ns);
}

/// Fresh-process regex query: cold-load the index, prefilter on the regex's
/// required literal (the substring that must appear in every match — sound, so
/// no true match is dropped) or, for an alternation, the UNION of its branches'
/// cover literals (`foo|bar` ⇒ {foo, bar}); then verify candidates with the
/// Thompson NFA. `(?-u)` byte semantics, exactly the slice the equality oracle
/// proves against `rg`. No usable ≥3-byte cover ⇒ a full scan (like rg).
pub fn runRegex(gpa: std.mem.Allocator, io: std.Io, pattern: []const u8) !void {
    var re = Regex.compile(gpa, pattern) catch {
        std.debug.print("bad pattern /{s}/ — supported: literals . [] [^] a-z * + ? {{n,m}} | () ^ $ and \\d \\w \\s \\t \\n \\r (see src/regex/syntax.zig)\n", .{pattern});
        return;
    };
    defer re.deinit();

    // No usable trigram prefilter (no ≥3 B required literal, no all-≥3 alternation
    // cover) ⇒ every doc is a candidate, so the index filters nothing. Loading it
    // and running the corpus-wide T3 freshness stat-walk is then pure overhead vs
    // rg's single walk; scan the live tree directly (one traversal, inherently
    // fresh — the read IS the freshness guarantee). This is exactly the
    // no-prefilter scan tail that used to tie/trail rg, now a win (see scan.zig).
    if (re.required.len < 3 and re.alts.len == 0)
        return scan.runRegexFullScan(gpa, io, &re);

    const l0 = nowNs(io);
    var p = (try loadPersisted(gpa, io)) orelse return;
    defer p.deinit();
    const load_ns = nowNs(io) - l0;

    const q0 = nowNs(io);
    var matches: std.ArrayList([]const u8) = .empty;
    defer matches.deinit(gpa);
    var read_files: usize = 0;

    // Prefilter set: the single mandatory literal, else the alternation cover
    // set (`foo|bar` ⇒ {foo, bar}), else empty ⇒ full scan — all sound supersets.
    var one = [_][]const u8{re.required};
    const filters: []const []const u8 = if (re.required.len >= 3) one[0..] else re.alts;
    var cand = try fresh.candidates(gpa, io, &p.idx, &p.paths, filters, &corpus_mod.default_roots);
    defer cand.deinit();
    try parallelRead(gpa, p.paths.items, cand.ids, pattern, &re, &matches, &read_files);
    const query_ns = nowNs(io) - q0;
    try emitMatches(gpa, &matches, read_files, p.paths.items.len, load_ns, query_ns);
}

// ─────────────────────────── T4: ranked output ───────────────────────────
//
// `query`/`regex` return an unordered match SET. `rank` turns it into the
// ranked, token-compressed list an agent actually wants — the *definition* of a
// symbol first, its call sites below — via the weighted RRF kernel in
// `src/rank.zig`. Features are extracted per file in a parallel read pass; the
// top-K best lines are then re-read for display.

const Doc = gist.rank.Doc;

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
/// blocking posix reads (same proven pattern as `parallelRead`).
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

/// Fresh-process ranked query: locate candidates, extract per-file features,
/// fuse via the RRF kernel, print the top-K as token-compressed `path:line` +
/// surfaced line. The win rg can't express: a symbol's *definition* outranks its
/// call sites.
pub fn runRank(gpa: std.mem.Allocator, io: std.Io, needle: []const u8) !void {
    if (needle.len == 0) return;
    const l0 = nowNs(io);
    var p = (try loadPersisted(gpa, io)) orelse return;
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
    const order = try gist.rank.rank(gpa, docs.items, .{}, null);
    defer gpa.free(order);
    const query_ns = nowNs(io) - q0;

    const top = @min(order.len, 20);
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
