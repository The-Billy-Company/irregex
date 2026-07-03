//! gist `rg` — a ripgrep-DEFAULT drop-in over an arbitrary directory tree, and
//! (since the two engines merged) the SOLE search engine gist ships: the same
//! walk-and-emit pipeline backs the bare `gist <pattern> [PATH...]` shorthand
//! (no verb, no index required — the everyday zero-setup front door) and the
//! explicit `gist rg` alias. A persisted trigram index, when it covers the
//! searched roots, is used purely to ELIDE reads of files it proves can't match
//! (`IndexSkip` below) — never to change the file set, ignore semantics,
//! ordering, or output; `--no-index`/`--index` force the pure walk / the
//! accelerated path, and `--rank[=N]` rides the same candidate source into the
//! definition-first RRF view (`rank.zig`). This needs to *prove* gist is a
//! genuine ripgrep drop-in against ripgrep's own integration suite — which
//! creates a throwaway directory, drops in fixtures, and runs `rg` in that CWD —
//! so this module searches an arbitrary tree with ripgrep's DEFAULT presentation:
//!   • filename shown only when recursive or >1 file (a single explicit file
//!     prints no `path:` prefix), `-H` forces it, `--no-filename`/`-I` suppress;
//!   • line numbers OFF by default, `-n` turns them on;
//!   • `:` frames a match line, `-` a context line, `--` separates groups;
//!   • `-t/-T/-g/--glob/--iglob` scope by type/glob (reusing `../scope/`);
//!   • `.gitignore`/`.ignore`/`.rgignore` precedence honored (`ignore.zig`),
//!     byte-identical to `rg`'s own default corpus scope;
//!   • exit 0 = matched, 1 = no match, 2 = error/unsupported (ripgrep's codes).
//! It reuses gist's regex engine verbatim (one linear-time RE2-style matcher, no
//! second code path) — this module is the walk + presentation shell that makes
//! that engine addressable the way `rg` is. `--json`/`--column`/`--vimgrep` ARE
//! honored (`json.zig`, `output.zig`); the genuine divergences that fail LOUD
//! with exit 2 (so the differential harness scores them N/A rather than silently
//! wrong) are `-U`/`--multiline` (per-line by construction) and `-P`/`--pcre2`
//! (a linear-time RE2 engine has no backreferences/lookaround).

const std = @import("std");
const corpus_mod = @import("../../corpus/corpus.zig");
const args = @import("args.zig");
const output = @import("output.zig");
const ignore = @import("ignore.zig");
const json = @import("json.zig");
const color = @import("color.zig");
const types = @import("../scope/types.zig");
const simd = @import("../../scan/simd.zig");
const persist = @import("../../index/persist.zig");
const fresh = @import("../../corpus/fresh.zig");
const rank = @import("rank.zig");
const Opts = args.Opts;
const Emitter = output.Emitter;
const die = args.die;
const Regex = @import("../../regex/core.zig").Regex;
const Captures = @import("../../regex/captures.zig").Captures;
const Dir = std.Io.Dir;

// ─────────────────────────── file gathering ───────────────────────────

const InFile = struct { path: []const u8, bytes: []const u8, explicit: bool = false };

/// ripgrep's default read-buffer capacity. Binary detection scans buffer-sized
/// reads for a NUL; a match in the buffer that first contains the NUL is NOT
/// printed (rg has already scanned ahead), so the emission cutoff is the start
/// of that buffer — `(nul_offset / BUFCAP) * BUFCAP`.
const BUFCAP: usize = 65536;

/// Replace every `/` in `path` with the (arbitrary-length) `sep` string for
/// `--path-separator`. Returns `path` unchanged when it has no separator.
fn replaceSep(a: std.mem.Allocator, path: []const u8, sep: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, path, '/') == null) return path;
    var out: std.ArrayList(u8) = .empty;
    for (path) |c| {
        if (c == '/') out.appendSlice(a, sep) catch die("oom\n", .{}) else out.append(a, c) catch die("oom\n", .{});
    }
    return out.toOwnedSlice(a) catch die("oom\n", .{});
}

fn escapeLiteral(a: std.mem.Allocator, pat: []const u8) []u8 {
    var out: std.ArrayList(u8) = .empty;
    for (pat) |c| {
        switch (c) {
            '.', '^', '$', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '\\' => out.append(a, '\\') catch die("oom\n", .{}),
            else => {},
        }
        out.append(a, c) catch die("oom\n", .{});
    }
    return out.toOwnedSlice(a) catch die("oom\n", .{});
}

/// Strip a leading UTF-8 BOM (ripgrep transparently skips it so `^` anchors to
/// the first real byte). Downstream of `decodeBom` this is a no-op for files (the
/// BOM is already gone); it still guards the stdin path, which isn't BOM-decoded.
fn stripBom(buf: []const u8) []const u8 {
    if (buf.len >= 3 and buf[0] == 0xEF and buf[1] == 0xBB and buf[2] == 0xBF) return buf[3..];
    return buf;
}

