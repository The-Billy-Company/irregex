//! gist T3 — local-filesystem freshness overlay. A persisted trigram index only
//! elides a live read when the path was indexed and both filesystem change
//! clocks prove it predates the build anchor. Every other file is read and
//! verified against live bytes before output.
//!
//! The anchor is captured before the index reads the corpus. A file is
//! conservatively fresh when mtime OR ctime is `>= anchor`, or either timestamp
//! is unavailable. ctime closes the ordinary preserved-mtime hole: writing or
//! replacing bytes advances status-change time even if a later `touch -r`
//! restores mtime. Equality is fresh so coarse clocks that collapse a
//! post-anchor write onto the anchor tick remain conservative.
//!
//! This is freshness-aware with no false negatives under the model documented
//! in `README.md`: a local filesystem whose reported ctime advances to the
//! anchor tick or later for a completed ordinary write, and a primary live walk
//! that reports traversal failures. Deliberately backdating both clocks,
//! network/cache incoherence, and writes racing the metadata/read window are
//! outside a snapshot guarantee. A racing query may resolve to the before- or
//! after-write state; the next query observes the advanced ctime. `git diff
//! HEAD` remains unsound because a coworker's committed change can differ from
//! the older index without appearing in the working-tree diff.

const std = @import("std");
const corpus_mod = @import("../../tree/corpus.zig");
const haystack = @import("../../tree/haystack.zig");
const ignore = @import("../../tree/ignore.zig");
const scope = @import("../../scope/glob.zig");
const path_utils = @import("../../scope/paths.zig");
const bulkstat = @import("../../tree/bulkstat.zig");
const journal = @import("../../tree/journal.zig");
const persist = @import("persist.zig");
const sweep = @import("sweep.zig");
const Dir = std.Io.Dir;

const anchor_path = corpus_mod.ArtifactPath("built.ns");
const journal_tok_path = corpus_mod.ArtifactPath(journal.file_name);
/// Lost-race marker: the encoded token of a replay that could not answer
/// within the per-query budget. While the persisted token still matches,
/// later queries skip straight to the walk instead of re-paying the probe;
/// any new token (index build/amend) makes the marker stale and re-arms
/// the fast path. Best-effort on both ends — never load-bearing.
const journal_skip_path = corpus_mod.ArtifactPath("journal.skip");

/// Persist the build instant (wall-clock ns) as the freshness anchor. Atomic
/// (temp-then-rename, see `persist.writeAtomic`) so a concurrent reader never
/// observes a momentarily-truncated anchor file (which would silently disable
/// the freshness overlay for that one query — a soft correctness gap, not a
/// crash, but still avoidable at the same cost as the index/paths writes).
pub fn writeAnchor(io: std.Io, built_ns: i128) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(i64, &buf, @intCast(built_ns), .little); // epoch-ns fits i64 until 2262
    try persist.writeAtomic(io, anchor_path.get(), &buf);
}

/// Persist the filesystem-journal since-token (macOS FSEvents id + device +
/// mint instant) captured at full-build time. Best-effort: a missing token
/// only costs the journal fast path — every freshness question still has the
/// stat walk. Written AFTER the pair publishes, same as the anchor.
pub fn writeJournalToken(io: std.Io, tok: journal.Token) void {
    const bytes = journal.encode(tok);
    persist.writeAtomic(io, journal_tok_path.get(), &bytes) catch {};
}

/// The persisted journal since-token, or null when absent/undecodable. `pub`
/// so the resident daemon can boot-seed its annals from the same token the
/// one-shot replay rides (`serve.zig`).
pub fn readJournalToken(gpa: std.mem.Allocator, io: std.Io) ?journal.Token {
    const b = Dir.cwd().readFileAlloc(io, journal_tok_path.get(), gpa, .limited(64)) catch return null;
    defer gpa.free(b);
    return journal.decode(b);
}

