//! The read-elision oracle: the indexed→live seam both cold engines
//! admit before they read a byte (fault-channel law 1).
//!
//! The persisted trigram index is an ACCELERATION structure, never a semantic
//! one. It answers, for a path the walk already admitted, "can this file
//! possibly hold a match?" — and when the answer is a proven no AND the file's
//! clocks prove it predates the index's build anchor, the read is elided. A
//! skipped file could not have produced one line of output, so elision is
//! byte-invisible: the walk stays the sole authority on WHAT to search, and
//! every declinature here simply names the live read, which answers identically
//! (just slower). That is why `--no-index`, a missing index, and a stale one are
//! all cost differences rather than faults.
//!
//! `Oracle` is the per-file form the fused parallel walk uses: the walk already
//! learns every file's mtime+ctime for free from its bulk listing
//! (`getattrlistbulk` returns them beside the name), so staleness is decided per
//! file instead of by a second whole-tree stat pass. `Lazy` wraps it in the
//! concurrent loader that walk races against — files walked before the oracle
//! lands are deferred, never blocked on.
//!
//! "Candidate" folds BOTH necessary conditions at assembly time: the trigram
//! prefilter's hits, and the crest sieve's survivors. The sieve is what elides
//! for the literal-free class-repetition patterns (`[0-9a-f]{8}`) the trigram
//! filter concedes entirely — sound here precisely because `Oracle.skip` already
//! refuses any file whose timestamps can't prove it unchanged, which is the
//! exact validity condition of a persisted crest vector.

const std = @import("std");
const args = @import("../argv/args.zig");
const assay = @import("../../../assay/assay.zig");
const bulkstat = @import("../../../corpus/tree/bulkstat.zig");
const crest = @import("../../../kernel/math/crest.zig");
const crest_runtime = @import("../../../corpus/index/crest/runtime.zig");
const fault = @import("../../../fault.zig");
const fresh = @import("../../../corpus/fresh/fresh.zig");
const home = @import("../../../corpus/index/frame/home.zig");
const persist = @import("../../../corpus/index/trigrams/persist.zig");
const portal = @import("../../../portal.zig");
const trigram = @import("../../../corpus/index/trigrams/trigram.zig");

const Dir = std.Io.Dir;
const Opts = args.Opts;

/// The conjunctive cover this run offers the index (`writ.Writ.plan`), or null
/// to prune by the flat OR of `filters` exactly as before. The plan is a
/// STRENGTHENING of the same question, never a different one: `assemble` reads
/// a declined plan as "ask with the filters instead", and a declined filter set
/// as "no candidate set" — neither is ever "no matches".
pub const Plan = []const trigram.Index.Clause;

/// `assemble`'s private control flow (fault-channel law 2). Three of these are
/// declinatures the moment they cross into `build` — "no anchor", "no index",
/// "the table would not pay for itself" each name the live read as the tier that
/// answers correctly — but inside this file they are how an early exit reaches
/// `errdefer`. Named and non-`pub` so they cannot leak into the tier's
/// vocabulary, exactly as the PCRE2 shadow rewriter keeps its `Bail`.
const Err = error{ NoAnchor, NoIndex, NotWorthwhile, OutOfMemory };

