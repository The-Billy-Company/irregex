//! gist line-emitting grep — the `path:line:content` output an agent actually
//! consumes, the one mode `query`/`regex`/`rank` never gave it.
//!
//! WHY THIS IS THE KEYSTONE FOR REPLACING ripgrep IN AN AGENT LOOP: `query` and
//! `regex` answer "which FILES match" (a path set), and `rank` answers "which is
//! the ONE best line" (top-K, one line/file). Neither is what an agent reaches
//! for 90% of the time — it runs `rg -n <pat>` and reads *every* matching line
//! with its line number, in place, to reason about the code. Emitting paths
//! alone forces the agent to re-open and re-scan each file, the exact
//! read-amplification gist exists to kill. So this module makes gist a true
//! `rg -n --no-heading` drop-in: same `path:line:text` rows, byte-faithful, but
//! served from the persisted trigram index (read only candidate files) instead
//! of a whole-tree walk.
//!
//! It UNIFIES literal + regex on one engine: every pattern compiles to a `Regex`
//! (a pure literal like `WalletService` has itself as its required literal, so it
//! rides the *same* trigram prefilter the dedicated literal path uses — no
//! second code path, no correctness gap). `-i` ASCII-folds the pattern's classes
//! (`Regex.compileOpts`); a folded literal is no longer a singleton class, so the
//! required literal is "" and the query soundly falls back to the seed-all scan
//! (trigrams are case-sensitive — a case-insensitive needle can't prefilter).
//!
//! The agent-grade flag surface mirrors the ripgrep an agent already types:
//!   • `-A/-B/-C N` context lines (rg-exact `:`/`-`/`--` framing) — read the code
//!     around a hit without a second round-trip, the #1 affordance after `-n`.
//!   • `-t <lang>` / `-g <glob>` path scoping (`pathfilter.zig`) — confine to one
//!     language or subtree. Unlike rg (which filters while walking the tree),
//!     gist prunes candidate ids *before* reading, so scoping makes it faster.
//!   • `-w` word boundary, `-F` fixed-string (regex metachars escaped), `-l`
//!     files-with-matches, `-c` per-file count, `-v` invert, `-m N` per-file cap.
//! Unknown flags FAIL LOUD (a silent empty result is the worst agent failure);
//! `--` ends flag parsing and `-e <pat>` gives an explicit pattern.
//!
//! Candidate resolution + freshness reuse the persisted index path verbatim
//! (`cli.loadPersisted` + `fresh.candidates`), so read-your-own-writes and the
//! zero-false-negative guarantee hold here exactly as they do for `query`.

const std = @import("std");
const gist = @import("gist");
const corpus_mod = @import("corpus.zig");
const fresh = @import("fresh.zig");
const cli = @import("cli.zig");
const grepargs = @import("grepargs.zig");
const Regex = gist.regex.Regex;

// The argv parser + its result types live in `grepargs.zig` (the ripgrep-
// compatible flag surface); re-exported here so `runGrep`'s callers and the
// tests keep addressing them through `lines`.
pub const Options = grepargs.Options;
pub const Parsed = grepargs.Parsed;
pub const parseGrep = grepargs.parseGrep;