/// The anchor, or null when it is missing, truncated, or in the future. Query
/// callers fail closed to reading every walked file when this proof is absent.
/// `pub` so the `status` verb can report the build instant without a query.
pub fn readAnchor(gpa: std.mem.Allocator, io: std.Io) ?i128 {
    const b = Dir.cwd().readFileAlloc(io, anchor_path.get(), gpa, .limited(64)) catch return null;
    defer gpa.free(b);
    if (b.len < 8) return null;
    const built_ns: i128 = std.mem.readInt(i64, b[0..8], .little);
    if (built_ns > std.Io.Clock.now(.real, io).nanoseconds) return null;
    return built_ns;
}

/// Candidate doc-ids + a private arena owning any new-file paths appended to the
/// caller's `paths` list. Keep it alive until after the candidate read.
pub const Candidates = struct {
    ids: []u32,
    /// Doc ids the freshness walk proved changed at/after the anchor (every id
    /// the fresh-path fold touched, dedupe-independent). A doc listed here has
    /// live bytes the persisted per-doc artifacts (trigram postings, crest
    /// sidecar) no longer describe — content-conditioned pruning must skip it.
    fresh_ids: []u32,
    /// False when no trustworthy build anchor existed: NO doc is provably
    /// unchanged, so `ids` seeds everything and content pruning must stand down.
    anchored: bool,
    arena: std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    pub fn deinit(self: *Candidates) void {
        self.gpa.free(self.fresh_ids);
        self.gpa.free(self.ids);
        self.arena.deinit();
    }
};

/// Base trigram candidates for `filters` UNIONed with every file whose mtime or
/// ctime is at/after the build anchor (plus metadata-unknown files). `filters`
/// is the prefilter set: a single mandatory
/// literal (`{required}`), an alternation cover set (`foo|bar` ⇒ {foo, bar}), or
/// empty ⇒ every doc. Each filter must be ≥3 B; an empty set or any short/failed
/// filter falls back to seeding every doc (sound — the verify pass still gates).
/// Files already in `paths` contribute their existing id (forced into the set
/// even if the trigram filter skipped them); brand-new files are appended to
/// `paths` (id = new index) so the caller's read path resolves them unchanged.
/// Queries go through the LAYERED view (`Persisted.queryAny` — base ∪ codicil
/// ∪ tombstones), so an amended generation's candidates are exactly as sound
/// as a full rebuild's.
pub fn candidates(
    gpa: std.mem.Allocator,
    io: std.Io,
    p: *const persist.Persisted,
    paths: *std.ArrayList([]const u8),
    filters: []const []const u8,
    roots: []const []const u8,
) !Candidates {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    var ids: std.ArrayList(u32) = .empty;
    errdefer ids.deinit(gpa);
    var fresh_ids: std.ArrayList(u32) = .empty;
    errdefer fresh_ids.deinit(gpa);
    var usable = filters.len > 0;
    for (filters) |f| usable = usable and f.len >= 3;
    if (usable) {
        if (p.queryAny(gpa, filters)) |cand| {
            defer gpa.free(cand);
            try ids.appendSlice(gpa, cand);
        } else |_| try seedAll(gpa, &ids, paths.items.len);
    } else try seedAll(gpa, &ids, paths.items.len);

    var anchored = false;
    if (readAnchor(gpa, io)) |built_ns| {
        anchored = true;
        const a = arena.allocator();
        var freshlist: std.ArrayList([]const u8) = .empty; // arena-owned strings
        try walkFresh(gpa, io, roots, built_ns, a, &freshlist);
        if (freshlist.items.len > 0) try widen(gpa, paths, &ids, &fresh_ids, freshlist.items);
    } else {
        // Without a trustworthy anchor no indexed non-candidate is provably
        // unchanged. Seed all so the caller declines elision and live-reads.
        ids.clearRetainingCapacity();
        try seedAll(gpa, &ids, paths.items.len);
    }

    return .{ .ids = try ids.toOwnedSlice(gpa), .fresh_ids = try fresh_ids.toOwnedSlice(gpa), .anchored = anchored, .arena = arena, .gpa = gpa };
}