/// Compact exact path→doc lookup for a persisted path table. Slots hold only a
/// u32 doc id; collisions probe onward and always compare the full path before
/// returning, so an unknown/new path can never become an indexed false positive.
/// At ≤50% load this is ~128 KiB for today's 16k-file corpus, versus a
/// StringHashMap node for every non-candidate path.
pub const IndexedPaths = struct {
    const empty = std.math.maxInt(u32);

    slots: []u32,
    mask: usize,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator, paths: []const []const u8) std.mem.Allocator.Error!IndexedPaths {
        if (paths.len > std.math.maxInt(usize) / 2) return error.OutOfMemory;
        const capacity = std.math.ceilPowerOfTwo(usize, @max(8, paths.len * 2)) catch return error.OutOfMemory;
        const slots = try gpa.alloc(u32, capacity);
        @memset(slots, empty);
        const table: IndexedPaths = .{ .slots = slots, .mask = capacity - 1, .gpa = gpa };
        for (paths, 0..) |path, doc| {
            var pos = table.slot(path);
            while (slots[pos] != empty) pos = (pos + 1) & table.mask;
            slots[pos] = @intCast(doc);
        }
        return table;
    }

    /// Resolve a WALK-relative path (what the descent hands us, and what rg
    /// prints) against a CHECKOUT-relative table (what the index persisted).
    ///
    /// The rebase lives here rather than at the three call sites because the
    /// coordinate mismatch is a property of this lookup — a table keyed at the
    /// tree root, questioned by a walk rooted wherever the user is standing —
    /// and a caller that forgot would not fail loudly. It would ask for
    /// `README.md` from `services/ai` and be handed the root's doc id: a real
    /// answer about the wrong file. Two callers elide reads off that id and one
    /// serves bytes off it, so the cost of forgetting is a wrong result, not a
    /// slow one. Nothing above this line has to know a coordinate system exists.
    ///
    /// A search run at the tree root — the overwhelmingly common case — pays an
    /// acquire load and a length test.
    pub fn get(self: *const IndexedPaths, paths: []const []const u8, path: []const u8) ?u32 {
        var buf: [portal.max_path]u8 = undefined;
        const key = home.inTree(&buf, path) orelse return null;
        var pos = self.slot(key);
        while (true) {
            const doc = self.slots[pos];
            if (doc == empty) return null;
            if (std.mem.eql(u8, paths[doc], key)) return doc;
            pos = (pos + 1) & self.mask;
        }
    }

    pub fn deinit(self: *IndexedPaths) void {
        self.gpa.free(self.slots);
    }

    fn slot(self: *const IndexedPaths, path: []const u8) usize {
        return @as(usize, @truncate(std.hash.Wyhash.hash(0, path))) & self.mask;
    }
};

/// Why one walked file was, or was not, spared its read.
///
/// `Oracle.skip` answers this as a bool, which is everything the walk needs in
/// order to act and not enough for the run to say anything true about itself
/// afterwards. The three negative causes are not interchangeable, and only one
/// of them is a cost:
///
///   • `candidate` is the index working exactly as designed — the trigrams admit
///     this file as a possible match, so it is read and the answer comes from
///     live bytes.
///   • `unindexed` is a file the index never covered (born since the build, or
///     outside its roots), so there was never a read here to spare.
///   • `stale` is the one that is a LOSS: the file is indexed and its postings
///     would have proven it out, but its clocks reach the build anchor, so those
///     postings no longer describe its bytes and the read is bought back.
///
/// Collapsing those three is why the elision rate — the whole reason the index
/// exists — has never been observable from outside the process, and why a days-
/// old anchor is indistinguishable from a fresh one at the point where it costs
/// you. Separating them lets a finished run report the rate it actually achieved
/// rather than the one its file count implies.
pub const Verdict = enum { elide, stale, unindexed, candidate };

/// Per-worker verdict counts, folded into a run total after the walk. The
/// schema IS `Verdict`, so a cause cannot be counted under a name that does not
/// exist and the tally can never drift from the decision it records.
pub const Rate = assay.Tally(Verdict);

