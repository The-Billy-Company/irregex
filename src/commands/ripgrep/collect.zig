//! gist `rg` — read the walked candidates (in parallel) into a query's file set.
//!
//! Split from `run.zig`: `walk.zig` DISCOVERS candidates single-threaded; this
//! module READS them — across the machine's cores above `par_threshold`, the
//! multi-core walk ripgrep itself runs (`ignore::WalkParallel`) — and applies
//! the type/glob filter, path sort, and `--path-separator`. The persisted
//! trigram index, when it covers the searched roots, is used ONLY to ELIDE
//! reading files the walk already found but that provably can't match
//! (`IndexSkip`) — never to change the file set, ignore semantics, ordering, or
//! output. `collectFiles` is the single public seam the run/`--files` paths call.

const std = @import("std");
const corpus_mod = @import("../../corpus/corpus.zig");
const args = @import("args.zig");
const ignore = @import("ignore.zig");
const grepfile = @import("grepfile.zig");
const walk = @import("walk.zig");
const simd = @import("../../scan/simd.zig");
const persist = @import("../../index/persist.zig");
const fresh = @import("../../corpus/fresh.zig");
const Opts = args.Opts;
const die = args.die;
const Candidate = walk.Candidate;
const Regex = @import("../../regex/core.zig").Regex;

const decodeBom = grepfile.decodeBom;

/// A read file's display path + bytes; `explicit` marks a path named on the argv
/// (searched verbatim, reported as a binary match rather than warned).
pub const InFile = struct { path: []const u8, bytes: []const u8, explicit: bool = false };

/// Replace every `/` in `path` with the (arbitrary-length) `sep` string for
/// `--path-separator`. Returns `path` unchanged when it has no separator.
fn replaceSep(a: std.mem.Allocator, path: []const u8, sep: []const u8) []const u8 {
    if (std.mem.findScalar(u8, path, '/') == null) return path;
    var out: std.ArrayList(u8) = .empty;
    for (path) |c| {
        if (c == '/') out.appendSlice(a, sep) catch die("oom\n", .{}) else out.append(a, c) catch die("oom\n", .{});
    }
    return out.toOwnedSlice(a) catch die("oom\n", .{});
}

// ─────────────────────────── parallel candidate reads ───────────────────────────

/// Spawn one shard per core above this candidate count; below it, thread-spawn
/// overhead isn't worth it and the whole batch runs inline on the calling
/// thread. Mirrors `ripgrep/rank.zig`'s identical `read_par_threshold` tuning
/// for its own parallel candidate-read shards.
const par_threshold = 64;

const ReadShard = struct {
    gpa: std.mem.Allocator,
    // Thread-confined bump allocator for every kept file's byte copy — owned
    // by this shard alone until `readCandidates` has copied `out` into the
    // caller's long-lived arena and tears it down, so parallel shards never
    // contend on `gpa`'s shared allocator machinery for that traffic (the
    // exact reasoning `emit.zig`'s `Shard.arena` documents).
    arena: std.heap.ArenaAllocator,
    candidates: []const Candidate,
    needle: ?[]const u8,
    out: std.ArrayList(InFile) = .empty,
};

/// One candidate's read-and-filter: raw POSIX open/read/close into a reused
/// per-shard scratch buffer — the same proven-fast cold-read idiom
/// `emit.zig`'s `grepShard` already uses for its parallel candidate reads
/// (plain syscalls, no `std.Io` handle to share across threads) — then
/// BOM-decoded, then dropped on the spot when `needle` (see `literalGate`)
/// provably isn't in it: one SIMD `contains` call replaces reading a file all
/// the way to "zero hits" through three more serial passes (binary sniff,
/// line split, per-line match) in the caller's loop. A kept file's bytes are
/// copied into `a` (the shard's arena) so they outlive the next reuse of
/// `scratch`.
///
/// `scratch` is sized to `corpus_mod.per_file_cap` — an indexing-corpus
/// budget, NOT a hard ceiling on what `rg`-compat may search (ripgrep itself
/// has no default max file size; only an explicit `--max-filesize` caps it,
/// applied downstream in `collectFiles`). A file that fills `scratch`
/// completely is ambiguous (exactly cap-sized, or bigger) — `readTail` keeps
/// reading past it into a growable buffer instead of silently truncating.
fn readOneCandidate(a: std.mem.Allocator, scratch: []u8, c: Candidate, needle: ?[]const u8) ?InFile {
    const raw = grepfile.readFileRaw(a, scratch, c.disk) orelse return null;
    const body = decodeBom(a, raw);
    if (needle) |needle_v| if (!simd.contains(body, needle_v)) return null;
    // A tail-read (≥ cap) or UTF-16-transcoded body is already `a`-owned; a
    // body still inside `scratch` must be duped to outlive scratch's next reuse.
    const in_scratch = @intFromPtr(body.ptr) >= @intFromPtr(scratch.ptr) and
        @intFromPtr(body.ptr) < @intFromPtr(scratch.ptr) + scratch.len;
    const owned = if (in_scratch) (a.dupe(u8, body) catch return null) else body;
    return .{ .path = c.rel, .bytes = owned, .explicit = c.explicit };
}