/// BOM-driven encoding auto-detection, applied once per file at ingest — ripgrep's
/// default (`--encoding auto`) behavior. A UTF-8 BOM is stripped; a UTF-16 LE/BE
/// BOM transcodes the whole file to UTF-8 so the (UTF-8) pattern matches and the
/// UTF-16 NULs never trip binary detection. BOM-less UTF-16 is NOT sniffed (rg
/// needs explicit `-E utf-16` for that, which stays NA); anything else is bytes.
fn decodeBom(a: std.mem.Allocator, buf: []const u8) []const u8 {
    if (buf.len >= 3 and buf[0] == 0xEF and buf[1] == 0xBB and buf[2] == 0xBF) return buf[3..];
    if (buf.len >= 2 and buf[0] == 0xFF and buf[1] == 0xFE) return utf16ToUtf8(a, buf[2..], .little);
    if (buf.len >= 2 and buf[0] == 0xFE and buf[1] == 0xFF) return utf16ToUtf8(a, buf[2..], .big);
    return buf;
}

/// Transcode UTF-16 (BOM already consumed) to UTF-8, resolving surrogate pairs;
/// a lone/invalid surrogate or trailing odd byte becomes U+FFFD (rust-encoding's
/// lossy behavior, which ripgrep uses).
fn utf16ToUtf8(a: std.mem.Allocator, bytes: []const u8, endian: std.builtin.Endian) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) {
        var cp: u21 = std.mem.readInt(u16, bytes[i..][0..2], endian);
        if (cp >= 0xD800 and cp <= 0xDBFF) { // high surrogate → need a low one
            if (i + 3 < bytes.len) {
                const lo: u16 = std.mem.readInt(u16, bytes[i + 2 ..][0..2], endian);
                if (lo >= 0xDC00 and lo <= 0xDFFF) {
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    i += 2;
                } else cp = 0xFFFD;
            } else cp = 0xFFFD;
        } else if (cp >= 0xDC00 and cp <= 0xDFFF) cp = 0xFFFD; // stray low surrogate
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &enc) catch blk: {
            // U+FFFD REPLACEMENT CHARACTER — its UTF-8 encoding is a fixed 3 bytes.
            enc[0..3].* = .{ 0xEF, 0xBF, 0xBD };
            break :blk 3;
        };
        out.appendSlice(a, enc[0..n]) catch die("oom\n", .{});
    }
    return out.toOwnedSlice(a) catch die("oom\n", .{});
}

/// rg line semantics: `\n` terminates; trailing `\n` yields no phantom empty
/// line; content after the last `\n` is still a line. `\r` is KEPT (ripgrep's
/// default without `--crlf`). Pre-sized from one `\n` count pass (same idiom
/// as `persist.zig`'s NUL-count split) so appending a file's lines is a single
/// allocation instead of the list's usual grow-and-copy doubling — the search
/// loop below calls this once per candidate file, so the saved reallocations
/// scale with the corpus, not just one file.
fn collectLines(a: std.mem.Allocator, buf: []const u8, term: u8, out: *std.ArrayList([]const u8)) void {
    out.ensureUnusedCapacity(a, std.mem.count(u8, buf, &.{term}) + 1) catch die("oom\n", .{});
    var rest = buf;
    while (true) {
        const nl = std.mem.indexOfScalar(u8, rest, term);
        const end = nl orelse rest.len;
        if (nl != null or end > 0) out.appendAssumeCapacity(rest[0..end]);
        if (nl == null) break;
        rest = rest[end + 1 ..];
    }
}

/// Depth of a walker-relative path (root children = 1). `--max-depth` caps it.
fn pathDepth(rel: []const u8) usize {
    return std.mem.count(u8, rel, "/") + 1;
}

/// A walker entry's path relative to CWD (prefix-joined), for output + ignore.
fn relPath(a: std.mem.Allocator, prefix: []const u8, p: []const u8) []const u8 {
    return if (prefix.len == 0) a.dupe(u8, p) catch die("oom\n", .{}) else std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, p }) catch die("oom\n", .{});
}

/// A walker entry's on-disk path (root-joined), for opening/reading ignore files.
fn diskPath(a: std.mem.Allocator, root_path: []const u8, p: []const u8) []const u8 {
    return if (std.mem.eql(u8, root_path, ".")) a.dupe(u8, p) catch die("oom\n", .{}) else std.fmt.allocPrint(a, "{s}/{s}", .{ root_path, p }) catch die("oom\n", .{});
}

/// A file the walk found but hasn't read yet: `rel` is the display path
/// (`.gitignore`-relative, prefix-joined per root); `disk` is a plain,
/// CWD-openable path string a later phase reopens to actually read bytes.
/// A walker `Dir`/entry handle is only valid until the walk advances past it
/// (`std.Io.Dir.Walker`'s own contract), so a read deferred to a parallel
/// phase — after the single-threaded walk has moved on — needs a reopenable
/// string, not the handle it was discovered through.
const Candidate = struct { rel: []const u8, disk: []const u8, explicit: bool = false };

fn walkDir(a: std.mem.Allocator, io: std.Io, root_path: []const u8, prefix: []const u8, o: Opts, ig: *ignore.Ignore, out: *std.ArrayList(Candidate)) void {
    ig.loadDir(root_path, prefix);
    // `-L`/`--follow` cycle guard: the real (canonicalized) path of every
    // directory currently on this DFS's ancestor chain — ripgrep's own
    // strategy (ripgrep tracks realpaths, not just a depth counter). A
    // symlink whose target's realpath is already an ancestor is a genuine
    // cycle and is refused; a symlink that reconverges on an already-FINISHED
    // sibling subtree (a diamond, not a cycle) is still followed, since it's
    // popped back off `visited` once its own subtree walk returns.
    var visited: std.ArrayList([]const u8) = .empty;
    if (o.follow) if (realDirPath(a, root_path)) |rp| visited.append(a, rp) catch {};
    walkDirLinked(a, io, root_path, prefix, o, ig, out, 0, &visited);
}