/// The per-file read-elision oracle — `intake.zig`'s `IndexSkip` minus the
/// corpus-wide freshness stat-walk: the walk itself already learns every file's mtime and
/// ctime for free (`getattrlistbulk` returns them with the name), so
/// staleness is decided per file against the persisted build anchor instead of
/// via a second full tree traversal. Elide reading P iff P is indexed, NOT a
/// candidate, AND both timestamps prove it predates the anchor.
/// Equality or unavailable metadata forces a live read.
///
/// `rel` is a PATH, and both clocks are the filesystem's own report, so this is
/// exactly as strong as the model in `corpus/fresh/README.md` and no stronger:
/// a replacement at an indexed path is caught because rename/create advance the
/// new inode's ctime, and a file whose ctime was deliberately rewound below the
/// anchor is the documented out-of-model case where `--no-index` is the answer.
///
/// "Candidate" folds BOTH necessary conditions at assembly time: the trigram
/// prefilter hits AND the crest sieve's survivors (`assemble` clears the
/// bit for a doc whose persisted crest vector falls short of ĝ — sound here
/// precisely because `skip` already refuses any file the timestamps can't
/// prove unchanged, which is the exact validity condition of the persisted
/// vector). The sieve is what elides for literal-free class patterns
/// (`[0-9a-f]{8}`) where the trigram filter concedes (research/crest/).
pub const Oracle = struct {
    p: persist.Persisted,
    indexed: IndexedPaths,
    candidates: std.DynamicBitSet,
    anchor: i128,

    /// The elision decision, resolved into its cause. Membership is tested
    /// BEFORE freshness — the reverse of the order `skip` used — because a file
    /// born since the anchor trips `needsLiveRead` too, and short-circuiting on
    /// that would file every brand-new file under `stale` and inflate the one
    /// number this whole vocabulary exists to report honestly. The reorder is
    /// free in the common case (an unchanged file always paid the lookup) and
    /// costs one hash probe for a changed file, which is the minority by
    /// construction — an anchor whose changed set is the majority is the very
    /// state the verdict is trying to tell you about.
    pub fn judge(self: *const Oracle, rel: []const u8, mtime_ns: ?i128, ctime_ns: ?i128) Verdict {
        const doc = self.indexed.get(self.p.paths.items, rel) orelse return .unindexed;
        if (bulkstat.needsLiveRead(self.anchor, mtime_ns, ctime_ns)) return .stale;
        return if (self.candidates.isSet(doc)) .candidate else .elide;
    }

    pub fn skip(self: *const Oracle, rel: []const u8, mtime_ns: ?i128, ctime_ns: ?i128) bool {
        return self.judge(rel, mtime_ns, ctime_ns) == .elide;
    }
    pub fn deinit(self: *Oracle) void {
        self.candidates.deinit();
        self.indexed.deinit();
        self.p.deinit();
    }
};

/// The elide oracle is built CONCURRENTLY with the walk. Trusted local blobs now
/// map and structurally validate in sub-millisecond time, but sparse posting
/// decode + path-table construction can still lose to a narrow scoped walk.
/// The loader flips `ready`; files walked before that are deferred per-worker
/// (`swarm/crew.zig`'s `Worker.pending`) and elided/searched at the end.
/// Under the local-filesystem model in `corpus/fresh/README.md`, elision stays
/// sound either way: a deferred file still requires both timestamps to predate
/// the anchor before it can be skipped.
pub const Lazy = struct {
    val: ?Oracle = null,
    ready: std.atomic.Value(bool) = .init(false),

    /// Run the indexed→live seam and keep the oracle if it was admitted. Every
    /// declinature this seam can carry names the live read, so the walk only
    /// ever needs to know whether `val` is there — which is what the three
    /// callers each used to spell out for themselves.
    pub fn admit(le: *Lazy, gpa: std.mem.Allocator, io: std.Io, o: Opts, filters: []const []const u8, plan: ?Plan, sieve: crest.Swell) void {
        le.val = switch (build(gpa, io, o, filters, plan, sieve)) {
            .got => |el| el,
            .declined => null,
        };
    }

    pub fn loaderMain(le: *Lazy, gpa: std.mem.Allocator, io: std.Io, o: Opts, filters: []const []const u8, plan: ?Plan, sieve: crest.Swell) void {
        le.admit(gpa, io, o, filters, plan, sieve);
        le.ready.store(true, .release);
    }
};

/// Explicit nested roots usually finish their scoped walk before a fresh index
/// process can load. Rootless searches, `.`, and whole top-level subtrees are
/// broad enough to plausibly amortize it; narrower scopes stay on the live path.
/// This is a pre-load COST heuristic only (the index's real roots are persisted
/// beside it and load with it): a scoped query that declines here just walks
/// live — same answer, no index load.
pub fn broadIndexedRoots(roots: []const []const u8) bool {
    if (roots.len == 0) return true;
    for (roots) |raw| {
        var root = raw;
        while (std.mem.startsWith(u8, root, "./")) root = root[2..];
        root = std.mem.trimEnd(u8, root, "/");
        // Empty / `.` = the whole tree; a single path segment = a top-level
        // subtree of the corpus — both plausibly amortize the index load.
        if (root.len == 0 or std.mem.eql(u8, root, ".")) return true;
        if (std.mem.indexOfScalar(u8, root, '/') == null) return true;
    }
    return false;
}

