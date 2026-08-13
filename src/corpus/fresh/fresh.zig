//! irregex T3 — local-filesystem freshness overlay. A persisted trigram index
//! only elides a live read when the path was indexed and both filesystem change
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
//! in `README.md` § The model — a local filesystem whose reported ctime advances
//! to the anchor tick or later for a completed ordinary write, and a primary
//! live walk that reports traversal failures. That conditional is the claim;
//! anything stronger would be a promise about someone else's filesystem.
//! Deliberately backdating both clocks, network/cache incoherence, and writes
//! racing the metadata/read window are outside a snapshot guarantee. A racing
//! query may resolve to the before- or after-write state; the next query
//! observes the advanced ctime. `git diff HEAD` remains unsound because a
//! coworker's committed change can differ from the older index without
//! appearing in the working-tree diff.
//!
//! Why pay a metadata walk the rest of the indexed field skips: ripgrep is not
//! the comparator (no index, so nothing to elide), and the two engines that do
//! carry one both answer a weaker question. Measured on a corpus mutated after
//! indexing — one file gains the needle, one is added with it, one loses it —
//! csearch returns nothing (it greps live bytes so it never reports absent
//! content, but a file that GAINED the pattern was never a candidate: false
//! negatives only) and zoekt returns the file that lost it (it matches shard-
//! stored content: false positive plus the same misses). Both are correct on
//! their own terms, being built for reindex-on-a-cadence; neither is what a
//! query against a tree ~10 agents are editing needs. See `README.md` § What
//! this package buys for the reproduction.

const std = @import("std");
const assay = @import("../../assay/assay.zig");
const haystack = @import("../tree/haystack.zig");
const ignore = @import("../tree/ignore.zig");
const scope = @import("../scope/filter.zig");
const path_utils = @import("../scope/paths.zig");
const bulkstat = @import("../tree/bulkstat.zig");
const journal = @import("journal.zig");
const frame = @import("../index/frame/frame.zig");
const persist = @import("../index/trigrams/persist.zig");
const sweep = @import("sweep.zig");
const fault = @import("../../fault.zig");
const home = @import("../index/frame/home.zig");
const Dir = std.Io.Dir;

const anchor_path = home.ArtifactPath("built.ns");
const journal_tok_path = home.ArtifactPath(journal.file_name);
/// Lost-race marker: the encoded token of a replay that could not answer
/// within the per-query budget. While the persisted token still matches,
/// later queries skip straight to the walk instead of re-paying the probe;
/// any new token (index build/amend) makes the marker stale and re-arms
/// the fast path. Best-effort on both ends — never load-bearing.
const journal_skip_path = home.ArtifactPath("journal.skip");
/// Moved-anchor marker: the anchor a replay positively proved the corpus has
/// moved away from. Distinct from `journal.skip` — that one records a replay that
/// could not ANSWER, this one records an answer of "yes, something changed", which
/// for a fixed anchor can never later become "no" (see `unmoved`). Keyed to the
/// anchor rather than the token, so a rebuild re-arms it. Best-effort on both
/// ends; never load-bearing.
const moved_path = home.ArtifactPath("fresh.moved");

/// Persist the build instant (wall-clock ns) as the freshness anchor. Atomic
/// (temp-then-rename, see `frame.writeAtomic`) so a concurrent reader never
/// observes a momentarily-truncated anchor file (which would silently disable
/// the freshness overlay for that one query — a soft correctness gap, not a
/// crash, but still avoidable at the same cost as the index/paths writes).
pub fn writeAnchor(io: std.Io, built: assay.Anchor) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(i64, &buf, @intCast(built.ns()), .little); // epoch-ns fits i64 until 2262
    try frame.writeAtomic(io, anchor_path.get(), &buf);
}

