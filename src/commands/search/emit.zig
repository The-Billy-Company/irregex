//! gist search — the line-emitting engine: the `path:line:text` output an agent
//! actually consumes (the default `--show lines`, plus `--show files`/`count`
//! with flags, `--files`, and `--json`).
//!
//! WHY THIS IS THE KEYSTONE FOR REPLACING ripgrep IN AN AGENT LOOP: `--show
//! files` answers "which FILES match" (a path set) and `--show ranked` answers
//! "which is the ONE best line" (top-K), but neither is what an agent reaches for
//! 90% of the time — it runs `rg -n <pat>` and reads *every* matching line with
//! its line number, in place, to reason about the code. Emitting paths alone
//! forces the agent to re-open and re-scan each file, the exact read-amplification
//! gist exists to kill. So this engine makes `gist search` a true `rg -n
//! --no-heading` drop-in: same `path:line:text` rows, byte-faithful, served from
//! the persisted trigram index (read only candidate files) instead of a
//! whole-tree walk.
//!
//! It UNIFIES literal + regex on one engine: every pattern compiles to a `Regex`
//! (a pure literal like `WalletService` has itself as its required literal, so it
//! rides the *same* trigram prefilter — no second code path, no correctness gap).
//! `--ignore-case` ASCII-folds the pattern's classes (`Regex.compileOpts`); a
//! folded literal is no longer a singleton class, so the required literal is ""
//! and the query soundly falls back to the seed-all scan (trigrams are
//! case-sensitive — a case-insensitive needle can't prefilter).
//!
//! The span-rewrite (`-o`/`-r`) and `--json` record shaping live in the sibling
//! `render.zig`; this file is the candidate-read + line-walk + framing loop.
//! Candidate resolution + freshness reuse the persisted index path verbatim
//! (`persist.load` + `fresh.candidates`), so read-your-own-writes and the
//! zero-false-negative guarantee hold here exactly as they do for `--show files`.

const std = @import("std");
const corpus_mod = @import("../../corpus/corpus.zig");
const fresh = @import("../../corpus/fresh.zig");
const persist = @import("../../index/persist.zig");
const args = @import("args.zig");
const render = @import("render.zig");
const Regex = @import("../../regex/core.zig").Regex;

// The argv parser + its result types live in the sibling `args.zig`; re-exported
// here so the run dispatcher and the tests keep addressing them through search.
pub const Options = args.Options;
pub const Parsed = args.Parsed;

fn nowNs(io: std.Io) i128 {
    return std.Io.Clock.now(.awake, io).nanoseconds;
}
fn ms(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

/// Escape every regex metachar in `pat` so the engine matches it literally
/// (`--fixed`). Backslash-escapes the RE2 metaset gist's parser recognizes.
fn escapeLiteral(gpa: std.mem.Allocator, pat: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (pat) |c| {
        switch (c) {
            '.', '^', '$', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '\\' => try out.append(gpa, '\\'),
            else => {},
        }
        try out.append(gpa, c);
    }
    return out.toOwnedSlice(gpa);
}

/// The pattern actually compiled, after `--fixed` (escape) and `--word` (wrap
/// `\b(…)\b`). gpa-owned iff it differs from the input; caller frees when `owned`.
/// `pub` so the sibling `live.zig` compiles the same effective pattern the
/// indexed path does (one definition of what `--fixed`/`--word` mean).
pub fn effectivePattern(gpa: std.mem.Allocator, pat: []const u8, opts: Options) !struct { s: []const u8, owned: bool } {
    var base: []const u8 = pat;
    var base_owned = false;
    if (opts.fixed) {
        base = try escapeLiteral(gpa, pat);
        base_owned = true;
    }
    if (opts.word) {
        defer if (base_owned) gpa.free(base);
        const wrapped = try std.fmt.allocPrint(gpa, "\\b({s})\\b", .{base});
        return .{ .s = wrapped, .owned = true };
    }
    return .{ .s = base, .owned = base_owned };
}

// ─────────────────────────── match + emit ───────────────────────────

/// One file's matching rows, pre-formatted (`path:line:text\n…`, plus context
/// `path-line-text` and internal `--` group separators when context is on).
/// `path` aliases the persisted paths list (alive for the whole call); `body`
/// is gpa-owned.
const FileBlock = struct {
    path: []const u8,
    body: std.ArrayList(u8),
};

fn cmpBlocks(_: void, a: FileBlock, b: FileBlock) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

/// Spawn one shard per core above this candidate count; below it the spawn
/// overhead isn't worth it and the shard runs inline (same tuning as the CLI).
const par_threshold = 64;

const Shard = struct {
    gpa: std.mem.Allocator,
    paths: []const []const u8,
    ids: []const u32,
    re: *const Regex,
    opts: Options,
    out: std.ArrayList(FileBlock) = .empty,
    reads: usize = 0,
    lines: usize = 0,
};

/// Split a buffer into display lines with rg's `\n`-terminates semantics: a
/// trailing newline does NOT yield a phantom empty final line (so `$`/`^$`
/// match exactly as rg does), but content after the last `\n` (no terminator)
/// is still a line. A trailing `\r` is trimmed for CRLF display parity.
fn collectLines(gpa: std.mem.Allocator, buf: []const u8, out: *std.ArrayList([]const u8)) !void {
    var rest = buf;
    while (true) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const end = nl orelse rest.len;
        if (nl != null or end > 0) {
            const raw = rest[0..end];
            const line = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
            try out.append(gpa, line);
        }
        if (nl == null) break;
        rest = rest[end + 1 ..];
    }
}