fn readShard(sh: *ReadShard) void {
    const a = sh.arena.allocator();
    const scratch = sh.gpa.alloc(u8, corpus_mod.per_file_cap) catch return;
    defer sh.gpa.free(scratch);
    sh.out.ensureTotalCapacity(sh.gpa, sh.candidates.len) catch die("oom\n", .{});
    for (sh.candidates) |c| {
        if (readOneCandidate(a, scratch, c, sh.needle)) |f| sh.out.appendAssumeCapacity(f);
    }
}

/// Read every discovered candidate — in parallel across the machine's cores
/// above `par_threshold` candidates, the multi-core walk ripgrep itself runs
/// (`ignore::WalkParallel`) — and append the kept `InFile`s (bytes duped into
/// `dest`, the caller's long-lived arena) into `out`. Below the threshold this
/// runs inline: for a handful of files, spawn cost dwarfs the read itself.
fn readCandidates(dest: std.mem.Allocator, gpa: std.mem.Allocator, candidates: []const Candidate, needle: ?[]const u8, out: *std.ArrayList(InFile)) void {
    const ncpu = std.Thread.getCpuCount() catch 8;
    const nshards = if (candidates.len < par_threshold) 1 else @min(candidates.len, ncpu);
    const shards = gpa.alloc(ReadShard, nshards) catch die("oom\n", .{});
    defer gpa.free(shards);
    const per = (candidates.len + nshards - 1) / nshards;
    var off: usize = 0;
    for (shards) |*sh| {
        const lo = off;
        const hi = @min(off + per, candidates.len);
        off = hi;
        sh.* = .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa), .candidates = candidates[lo..hi], .needle = needle };
    }
    if (nshards == 1) {
        readShard(&shards[0]);
    } else {
        const threads = gpa.alloc(std.Thread, nshards) catch die("oom\n", .{});
        defer gpa.free(threads);
        for (shards, 0..) |*sh, k| threads[k] = std.Thread.spawn(.{}, readShard, .{sh}) catch die("thread spawn failed\n", .{});
        for (threads) |t| t.join();
    }
    out.ensureUnusedCapacity(dest, candidates.len) catch die("oom\n", .{});
    for (shards) |*sh| {
        for (sh.out.items) |f| out.appendAssumeCapacity(.{ .path = f.path, .bytes = dest.dupe(u8, f.bytes) catch die("oom\n", .{}), .explicit = f.explicit });
        sh.out.deinit(gpa);
        sh.arena.deinit();
    }
}

/// This invocation's pattern reduces to a plain, case-sensitive, unanchored
/// substring scan when nothing changes what "the file contains it" means:
/// one pattern source (`-e`/`-f` fan-in and `-x`/line_regexp anchoring both
/// route through `combinePatterns` and would already show up as regex syntax
/// below, but a single-source check keeps this independent of that plumbing),
/// no `-w`/`-i` (both broaden what counts as a hit past raw byte containment),
/// no `-v` (inverted mode needs every line INCLUDING files with zero hits).
pub fn literalGate(parsed: args.Parsed) ?[]const u8 {
    const o = parsed.opts;
    // `-w` stays gateable: `\bLIT\b` can only match where LIT occurs, so a
    // file (or line) without the literal bytes is skippable — the boundary
    // check only ever REJECTS occurrences. Inversion flips selection to
    // non-matching lines (a literal-free file still prints), so it can't gate.
    if (o.caseless or o.invert or o.files_without or o.stats or o.json) return null;
    if (parsed.patterns.len != 1 or parsed.pattern_files.len != 0) return null;
    const pattern = parsed.patterns[0];
    if (pattern.len == 0) return null;
    if (o.fixed) return pattern; // -F: escaped for the engine, but these ARE the literal bytes
    if (args.looksLikeRegex(pattern)) return null;
    return pattern;
}