/// Persist the filesystem-journal since-token (macOS FSEvents id + device +
/// mint instant). Written at full-build time, and re-written by `journalFresh`
/// each time an empty replay certifies the tree still matches the anchor.
/// Best-effort: a missing token only costs the journal fast path — every
/// freshness question still has the stat walk. Written AFTER the pair
/// publishes, same as the anchor.
pub fn writeJournalToken(io: std.Io, tok: journal.Token) void {
    const bytes = journal.encode(tok);
    fault.spare("write the journal since-token", frame.writeAtomic(io, journal_tok_path.get(), &bytes));
}

/// The persisted journal since-token, or null when absent/undecodable. `pub`
/// so the resident daemon can boot-seed its annals from the same token the
/// one-shot replay rides (`serve.zig`).
pub fn readJournalToken(gpa: std.mem.Allocator, io: std.Io) ?journal.Token {
    const b = Dir.cwd().readFileAlloc(io, journal_tok_path.get(), gpa, .limited(64)) catch return null;
    defer gpa.free(b);
    return journal.decode(b);
}

/// The TRUSTWORTHY anchor — what every freshness proof may be dated against.
/// Null when none was recorded (`anchorOnDisk`) or when the artifacts were
/// built over a DIFFERENT tree (`frame.boundHere`): an anchor dates the files
/// of the directory it was minted in, so a foreign one — younger than every
/// file here — would "prove" the whole tree unchanged. Query callers fail
/// closed to reading every walked file when this proof is absent.
pub fn readAnchor(gpa: std.mem.Allocator, io: std.Io) ?assay.Anchor {
    if (!frame.boundHere()) return null;
    return anchorOnDisk(gpa, io);
}

/// The anchor as RECORDED, without asking whose tree it dates — null only when
/// it is missing, truncated, or in the future. Index status reports through
/// this so a foreign artifact reads as what it is (built then, over there)
/// rather than as an index that never had an anchor at all.
pub fn anchorOnDisk(gpa: std.mem.Allocator, io: std.Io) ?assay.Anchor {
    const b = Dir.cwd().readFileAlloc(io, anchor_path.get(), gpa, .limited(64)) catch return null;
    defer gpa.free(b);
    if (b.len < 8) return null;
    const built_ns: i128 = std.mem.readInt(i64, b[0..8], .little);
    if (built_ns > std.Io.Clock.now(.real, io).nanoseconds) return null;
    return @enumFromInt(built_ns);
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

/// Base trigram candidates for `filters` UNIONNed with every file whose mtime or
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
    if (readAnchor(gpa, io)) |built| {
        anchored = true;
        const a = arena.allocator();
        var freshlist: std.ArrayList([]const u8) = .empty; // arena-owned strings
        try walkFresh(gpa, io, roots, built.ns(), a, &freshlist);
        if (freshlist.items.len > 0) try widen(gpa, paths, &ids, &fresh_ids, freshlist.items);
    } else {
        // Without a trustworthy anchor no indexed non-candidate is provably
        // unchanged. Seed all so the caller declines elision and live-reads.
        ids.clearRetainingCapacity();
        try seedAll(gpa, &ids, paths.items.len);
    }

    return .{ .ids = try ids.toOwnedSlice(gpa), .fresh_ids = try fresh_ids.toOwnedSlice(gpa), .anchored = anchored, .arena = arena, .gpa = gpa };
}