/// Paths under `roots` whose metadata says they changed at/after `since_ns` —
/// the same conservative stat walk the T3 overlay runs (mtime OR ctime ≥
/// anchor, metadata-unknown counted as changed), exposed for tiers that carry
/// their OWN build anchor (the codex shelf) instead of the trigram one.
/// Strings land in `a`; the caller owns their lifetime.
pub fn changedSince(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, since_ns: i128, a: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
    try walkFresh(gpa, io, roots, since_ns, a, out);
}

/// `changedSince` reduced to its count — the honest staleness number every
/// anchor-carrying status/report surface prints. Walk errors read as 0:
/// staleness here is advisory, never load-bearing.
pub fn staleCount(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, since_ns: i128) usize {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var changed: std.ArrayList([]const u8) = .empty;
    changedSince(gpa, io, roots, since_ns, arena.allocator(), &changed) catch return 0;
    return changed.items.len;
}

fn seedAll(gpa: std.mem.Allocator, ids: *std.ArrayList(u32), total: usize) !void {
    try ids.ensureTotalCapacity(gpa, total);
    for (0..total) |i| ids.appendAssumeCapacity(@intCast(i));
}

/// Fold the fresh paths into `ids`: existing → its id, new → append to `paths`.
/// Dedup against the base set so a fresh file that's also a trigram candidate is
/// read once. Every fresh doc id ALSO lands in `fresh_ids` (dedupe-independent
/// of the base set — a fresh trigram candidate is still fresh), the set the
/// crest sieve consults before trusting a persisted per-doc vector.
/// The path→id map is built only when there *are* fresh files.
/// `pub` so the sibling `fresh_test.zig` can exercise it directly.
pub fn widen(gpa: std.mem.Allocator, paths: *std.ArrayList([]const u8), ids: *std.ArrayList(u32), fresh_ids: *std.ArrayList(u32), fresh: []const []const u8) !void {
    var seen = std.AutoHashMap(u32, void).init(gpa);
    defer seen.deinit();
    try seen.ensureTotalCapacity(@intCast(ids.items.len + fresh.len));
    for (ids.items) |d| seen.putAssumeCapacity(d, {});

    var fresh_seen = std.AutoHashMap(u32, void).init(gpa);
    defer fresh_seen.deinit();
    try fresh_seen.ensureTotalCapacity(@intCast(fresh.len));

    var by_path = std.StringHashMap(u32).init(gpa);
    defer by_path.deinit();
    try by_path.ensureTotalCapacity(@intCast(paths.items.len));
    for (paths.items, 0..) |pp, i| by_path.putAssumeCapacity(pp, @intCast(i));

    for (fresh) |fp| {
        const id = by_path.get(fp) orelse blk: {
            try paths.append(gpa, fp); // fp lives in the Candidates arena
            break :blk @as(u32, @intCast(paths.items.len - 1));
        };
        if (!(try fresh_seen.getOrPut(id)).found_existing) try fresh_ids.append(gpa, id);
        if ((try seen.getOrPut(id)).found_existing) continue;
        try ids.append(gpa, id);
    }
}

fn retainAdmitted(io: std.Io, roots: []const []const u8, a: std.mem.Allocator, out: *std.ArrayList([]const u8), start: usize) void {
    var ig = ignore.Ignore.init(a, io, .{}, roots);
    var write = start;
    for (out.items[start..]) |path| {
        for (roots) |root| {
            if (!scope.underRoot(path, path_utils.stripDot(root))) continue;
            if (ig.admitsPath(root, path)) {
                out.items[write] = path;
                write += 1;
                break;
            }
        }
    }
    out.items.len = write;
}