fn nowNs(io: std.Io) i128 {
    return std.Io.Clock.now(.awake, io).nanoseconds;
}
fn ms(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

/// Escape every regex metachar in `pat` so the engine matches it literally
/// (`-F`). Backslash-escapes the RE2 metaset gist's parser recognizes.
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

/// The pattern actually compiled, after `-F` (escape) and `-w` (wrap `\b(…)\b`).
/// gpa-owned iff it differs from the input; the caller frees via `freePattern`.
fn effectivePattern(gpa: std.mem.Allocator, pat: []const u8, opts: Options) !struct { s: []const u8, owned: bool } {
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
/// overhead isn't worth it and the shard runs inline (same tuning as cli.zig).
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
/// `-o`/--only-matching: emit each non-overlapping match's TEXT alone (not the
/// whole line), one row per match `path:line:text`, exactly as ripgrep does.
/// Leftmost-first spans come from the Pike VM (`matchSpan`); after a match at
/// `[s,e)` the next search resumes at `e` (non-overlapping), and a zero-width
/// match advances one byte so a nullable pattern can't loop. Returns the row count.
/// Expand a `-r` template's whole-match references into `body` against the
/// matched text `m`: `$0` / `${0}` / `$&` → `m`, `$$` → a literal `$`, everything
/// else verbatim. The parser (`grepargs.validReplaceTemplate`) has already
/// rejected any capture-group ref gist's span engine can't honor, so only these
/// forms reach here — this stays a pure, allocation-free byte copy.
fn appendReplacement(gpa: std.mem.Allocator, body: *std.ArrayList(u8), tmpl: []const u8, m: []const u8) !void {
    var i: usize = 0;
    while (i < tmpl.len) : (i += 1) {
        if (tmpl[i] != '$') {
            try body.append(gpa, tmpl[i]);
            continue;
        }
        if (i + 1 >= tmpl.len) {
            try body.append(gpa, '$');
            break;
        }
        switch (tmpl[i + 1]) {
            '$' => {
                try body.append(gpa, '$');
                i += 1;
            },
            '&', '0' => {
                try body.appendSlice(gpa, m);
                i += 1;
            },
            '{' => { // `${0}` — the only braced form the parser admits
                try body.appendSlice(gpa, m);
                i = std.mem.indexOfScalarPos(u8, tmpl, i + 2, '}').?;
            },
            else => try body.append(gpa, '$'), // unreachable given validation
        }
    }
}

/// Append `line`, with each non-overlapping match rewritten by the `-r` template
/// (`sh.opts.replace`). Mirrors rg's line-mode `--replace`: text between matches
/// is copied verbatim, a zero-width match is stepped over (never rewritten), and
/// the tail after the last match is copied. Used only when a replacement is set.
fn appendReplacedLine(sh: *Shard, ssim: *Regex.SpanSim, line: []const u8, body: *std.ArrayList(u8)) !void {
    const tmpl = sh.opts.replace.?;
    var from: usize = 0;
    var cursor: usize = 0;
    while (from <= line.len) {
        const span = sh.re.matchSpan(ssim, line, from) orelse break;
        if (span.end == span.start) {
            from = span.start + 1;
            continue;
        }
        try body.appendSlice(sh.gpa, line[cursor..span.start]);
        try appendReplacement(sh.gpa, body, tmpl, line[span.start..span.end]);
        cursor = span.end;
        from = span.end;
    }
    try body.appendSlice(sh.gpa, line[cursor..]);
}

fn emitOnlyMatching(sh: *Shard, path: []const u8, lines: []const []const u8, body: *std.ArrayList(u8)) !usize {
    var ssim = Regex.SpanSim.init(sh.gpa, sh.re) catch return 0;
    defer ssim.deinit();
    var emitted: usize = 0;
    for (lines, 0..) |line, idx| {
        var from: usize = 0;
        while (from <= line.len) {
            const span = sh.re.matchSpan(&ssim, line, from) orelse break;
            if (span.end == span.start) { // zero-width: don't emit, step past to avoid a loop
                from = span.start + 1;
                continue;
            }
            const text = line[span.start..span.end];
            if (sh.opts.no_line_num)
                try body.print(sh.gpa, "{s}:", .{path})
            else
                try body.print(sh.gpa, "{s}:{d}:", .{ path, idx + 1 });
            // `-o -r <tmpl>`: emit the rewritten match, not the raw span (rg parity).
            if (sh.opts.replace) |t| try appendReplacement(sh.gpa, body, t, text) else try body.appendSlice(sh.gpa, text);
            try body.append(sh.gpa, '\n');
            emitted += 1;
            if (sh.opts.max_per_file != 0 and emitted >= sh.opts.max_per_file) return emitted;
            from = span.end;
        }
    }
    return emitted;
}

fn emitFileLines(sh: *Shard, path: []const u8, lines: []const []const u8, body: *std.ArrayList(u8)) !usize {
    const opts = sh.opts;
    if (opts.only_matching and !opts.invert) return emitOnlyMatching(sh, path, lines, body);
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
    // nothing. A match line is emitted through `appendReplacedLine`; context and
    // non-match lines are always copied verbatim (rg only rewrites match lines).
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
                if (opts.wantsContext()) try body.appendSlice(sh.gpa, "--\n"); // gap ⇒ new group
            } else if (hi <= pe) {
                continue; // fully inside the previous window — already emitted
            } else start = pe + 1; // contiguous/overlapping ⇒ extend the group
        }
        var k = start;
        while (k <= hi) : (k += 1) {
            const sep: u8 = if (is_match[k]) ':' else '-';
            if (opts.no_line_num) // `-N`: drop the line column → `path:text`
                try body.print(sh.gpa, "{s}{c}", .{ path, sep })
            else
                try body.print(sh.gpa, "{s}{c}{d}{c}", .{ path, sep, k + 1, sep });
            if (is_match[k]) {
                if (rssim) |*s| try appendReplacedLine(sh, s, lines[k], body) else try body.appendSlice(sh.gpa, lines[k]);
            } else try body.appendSlice(sh.gpa, lines[k]); // context lines never rewritten
            try body.append(sh.gpa, '\n');
        }
        prev_end = hi;
    }
    return match_idx.items.len;
}