// ─────────────────── index-backed read elision (acceleration) ───────────────────
//
// The persisted trigram index is used ONLY to skip *reading* files the walk
// already discovered but that provably can't match — it never changes the file
// set, the ignore semantics, the ordering, or the output. The live walk stays
// the sole authority on WHAT to search (so every rgsuite parity guarantee holds
// unchanged); the index just answers, for a walked path it already knows, "does
// this file contain the pattern's required literal?" and, if not (and the file
// is unchanged since the index was built — the freshness overlay forces a
// re-read of anything touched since), lets the read be elided. A skipped file
// couldn't have produced a single line of output, so eliding its read is
// byte-invisible — the win is turning "open+read ~16k files" into "open+read
// only the trigram candidates" for a selective query, gist's whole thesis.
//
// Soundness rests on two sets drawn from the index:
//   • `indexed`  — every path the index covers (only THESE may be elided; a path
//     the index doesn't know — a new file, or one outside the indexed roots — is
//     always read, so nothing is ever wrongly skipped);
//   • `candset`  — `fresh.candidates`: the trigram hits for the prefilter UNIONed
//     with every file touched since the build (the freshness overlay closes the
//     stale-index gap — a file that GAINED the needle since the build is in this
//     set and gets read).
// Elide reading path P iff  P ∈ indexed  AND  P ∉ candset.
const IndexSkip = struct {
    p: persist.Persisted,
    cand: fresh.Candidates,
    indexed: std.StringHashMap(void),
    candset: std.StringHashMap(void),

    fn skip(self: *const IndexSkip, rel: []const u8) bool {
        return self.indexed.contains(rel) and !self.candset.contains(rel);
    }
    fn deinit(self: *IndexSkip) void {
        self.candset.deinit();
        self.indexed.deinit();
        self.cand.deinit();
        self.p.deinit();
    }
};

/// The sound trigram prefilter for this invocation, or empty (⇒ no read is ever
/// elided) whenever anything makes "contains the required literal" an unsafe
/// proxy for "can match": `--no-index`, case-folding (`-i`/resolved `-S`),
/// inversion (`-v` emits zero-hit files too), or the whole-file scans
/// (`--stats`, `--passthru`) that must read every byte regardless. Otherwise the
/// engine's own required literal (`re.required`, present in EVERY match) or, for
/// an alternation, its per-branch cover set (`re.alts` — `foo|bar` ⇒ {foo,bar}),
/// both of which `fresh.candidates` treats as sound supersets.
pub fn trigramFilter(o: Opts, re: *const Regex, one: *[1][]const u8) []const []const u8 {
    if (o.no_index or o.caseless or o.invert or o.stats or o.passthru) return &.{};
    if (re.required.len >= 3) {
        one[0] = re.required;
        return one[0..];
    }
    return re.alts;
}

