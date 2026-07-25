//! The candidate walk every warm answer face shares — compile, prune, visit.
//!
//! No face here decides what an answer looks like; each one only decides which
//! documents deserve to be looked at, and in what order. That split is what
//! keeps the five faces (`fold.zig`, `stream.zig`, `present.zig`) from drifting:
//! they cannot prune differently because they all prune through `candidateIds`,
//! and they cannot disagree about which doc is live because they all walk
//! through the same `each*` pair (trigram-pruned base, then the bounded
//! overlay whose docs are always visited directly — the index is stale for
//! exactly those).
//!
//! Two comptime seams keep the walk free of per-face branching. A visitor is
//! any type with `visit(path, bytes, nul)`; it MAY also expose `stop: bool` to
//! abandon the walk early (`wantsStop` compiles the check away for the ones that
//! don't), and a search sink MAY expose `runBudget()` to bound the gather
//! (`sinkBudget` resolves to an empty budget for the ones that don't).

const std = @import("std");
const corpus_mod = @import("../../../../corpus/tree/corpus.zig");
const answer = @import("answer.zig");
const resident = @import("../warm/resident.zig");
const query_mod = @import("../../../../kernel/match/query/query.zig");
const ResidentSession = resident.ResidentSession;
const PathFilter = resident.PathFilter;
const Admit = answer.Admit;
const CancelToken = answer.CancelToken;
const Ceiling = answer.Ceiling;
const DocRef = answer.DocRef;
const QueryError = answer.QueryError;
const RunBudget = answer.RunBudget;
const CompiledQuery = query_mod.CompiledQuery;
const Scratch = query_mod.Scratch;
const Mode = resident.Mode;
const Request = resident.Request;
const Dir = std.Io.Dir;

/// Compile the request's pattern for `mode` through the shared core; a
/// pattern it declines routes to the certified cold fallback.
/// Case state lowers through `effectiveIgnoreCase` — the single smart-case
/// resolution site — so the engine fold AND the compiled query's
/// `caseless` (which drives the trigram-prefilter decline) both see the
/// RESOLVED value, exactly as cold's finalize fold produces it.
pub fn compileFor(self: *ResidentSession, req: Request, mode: Mode) QueryError!answer.Answer(CompiledQuery) {
    const compiled = CompiledQuery.compile(self.gpa, .{
        .pattern = req.pattern,
        .mode = mode,
        .fixed = req.fixed,
        .ignore_case = req.effectiveIgnoreCase(),
        .unicode = req.unicode,
        // `-w`: the shared core owns the word-valid span decision, so every
        // face (docMatches for -l, countLines for -c, collectSpans for the
        // record stream) applies cold's exact rule. The word check runs on
        // the ORIGINAL bytes regardless of the case fold above.
        .word = req.word,
        // `-m N`: the per-file count cap (`null` ⇒ 0 ⇒ unlimited). `-m0`
        // (match nothing) never reaches here — every entry point below
        // short-circuits `req.matchNothing()` before compiling.
        .max_count = req.max_count orelse 0,
        // `-P`: compile the regex body through the PCRE2 backend behind the
        // shared `Matcher` seam (lookaround/backreferences the linear engine
        // declines). A pattern PCRE2 rejects returns
        // `freshness_unprovable` → certified cold fallback, exactly like a
        // linear-syntax decline.
        .pcre = req.pcre,
    }) catch |e| return if (e == error.OutOfMemory)
        QueryError.OutOfMemory
    else
        .{ .declined = .freshness_unprovable };
    return .{ .got = compiled };
}

/// Gather searchable docs (base ∪ overlay − tombstones) into a path-sorted
/// slice, shared by the `lines` renderer and the FFI record stream. Positive
/// searches require the whole-doc match gate; invert admits every text doc
/// because any one of its lines may be selected. Off the
/// watcher-clean path a matching doc is then existence-checked (the same
/// fail-closed stat-per-hit `query` uses) so a file removed in the
/// walk→report window is never reported. `admit` selects the binary policy
/// (see `Admit`). The sort is `run.pathLess` — the warm canonical file
/// order (see `answer.docLess`) — so downstream output is deterministic. `budget`
/// is the hosted record stream's cooperative halt (`cancel`/`timeout_ns`):
/// on trip the gather stops CLEANLY with a partial doc set (no `Stale`), so
/// a scan that emits few or no records still respects the caller's budget;
/// it is empty for the daemon `lines` faces, whose completeness the session
/// ceiling guards instead.
pub fn matchingDocs(self: *ResidentSession, arena: std.mem.Allocator, cq: *const CompiledQuery, filter: PathFilter, sc: *Scratch, admit: Admit, invert: bool, budget: RunBudget, ceil: Ceiling) QueryError![]const DocRef {
    var g = Gather{ .arena = arena, .io = self.io, .cq = cq, .sc = sc, .admit = admit, .require_match = !invert, .check_exists = !self.seqlock.provenClean(), .cancel = budget.cancel, .deadline_ns = budget.deadline_ns };
    if (invert) try eachDoc(self, filter, &g, ceil) else try eachCandidate(self, cq, filter, &g, ceil);
    std.mem.sort(DocRef, g.docs.items, {}, answer.docLess);
    return g.docs.items;
}