/// Emit one file's matching lines into `body`, honoring context windows and the
/// per-file cap. Returns the number of match lines emitted (0 ⇒ caller drops the
/// file). Context windows around successive matches are merged when they touch
/// or overlap; disjoint groups are separated by a `--` line (rg's framing).
/// Under `--json` every row is a `{path,line,kind,text}` record instead.
fn emitFileLines(sh: *Shard, path: []const u8, lines: []const []const u8, body: *std.ArrayList(u8)) !usize {
    const opts = sh.opts;
    if (opts.only_matching and !opts.invert)
        return render.emitOnlyMatching(sh.gpa, sh.re, opts, path, lines, body);
    // Pass 1: which line indices match (respecting -v), capped per file.
    var match_idx: std.ArrayList(usize) = .empty;
    defer match_idx.deinit(sh.gpa);
    var sim = Regex.Sim.init(sh.gpa, sh.re) catch return 0;
    defer sim.deinit();
    for (lines, 0..) |line, idx| {
        const hit = sh.re.lineMatch(&sim, line);
        if (hit == opts.invert) continue; // -v flips the desired verdict
        try match_idx.append(sh.gpa, idx);
        if (opts.max_per_file != 0 and match_idx.items.len >= opts.max_per_file) break;
    }
    if (match_idx.items.len == 0) return 0;

    // A match-line lookup so a hit that falls inside a *neighboring* match's
    // context window is still framed `:` (a match), never `-` (context) — the
    // label depends on the whole match set, not just the group's anchor.
    const is_match = try sh.gpa.alloc(bool, lines.len);
    defer sh.gpa.free(is_match);
    @memset(is_match, false);
    for (match_idx.items) |m| is_match[m] = true;

    // `-r` (line mode): a per-thread span scratch to rewrite matches in place.
    // Only initialized when a replacement is set (rare), so the common path pays
    // nothing. A match line is emitted through `render.appendReplacedLine`;
    // context/non-match lines are copied verbatim (rg only rewrites match lines).
    var rssim: ?Regex.SpanSim = if (opts.replace != null) (Regex.SpanSim.init(sh.gpa, sh.re) catch null) else null;
    defer if (rssim) |*s| s.deinit();

    // Pass 2: expand to context windows, merge, emit with `:`/`-`/`--` framing.
    const B = opts.before;
    const A = opts.after;
    var prev_end: ?usize = null; // last emitted line index (for merge + `--`)
    for (match_idx.items) |m| {
        const lo = if (m >= B) m - B else 0;
        const hi = @min(m + A, lines.len - 1);
        var start = lo;
        if (prev_end) |pe| {
            if (lo > pe + 1) {
                if (opts.wantsContext() and !opts.json) try body.appendSlice(sh.gpa, "--\n"); // gap ⇒ new group
            } else if (hi <= pe) {
                continue; // fully inside the previous window — already emitted
            } else start = pe + 1; // contiguous/overlapping ⇒ extend the group
        }
        var k = start;
        while (k <= hi) : (k += 1) {
            if (opts.json) {
                if (is_match[k] and rssim != null) {
                    var tmp: std.ArrayList(u8) = .empty;
                    defer tmp.deinit(sh.gpa);
                    try render.appendReplacedLine(sh.gpa, sh.re, &rssim.?, opts.replace.?, lines[k], &tmp);
                    try render.jsonLineRow(sh.gpa, body, path, k + 1, true, tmp.items);
                } else try render.jsonLineRow(sh.gpa, body, path, k + 1, is_match[k], lines[k]);
                continue;
            }
            const sep: u8 = if (is_match[k]) ':' else '-';
            if (opts.no_line_num) // `-N`: drop the line column → `path:text`
                try body.print(sh.gpa, "{s}{c}", .{ path, sep })
            else
                try body.print(sh.gpa, "{s}{c}{d}{c}", .{ path, sep, k + 1, sep });
            if (is_match[k]) {
                if (rssim) |*s| try render.appendReplacedLine(sh.gpa, sh.re, s, opts.replace.?, lines[k], body) else try body.appendSlice(sh.gpa, lines[k]);
            } else try body.appendSlice(sh.gpa, lines[k]); // context lines never rewritten
            try body.append(sh.gpa, '\n');
        }
        prev_end = hi;
    }
    return match_idx.items.len;
}