/// `-L` symlink-recursion depth cap — defense in depth alongside the realpath
/// cycle guard below (belt-and-suspenders against a non-cyclic but absurdly
/// deep symlink relay, or a platform where `realpath(3)` can't resolve a leg).
const max_link_depth: usize = 40;

/// The canonicalized absolute path of `path` (POSIX `realpath(3)`), or null if
/// it can't be resolved (dangling symlink, permission error, name too long) —
/// treated as "not provably a cycle" (the subsequent `openDir` surfaces the
/// real error if there is one).
fn realDirPath(a: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const cpath = std.posix.toPosixPath(path) catch return null;
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const resolved = std.c.realpath(&cpath, &buf) orelse return null;
    return a.dupe(u8, std.mem.sliceTo(resolved, 0)) catch null;
}

fn containsPath(haystack_paths: []const []const u8, needle_path: []const u8) bool {
    for (haystack_paths) |p| if (std.mem.eql(u8, p, needle_path)) return true;
    return false;
}

/// Single-threaded directory descent: `.gitignore`/depth/hidden filtering must
/// stay inline with the walk (each dir's ignore rules load as we enter it), so
/// this phase only ever DISCOVERS candidates — no file is opened here. The
/// actual reads happen afterward, in parallel, over the flat list this builds
/// (see `readCandidates`), matching ripgrep's own split between walking the
/// tree and reading what it finds.
fn walkDirLinked(a: std.mem.Allocator, io: std.Io, root_path: []const u8, prefix: []const u8, o: Opts, ig: *ignore.Ignore, out: *std.ArrayList(Candidate), link_depth: usize, visited: *std.ArrayList([]const u8)) void {
    var root = Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch return;
    defer root.close(io);
    var walker = root.walkSelectively(a) catch return;
    defer walker.deinit();
    while (walker.next(io) catch return) |entry| {
        const depth = pathDepth(entry.path);
        const rel = relPath(a, prefix, entry.path);
        // -L/--follow: a symlink is resolved to its target — a dir is walked as a
        // subtree (path-prefixed by the link), a file is read like any other.
        if (entry.kind == .sym_link and o.follow) {
            if (link_depth >= max_link_depth) continue;
            if (ig.shouldSkip(rel, false, entry.basename)) continue;
            const full = if (std.mem.eql(u8, root_path, ".")) std.fmt.allocPrint(a, "./{s}", .{entry.path}) catch continue else std.fmt.allocPrint(a, "{s}/{s}", .{ root_path, entry.path }) catch continue;
            if (Dir.cwd().openDir(io, full, .{ .iterate = true })) |sub_const| {
                var sub = sub_const;
                sub.close(io);
                if (o.max_depth == 0 or depth < o.max_depth) {
                    const mark = visited.items.len;
                    var cyclic = false;
                    if (realDirPath(a, full)) |rp| {
                        cyclic = containsPath(visited.items, rp);
                        if (!cyclic) visited.append(a, rp) catch {};
                    }
                    if (!cyclic) {
                        ig.loadDir(full, rel);
                        walkDirLinked(a, io, full, rel, o, ig, out, link_depth + 1, visited);
                        visited.shrinkRetainingCapacity(mark);
                    }
                }
            } else |_| {
                if (o.max_depth != 0 and depth > o.max_depth) continue;
                out.append(a, .{ .rel = rel, .disk = full }) catch die("oom\n", .{});
            }
            continue;
        }
        if (entry.kind == .directory) {
            // rg's DEFAULT walk descends everything except hidden dirs, `.git`, and
            // ignored ones (.gitignore/.ignore — see ignore.zig). It does NOT
            // hardcode node_modules/target skips (that's gist's monorepo-corpus
            // policy in corpus.zig, wrong for an arbitrary-tree drop-in).
            if (ig.shouldSkip(rel, true, entry.basename)) continue;
            const shallow = o.max_depth == 0 or depth < o.max_depth;
            if (shallow) {
                ig.loadDir(diskPath(a, root_path, entry.path), rel);
                walker.enter(io, entry) catch {};
            }
            continue;
        }
        if (entry.kind != .file) continue;
        if (ig.shouldSkip(rel, false, entry.basename)) continue;
        if (o.max_depth != 0 and depth > o.max_depth) continue;
        out.append(a, .{ .rel = rel, .disk = diskPath(a, root_path, entry.path) }) catch die("oom\n", .{});
    }
}