/// Walk every live document without trigram pruning. Invert-match needs this:
/// a document excluded by the positive candidate set may be entirely made of
/// selected nonmatching lines.
pub fn eachDoc(self: *ResidentSession, filter: PathFilter, v: anytype, ceil: Ceiling) QueryError!void {
    for (self.mir.paths, self.mir.docs, self.mir.nuls, 0..) |path, bytes, nul, i| {
        if (ceil.over(self.io, i)) {
            self.noteBudgetAbort();
            return;
        }
        if (self.overlay.contains(path)) continue;
        if (!filter.admits(path)) continue; // out-of-scope for a scoped `-v` walk
        try v.visit(path, bytes, nul);
        if (wantsStop(v)) return;
    }
    var it = self.overlay.iterator();
    while (it.next()) |e| switch (e.value_ptr.*) {
        .tombstone => {},
        .doc => |d| {
            if (!filter.admits(e.key_ptr.*)) continue;
            try v.visit(e.key_ptr.*, d.bytes, d.nul);
            if (wantsStop(v)) return;
        },
    };
}

/// Walk every candidate doc through `v.visit(path, bytes, nul)`: first the
/// trigram-pruned base docs (`candidateIds`) that are not overlaid, then
/// the overlay's replacement docs — the visitor verifies each with the
/// shared match kernel. Overlay docs (changed/new since the build) are
/// always visited directly — the index is stale for exactly those. Shared
/// by the files/count fold (`Accumulator`) and the doc gather (`Gather`),
/// so every answer face prunes candidates identically.
pub fn eachCandidate(self: *ResidentSession, cq: *const CompiledQuery, filter: PathFilter, v: anytype, ceil: Ceiling) QueryError!void {
    var cand_buf: ?[]u32 = null;
    defer if (cand_buf) |c| self.gpa.free(c);
    try eachBase(self, try candidateIds(self, cq, filter, &cand_buf), v, ceil);
    if (wantsStop(v)) return;
    try eachOverlay(self, filter, v);
}

/// The base half of `eachCandidate`: visit each trigram base candidate id in
/// `cand` that is not shadowed by the overlay. Split out so the `-l`/`-c`
/// fold can SHARD this walk across cores (a contiguous id range per thread,
/// each with its own scratch over the immutable mirror), while the bounded
/// overlay stays serial. `cand` is contiguous and ordered, so a sharded walk
/// yields the same visits in the same per-shard order.
pub fn eachBase(self: *ResidentSession, cand: []const u32, v: anytype, ceil: Ceiling) QueryError!void {
    for (cand, 0..) |id, i| {
        if (ceil.over(self.io, i)) {
            self.noteBudgetAbort();
            return;
        }
        if (self.overlay.contains(self.mir.paths[id])) continue; // overlay owns it
        try v.visit(self.mir.paths[id], self.mir.docs[id], self.mir.nuls[id]);
        if (wantsStop(v)) return; // `-q` early-halt (comptime no-op for other visitors)
    }
}

/// The overlay half of `eachCandidate`: visit each overlay replacement doc.
/// Overlay docs (changed/new since the build) are always visited directly —
/// the index is stale for exactly those. A reconcile tombstones any overlay
/// path that left the walk set, but (as for base docs) a delete can still
/// race the walk→report window, so off the watcher-clean path each visitor
/// existence-checks its match (the same fail-closed stat-per-hit the base
/// docs get); the clean path already tombstoned any delete, keeping the
/// no-stat path. Bounded by the mutation count since build, so always serial.
pub fn eachOverlay(self: *ResidentSession, filter: PathFilter, v: anytype) QueryError!void {
    var it = self.overlay.iterator();
    while (it.next()) |e| switch (e.value_ptr.*) {
        .tombstone => {},
        .doc => |d| {
            if (!filter.admits(e.key_ptr.*)) continue; // out-of-scope overlay doc
            try v.visit(e.key_ptr.*, d.bytes, d.nul);
            if (wantsStop(v)) return;
        },
    };
}