/// Cheap pre-checks before spawning the loader. Short literals cannot query the
/// trigram index; an active crest sieve admits elision even with NO usable
/// trigram filter — the literal-free class-repetition queries are exactly the
/// sieve's raison d'être. Narrow nested roots qualify too: the loader runs
/// CONCURRENTLY with the walk and the end-of-walk flush never blocks on it
/// (`flushPending` `final=true`), so a scoped walk that outruns the load pays
/// only the per-worker deferral append — while a read-heavy subtree the loader
/// DOES beat gets its candidate reads elided like any broad scan.
pub fn indexElisionWanted(io: std.Io, parsed: args.Parsed, filters: []const []const u8, plan: ?Plan, sieve: crest.Swell) bool {
    const o = parsed.opts;
    if (o.mode == .files or o.no_index) return false;
    // Explicit-file roots elide NOTHING: the index answers "which of the walked
    // files can't match" — but a named file is read no matter what the trigrams
    // say, so loading + decompressing the persisted index and reading the
    // freshness anchor is pure launch-time tax (measured ~1.5 ms on a warm
    // corpus) that only the tree walk ever amortizes. Skip it when every root is
    // a regular file; the mixed / directory / implicit-CWD cases keep it.
    if (rootsAllRegularFiles(io, parsed)) return false;
    return usableFilters(filters) or usablePlan(plan) or sieve.active();
}

/// True iff ≥1 root was given and every one stats as a regular file (a lone
/// `PAT file.txt`, or several explicit files) — the case where index
/// elision is provably useless. Empty roots (implicit CWD walk) or any
/// directory / symlink-to-dir / unstattable root returns false, so a broad or
/// mixed scan still gets the oracle. The stat is one syscall per root, dwarfed
/// by the index load it avoids.
fn rootsAllRegularFiles(io: std.Io, parsed: args.Parsed) bool {
    if (parsed.roots.len == 0) return false;
    for (parsed.roots) |r| {
        const st = Dir.cwd().statFile(io, r, .{}) catch return false;
        if (st.kind != .file) return false;
    }
    return true;
}

/// Every filter can actually be offered to the index (non-empty, no empty
/// filter). A 1- or 2-byte filter reaches the sub-trigram sliver tier
/// (`corpus/index/trigrams/sliver.zig`) rather than the trigram directory
/// directly; that tier declines with `NeedleTooShort` when it cannot pay, and
/// `assemble` reads a decline as "no candidate set", never as "no matches".
fn usableFilters(filters: []const []const u8) bool {
    if (filters.len == 0) return false;
    for (filters) |f| if (f.len == 0) return false;
    return true;
}

/// A plan worth loading the index for. Non-empty is the whole test: the planner
/// already refused every clause it could not witness, and `queryPlan` costs and
/// drops clauses individually. This is deliberately independent of
/// `usableFilters` — the patterns the cover wins hardest on (`\d{4}-\d{2}-\d{2}`,
/// `0x[0-9a-fA-F]{6}`) are exactly the ones whose single-literal extraction is
/// EMPTY, so gating a plan behind a usable filter set would discard the win.
fn usablePlan(plan: ?Plan) bool {
    return if (plan) |p| p.len > 0 else false;
}

/// Once the index has answered, only build the path table when the corpus and
/// provable savings can amortize it. The loader still degrades to a full live
/// read, so declining here changes cost only.
pub fn indexSavingsWorthTable(total: usize, candidates: usize) bool {
    if (total < 1024 or candidates >= total) return false;
    const elidable = total - candidates;
    const quarter = total / 4 + @intFromBool(total % 4 != 0);
    return elidable >= 512 and elidable >= quarter;
}