/// Does the lost-race marker match `tok` byte-for-byte? A marker for any
/// other token is stale and ignored.
fn skippedToken(gpa: std.mem.Allocator, io: std.Io, tok: journal.Token) bool {
    const b = Dir.cwd().readFileAlloc(io, journal_skip_path.get(), gpa, .limited(64)) catch return false;
    defer gpa.free(b);
    return std.mem.eql(u8, b, &journal.encode(tok));
}

fn journalDisabled() bool {
    const v = std.c.getenv("GIST_NO_JOURNAL") orelse return false;
    const s = std.mem.span(v);
    return s.len != 0 and !std.mem.eql(u8, s, "0") and
        !std.ascii.eqlIgnoreCase(s, "false") and !std.ascii.eqlIgnoreCase(s, "no");
}

/// Past this many replayed file paths the per-path confirm stats stop being
/// decisively cheaper than the walk (and the base is stale enough that a
/// compaction is due anyway).
const max_journal_changes: usize = 8192;

/// Does any DIRECTORY component of `path` sit in the corpus skip set? The
/// walk never enters such subtrees, so a journaled change under one must not
/// widen a candidate set. The basename is deliberately NOT checked — a FILE
/// named like a skip dir is corpus-admissible, exactly as the walk sees it.
fn underSkippedDir(path: []const u8) bool {
    var rest = path;
    while (std.mem.indexOfScalar(u8, rest, '/')) |i| {
        if (haystack.isSkipDir(rest[0..i])) return true;
        rest = rest[i + 1 ..];
    }
    return false;
}