/// Read each candidate file (blocking posix — the proven-fast cold-read idiom),
/// then walk its lines. `-l`/`-c` short-circuit to a path / count row; otherwise
/// `emitFileLines` produces the `path:line:text` (+ context) block. Binary files
/// (a NUL in the first 8 KiB) are skipped, matching the indexer's own filter.
fn grepShard(sh: *Shard) void {
    const scratch = sh.gpa.alloc(u8, corpus_mod.per_file_cap) catch return;
    defer sh.gpa.free(scratch);
    var lines_buf: std.ArrayList([]const u8) = .empty;
    defer lines_buf.deinit(sh.gpa);
    var sim_files = Regex.Sim.init(sh.gpa, sh.re) catch return; // for -l/-c fast path
    defer sim_files.deinit();
    // `--count-matches` counts individual match SPANS (not matching lines), so it
    // needs the span engine, not `lineMatch`. Init once per shard, reused across
    // files; only paid when the flag is set (the common path allocates nothing).
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

        // `--count-matches`: count individual (non-overlapping, leftmost-first)
        // match spans, not matching lines — the semantic `-c`/`--count` can't
        // express. Invert (`-v`) has no per-line span to count, so rg falls back
        // to counting non-matching *lines* there; we do the same via the `-c`
        // path below (count_matches+invert ⇒ line semantics).
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
            body.print(sh.gpa, "{s}:{d}\n", .{ path, total }) catch {};
            sh.lines += total;
            sh.out.append(sh.gpa, .{ .path = path, .body = body }) catch body.deinit(sh.gpa);
            continue;
        }

        // `-l` / `-c` (and `--count-matches -v`): no line bodies, so count
        // matching lines (or stop at the first).
        if (sh.opts.files_only or sh.opts.count_only or sh.opts.count_matches) {
            var hits: usize = 0;
            for (lines_buf.items) |line| {
                if (sh.re.lineMatch(&sim_files, line) == sh.opts.invert) continue;
                hits += 1;
                if (sh.opts.files_only) break; // presence is enough
            }
            if (hits == 0) continue;
            var body: std.ArrayList(u8) = .empty;
            if (sh.opts.count_only or sh.opts.count_matches)
                body.print(sh.gpa, "{s}:{d}\n", .{ path, hits }) catch {}
            else
                body.print(sh.gpa, "{s}\n", .{path}) catch {};
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

/// Fresh-process grep: cold-load the index, prefilter on the pattern's required
/// literal (or alternation cover, or — for `-i`/`-v`/no usable literal — seed
/// every doc), prune candidates by the `-t`/`-g` path filter (before any read),
/// then emit `path:line:text` for every matching line, grouped & sorted by path.
/// This is the agent's `rg -n --no-heading`, served from the index.
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
    var p = (try cli.loadPersisted(gpa, io)) orelse return;
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
        try buf.appendSlice(gpa, path);
        try buf.append(gpa, '\n');
    }
    corpus_mod.emitStdout(buf.items); // file paths → stdout (rg convention)
    std.debug.print("— {d} files · 0 reads (in-memory index projection) · cold-load {d:.1} ms · list {d:.1} ms · total {d:.1} ms\n", .{
        out.items.len, ms(load_ns), ms(query_ns), ms(load_ns + query_ns),
    });
}

fn cmpPaths(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

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
    var p = (try cli.loadPersisted(gpa, io)) orelse return;
    defer p.deinit();
    const load_ns = nowNs(io) - l0;

    const q0 = nowNs(io);
    // Prefilter set: the single mandatory literal (≥3 B), else the alternation
    // cover, else empty ⇒ seed every doc. `-i` zeroes both (folded literals are
    // not singletons); `-v` (invert) can match in files lacking the literal, so
    // it too must seed all. Both correctly land on the seed-all scan.
    var one = [_][]const u8{re.required};
    const filters: []const []const u8 = if (opts.invert) &.{} else if (re.required.len >= 3) one[0..] else re.alts;
    var cand = try fresh.candidates(gpa, io, &p.idx, &p.paths, filters, &corpus_mod.default_roots);
    defer cand.deinit();

    // Path scope (`-t`/`-g`): prune candidate ids BEFORE reading — gist's edge
    // over rg, which can only filter while walking. A no-op filter is free.
    const scoped = opts.filter.prune(p.paths.items, cand.ids);

    var blocks: std.ArrayList(FileBlock) = .empty;
    defer {
        for (blocks.items) |*b| b.body.deinit(gpa);
        blocks.deinit(gpa);
    }
    var reads: usize = 0;
    var lines: usize = 0;
    try runShards(gpa, p.paths.items, scoped, &re, opts, &blocks, &reads, &lines);
    std.mem.sort(FileBlock, blocks.items, {}, cmpBlocks);
    const query_ns = nowNs(io) - q0;

    // With context on, every group (including across files) is `--`-separated,
    // matching rg's `--no-heading -C` framing; otherwise bodies concatenate. The
    // separator is line-body-only — `-l`/`-c` rows are never `--`-joined.
    const join_groups = opts.wantsContext() and !opts.files_only and !opts.count_only;
    var outbuf: std.ArrayList(u8) = .empty;
    defer outbuf.deinit(gpa);
    for (blocks.items, 0..) |b, bi| {
        if (join_groups and bi > 0) try outbuf.appendSlice(gpa, "--\n");
        try outbuf.appendSlice(gpa, b.body.items);
    }
    corpus_mod.emitStdout(outbuf.items); // `path:line:text` rows → stdout (rg convention)

    std.debug.print("— {d} matching lines in {d} files · read {d}/{d} candidates · cold-load {d:.1} ms · grep {d:.1} ms · total {d:.1} ms\n", .{
        lines, blocks.items.len, reads, p.paths.items.len, ms(load_ns), ms(query_ns), ms(load_ns + query_ns),
    });
}