/// The indexed→live seam (fault-channel law 1): the read-elision oracle, or the reason
/// this run reads live. `--no-index` is the caller making the index absent, and
/// declining is never a fault here — the live walk answers identically, which is
/// what makes the index an acceleration structure and not a semantic one.
fn build(gpa: std.mem.Allocator, io: std.Io, o: Opts, filters: []const []const u8, plan: ?Plan, sieve: crest.Swell) fault.Answer(Oracle) {
    if (o.no_index) return .{ .declined = .index_absent };
    if (!usableFilters(filters) and !usablePlan(plan) and !sieve.active()) return .{ .declined = .not_worthwhile };
    if (assemble(gpa, io, filters, plan, sieve)) |el| return .{ .got = el } else |e| return switch (e) {
        error.NoAnchor, error.NoIndex => .{ .declined = .index_absent },
        error.NotWorthwhile => .{ .declined = .not_worthwhile },
        // A genuine fault in BUILDING the oracle — an allocation failure, an
        // unreadable postings blob. Every persisted artifact fails CLOSED to
        // the live path (`fault.Persist`), so from this query's side the index
        // is simply not there: it loses the elision and nothing else.
        else => .{ .declined = .index_absent },
    };
}

/// Put this run's question to the index and get the candidate docs, or null for
/// "no candidate set" (never "no matches" — the caller then prunes by the sieve
/// alone, or reads live).
///
/// TWO spellings of one question, strongest first. The conjunctive cover states
/// everything the pattern forces and is asked first; the flat OR of `filters` is
/// what a single extracted literal can state, and is both the fallback and the
/// only tier that reaches the sub-trigram sliver (`filters` may hold a 1–2 byte
/// needle; a plan's literals are ≥ `min_literal`). A plan that cannot be
/// witnessed declines with `NeedleTooShort` and we simply ask the weaker
/// question — dropping to a WIDER candidate set can cost reads, never a match.
fn askIndex(gpa: std.mem.Allocator, p: *const persist.Persisted, filters: []const []const u8, plan: ?Plan) Err!?[]u32 {
    if (usablePlan(plan)) {
        if (p.queryPlan(gpa, plan.?)) |c| return answered(p, "cover", c) else |e| try indexAsked(e);
    }
    if (usableFilters(filters)) {
        if (p.queryAny(gpa, filters)) |c| return answered(p, "filters", c) else |e| try indexAsked(e);
    }
    assay.trace(.index, assay.tag ++ "elide tier=none candidates={d}/{d}\n", .{ p.paths.items.len, p.paths.items.len });
    return null;
}

/// Name the tier that answered and how much it admitted. Behind the `.index`
/// lens, so a production run pays one relaxed atomic load — this is the number
/// the certificate's production column is read from, taken from the wired path
/// itself rather than re-derived by a harness.
fn answered(p: *const persist.Persisted, tier: []const u8, cand: []u32) []u32 {
    assay.trace(.index, assay.tag ++ "elide tier={s} candidates={d}/{d}\n", .{ tier, cand.len, p.paths.items.len });
    return cand;
}

/// The one mapping from "the index declined / failed" to this file's control
/// flow. Returning normally means the decline was benign and the caller may ask
/// a weaker question or keep its full scan.
fn indexAsked(e: trigram.QueryError) Err!void {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        // A needle below the trigram floor whose sliver tier could not pay, or
        // an extraction/plan that yielded nothing witnessable. Not a fault and
        // not an empty answer.
        error.NeedleTooShort => {},
        // A corrupt / version-mismatched / truncated postings blob fails CLOSED
        // to the live read, so from this query's side it is simply an index that
        // isn't there — one declinature, not seven faults.
        else => error.NoIndex,
    };
}