fn gather(a: std.mem.Allocator, io: std.Io, roots: []const []const u8, o: Opts, ig: *ignore.Ignore, out: *std.ArrayList(Candidate)) bool {
    if (roots.len == 0) {
        walkDir(a, io, ".", "", o, ig, out);
        return true;
    }
    var recursive = false;
    for (roots) |r| {
        if (Dir.cwd().openDir(io, r, .{ .iterate = true })) |dir_const| {
            var dir = dir_const;
            dir.close(io);
            const prefix = if (std.mem.eql(u8, r, ".")) "." else std.mem.trimEnd(u8, r, "/");
            // Exempt this root's own path components from ancestor/CWD-sourced
            // ignore rules (ripgrep never ignore-filters an explicitly named
            // root — only what's found beneath it); see `Ignore.scopeToRoot`.
            ig.scopeToRoot(prefix);
            walkDir(a, io, r, prefix, o, ig, out);
            recursive = true;
        } else |_| {
            // An explicitly named file arg is searched verbatim (ripgrep never
            // ignore-filters an explicit path).
            out.append(a, .{ .rel = r, .disk = r, .explicit = true }) catch die("oom\n", .{});
        }
    }
    return recursive;
}

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
    const fd = std.posix.openat(std.posix.AT.FDCWD, c.disk, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = std.posix.system.close(fd);
    var n: usize = 0;
    while (n < scratch.len) {
        const r = std.posix.read(fd, scratch[n..]) catch break;
        if (r == 0) break;
        n += r;
    }
    if (n == scratch.len) {
        const raw = readTail(a, fd, scratch) orelse return null;
        const body = decodeBom(a, raw);
        if (needle) |needle_v| if (!simd.contains(body, needle_v)) return null;
        return .{ .path = c.rel, .bytes = body, .explicit = c.explicit };
    }
    const body = decodeBom(a, scratch[0..n]);
    if (needle) |needle_v| if (!simd.contains(body, needle_v)) return null;
    return .{ .path = c.rel, .bytes = a.dupe(u8, body) catch return null, .explicit = c.explicit };
}

/// `scratch` (already full) plus whatever remains on `fd`, copied into one
/// arena-owned buffer — the uncommon path for a file at/above `per_file_cap`,
/// kept out of the hot common-case function above.
fn readTail(a: std.mem.Allocator, fd: std.posix.fd_t, scratch: []const u8) ?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, scratch) catch return null;
    var tmp: [64 * 1024]u8 = undefined;
    while (true) {
        const r = std.posix.read(fd, &tmp) catch break;
        if (r == 0) break;
        out.appendSlice(a, tmp[0..r]) catch return null;
    }
    return out.toOwnedSlice(a) catch null;
}