/// Read each candidate file (blocking posix — the proven-fast cold-read idiom),
/// then walk its lines. `--show files`/`count` short-circuit to a path / count
/// row; otherwise `emitFileLines` produces the `path:line:text` (+ context)
/// block. Binary files (a NUL in the first 8 KiB) are skipped, matching the
/// indexer's own filter.
fn grepShard(sh: *Shard) void {
    const scratch = sh.gpa.alloc(u8, corpus_mod.per_file_cap) catch return;
    defer sh.gpa.free(scratch);
    var lines_buf: std.ArrayList([]const u8) = .empty;
    defer lines_buf.deinit(sh.gpa);
    var sim_files = Regex.Sim.init(sh.gpa, sh.re) catch return; // for -l/-c fast path
    defer sim_files.deinit();
    // `--spans`/--count-matches counts individual match SPANS (not matching
    // lines), so it needs the span engine, not `lineMatch`. Init once per shard,
    // reused across files; only paid when set (common path allocates nothing).
    var span_sim: ?Regex.SpanSim = if (sh.opts.count_matches) (Regex.SpanSim.init(sh.gpa, sh.re) catch return) else null;
    defer if (span_sim) |*s| s.deinit();

    for (sh.ids) |d| {
        const path = sh.paths[d];
        const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch continue;
        var n: usize = 0;
        while (n < scratch.len) {
            const r = std.posix.read(fd, scratch[n..]) catch break;
            if (r == 0) break;
            n += r;
        }
        _ = std.posix.system.close(fd);
        sh.reads += 1;
        const buf = scratch[0..n];
        if (n == 0 or corpus_mod.isBinary(buf)) continue;

        lines_buf.clearRetainingCapacity();
        collectLines(sh.gpa, buf, &lines_buf) catch continue;

        // `--spans`: count individual (non-overlapping, leftmost-first) match
        // spans, not matching lines — the semantic `--show count` can't express.
        // Invert (`-v`) has no per-line span to count, so rg falls back to
        // counting non-matching *lines* there; we do the same via the count path
        // below (count_matches+invert ⇒ line semantics).
        if (sh.opts.count_matches and !sh.opts.invert) {
            var total: usize = 0;
            for (lines_buf.items) |line| {
                var from: usize = 0;
                while (from <= line.len) {
                    const span = sh.re.matchSpan(&span_sim.?, line, from) orelse break;
                    if (span.end == span.start) { // zero-width: step past to avoid a loop
                        from = span.start + 1;
                        continue;
                    }
                    total += 1;
                    if (sh.opts.max_per_file != 0 and total >= sh.opts.max_per_file) break;
                    from = span.end;
                }
                if (sh.opts.max_per_file != 0 and total >= sh.opts.max_per_file) break;
            }
            if (total == 0) continue;
            var body: std.ArrayList(u8) = .empty;
            if (sh.opts.json) render.jsonCountRow(sh.gpa, &body, path, total) catch {} else body.print(sh.gpa, "{s}:{d}\n", .{ path, total }) catch {};
            sh.lines += total;
            sh.out.append(sh.gpa, .{ .path = path, .body = body }) catch body.deinit(sh.gpa);
            continue;
        }

        // `--show files` / `--show count` (and `--spans -v`): no line bodies, so
        // count matching lines (or stop at the first).
        if (sh.opts.files_only or sh.opts.count_only or sh.opts.count_matches) {
            var hits: usize = 0;
            for (lines_buf.items) |line| {
                if (sh.re.lineMatch(&sim_files, line) == sh.opts.invert) continue;
                hits += 1;
                if (sh.opts.files_only) break; // presence is enough
            }
            if (hits == 0) continue;
            var body: std.ArrayList(u8) = .empty;
            if (sh.opts.json) {
                if (sh.opts.files_only) render.jsonFileRow(sh.gpa, &body, path) catch {} else render.jsonCountRow(sh.gpa, &body, path, hits) catch {};
            } else if (sh.opts.count_only or sh.opts.count_matches) {
                body.print(sh.gpa, "{s}:{d}\n", .{ path, hits }) catch {};
            } else body.print(sh.gpa, "{s}\n", .{path}) catch {};
            sh.lines += hits;
            sh.out.append(sh.gpa, .{ .path = path, .body = body }) catch body.deinit(sh.gpa);
            continue;
        }

        var body: std.ArrayList(u8) = .empty;
        const hits = emitFileLines(sh, path, lines_buf.items, &body) catch {
            body.deinit(sh.gpa);
            continue;
        };
        if (hits > 0) {
            sh.lines += hits;
            sh.out.append(sh.gpa, .{ .path = path, .body = body }) catch body.deinit(sh.gpa);
        } else body.deinit(sh.gpa);
    }
}