/// Fallible half of `build`: every early exit (a missing anchor, an
/// unloadable/unworthwhile index, an OOM) is an error, so `errdefer` sheds the
/// half-built state instead of hand-threading `deinit` down each return path.
/// Those errors are this file's private control flow (`Err`), like the shadow
/// rewriter's `Bail`; `build` is where they become the typed declinature.
fn assemble(gpa: std.mem.Allocator, io: std.Io, filters: []const []const u8, plan: ?Plan, sieve: crest.Swell) Err!Oracle {
    const anchor = fresh.readAnchor(gpa, io) orelse return error.NoAnchor;
    var p = (persist.loadQuiet(gpa, io) catch return error.NoIndex) orelse return error.NoIndex;
    errdefer p.deinit();
    var candidates = try std.DynamicBitSet.initEmpty(gpa, p.paths.items.len);
    errdefer candidates.deinit();
    const cand: ?[]u32 = try askIndex(gpa, &p, filters, plan);
    if (cand) |c| {
        defer gpa.free(c);
        for (c) |d| candidates.set(d);
    } else {
        // Sieve-only elision: every doc starts as a candidate; the crest
        // subtraction below is the sole pruning criterion.
        candidates.setRangeValue(.{ .start = 0, .end = p.paths.items.len }, true);
    }
    // Crest sieve: clear docs whose persisted crest vector provably falls short
    // of EVERY alternative's ĝ. Valid because `Oracle.skip` refuses any file whose
    // timestamps can't prove it predates the anchor — exactly when the vector
    // describes live bytes.
    if (sieve.active()) {
        if (p.crest) |table| {
            const ranked = sieve.ranked();
            _ = try crest_runtime.apply(gpa, table, &candidates, ranked);
        } else if (cand == null) {
            // No table to sieve with and no trigram filter either — nothing
            // can be elided; decline rather than build a can't-prune oracle.
            return error.NotWorthwhile;
        }
    }
    const worth = indexSavingsWorthTable(p.paths.items.len, candidates.count());
    reportCandidateBytes(io, &p, &candidates, worth);
    if (!worth) return error.NotWorthwhile;
    const indexed = try IndexedPaths.init(gpa, p.paths.items);
    return .{ .p = p, .indexed = indexed, .candidates = candidates, .anchor = anchor.ns() };
}

/// Gate-only: the SIZE of the admitted candidate set, in the bytes a reader
/// would actually have to scan. The persisted index stores no per-document
/// length, so this is a stat per candidate — far too costly to put on a query,
/// and the reason it hides behind `<prefix>CANDIDATE_BYTES` (internal, undocumented
/// — the `<prefix>TEST_REQUIRE_ELISION` idiom) instead of riding the `.index` lens.
///
/// It exists so the certificate's production column is read off the WIRED path
/// rather than re-derived by a harness that might ask a subtly different
/// question. Measured after the crest subtraction, so it is the oracle's real
/// final candidate set and not just the trigram answer — and reported even when
/// the saving does not clear `indexSavingsWorthTable`, because `worth=0` means
/// the run went on to read the WHOLE corpus and a report that stayed silent
/// there would quietly omit the planner's worst cases from its own average.
fn reportCandidateBytes(io: std.Io, p: *const persist.Persisted, candidates: *const std.DynamicBitSet, worth: bool) void {
    if (!assay.knobFlag("CANDIDATE_BYTES")) return;
    var bytes: u64 = 0;
    var total: u64 = 0;
    for (p.paths.items, 0..) |path, doc| {
        const st = Dir.cwd().statFile(io, path, .{}) catch continue;
        total += st.size;
        if (candidates.isSet(doc)) bytes += st.size;
    }
    assay.diag(assay.tag ++ "elide candidate_bytes={d} corpus_bytes={d} candidate_docs={d}/{d} worth={d}\n", .{ bytes, total, candidates.count(), p.paths.items.len, @intFromBool(worth) });
}

/// Gate-only proof that the admitted oracle can actually elide a real indexed
/// file with live metadata. This runs only under `<prefix>TEST_REQUIRE_ELISION`;
/// production queries pay no probe or counter overhead.
pub fn testHasElidableFile(io: std.Io, el: *const Oracle) bool {
    for (el.p.paths.items, 0..) |path, doc| {
        if (el.candidates.isSet(doc)) continue;
        const st = Dir.cwd().statFile(io, path, .{}) catch continue;
        if (el.skip(path, st.mtime.nanoseconds, st.ctime.nanoseconds)) return true;
    }
    return false;
}