fn readShard(sh: *ReadShard) void {
    const a = sh.arena.allocator();
    const scratch = sh.gpa.alloc(u8, corpus_mod.per_file_cap) catch return;
    defer sh.gpa.free(scratch);
    sh.out.ensureTotalCapacity(sh.gpa, sh.candidates.len) catch {};
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
fn literalGate(parsed: args.Parsed) ?[]const u8 {
    const o = parsed.opts;
    if (o.word or o.caseless or o.invert or o.files_without or o.stats or o.json) return null;
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
// set, the ignore semantics, the ordering, or the output. The live walk above
// stays the sole authority on WHAT to search (so every rgsuite parity guarantee
// holds unchanged); the index just answers, for a walked path it already knows,
// "does this file contain the pattern's required literal?" and, if not (and the
// file is unchanged since the index was built — the freshness overlay forces a
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
fn trigramFilter(o: Opts, re: *const Regex, one: *[1][]const u8) []const []const u8 {
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

/// Gather (walk, single-threaded) → read (parallel, see `readCandidates`) →
/// type/glob filter → path-sort → apply --path-separator. Shared by the
/// search path and `--files`. `gpa` (not the arena `a`) backs the parallel
/// read shards — `std.heap.ArenaAllocator` isn't safe to allocate through
/// concurrently, so each shard gets its OWN arena wrapping the shared,
/// thread-safe `gpa` (see `ReadShard`/`readCandidates`). `filters` is the sound
/// trigram prefilter (`trigramFilter`); empty ⇒ read every walked file (today's
/// behavior), non-empty ⇒ let the persisted index elide provable-non-candidate
/// reads (`buildIndexSkip`) — the output is identical either way.
const Collected = struct { files: []InFile, recursive: bool };
fn collectFiles(a: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, parsed: args.Parsed, filters: []const []const u8) Collected {
    const o = parsed.opts;
    var candidates: std.ArrayList(Candidate) = .empty;
    var ig = ignore.Ignore.init(a, io, o, parsed.roots);
    const recursive = gather(a, io, parsed.roots, o, &ig, &candidates);

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
    return .{ .files = files.items, .recursive = recursive };
}

/// Combine every pattern source — bare/`-e`/`--regexp` plus each `-f/--file`
/// line — into one regex: `-F` escapes each literal, multiple patterns OR via
/// `(?:…)|(?:…)`, and `-x/--line-regexp` anchors the whole with `^(?:…)$`.
/// Returns null for the "zero patterns" case (an empty `-f` file with no other
/// source) — ripgrep matches nothing (and everything under `-v`); the caller
/// handles that without the engine. An empty pattern LINE is kept (it's a valid
/// empty pattern = match-all), only the phantom line after a trailing `\n` drops.
fn combinePatterns(a: std.mem.Allocator, io: std.Io, parsed: args.Parsed) ?[]const u8 {
    var pats: std.ArrayList([]const u8) = .empty;
    pats.appendSlice(a, parsed.patterns) catch die("oom\n", .{});
    for (parsed.pattern_files) |pf| {
        const buf = Dir.cwd().readFileAlloc(io, pf, a, .limited(corpus_mod.per_file_cap)) catch
            die("cannot read pattern file: {s}\n", .{pf});
        if (buf.len == 0) continue;
        var it = std.mem.splitScalar(u8, buf, '\n');
        while (it.next()) |ln| {
            // The piece after a final '\n' is a phantom (not a pattern); every
            // other line — including a genuinely empty one — is a real pattern.
            if (it.index == null and ln.len == 0) break;
            pats.append(a, std.mem.trimEnd(u8, ln, "\r")) catch die("oom\n", .{});
        }
    }
    if (pats.items.len == 0) return null;
    if (parsed.opts.fixed) for (pats.items) |*p| {
        p.* = escapeLiteral(a, p.*);
    };
    var combined: []const u8 = pats.items[0];
    if (pats.items.len > 1) {
        var buf: std.ArrayList(u8) = .empty;
        for (pats.items, 0..) |p, i| {
            if (i != 0) buf.append(a, '|') catch die("oom\n", .{});
            buf.print(a, "(?:{s})", .{p}) catch die("oom\n", .{});
        }
        combined = buf.toOwnedSlice(a) catch die("oom\n", .{});
    }
    if (parsed.opts.line_regexp) combined = std.fmt.allocPrint(a, "^(?:{s})$", .{combined}) catch die("oom\n", .{});
    return combined;
}

fn cmpFiles(_: void, x: InFile, y: InFile) bool {
    return std.mem.lessThan(u8, x.path, y.path);
}

/// ripgrep's `is_readable_stdin` (grep/cli): `!is_terminal(fd0) && (is_file ||
/// is_fifo || is_socket)`. We whitelist exactly those three fd types — regular
/// file, FIFO (pipe), and socket — which by construction excludes a tty and a
/// char device (`/dev/null`), so the `is_terminal` guard is subsumed. This is
/// the rule that lets `cmd | rg pat` and `sock_producer | rg pat` search the
/// stream while `rg pat` (bare tty) and `rg pat </dev/null` fall through to the
/// directory walk. The socket case matters for exec APIs that wire fd0 to a
/// socketpair; omitting it silently diverged from rg on piped-socket input.
///
/// Deliberate departure from raw rg parity: a FIFO or socket can be a
/// long-lived control channel that never writes a byte and never closes (seen
/// in the wild — some sandboxed shell/tool-call harnesses wire fd 0 to exactly
/// such a socket). Blocking `read(2)` against that hangs forever, which is
/// unacceptable for an agent-facing tool. Before committing to the stdin path,
/// `poll(2)` fd 0 for actual readiness with a short deadline: a real pipe or
/// socket producer signals within milliseconds (data, or HUP on an
/// already-closed/empty write end); only the pathological "open forever,
/// silent" case times out, and that falls through to the ordinary directory
/// walk instead of hanging. A regular file never blocks on `read`, so it skips
/// the poll entirely.
const stdin_poll_timeout_ms = 200;

fn readableStdin() bool {
    var st: std.posix.Stat = undefined;
    if (std.posix.system.fstat(0, &st) != 0) return false;
    const fmt = st.mode & std.posix.S.IFMT;
    if (fmt == std.posix.S.IFREG) return true;
    if (fmt != std.posix.S.IFIFO and fmt != std.posix.S.IFSOCK) return false;
    var fds = [_]std.posix.pollfd{.{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }};
    const n = std.posix.poll(&fds, stdin_poll_timeout_ms) catch return false;
    return n > 0;
}

/// Ripgrep has no default cap on stdin size (only `--max-filesize`, which
/// doesn't apply to a stream with no a-priori length) — read to EOF, not to
/// `per_file_cap` (that constant is an indexing-corpus budget, not a search
/// ceiling; see `readOneCandidate`'s identical reasoning for on-disk files).
/// Same hang guard as `readableStdin`'s initial check, applied per read: a
/// FIFO/socket producer that goes silent mid-stream (never writing again, never
/// closing) must not block this loop forever, so each iteration polls with the
/// same bounded deadline before reading and treats a timeout as EOF — whatever
/// arrived before the stall is still searched, nothing is ever discarded.
fn readStdin(a: std.mem.Allocator) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var tmp: [64 * 1024]u8 = undefined;
    while (true) {
        var fds = [_]std.posix.pollfd{.{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, stdin_poll_timeout_ms) catch break;
        if (ready == 0) break; // silent for too long — stop waiting, not hanging
        const n = std.posix.read(0, &tmp) catch break;
        if (n == 0) break;
        buf.appendSlice(a, tmp[0..n]) catch die("oom\n", .{});
    }
    return buf.toOwnedSlice(a) catch die("oom\n", .{});
}

// ─────────────────────────── run ───────────────────────────

pub fn run(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, env: *const std.process.Environ.Map) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const parsed = args.parseArgv(a, argv);
    var o = parsed.opts;
    // Resolved ONCE per run (not per file/emitter): stdout tty + `--color` +
    // env. Every emitter below shares this single yes/no.
    const use_color = color.enabled(o, io, env);

    // Honest deferrals: recognized flags gist doesn't yet emit byte-identically.
    // Failing loud (exit 2) keeps the harness scoring them N/A, never silently
    // wrong — each is a scoped follow-up, not a design divergence.
    deferUnimplemented(o);

    // --type-list: dump every `-t` name and the globs it recognizes, one name
    // per line (aliases repeat their row) — the whole comptime table in
    // `../scope/types.zig`, in the same domain-grouped order it's declared.
    if (o.type_list) {
        var out: std.ArrayList(u8) = .empty;
        for (types.type_table) |row| {
            for (row.names) |name| {
                out.print(a, "{s}: ", .{name}) catch die("oom\n", .{});
                for (row.globs, 0..) |g, i| {
                    out.print(a, "{s}{s}", .{ if (i > 0) ", " else "", g }) catch die("oom\n", .{});
                }
                out.append(a, '\n') catch die("oom\n", .{});
            }
        }
        corpus_mod.emitStdout(out.items);
        std.process.exit(0);
    }

    // --files: list the files that would be searched (no pattern), path-sorted,
    // NUL-terminated under --null. Uses the same gather+filter as the search path.
    if (o.files_list) {
        // --files lists every file (no pattern) — nothing to prefilter, so no read
        // elision applies; pass an empty trigram filter.
        const c = collectFiles(a, gpa, io, parsed, &.{});
        if (o.quiet) std.process.exit(if (c.files.len > 0) 0 else 1);
        var out: std.ArrayList(u8) = .empty;
        for (c.files) |f| out.print(a, "{s}{c}", .{ f.path, if (o.null_sep) @as(u8, 0) else '\n' }) catch die("oom\n", .{});
        corpus_mod.emitStdout(out.items);
        std.process.exit(if (c.files.len > 0) 0 else 1);
    }

    // --rank: gist's definition-first ranked view — a distinct output shape from
    // the rg-parity line engine, resolved from the persisted index (which it
    // requires). Dispatch before pattern combination / the walk: it ranks the
    // indexed candidate set for the raw literal, not a compiled line regex.
    if (o.rank) {
        try rank.run(gpa, io, if (parsed.patterns.len > 0) parsed.patterns[0] else "", o.rank_k);
        return;
    }

    // Zero patterns (an empty `-f` file): ripgrep matches nothing — so without
    // `-v` there is no output (exit 1); with `-v` every line is a match. We model
    // the latter as "match-all (empty pattern), un-inverted".
    const eff = combinePatterns(a, io, parsed) orelse blk: {
        if (!o.invert) std.process.exit(1);
        o.invert = false;
        break :blk "";
    };
    var re = Regex.compileOpts(gpa, eff, .{ .caseless = o.caseless }) catch
        die("bad pattern\n", .{});
    defer re.deinit();

    // -r/--replace: build the group-aware capture matcher (same AST, save-carrying
    // Pike VM) once and share it across every emitter for template expansion.
    var caps_store: ?Captures = if (o.replace != null)
        (Captures.compile(gpa, eff, o.caseless) catch die("bad pattern\n", .{}))
    else
        null;
    defer if (caps_store) |*cp| cp.deinit();
    const caps: ?*Captures = if (caps_store) |*cp| cp else null;

    // Stdin search (rg parity): with no PATH args and a readable stdin (pipe /
    // regular file), search the piped bytes as one unnamed source — no filename
    // prefix, rg exit codes. A tty or /dev/null stdin falls through to the walk.
    if (parsed.roots.len == 0 and readableStdin()) {
        const body = stripBom(readStdin(a));
        var lines: std.ArrayList([]const u8) = .empty;
        collectLines(a, body, o.term(), &lines);
        var out0: std.ArrayList(u8) = .empty;
        var em0 = Emitter{ .a = a, .re = &re, .o = o, .show_name = false, .out = &out0, .base = @intFromPtr(body.ptr), .caps = caps, .use_color = use_color };
        const hits = em0.file("<stdin>", lines.items);
        if (o.quiet) std.process.exit(if (hits > 0) 0 else 1);
        corpus_mod.emitStdout(out0.items);
        std.process.exit(if (hits > 0) 0 else 1);
    }

    // The persisted index (when present) accelerates the walk by eliding reads of
    // files that provably can't hold the pattern's required literal — a pure
    // acceleration, output-invisible (see `IndexSkip`). `req_one` backs a possible
    // one-element `{re.required}` filter slice for its lifetime here.
    var req_one: [1][]const u8 = undefined;
    const c = collectFiles(a, gpa, io, parsed, trigramFilter(o, &re, &req_one));
    const files = c.files;

    // --json: ripgrep's JSON Lines record stream (own printer, shared engine).
    if (o.json) {
        var jf: std.ArrayList(json.File) = .empty;
        for (files) |f| jf.append(a, .{ .path = f.path, .body = stripBom(f.bytes) }) catch die("oom\n", .{});
        var out: std.ArrayList(u8) = .empty;
        const matched = json.run(a, &out, &re, caps, o, jf.items);
        corpus_mod.emitStdout(out.items);
        std.process.exit(if (matched) 0 else 1);
    }

    const show_name = switch (o.filename) {
        .always => true,
        .never => false,
        .auto => c.recursive or files.len > 1 or parsed.roots.len > 1,
    };

    var out: std.ArrayList(u8) = .empty;
    var em = Emitter{ .a = a, .re = &re, .o = o, .show_name = if (o.heading) false else show_name, .out = &out, .caps = caps, .use_color = use_color };

    // --quiet short-circuits on first match — unless --stats is also asked for,
    // which must run the full search to tally (then print only the stats block).
    if (o.quiet and !o.stats) std.process.exit(if (anyMatch(a, &re, o, files)) 0 else 1);

    if (o.files_without) {
        var lsim = Regex.Sim.init(a, &re) catch die("engine init failed\n", .{});
        defer lsim.deinit();
        var wss: ?Regex.SpanSim = if (o.word) (Regex.SpanSim.init(a, &re) catch null) else null;
        defer if (wss) |*s| s.deinit();
        for (files) |f| {
            const body = stripBom(f.bytes);
            if (body.len > 0 and corpus_mod.isBinary(body) and !o.text) continue;
            var lines: std.ArrayList([]const u8) = .empty;
            collectLines(a, body, o.term(), &lines);
            var any = false;
            for (lines.items) |line| {
                const mv = if (o.crlf) std.mem.trimEnd(u8, line, "\r") else line;
                const hit = if (wss) |*s| em.lineHitWord(s, mv) else re.lineMatch(&lsim, mv);
                if (hit) {
                    any = true;
                    break;
                }
            }
            if (!any) out.print(a, "{s}{c}", .{ f.path, if (o.null_sep) @as(u8, 0) else '\n' }) catch die("oom\n", .{});
        }
        corpus_mod.emitStdout(out.items);
        std.process.exit(if (out.items.len > 0) 0 else 1);
    }

    const heading = o.heading and !o.count_only and !o.count_matches and !o.files_only and !o.vimgrep;
    const join_groups = o.wantsContext() and !o.files_only and !o.count_only and !o.count_matches and !heading;
    var matched_files: usize = 0;
    var first = true;
    // -l/--files-with-matches and -q short-circuit on first match (rg prints the
    // path / exits before scanning far enough to detect a NUL), so they treat a
    // binary file as text. Every other mode runs ripgrep's binary detection.
    const binary_detect = !o.text and !o.null_data and !o.files_only;
    var stat = Stats{};
    for (files) |f| {
        const body = stripBom(f.bytes);
        if (body.len == 0) continue;
        if (binary_detect) if (std.mem.indexOfScalar(u8, body, 0)) |nul| {
            em.base = @intFromPtr(body.ptr);
            if (handleBinary(a, &re, o, &out, &em, f, body, nul, show_name)) matched_files += 1;
            continue;
        };
        var lines: std.ArrayList([]const u8) = .empty;
        collectLines(a, body, o.term(), &lines);
        if (o.stats) {
            stat.files_searched += 1;
            const fs = fileMatchStats(&re, a, o, body, lines.items);
            stat.matches += fs.matches;
            stat.matched_lines += fs.lines;
            stat.bytes_searched += fs.bytes;
        }
        const before = out.items.len;
        // --heading: a blank-line-separated group per file, path on its own line.
        if (heading) out.print(a, "{s}{s}\n", .{ if (first) "" else "\n", f.path }) catch die("oom\n", .{});
        em.base = @intFromPtr(body.ptr);
        const hits = em.file(f.path, lines.items);
        if (hits > 0) {
            if (join_groups and !first and out.items.len > before)
                out.insertSlice(a, before, "--\n") catch die("oom\n", .{});
            first = false;
            matched_files += 1;
        } else if (heading) {
            out.shrinkRetainingCapacity(before); // no matches → drop the header we wrote
        }
    }
    if (o.stats) {
        stat.files_with_match = matched_files;
        // --quiet --stats: suppress the match stream, report 0 bytes printed.
        stat.bytes_printed = if (o.quiet) 0 else out.items.len;
        if (o.quiet) out.clearRetainingCapacity();
        emitStats(a, &out, stat);
    }
    corpus_mod.emitStdout(out.items);
    std.process.exit(if (matched_files > 0) 0 else 1);
}

/// ripgrep binary-file handling (a NUL is present, no `--text`/`--null-data`).
/// Emits matching lines that start before the NUL-containing buffer, then either
/// the implicit WARNING (files reached via the walk / glob) or the explicit
/// `binary file matches` summary (an explicit path arg or stdin). Returns whether
/// the file counts as a match (drives the process exit code).
fn handleBinary(a: std.mem.Allocator, re: *const Regex, o: Opts, out: *std.ArrayList(u8), em: *Emitter, f: InFile, body: []const u8, nul: usize, show_name: bool) bool {
    const cut = (nul / BUFCAP) * BUFCAP; // start of the buffer that holds the NUL
    var lines: std.ArrayList([]const u8) = .empty;
    collectLines(a, body, o.term(), &lines);
    var cutoff: usize = lines.items.len;
    for (lines.items, 0..) |line, k| {
        if (@intFromPtr(line.ptr) - @intFromPtr(body.ptr) >= cut) {
            cutoff = k;
            break;
        }
    }
    const head = lines.items[0..cutoff];

    // -c/--count: implicit files are suppressed entirely (rg scans fully, detects
    // binary, drops the count); an explicit file counts every match across the
    // whole body (rg treats an explicit binary as text for counting).
    if (o.count_only or o.count_matches) {
        if (!f.explicit) return false;
        return em.file(f.path, lines.items) > 0;
    }

    const before = out.items.len;
    const hits = em.file(f.path, head);
    if (f.explicit) {
        // Explicit path / stdin: the summary fires if the file matches anywhere
        // (including after the NUL — rg reports the whole file as a binary match).
        if (anyLinesMatch(a, re, o, lines.items)) {
            binNote(a, out, o, f.path, nul, show_name, "binary file matches");
            return true;
        }
        out.shrinkRetainingCapacity(before);
        return false;
    }
    // Implicit (walk/glob): a WARNING only when we actually printed a match before
    // the NUL buffer; otherwise rg quits silently (no output, no match).
    if (hits > 0) {
        binNote(a, out, o, f.path, nul, show_name, "WARNING: stopped searching binary file after match");
        return true;
    }
    return false;
}

/// Append ripgrep's binary note: `[<path>: ]<msg> (found "\0" byte around offset
/// N)`. The path prefix (with `: ` separator) is shown only when filenames are on.
fn binNote(a: std.mem.Allocator, out: *std.ArrayList(u8), o: Opts, path: []const u8, nul: usize, show_name: bool, msg: []const u8) void {
    if (show_name) out.print(a, "{s}: ", .{path}) catch die("oom\n", .{});
    out.print(a, "{s} (found \"\\0\" byte around offset {d}){c}", .{ msg, nul, o.term() }) catch die("oom\n", .{});
}

/// Does any line match (used for the explicit binary summary)? Honors `-w` and
/// the `--crlf` view; ignores `-v` (rg's binary summary reflects real matches).
fn anyLinesMatch(a: std.mem.Allocator, re: *const Regex, o: Opts, lines: []const []const u8) bool {
    var sim = Regex.Sim.init(a, re) catch return false;
    defer sim.deinit();
    var wss: ?Regex.SpanSim = if (o.word) (Regex.SpanSim.init(a, re) catch null) else null;
    defer if (wss) |*s| s.deinit();
    var em = Emitter{ .a = a, .re = re, .o = o, .show_name = false, .out = undefined };
    for (lines) |line| {
        const mv = if (o.crlf) std.mem.trimEnd(u8, line, "\r") else line;
        const hit = if (wss) |*s| em.lineHitWord(s, mv) else re.lineMatch(&sim, mv);
        if (hit) return true;
    }
    return false;
}

/// `--stats` tally (ripgrep's summary). Timing fields are intentionally omitted:
/// they are non-deterministic and the differential harness normalizes the two
/// `seconds` lines away (ripgrep's own tests only `contains`-check them).
const Stats = struct {
    matches: usize = 0,
    matched_lines: usize = 0,
    files_with_match: usize = 0,
    files_searched: usize = 0,
    bytes_printed: usize = 0,
    bytes_searched: usize = 0,
};

const FileStat = struct { matches: usize, lines: usize, bytes: usize };

/// Count total match spans and matching lines in one file (for `--stats`),
/// honoring `-w` word bounds and the `--crlf` match view. Empty spans don't
/// count (ripgrep counts non-empty matches). Under `-m/--max-count`, ripgrep
/// stops reading after the Nth matching line, so `bytes` reports only the bytes
/// actually searched (ADR-parity with rg's `r2944` regression) rather than the
/// whole file.
fn fileMatchStats(re: *const Regex, a: std.mem.Allocator, o: Opts, body: []const u8, lines: []const []const u8) FileStat {
    var ss = Regex.SpanSim.init(a, re) catch return .{ .matches = 0, .lines = 0, .bytes = body.len };
    defer ss.deinit();
    var m: usize = 0;
    var l: usize = 0;
    for (lines) |line| {
        const mv = if (o.crlf) std.mem.trimEnd(u8, line, "\r") else line;
        var from: usize = 0;
        var line_hit = false;
        while (from <= mv.len) {
            const sp = re.matchSpan(&ss, mv, from) orelse break;
            if (sp.end == sp.start) {
                from = sp.start + 1;
                continue;
            }
            if (o.word and !output.wordOk(mv, sp.start, sp.end)) {
                from = sp.end;
                continue;
            }
            m += 1;
            line_hit = true;
            from = sp.end;
        }
        if (line_hit) l += 1;
        if (o.max_per_file != 0 and l >= o.max_per_file) {
            // rg stops after the Nth matching line; bytes searched = end of that
            // line (its terminator included when one follows).
            var end = (@intFromPtr(line.ptr) - @intFromPtr(body.ptr)) + line.len;
            if (end < body.len) end += 1;
            return .{ .matches = m, .lines = l, .bytes = end };
        }
    }
    return .{ .matches = m, .lines = l, .bytes = body.len };
}

/// Emit ripgrep's `--stats` block (leading blank line, one field per line). The
/// two `seconds` lines carry zeros — the harness normalizes them (see `Stats`).
fn emitStats(a: std.mem.Allocator, out: *std.ArrayList(u8), s: Stats) void {
    out.print(a,
        \\
        \\{d} matches
        \\{d} matched lines
        \\{d} files contained matches
        \\{d} files searched
        \\{d} bytes printed
        \\{d} bytes searched
        \\0.000000 seconds spent searching
        \\0.000000 seconds total
        \\
    , .{ s.matches, s.matched_lines, s.files_with_match, s.files_searched, s.bytes_printed, s.bytes_searched }) catch die("oom\n", .{});
}

/// Fail loud (exit 2 → harness N/A) for recognized-but-not-yet-emitted flags.
fn deferUnimplemented(o: Opts) void {
    if (o.multiline) die("-U/--multiline not yet implemented in gist rg-compat\n", .{});
}

/// `-q/--quiet`: true as soon as any file has a matching line (short-circuits).
fn anyMatch(a: std.mem.Allocator, re: *const Regex, o: Opts, files: []const InFile) bool {
    var sim = Regex.Sim.init(a, re) catch return false;
    defer sim.deinit();
    var wss: ?Regex.SpanSim = if (o.word) (Regex.SpanSim.init(a, re) catch null) else null;
    defer if (wss) |*s| s.deinit();
    var em = Emitter{ .a = a, .re = re, .o = o, .show_name = false, .out = undefined };
    for (files) |f| {
        const body = stripBom(f.bytes);
        if (body.len == 0 or (corpus_mod.isBinary(body) and !o.text)) continue;
        var lines: std.ArrayList([]const u8) = .empty;
        collectLines(a, body, o.term(), &lines);
        for (lines.items) |line| {
            const mv = if (o.crlf) std.mem.trimEnd(u8, line, "\r") else line;
            const hit = if (wss) |*s| em.lineHitWord(s, mv) else re.lineMatch(&sim, mv);
            if (hit != o.invert) return true;
        }
    }
    return false;
}