fn runShards(gpa: std.mem.Allocator, paths: []const []const u8, ids: []const u32, re: *const Regex, opts: Options, blocks: *std.ArrayList(FileBlock), reads: *usize, lines: *usize) !void {
    const ncpu = std.Thread.getCpuCount() catch 8;
    const nshards = if (ids.len < par_threshold) 1 else @min(ids.len, ncpu);
    const shards = try gpa.alloc(Shard, nshards);
    defer gpa.free(shards);
    const per = (ids.len + nshards - 1) / nshards;
    var off: usize = 0;
    for (shards) |*sh| {
        const lo = off;
        const hi = @min(off + per, ids.len);
        off = hi;
        sh.* = .{ .gpa = gpa, .paths = paths, .ids = ids[lo..hi], .re = re, .opts = opts };
    }
    if (nshards == 1) {
        grepShard(&shards[0]);
    } else {
        const threads = try gpa.alloc(std.Thread, nshards);
        defer gpa.free(threads);
        for (shards, 0..) |*sh, k| threads[k] = try std.Thread.spawn(.{}, grepShard, .{sh});
        for (threads) |t| t.join();
    }
    for (shards) |*sh| {
        try blocks.appendSlice(gpa, sh.out.items);
        sh.out.deinit(gpa);
        reads.* += sh.reads;
        lines.* += sh.lines;
    }
}