test "IndexedPaths resolves exactly and reads unknown paths" {
    const t = std.testing;
    const paths = [_][]const u8{ "libs/a.zig", "services/b.go", "clients/c.ts" };
    var indexed = try IndexedPaths.init(t.allocator, &paths);
    defer indexed.deinit();

    try t.expectEqual(0, indexed.get(&paths, "libs/a.zig"));
    try t.expectEqual(2, indexed.get(&paths, "clients/c.ts"));
    try t.expectEqual(null, indexed.get(&paths, "libs/new.zig"));

    var buf: [32]u8 = undefined;
    var collision_checked = false;
    for (0..1024) |i| {
        const unknown = try std.fmt.bufPrint(&buf, "new/path-{d}", .{i});
        if (indexed.slot(unknown) != indexed.slot(paths[0])) continue;
        try t.expectEqual(null, indexed.get(&paths, unknown));
        collision_checked = true;
        break;
    }
    try t.expect(collision_checked);
}

test "index table policy requires a material saving" {
    const t = std.testing;
    try t.expect(!indexSavingsWorthTable(1023, 0));
    try t.expect(indexSavingsWorthTable(16_000, 12_000));
    try t.expect(!indexSavingsWorthTable(16_000, 12_001));
    try t.expect(!indexSavingsWorthTable(16_000, 16_000));
}

test "index loading stays off narrow explicit roots" {
    const t = std.testing;
    try t.expect(broadIndexedRoots(&.{ "libs", "services" }));
    try t.expect(broadIndexedRoots(&.{"."}));
    try t.expect(!broadIndexedRoots(&.{"src/kernel"}));
    try t.expect(!broadIndexedRoots(&.{"/tmp/corpus"}));
}

test "skip: the three conditions are each necessary, over a real persisted pair" {
    const t = std.testing;
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const out_dir = try std.fmt.allocPrint(t.allocator, "/tmp/gist_elide_skip_{x}", .{@intFromPtr(&threaded)});
    defer t.allocator.free(out_dir);
    Dir.cwd().deleteTree(io, out_dir) catch {};
    defer Dir.cwd().deleteTree(io, out_dir) catch {};

    // A real published pair, so the oracle is asked over the same path table and
    // doc space production hands it — not a hand-built stand-in.
    const docs = [_][]const u8{ "alpha cat purrs", "beta dog barks" };
    const paths = [_][]const u8{ "a.txt", "b.txt" };
    var idx = try trigram.Index.build(t.allocator, &docs);
    defer idx.deinit();
    _ = try persist.persistIndexAndPathsAt(t.allocator, io, out_dir, &idx, &paths, &.{"."}, null, 0);

    const anchor: i128 = 1_000;
    var el: Oracle = .{
        .p = (try persist.loadAt(t.allocator, io, out_dir, false)).?,
        .indexed = try IndexedPaths.init(t.allocator, &paths),
        .candidates = try std.DynamicBitSet.initEmpty(t.allocator, paths.len),
        .anchor = anchor,
    };
    defer el.deinit();
    el.candidates.set(0); // doc 0 is a candidate, doc 1 is not

    // The only elidable combination: indexed ∧ not a candidate ∧ both clocks
    // strictly behind the anchor. It is what makes elision byte-invisible — a
    // file the prefilter proved cannot match, whose bytes the anchor covers.
    try t.expect(el.skip("b.txt", anchor - 1, anchor - 1));

    // Drop each conjunct in turn; each alone must restore the live read.
    try t.expect(!el.skip("a.txt", anchor - 1, anchor - 1)); // a candidate: must be read
    try t.expect(!el.skip("c.txt", anchor - 1, anchor - 1)); // never indexed: unknown bytes
    try t.expect(!el.skip("b.txt", anchor, anchor - 1)); // mtime on the anchor tick
    try t.expect(!el.skip("b.txt", anchor - 1, anchor)); // ctime on it — the `touch -r` half
    try t.expect(!el.skip("b.txt", null, anchor - 1)); // metadata absent, not proven old
    try t.expect(!el.skip("b.txt", anchor - 1, null));
}