/// Build the read-elision oracle from the persisted index, or null when there's
/// nothing to gain (no sound prefilter, `--no-index`, or no index on disk — the
/// last probed SILENTLY via `loadQuiet`, since a bare `gist <pattern>` outside an
/// indexed corpus is the normal case, not a miss to nag about). `fresh_roots`
/// scopes the freshness stat-walk to the query's own roots (else the indexed
/// corpus) so a scoped query doesn't pay a whole-corpus stat pass.
fn buildIndexSkip(gpa: std.mem.Allocator, io: std.Io, parsed: args.Parsed, filters: []const []const u8) ?IndexSkip {
    if (parsed.opts.no_index or filters.len == 0) return null;
    var p = (persist.loadQuiet(gpa, io) catch return null) orelse return null;
    // Snapshot the indexed path set BEFORE freshness widens `p.paths` with new
    // files (only originally-indexed paths are elision-eligible; the new files
    // freshness appends are, by definition, things to read).
    const n_indexed = p.paths.items.len;
    var indexed = std.StringHashMap(void).init(gpa);
    indexed.ensureTotalCapacity(@intCast(n_indexed)) catch {
        p.deinit();
        return null;
    };
    for (p.paths.items[0..n_indexed]) |pp| indexed.putAssumeCapacity(pp, {});

    const fresh_roots = if (parsed.roots.len > 0) parsed.roots else &corpus_mod.default_roots;
    var cand = fresh.candidates(gpa, io, &p.idx, &p.paths, filters, fresh_roots) catch {
        indexed.deinit();
        p.deinit();
        return null;
    };
    var candset = std.StringHashMap(void).init(gpa);
    candset.ensureTotalCapacity(@intCast(cand.ids.len)) catch {
        cand.deinit();
        indexed.deinit();
        p.deinit();
        return null;
    };
    for (cand.ids) |d| candset.putAssumeCapacity(p.paths.items[d], {});
    return .{ .p = p, .cand = cand, .indexed = indexed, .candset = candset };
}

// ─────────────────────────── collect ───────────────────────────

/// The resolved file set for a query: sorted `files`, whether the walk was
/// recursive, and whether any path could not be opened (forces exit 2).
pub const Collected = struct { files: []InFile, recursive: bool, path_error: bool };

/// Gather (walk, single-threaded — `walk.gather`) → read (parallel, see
/// `readCandidates`) → type/glob filter → path-sort → apply --path-separator.
/// Shared by the search path and `--files`. `gpa` (not the arena `a`) backs the
/// parallel read shards — `std.heap.ArenaAllocator` isn't safe to allocate
/// through concurrently, so each shard gets its OWN arena wrapping the shared,
/// thread-safe `gpa` (see `ReadShard`/`readCandidates`). `filters` is the sound
/// trigram prefilter (`trigramFilter`); empty ⇒ read every walked file (today's
/// behavior), non-empty ⇒ let the persisted index elide provable-non-candidate
/// reads (`buildIndexSkip`) — the output is identical either way.
pub fn collectFiles(a: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, parsed: args.Parsed, filters: []const []const u8) Collected {
    const o = parsed.opts;
    var candidates: std.ArrayList(Candidate) = .empty;
    var ig = ignore.Ignore.init(a, io, o, parsed.roots);
    const g = walk.gather(a, io, parsed.roots, o, &ig, &candidates);

    var all: std.ArrayList(InFile) = .empty;
    var skip = buildIndexSkip(gpa, io, parsed, filters);
    defer if (skip) |*s| s.deinit();
    const read_list = if (skip) |*s| blk: {
        // Partition the walked set: read only what the index can't prove out.
        // An elided file contributes nothing to any mode EXCEPT --files-without-
        // match, which lists every non-matching file — so there it's kept as an
        // unread (empty-body) entry, which the run loop treats as "no match".
        var to_read: std.ArrayList(Candidate) = .empty;
        to_read.ensureTotalCapacity(a, candidates.items.len) catch die("oom\n", .{});
        for (candidates.items) |c| {
            if (s.skip(c.rel)) {
                if (o.files_without) all.append(a, .{ .path = c.rel, .bytes = "", .explicit = c.explicit }) catch die("oom\n", .{});
            } else to_read.appendAssumeCapacity(c);
        }
        break :blk to_read.items;
    } else candidates.items;
    readCandidates(a, gpa, read_list, literalGate(parsed), &all);

    var files: std.ArrayList(InFile) = .empty;
    files.ensureTotalCapacity(a, all.items.len) catch die("oom\n", .{});
    for (all.items) |f| {
        if (o.filter.active() and !o.filter.admits(a, f.path)) continue;
        if (o.max_filesize != 0 and f.bytes.len > o.max_filesize) continue;
        files.appendAssumeCapacity(f);
    }
    std.mem.sort(InFile, files.items, {}, cmpFiles);
    if (o.path_sep) |sepstr| for (files.items) |*f| {
        f.path = replaceSep(a, f.path, sepstr);
    };
    return .{ .files = files.items, .recursive = g.recursive, .path_error = g.path_error };
}

fn cmpFiles(_: void, x: InFile, y: InFile) bool {
    return std.mem.lessThan(u8, x.path, y.path);
}