/// The anchor the WHOLE corpus provably still matches, or null when nothing
/// cheap could prove it.
///
/// Freshness is normally asked one file at a time — "do these clocks predate the
/// anchor?" — and asking it that way costs a metadata read per file. That is the
/// largest single line item in a selective cold query: 32.7 ms of a 42 ms
/// `-l <rare-literal>` run over this 20k-file corpus, where the walk that finds
/// those files is 9.3 ms and reading the survivors is 1.5 ms. The per-file shape
/// is also why the phantom membership snapshot cannot help there — a served
/// entry carries no clocks, so under per-file freshness it must buy them back
/// one `lstat` at a time and the snapshot declines rather than lose money.
///
/// But the question a query actually needs is corpus-WIDE, and the OS filesystem
/// journal answers exactly that shape: a replay whose admitted changed-set is
/// EMPTY proves every corpus file predates the anchor in a single round trip
/// whose cost tracks the change window rather than the corpus (12.7 ms measured,
/// and an empty replay re-dates its own token so the window stays the gap
/// between two queries instead of the age of the build).
///
/// So this is not a second freshness rule. It is the same rule — the same
/// `needsLiveRead` over the same anchor — asked once instead of twenty thousand
/// times. A caller holding this anchor may treat every corpus file as
/// clock-proven and collect no metadata at all. `null` is the ordinary path, and
/// is what every non-macOS target, absent token, and journal doubt resolves to.
///
/// Deliberately ONLY the empty case. A non-empty changed-set is a usable ledger
/// too, but consuming one means matching journal path spellings against walk
/// path spellings — and a spelling mismatch there reads as "absent from the
/// changed set", i.e. as *unchanged*, which fails OPEN. An empty answer names no
/// path at all, so it cannot fail that way.
pub fn unmoved(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8) ?i128 {
    const built = readAnchor(gpa, io) orelse return null;
    if (movedToken(gpa, io, built.ns())) {
        if (assay.lit(.journal)) assay.diag("journal: this anchor is already known moved\n", .{});
        return null;
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var changed: std.ArrayList([]const u8) = .empty;
    if (!journalFresh(gpa, io, roots, built.ns(), arena.allocator(), &changed)) return null;
    if (changed.items.len == 0) return built.ns();
    // A replay that positively accounted for ≥1 change has settled this anchor
    // for good: "nothing changed since T" is MONOTONE in time, so once the
    // journal has named an event after T, no later query can find fewer. Reverting
    // the edit does not restore the claim either — the revert is itself an event,
    // and the file's ctime now postdates T regardless of its bytes. So the answer
    // is cached against the anchor, not re-derived: on an actively-edited tree the
    // replay window only widens, and re-paying a whole round trip each query to
    // relearn a fact that cannot change is a pure tax (measured: 21 ms on every
    // cold query over this ten-agent tree). A rebuild moves the anchor and re-arms
    // the probe; `journal.skip` remains the separate, narrower record of a replay
    // that could not answer at all.
    fault.spare(
        "record that this anchor is provably moved",
        frame.writeAtomic(io, moved_path.get(), std.mem.asBytes(&@as(i64, @intCast(built.ns())))),
    );
    return null;
}

/// Has THIS anchor already been proven moved? Any unreadable/short/mismatched
/// marker reads as "unknown" and re-probes — the marker is a cache, never a
/// correctness input, so a stale or truncated one only costs a round trip.
fn movedToken(gpa: std.mem.Allocator, io: std.Io, built_ns: i128) bool {
    const b = Dir.cwd().readFileAlloc(io, moved_path.get(), gpa, .limited(64)) catch return false;
    defer gpa.free(b);
    if (b.len != 8) return false;
    return std.mem.readInt(i64, b[0..8], .little) == @as(i64, @intCast(built_ns));
}

/// `unmoved` proven CONCURRENTLY with the walk — the freshness twin of
/// `elide.Lazy`, and for the same reason. The proof's cost is one fseventsd round
/// trip (~10–15 ms, dominated by IPC rather than by anything the engine does),
/// which is longer than the names-only walk it unlocks (9.3 ms), so asking for
/// it before the walk starts spends more of the query's serial prefix than the
/// per-file clocks it replaces cost in the first place — measured: serial probe
/// 35.8 ms vs 42.4 ms for the ordinary walk, where overlapping should reach the
/// walk's own floor.
///
/// So the walk starts optimistically clock-FREE and defers each file's elision
/// decision (`Worker.pending`, the backlog the oracle already uses). Whichever
/// way this lands, the backlog is resolved correctly: an anchor elides by
/// certificate, and a `null` makes the drain buy the clocks it skipped, one
/// `lstat` per deferred file. That fallback is why the gamble is safe rather than
/// merely likely — it costs a query with no certificate about what the
/// clock-bearing walk would have cost anyway, and never changes an answer.
pub const Certificate = struct {
    anchor: ?i128 = null,
    ready: std.atomic.Value(bool) = .init(false),

    /// Detached-thread entry point. Mirrors `elide.Lazy.loaderMain`: publish the
    /// verdict, then flip `ready` so the waiter can observe it.
    pub fn proveMain(c: *Certificate, gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8) void {
        c.anchor = unmoved(gpa, io, roots);
        c.ready.store(true, .release);
    }

    /// The proven anchor, waited out — and returned as a VALUE, so a caller
    /// latches an immutable verdict instead of polling a live object. That matters
    /// beyond tidiness: a walk that re-read this mid-flight could list some
    /// directories clock-free and others not, depending on when the proof happened
    /// to land.
    ///
    /// There is deliberately no deadline here, and that is not an oversight.
    /// `journal.query_budget_ns` already bounds the prover, so this wait is
    /// bounded by construction — and abandoning it EARLY is strictly worse, not
    /// safer: the process exits, the detached prover dies mid-drain, and the
    /// refusal never reaches `journal.skip`. Measured on a ten-agent tree, a
    /// 25 ms cap turned one 78 ms query per index generation into 27 ms on EVERY
    /// query, because nothing was ever recorded. Waiting for the refusal is what
    /// buys the marker that makes the next thousand queries free.
    ///
    /// It SLEEPS rather than spins, and that is a cost-correctness property
    /// rather than a politeness one: the reply arrives on the prover's own
    /// CoreFoundation run loop, so a core held here is a core it needs to deliver
    /// on. A busy-wait starved the drain past its budget, which made every later
    /// query skip the probe and fall back (measured: 164 ms of system time per
    /// run). The slice is well under the prover's own 5 ms run-loop quantum, so
    /// the verdict is still observed promptly.
    pub fn settle(c: *const Certificate, io: std.Io) ?i128 {
        while (!c.ready.load(.acquire)) std.Io.sleep(io, .fromMicroseconds(200), .real) catch return null;
        return c.anchor;
    }
};

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

fn retainAdmitted(io: std.Io, roots: []const []const u8, a: std.mem.Allocator, out: *std.ArrayList([]const u8), start: usize) error{OutOfMemory}!void {
    var ig = try ignore.Ignore.init(a, io, .{}, roots);
    var write = start;
    for (out.items[start..]) |path| {
        for (roots) |root| {
            if (!scope.underRoot(path, path_utils.stripDot(root))) continue;
            if (try ig.admitsPath(root, path)) {
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

/// Past this many replayed file paths the per-path confirm stats stop being
/// decisively cheaper than the walk (and the base is stale enough that a
/// compaction is due anyway).
const max_journal_changes: usize = 8192;

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
    if (journal.disabled()) return false;
    const trace = assay.lit(.journal);
    var span = assay.Span.open(io);
    // Every refusal below says so on the lens. A silent decline is the one
    // outcome nobody can act on: the caller sees only "walk anyway", which is
    // indistinguishable from the accelerator never having been wired up.
    const tok = readJournalToken(gpa, io) orelse {
        if (trace) assay.diag("journal: no token for this index (nothing to replay from)\n", .{});
        return false;
    };
    // A token minted after the anchor hides (anchor, captured_ns] from the
    // replay — unless an earlier empty replay already certified that span for
    // THIS anchor (`Token.certified_ns`). Equality, not `>=`: a certification
    // names one anchor, and a rebuild moves it.
    if (tok.captured_ns > built_ns and tok.certified_ns != built_ns) {
        if (trace) assay.diag("journal: token postdates the anchor by {d:.1} ms and certifies none of it\n", .{@as(f64, @floatFromInt(tok.captured_ns - built_ns)) / @as(f64, std.time.ns_per_ms)});
        return false;
    }
    if (skippedToken(gpa, io, tok)) {
        if (trace) assay.diag("journal: skipped (lost the race for this token)\n", .{});
        return false;
    }
    // Mint the NEXT token before the stream opens, so a replay that comes back
    // empty is a proof about a span that provably reaches this instant: every
    // event up to `next` is already in the journal when the stream is created,
    // hence inside the historical window it drains. Capturing after the drain
    // would leave the events between the two uncovered.
    const next = journal.capture(io);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var entries: std.ArrayList(journal.Entry) = .empty;
    if (!journal.replay(gpa, io, roots, tok, journal.query_budget_ns, arena.allocator(), &entries)) {
        // Remember the loss for THIS token: on a busy tree the event window
        // only grows, so re-probing every query is a pure tax. A new build/
        // amend mints a new token and re-arms the attempt.
        fault.spare(
            "record the journal-replay loss for this token",
            frame.writeAtomic(io, journal_skip_path.get(), &journal.encode(tok)),
        );
        return false;
    }
    if (trace) assay.diag("journal: replay {d:.1} ms ({d} entries)\n", .{ span.lap(io).ms(), entries.items.len });
    if (entries.items.len > max_journal_changes) return false;
    const start = out.items.len;
    journalCollect(gpa, io, built_ns, entries.items, a, out) catch {
        out.items.len = start; // partial journal answer is no answer
        return false;
    };
    if (trace) assay.diag("journal: confirm {d:.1} ms ({d} kept)\n", .{ span.lap(io).ms(), out.items.len - start });
    retainAdmitted(io, roots, a, out, start) catch {
        out.items.len = start; // admission ran out of memory → no journal answer
        return false;
    };
    if (trace) assay.diag("journal: admit {d:.1} ms ({d} admitted)\n", .{ span.read(io).ms(), out.items.len - start });
    // The journal just answered "nothing in the corpus changed since the
    // anchor" — so the tree still stands exactly as the anchor describes it,
    // and `next` (captured before the stream opened, hence covered by this very
    // replay) may carry that claim forward as a certification. Re-dating here
    // is what stops the window from growing with the age of the build: each
    // query hands the next one a span the width of the gap between them, where
    // a build-pinned token widens until the drain costs more than the walk it
    // replaces and the budget retires it for good.
    //
    // The test is the ADMITTED set, which is the journal's own answer, not the
    // raw event count — and it must be, because this engine's own artifact
    // directory sits inside the walk root by default, so every build, amend,
    // and skip-marker write is a real event under the root that admission then
    // discards. A path admission discards is not in the corpus and so was
    // never indexed and can never be elided; should a later `.gitignore` edit
    // pull it in, that edit is itself a corpus file whose change lands in a
    // later window, and a path absent from the index is live-read regardless.
    //
    // A NON-empty answer certifies nothing: those paths are known only to the
    // caller now reading them, and forgetting them is precisely the blind
    // window this guards.
    if (out.items.len == start) if (next) |n| if (n.dev == tok.dev) {
        writeJournalToken(io, .{ .event_id = n.event_id, .dev = n.dev, .captured_ns = n.captured_ns, .certified_ns = built_ns });
        if (trace) assay.diag("journal: certified for this anchor (window reset)\n", .{});
    };
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
    retainAdmitted(io, roots, a, out, start) catch {
        out.items.len = start;
        return false;
    };
    return true;
}

/// The shared confirm pipeline: dedupe, drop walk-skipped subtrees, then hold
/// each path to the stat walk's own keep/drop predicate against live metadata.
fn confirmRaw(gpa: std.mem.Allocator, io: std.Io, since_ns: i128, raw: []const []const u8, a: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
    var seen = std.StringHashMap(void).init(gpa);
    defer seen.deinit();
    for (raw) |path| {
        if (haystack.underSkippedDir(path)) continue;
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
    try retainAdmitted(io, roots, a, out, start);
}