/// The base-doc candidate ids for `cq`: the sound trigram prefilter's index
/// hits (a single required literal → `queryLiteral`; an alternation cover →
/// `queryAny`), or every doc id when nothing is prunable or the index query
/// fails. `buf` owns any index-allocated slice (freed by the caller). Shared
/// by the files/count `answer`, the `lines` renderer, and the FFI match
/// stream (`matchingDocs`) so all faces prune candidates identically.
pub fn candidateIds(self: *ResidentSession, cq: *const CompiledQuery, filter: PathFilter, buf: *?[]u32) QueryError![]const u32 {
    var one: [1][]const u8 = undefined;
    const pf = cq.prefilter(&one);
    const hit: ?[]u32 = switch (pf.len) {
        0 => null,
        1 => self.idx.queryLiteral(self.gpa, pf[0]) catch null,
        else => self.idx.queryAny(self.gpa, pf) catch null,
    };
    const c = hit orelse blk: {
        const all = try self.gpa.alloc(u32, self.mir.docs.len);
        for (all, 0..) |*x, i| x.* = @intCast(i);
        break :blk all;
    };
    buf.* = c; // caller frees the full allocation; the pruned view is a prefix of it
    // Scope BEFORE matching: a `PathFilter` (positional roots today) drops
    // out-of-scope candidate ids in place, so the fold/gather never reads a
    // file outside the query's subtree — the "faster than rg" prune the
    // glob module documents, and the reason warm scoped work ≤ cold scoped
    // work. An empty filter returns `c` untouched (rootless pays nothing).
    return filter.prune(self.mir.paths, c);
}

/// Does `path` still exist right now? The fail-closed stat-per-hit every
/// answer face applies off the watcher-clean path — one definition, so the
/// fold accumulator and the doc gather can never drift on this check.
pub fn fileExists(io: std.Io, path: []const u8) bool {
    _ = Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

/// A walk visitor MAY expose a `stop: bool` to abandon `eachCandidate` early
/// (the `-q` existence halt). The `@hasField` guard is comptime, so a visitor
/// without the field compiles the check away entirely — no runtime branch is
/// added to the fold/gather hot walk.
inline fn wantsStop(v: anytype) bool {
    if (comptime @hasField(std.meta.Child(@TypeOf(v)), "stop")) return v.stop;
    return false;
}

/// The optional cooperative budget a search sink carries into the doc gather.
/// The hosted collector exposes `runBudget()` (its cancel token + deadline) so a
/// scan that never reaches `emit` — a rare pattern, an invert walk, a superset
/// that mostly fails the whole-doc gate — still honors `cancel`/`timeout_ns`.
/// Every other sink (the FFI relay, the parallel-shard buffer) declares none, so
/// the gather runs unbounded and this resolves to an empty budget at comptime.
pub inline fn sinkBudget(sink: anytype) RunBudget {
    const S = std.meta.Child(@TypeOf(sink));
    if (comptime @hasDecl(S, "runBudget")) return sink.runBudget();
    return .{};
}

/// The `matchingDocs` visitor — one admission decision per candidate doc:
/// binary policy, whole-doc gate, existence check, append.
const Gather = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    cq: *const CompiledQuery,
    sc: *Scratch,
    admit: Admit,
    require_match: bool,
    check_exists: bool,
    /// Hosted cooperative budget (both null off the hosted record stream). When
    /// tripped `visit` raises `stop`, so `eachCandidate`/`eachDoc` return early
    /// cleanly with the partial doc set — the collector then bounds the emit.
    cancel: ?*const CancelToken = null,
    deadline_ns: ?i128 = null,
    i: usize = 0,
    stop: bool = false,
    docs: std.ArrayList(DocRef) = .empty,

    fn visit(self: *Gather, path: []const u8, bytes: []const u8, nul: ?usize) QueryError!void {
        if (self.budgetTripped()) {
            self.stop = true;
            return;
        }
        // Cold `--json` skips a doc its 8 KiB `isBinary` window flags; a doc whose
        // first NUL sits past the window is streamed in full. Match that exactly.
        if (self.admit == .json_stream and nul != null and corpus_mod.isBinary(bytes)) return;
        if (self.require_match and !self.cq.docMatches(bytes, self.sc)) return;
        if (self.check_exists and !fileExists(self.io, path)) return;
        try self.docs.append(self.arena, .{ .path = path, .bytes = bytes, .nul = nul });
    }

    /// A hosted `cancel` (checked every visit — an armed-only atomic load, cheap
    /// beside the whole-doc gate that follows) or a `timeout_ns` deadline
    /// (sampled once per `budget_stride` visits, so the clock read amortizes to
    /// noise). Both branches compile to a constant `false` when unarmed.
    inline fn budgetTripped(self: *Gather) bool {
        if (self.cancel) |c| if (c.requested()) return true;
        if (self.deadline_ns) |d| {
            self.i +%= 1;
            if (self.i & answer.budget_stride == 0 and std.Io.Clock.now(.awake, self.io).nanoseconds >= d) return true;
        }
        return false;
    }
};
