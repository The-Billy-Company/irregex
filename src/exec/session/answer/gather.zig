//! The candidate walk every warm answer face shares — compile, prune, visit.
//!
//! No face here decides what an answer looks like; each one only decides which
//! documents deserve to be looked at, and in what order. That split is what
//! keeps the five faces (`fold.zig`, `stream.zig`, `present.zig`) from drifting:
//! they cannot prune differently because they all prune through `candidateIds`,
//! and they cannot disagree about which doc is live because they all walk
//! through the same `each*` pair (index-and-sieve-pruned base, then the bounded
//! overlay — where the index is stale by definition, so the crest sieve is the
//! only prefilter that still speaks, and `Candidates` carries it there).
//!
//! Two comptime seams keep the walk free of per-face branching. A visitor is
//! any type with `visit(path, bytes, nul)`; it MAY also expose `stop: bool` to
//! abandon the walk early (`wantsStop` compiles the check away for the ones that
//! don't), and a search sink MAY expose `runBudget()` to bound the gather
//! (`sinkBudget` resolves to an empty budget for the ones that don't).

const std = @import("std");
const assay = @import("../../../assay/assay.zig");
const corpus_mod = @import("../../../corpus/tree/corpus.zig");
const crest = @import("../../../kernel/math/crest.zig");
const answer = @import("answer.zig");
const resident = @import("../warm/resident.zig");
const query_mod = @import("../../../kernel/query/query.zig");
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
        // declines). A pattern PCRE2 rejects declines exactly like a
        // linear-syntax decline → certified cold fallback.
        .pcre = req.pcre,
        // `CompileError` has exactly two members, so the switch is exhaustive
        // and names each fact once (fault-channel law 1). `Unsupported` is
        // `unsupported_syntax` and NOT `freshness_unprovable`: both route to the
        // same cold fallback, so the mislabel was invisible in routing — but
        // `unsupported_syntax` is the ONLY refusable declinature
        // (`fault.Decline.refused`), the one `--engine linear` converts into a
        // fault because forbidding PCRE2 leaves the fact with no answer
        // anywhere. Spelling it "freshness" told the caller the resident bytes
        // were unproven, which is a different fact with a different remedy.
    }) catch |e| return switch (e) {
        error.OutOfMemory => QueryError.OutOfMemory,
        error.Unsupported => .{ .declined = .unsupported_syntax },
    };
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
/// pruned base docs (`candidateIds`) that are not overlaid, then the overlay's
/// replacement docs the same sieve admits — the visitor verifies each with the
/// shared match kernel. Overlay docs (changed/new since the build) are outside
/// every index tier, so the sieve is the only prefilter that reaches them.
/// Shared by the files/count fold (`Accumulator`) and the doc gather
/// (`Gather`), so every answer face prunes candidates identically.
pub fn eachCandidate(self: *ResidentSession, cq: *const CompiledQuery, filter: PathFilter, v: anytype, ceil: Ceiling) QueryError!void {
    var cand_buf: ?[]u32 = null;
    defer if (cand_buf) |c| self.gpa.free(c);
    const cand = try candidateIds(self, cq, filter, &cand_buf);
    try eachBase(self, cand.ids, v, ceil);
    if (wantsStop(v)) return;
    try eachOverlay(self, filter, &cand.sieve, v);
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

/// The overlay half of `eachCandidate`: visit each overlay replacement doc that
/// the crest sieve cannot rule out. No INDEX tier can speak for these — they
/// changed since the build, which is exactly what the postings no longer
/// describe — but the sieve can, because `OwnedDoc` carries ρ(d) measured off
/// the same live bytes the match would read (`mirror.readDocOwned`). That makes
/// this the one stage where warm prunes something cold cannot: cold's vectors
/// are persisted, so its oracle must refuse every file whose timestamps fail to
/// prove it unchanged. An inert swell prunes nothing by construction
/// (`Swell.prunes` is false at `len == 0` and against a 0⃗ alternative), so the
/// unsieved shape needs no separate branch.
///
/// A reconcile tombstones any overlay path that left the walk set, but (as for
/// base docs) a delete can still race the walk→report window, so off the
/// watcher-clean path each visitor existence-checks its match (the same
/// fail-closed stat-per-hit the base docs get); the clean path already
/// tombstoned any delete, keeping the no-stat path. Bounded by the mutation
/// count since build, so always serial.
pub fn eachOverlay(self: *ResidentSession, filter: PathFilter, sieve: *const crest.Swell, v: anytype) QueryError!void {
    var it = self.overlay.iterator();
    while (it.next()) |e| switch (e.value_ptr.*) {
        .tombstone => {},
        .doc => |d| {
            if (!filter.admits(e.key_ptr.*)) continue; // out-of-scope overlay doc
            if (sieve.prunes(d.crest)) continue; // provably short of every ĝ
            try v.visit(e.key_ptr.*, d.bytes, d.nul);
            if (wantsStop(v)) return;
        },
    };
}

/// The base-doc candidate ids for `cq` — the resident twin of cold's read-
/// elision oracle (`exec/cold/quarry/elide.zig`), and the one place any warm
/// face decides which documents deserve to be looked at.
///
/// Three prunings, in the order cheap-and-strong first. Each is independently
/// declinable and each is a NECESSARY condition on matching, so dropping any of
/// them can only widen the set — never drop a match:
///
///   1. **The index**, asked the strongest question it can answer: the
///      conjunctive cover plan (`winnowFor`) if the pattern forces one, else the
///      flat OR of the sound prefilter literals. Cold's `askIndex` precedence
///      exactly, including the fall-through — a plan the postings cannot witness
///      declines to the weaker question rather than to an empty answer.
///   2. **The crest sieve** over the mirror's per-doc ρ(d), which prunes the
///      class the trigram index concedes: a literal-free class repetition like
///      `[0-9a-f]{8}` has no trigram to ask for, so before this the index
///      admitted 100% of the corpus for those patterns.
///   3. **The path filter**, last because it is the only one that touches
///      strings — the two above are integer work over ids and 16-byte vectors.
///
/// `buf` owns the full allocation; every stage compacts in place, so the
/// returned slice is a prefix view of it and the caller's single free covers it.
pub fn candidateIds(self: *ResidentSession, cq: *const CompiledQuery, filter: PathFilter, buf: *?[]u32) QueryError!Candidates {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const win = winnowFor(arena.allocator(), cq);

    // An index tier's answer still has to be sieved; the no-index tier
    // enumerates THROUGH the sieve, so both arrive here already pruned.
    const kept = if (asked(self, &win, cq)) |c| blk: {
        buf.* = c; // caller frees the full allocation; each prune yields a prefix
        break :blk sieved(self, &win.sieve, c);
    } else try everyDoc(self, &win.sieve, buf);
    // Scope BEFORE matching: a `PathFilter` (positional roots today) drops
    // out-of-scope candidate ids in place, so the fold/gather never reads a
    // file outside the query's subtree — the "faster than rg" prune the
    // glob module documents, and the reason warm scoped work ≤ cold scoped
    // work. An empty filter returns the ids untouched (rootless pays nothing).
    return .{ .ids = filter.prune(self.mir.paths, kept), .sieve = win.sieve };
}

/// The pruned base candidate ids, and the sieve that pruned them.
///
/// The sieve rides along because the base ids are only half the walk: the
/// overlay's docs are outside every index tier's knowledge, and the sieve is the
/// one prefilter that can still speak for them (`eachOverlay`). Handing back the
/// ids alone is what left that half unpruned. `Swell` is a bounded by-value
/// struct, so this copies rather than borrowing the winnow's arena.
pub const Candidates = struct {
    ids: []const u32,
    sieve: crest.Swell = crest.no_sieve,
};

/// Put this query to the resident index, strongest question first, and hand back
/// an OWNED id slice — cold `askIndex`'s precedence over the warm index — or
/// null when no tier could answer (cold's "no candidate set", never "no
/// matches"; `everyDoc` is the fallback cold expresses as a full bitset).
///
/// The cover plan states everything the pattern forces (`if\s+err\s*!=\s*nil`
/// proves `if` AND `err` AND `nil`); the flat OR of `prefilter` literals is what
/// one extracted literal can state, and is both the fallback and the only tier
/// that reaches a sub-trigram sliver. A plan the postings cannot witness
/// declines to the weaker question rather than to an empty answer.
fn asked(self: *ResidentSession, win: *const query_mod.Winnow, cq: *const CompiledQuery) ?[]u32 {
    if (win.plan) |plan| {
        if (self.idx.queryPlan(self.gpa, plan) catch null) |c| return tiered("cover", c, self.mir.docs.len);
    }
    var one: [1][]const u8 = undefined;
    const pf = cq.prefilter(&one);
    const flat: ?[]u32 = switch (pf.len) {
        0 => null,
        1 => self.idx.queryLiteral(self.gpa, pf[0]) catch null,
        else => self.idx.queryAny(self.gpa, pf) catch null,
    };
    if (flat) |c| return tiered("filters", c, self.mir.docs.len);
    return null;
}

/// Every base doc id, admitted through the sieve in ONE pass — the shape the
/// no-index tier takes, and the one place the two stages fuse.
///
/// Enumerating the corpus and then compacting it wrote a u32 per document that
/// the sieve was about to discard, and `tier=none` is precisely the case the
/// sieve exists for: a literal-free class repetition forces no trigram, so the
/// index concedes every document and the wasted write landed on the hot path
/// every time. The allocation is still the corpus-sized upper bound — the
/// survivor count is not known until the walk finishes — so what shrinks is the
/// traffic through it, not the peak.
///
/// Both trace lines are emitted exactly as the two-pass shape emitted them, so
/// the `.index` lens grammar the certificate reads is unmoved.
fn everyDoc(self: *ResidentSession, sieve: *const crest.Swell, buf: *?[]u32) QueryError![]u32 {
    const all = try self.gpa.alloc(u32, self.mir.docs.len);
    buf.* = all; // caller frees the full allocation; the return is a prefix
    _ = tiered("none", all, all.len);
    if (!sieving(self, sieve)) {
        for (all, 0..) |*x, i| x.* = @intCast(i);
        return all;
    }
    var w: usize = 0;
    for (self.mir.crests, 0..) |rho, i| if (!sieve.prunes(rho)) {
        all[w] = @intCast(i);
        w += 1;
    };
    assay.trace(.index, assay.tag ++ "warm sieve candidates={d}/{d}\n", .{ w, all.len });
    return all[0..w];
}

/// Name the index tier that answered and how much it admitted — the warm twin of
/// cold `elide.answered`, so one `GIST_TRACE=index` run reports both tiers in the
/// same grammar and the certificate reads warm's numbers off the wired path.
fn tiered(tier: []const u8, cand: []u32, corpus: usize) []u32 {
    assay.trace(.index, assay.tag ++ "warm tier={s} candidates={d}/{d}\n", .{ tier, cand.len, corpus });
    return cand;
}

/// Both AST-derived prunings for a compiled query, or none. Null `cq.source` is
/// the standing certificate that re-parsing is safe: it is set only for a
/// linear-engine body, so a literal (not regex source) and a PCRE2 body (a
/// grammar this parser does not implement) both arrive here inert.
///
/// Caseless declines the cover for cold's reason (`gate.winnow`): the
/// Unicode-fold bounds are stated once, in `caselessVariants`, and a folded-AST
/// cover would be a second spelling of that argument. The sieve needs no such
/// care — `-i` folds the AST before the calculus reads it. The two env knobs are
/// cold's, so one binary A/Bs both tiers.
fn winnowFor(arena: std.mem.Allocator, cq: *const CompiledQuery) query_mod.Winnow {
    const source = cq.source orelse return .{};
    const want_cover = !cq.caseless and !assay.knobFlag("NO_COVER");
    var win = query_mod.winnow(arena, source, .{ .caseless = cq.caseless, .unicode = cq.unicode }, if (want_cover) .{} else null);
    if (assay.knobFlag("NO_CREST")) win.sieve = crest.no_sieve;
    return win;
}

/// Drop the candidate ids whose crest vector provably falls short of EVERY
/// alternative's ĝ, compacting in place (ids stay ascending, so a sharded walk
/// over the result is unchanged).
///
/// ρ is taken over each doc's WHOLE body while a binary doc is only matched over
/// its pre-NUL region (`mirror.gatedBody`). That direction is the safe one:
/// ρ(whole) ≥ ρ(prefix) componentwise, so a whole-body vector falling short of ĝ
/// means the prefix falls short too. The sieve therefore prunes a subset of what
/// a gated vector would — conservative, never a missed match.
fn sieved(self: *ResidentSession, sieve: *const crest.Swell, ids: []u32) []u32 {
    if (!sieving(self, sieve)) return ids;
    var w: usize = 0;
    for (ids) |d| if (!sieve.prunes(self.mir.crests[d])) {
        ids[w] = d;
        w += 1;
    };
    assay.trace(.index, assay.tag ++ "warm sieve candidates={d}/{d}\n", .{ w, ids.len });
    return ids[0..w];
}

/// Can the sieve speak for this session's BASE docs at all? An inert swell
/// proves nothing, and a crest table that failed to build (or that does not
/// cover every doc) has no vector to speak with — the resident twin of a missing
/// `crest.bin`, which leaves the cold path unpruned the same way. Overlay docs
/// need no such guard: each carries its own vector by construction.
inline fn sieving(self: *ResidentSession, sieve: *const crest.Swell) bool {
    return sieve.active() and self.mir.crests.len == self.mir.docs.len;
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