/// The journal fast path: answer `walkFresh` from the OS filesystem journal
/// (macOS FSEvents historical replay — `tree/journal.zig`) instead of the
/// whole-tree stat walk. Sound by construction against the SAME local-VFS
/// model the walk already assumes (header above): a token minted BEFORE the
/// base build covers every vnode change in (token, now) ⊇ (built_ns, now),
/// each replayed path is then re-confirmed by the walk's own metadata
/// predicate (`needsLiveRead`), and every doubt — foreign device, dropped
/// events, rescan hints, id wrap, deadline, flood — falls back to the walk.
/// Walk-parity choices: directory events are dropped (the walk emits files
/// only, and files inside a renamed directory keep pre-anchor metadata under
/// either strategy); a path whose live lstat is not a regular file is dropped
/// (the walk never yields symlinks/specials) — but an UNSTATTABLE path is
/// kept, conservatively fresh, which is how deleted files become tombstones
/// (a strict superset of the walk, which cannot see deletions at all).
/// False ⇒ run the walk.
fn journalFresh(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, built_ns: i128, a: std.mem.Allocator, out: *std.ArrayList([]const u8)) bool {
    if (comptime !journal.supported) return false;
    if (journalDisabled()) return false;
    const trace = std.c.getenv("GIST_JOURNAL_TRACE") != null;
    const t0 = std.Io.Clock.now(.awake, io).nanoseconds;
    const tok = readJournalToken(gpa, io) orelse return false;
    if (tok.captured_ns > built_ns) return false; // blind window before the anchor
    if (skippedToken(gpa, io, tok)) {
        if (trace) std.debug.print("journal: skipped (lost the race for this token)\n", .{});
        return false;
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var entries: std.ArrayList(journal.Entry) = .empty;
    if (!journal.replay(gpa, io, roots, tok, journal.query_budget_ns, arena.allocator(), &entries)) {
        // Remember the loss for THIS token: on a busy tree the event window
        // only grows, so re-probing every query is a pure tax. A new build/
        // amend mints a new token and re-arms the attempt.
        persist.writeAtomic(io, journal_skip_path.get(), &journal.encode(tok)) catch {};
        return false;
    }
    const t1 = std.Io.Clock.now(.awake, io).nanoseconds;
    if (trace) std.debug.print("journal: replay {d:.1} ms ({d} entries)\n", .{ @as(f64, @floatFromInt(t1 - t0)) / 1e6, entries.items.len });
    if (entries.items.len > max_journal_changes) return false;

    const start = out.items.len;
    journalCollect(gpa, io, built_ns, entries.items, a, out) catch {
        out.items.len = start; // partial journal answer is no answer
        return false;
    };
    const t2 = std.Io.Clock.now(.awake, io).nanoseconds;
    if (trace) std.debug.print("journal: confirm {d:.1} ms ({d} kept)\n", .{ @as(f64, @floatFromInt(t2 - t1)) / 1e6, out.items.len - start });
    retainAdmitted(io, roots, a, out, start);
    if (trace) std.debug.print("journal: admit {d:.1} ms ({d} admitted)\n", .{ @as(f64, @floatFromInt(std.Io.Clock.now(.awake, io).nanoseconds - t2)) / 1e6, out.items.len - start });
    return true;
}

/// Filter + confirm the raw replay into walk-shaped fresh paths (see
/// `journalFresh` for the parity argument behind each drop/keep). Directory
/// entries are dropped up front (the walk emits files only); everything else
/// runs the shared confirm pipeline.
fn journalCollect(gpa: std.mem.Allocator, io: std.Io, built_ns: i128, entries: []const journal.Entry, a: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(gpa);
    for (entries) |e| if (!e.is_dir) try files.append(gpa, e.path);
    try confirmRaw(gpa, io, built_ns, files.items, a, out);
}

/// Confirm + admit an externally-sourced repo-relative changed-path list (the
/// resident daemon's annals answer) into walk-shaped fresh paths — the same
/// dedupe / skip-dir / live-stat (`needsLiveRead`) / ignore-admission pipeline
/// the journal fast path applies to its replay, so a daemon answer and a
/// journal answer describe the same corpus surface. The source has no kind
/// information (the annals note directories too), which the live stat absorbs:
/// a statable non-file drops, a vanished path stays conservatively fresh.
/// False ⇒ partial (OOM); `out` is restored and the caller falls back.
pub fn confirmChanged(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, since_ns: i128, raw: []const []const u8, a: std.mem.Allocator, out: *std.ArrayList([]const u8)) bool {
    const start = out.items.len;
    confirmRaw(gpa, io, since_ns, raw, a, out) catch {
        out.items.len = start; // a partial answer is no answer
        return false;
    };
    retainAdmitted(io, roots, a, out, start);
    return true;
}

/// The shared confirm pipeline: dedupe, drop walk-skipped subtrees, then hold
/// each path to the stat walk's own keep/drop predicate against live metadata.
fn confirmRaw(gpa: std.mem.Allocator, io: std.Io, since_ns: i128, raw: []const []const u8, a: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
    var seen = std.StringHashMap(void).init(gpa);
    defer seen.deinit();
    for (raw) |path| {
        if (underSkippedDir(path)) continue;
        if ((try seen.getOrPut(path)).found_existing) continue;
        const keep = if (Dir.cwd().statFile(io, path, .{ .follow_symlinks = false })) |st|
            st.kind == .file and bulkstat.needsLiveRead(since_ns, st.mtime.nanoseconds, st.ctime.nanoseconds)
        else |_|
            true; // vanished/unstatable: conservatively fresh (deletion → tombstone)
        if (keep) try out.append(a, try a.dupe(u8, path));
    }
}

/// The fresh-path source of truth: the journal fast path when the OS
/// filesystem journal can answer without a walk (`journalFresh` — already
/// self-admitted and short-circuiting), otherwise the self-balancing
/// work-stealing metadata sweep in `sweep.zig`. Either way the raw result is
/// certified through the canonical ignore engine (`retainAdmitted`) before any
/// new path can widen a persisted index candidate set — metadata traversal is
/// deliberately optimized independently of content loading, so admission is the
/// one gate both strategies converge on.
fn walkFresh(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, built_ns: i128, a: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
    if (journalFresh(gpa, io, roots, built_ns, a, out)) return;
    const start = out.items.len;
    try sweep.run(gpa, io, roots, built_ns, a, out);
    retainAdmitted(io, roots, a, out, start);
}