fn cmpPaths(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// `--files`: list every corpus file the path filter admits — WITHOUT reading a
/// single file's bytes. gist already holds the whole path list in the mmap'd
/// index, so file discovery is a pure in-memory filter + sort where rg must walk
/// the entire tree (and, from an uncurated root, can stall on the build/vendor
/// mass gist's corpus policy already excludes). Read-your-own-writes is kept:
/// `fresh.candidates` with an empty filter seeds every indexed doc AND folds in
/// files created/touched since the build (a stat-only walk, no reads), so a file
/// a coworker just wrote still appears. A file *deleted* since the last index
/// rebuild may still be listed (there's no read to verify it away) and self-heals
/// on the next `index` — the same tolerated false-positive the trigram filter has.
pub fn runFilesList(gpa: std.mem.Allocator, io: std.Io, opts: Options) !void {
    const l0 = nowNs(io);
    var p = (try persist.load(gpa, io)) orelse return;
    defer p.deinit();
    const load_ns = nowNs(io) - l0;

    const q0 = nowNs(io);
    // Empty filter ⇒ seed every indexed doc; the freshness overlay appends any
    // file born since the build. No trigram query, no candidate read.
    var cand = try fresh.candidates(gpa, io, &p.idx, &p.paths, &.{}, &corpus_mod.default_roots);
    defer cand.deinit();

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(gpa);
    for (cand.ids) |d| {
        const path = p.paths.items[d];
        if (opts.filter.admits(path)) try out.append(gpa, path);
    }
    std.mem.sort([]const u8, out.items, {}, cmpPaths);
    const query_ns = nowNs(io) - q0;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    for (out.items) |path| {
        if (opts.json) try render.jsonFileRow(gpa, &buf, path) else {
            try buf.appendSlice(gpa, path);
            try buf.append(gpa, '\n');
        }
    }
    corpus_mod.emitStdout(buf.items); // file paths → stdout (rg convention)
    std.debug.print("— {d} files · 0 reads (in-memory index projection) · cold-load {d:.1} ms · list {d:.1} ms · total {d:.1} ms\n", .{
        out.items.len, ms(load_ns), ms(query_ns), ms(load_ns + query_ns),
    });
}

/// Fresh-process line search: cold-load the index, prefilter on the pattern's
/// required literal (or alternation cover, or — for `-i`/`-v`/no usable literal —
/// seed every doc), prune candidates by the `--lang`/`--glob` filter (before any
/// read), then emit `path:line:text` for every matching line, grouped & sorted
/// by path. This is the agent's `rg -n --no-heading`, served from the index.
/// `--show files`/`count` short-circuit to a path / count row per file.
pub fn runGrep(gpa: std.mem.Allocator, io: std.Io, pattern: []const u8, opts: Options) !void {
    if (opts.files_list) return runFilesList(gpa, io, opts);
    const eff = try effectivePattern(gpa, pattern, opts);
    defer if (eff.owned) gpa.free(eff.s);
    var re = Regex.compileOpts(gpa, eff.s, .{ .caseless = opts.caseless }) catch {
        std.debug.print("bad pattern /{s}/ — supported: literals . [] [^] a-z * + ? {{n,m}} | () ^ $ and \\d \\w \\s \\t \\n \\r (see src/regex/syntax.zig)\n", .{pattern});
        return;
    };
    defer re.deinit();

    const l0 = nowNs(io);
    var p = (try persist.load(gpa, io)) orelse return;
    defer p.deinit();

    // Prefilter set: the single mandatory literal (≥3 B), else the alternation
    // cover, else empty ⇒ seed every doc. `-i` zeroes both (folded literals are
    // not singletons); `-v` (invert) can match in files lacking the literal, so
    // it too must seed all. Both correctly land on the seed-all scan.
    var one = [_][]const u8{re.required};
    const filters: []const []const u8 = if (opts.invert) &.{} else if (re.required.len >= 3) one[0..] else re.alts;
    var cand = try fresh.candidates(gpa, io, &p.idx, &p.paths, filters, &corpus_mod.default_roots);
    defer cand.deinit();

    // Path scope (`--lang`/`--glob`): prune candidate ids BEFORE reading — gist's
    // edge over rg, which can only filter while walking. A no-op filter is free.
    const scoped = opts.filter.prune(p.paths.items, cand.ids);
    const pre_ns = nowNs(io) - l0; // cold-load + candidate resolution + prune
    try grepOverPaths(gpa, io, opts, &re, p.paths.items, scoped, p.paths.items.len, pre_ns);
}

/// Run the line engine over an EXPLICIT candidate set (`ids` indexing `paths`)
/// and emit the assembled output + timing summary. This is the shared keystone:
/// the indexed `runGrep` feeds it the trigram-prefiltered + freshness-widened
/// candidates, while the `--live` driver (`live.zig`) feeds it every live-tree
/// path — one line engine, two candidate sources. `pre_ns` is the pre-search
/// cost folded into the summary (the index cold-load, or the live walk).
pub fn grepOverPaths(gpa: std.mem.Allocator, io: std.Io, opts: Options, re: *const Regex, paths: []const []const u8, ids: []u32, total_paths: usize, pre_ns: i128) !void {
    const q0 = nowNs(io);
    var blocks: std.ArrayList(FileBlock) = .empty;
    defer {
        for (blocks.items) |*b| b.body.deinit(gpa);
        blocks.deinit(gpa);
    }
    var reads: usize = 0;
    var lines: usize = 0;
    try runShards(gpa, paths, ids, re, opts, &blocks, &reads, &lines);
    std.mem.sort(FileBlock, blocks.items, {}, cmpBlocks);
    const query_ns = nowNs(io) - q0;

    // With context on, every group (including across files) is `--`-separated,
    // matching rg's `--no-heading -C` framing; otherwise bodies concatenate. The
    // separator is line-body-only — `--show files`/`count` rows are never
    // `--`-joined, and `--json` streams records with no separators.
    const join_groups = opts.wantsContext() and !opts.files_only and !opts.count_only and !opts.json;
    var outbuf: std.ArrayList(u8) = .empty;
    defer outbuf.deinit(gpa);
    for (blocks.items, 0..) |b, bi| {
        if (join_groups and bi > 0) try outbuf.appendSlice(gpa, "--\n");
        try outbuf.appendSlice(gpa, b.body.items);
    }
    corpus_mod.emitStdout(outbuf.items); // `path:line:text` rows → stdout (rg convention)

    std.debug.print("— {d} matching lines in {d} files · read {d}/{d} candidates · pre {d:.1} ms · search {d:.1} ms · total {d:.1} ms\n", .{
        lines, blocks.items.len, reads, total_paths, ms(pre_ns), ms(query_ns), ms(pre_ns + query_ns),
    });
}
