//! Narrowing a corpus before reading it: the trigram index and the crest sieve.
//!
//! The difference between a grep and a search engine is that a search engine
//! declines to open most of the corpus. Two mechanisms do that here, and both
//! are sound in the only direction that matters — they may admit a file that
//! cannot match, and never reject one that can.
//!
//! A host building its own index gets neither today, and reimplementing them is
//! not a weekend: the trigram planner has to derive its query from the SAME
//! parse the matcher will run, or it can require a trigram no real match
//! contains.
//!
//! ## The soundness posture — read this before believing an answer
//!
//! Everything in this tier rounds DOWN. The crest sieve takes the longest run
//! a match must force and saturates it; the cover planner drops any clause it
//! cannot bound; a literal below the trigram floor declines instead of
//! guessing. **Under-pruning is the only failure mode.** Every number that
//! could be wrong is wrong in the direction of admitting more work.
//!
//! So a doc id from this tier is a CANDIDATE and never a match:
//!
//!   * the set is a conservative SUPERSET of the documents that match;
//!   * false positives are ordinary and expected — most of them, for a
//!     selective pattern, are documents the index could not rule out;
//!   * the caller MUST still run the matcher over the document's live bytes.
//!
//! A host that reports a candidate as a hit has been misled by this API, not
//! by itself, so the two verbs that answer in doc ids are named for what they
//! are (`candidates`, `readingList`) and neither will ever be named `matches`.
//!
//! ## Two verbs, two different corpora
//!
//! The artifacts describe the bytes that were on disk when `gist index` ran.
//! That is not a caveat, it is the load-bearing distinction between the two
//! answering verbs:
//!
//!   * `candidates` speaks about the corpus **as built**. It is the raw index
//!     answer — cheap, ascending ids, exactly what a host intersecting two
//!     queries wants. A file written after the build may be absent from it.
//!   * `readingList` speaks about the corpus **as it is now**. It folds in
//!     every file whose mtime or ctime is at/after the build anchor, so it is
//!     the verb a grep replacement must use. Ids it invents for files born
//!     after the build extend this handle's id→path table.
//!
//! ## Freshness, and what a bad anchor degrades TO
//!
//! The anchor is a wall-clock instant in epoch NANOSECONDS, written beside the
//! index. `readingList` folds in every file that changed at or after it.
//!
//! Three ways that fails, all with the same consequence and none of them
//! silent — `freshness` reports which one is in force:
//!
//!   * **missing / truncated / in the future** (`unanchored`) — nothing to date
//!     against;
//!   * **bound to another tree** (`foreign`) — an anchor recorded here dates a
//!     different checkout's build;
//!   * **opened away from the artifact home** (`foreign`) — the index came from
//!     an explicit directory, so this tree's anchor does not date it.
//!
//! In every one of them the fold stands down and `readingList` degrades to
//! **every document is a candidate, read elision off** — correct, and as slow
//! as no index at all. That degradation is deliberate; being invisible would
//! not be, which is why it is a verb a host can ask rather than a log line.

const std = @import("std");

const contract = @import("contract.zig");
const rows = @import("rows.zig");
const pat = @import("pattern.zig");

const crest = @import("../../kernel/math/crest.zig");
const fresh = @import("../../corpus/fresh/fresh.zig");
const frame = @import("../../corpus/index/frame/frame.zig");
const home = @import("../../corpus/index/frame/home.zig");
const persist = @import("../../corpus/index/trigrams/persist.zig");
const qy = @import("../../kernel/query/query.zig");
const rx = @import("../../kernel/regex/regex.zig");
const trigram = @import("../../corpus/index/trigrams/trigram.zig");

const Status = contract.Status;
const Ids = contract.Sink(u32);

/// The C ABI's allocator, as everywhere else in this plane: a host owns its own
/// heap and we must not assume a Zig one exists in the process.
const gpa = std.heap.c_allocator;

// ── the loaded narrowing tier ────────────────────────────────────────────────

/// One opened persisted index, its doc→path table, and whatever sidecars stood
/// up beside it. Single-threaded, like every handle on this seam: one thread
/// may use one handle at a time, and two threads may hold two handles.
///
/// It is heap-allocated and never moved because `io` closes over `threaded`.
pub const Sieve = struct {
    threaded: std.Io.Threaded,
    io: std.Io,
    p: persist.Persisted,
    /// Path strings for files born AFTER the build, which a `readingList` fold
    /// discovered and gave ids to. They outlive the call that found them
    /// because the id→path table must stay answerable for the handle's whole
    /// life — an id this tier issued is never allowed to go dark. Released as
    /// one arena by `close`.
    folded: std.heap.ArenaAllocator,
    /// Whether the artifacts were opened at the artifact home. False makes
    /// freshness `foreign` by construction: the anchor lives in the home, so it
    /// cannot date an index that came from somewhere else.
    homed: bool,
};

/// What stood up, so a host can size its buffers and know which of the two
/// prunings it actually has. Append-only; `struct_size` is set by the caller.
pub const Facts = extern struct {
    struct_size: u32,
    /// Documents the postings were built over.
    doc_count: u32,
    /// Entries in the id→path table — the exclusive upper bound on every doc id
    /// this handle will ever hand back. It is `>= doc_count` and GROWS: a
    /// `readingList` fold appends ids for files born after the build.
    path_count: u32,
    posting_count: u32,
    /// Roots the index was built over — the scope a freshness walk covers.
    root_count: u32,
    /// The crest sidecar loaded, so the sieve can prune. Without it the sieve
    /// stands down and only the trigram plan narrows.
    has_crest: u32,
    /// An amend codicil is layered over the base postings. Purely a fact about
    /// how the answer was assembled; it changes no contract above.
    has_codicil: u32,
    reserved: u32,
};

/// Which freshness posture is in force — see the header for what each degrades
/// to. Never inferred from another field: a host asking "may I trust read
/// elision" gets a `switch`, not a conjunction it has to get right.
pub const Freshness = extern struct {
    struct_size: u32,
    /// `anchored` = 1, `unanchored` = 2, `foreign` = 3.
    state: i32,
    /// The recorded build instant in epoch NANOSECONDS, or 0 when there is
    /// none. Non-zero under `foreign`: the anchor exists, it just dates
    /// somebody else's tree, and seeing the instant is how a host recognizes
    /// that.
    anchor_ns: i64,
    reserved: i32,
};

pub const State = enum(i32) {
    anchored = 1,
    unanchored = 2,
    foreign = 3,
};

/// Open the persisted narrowing tier. `dir_len == 0` means the artifact home
/// (`GIST_DIR`, else the tree's `.gist`); any other directory is a deliberate override and
/// costs freshness — see `Sieve.homed`.
///
/// `.stale` when no index has been built: a declinature, not a fault. There is
/// nothing wrong, this corpus simply has no narrowing tier and the host should
/// read every file exactly as it did before.
pub fn open(dir: ?[*]const u8, dir_len: usize, out: ?**Sieve) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    const where = contract.view(dir, dir_len) orelse return .invalid;

    const s = gpa.create(Sieve) catch return contract.report(.{ .code = error.OutOfMemory });
    s.threaded = std.Io.Threaded.init(gpa, .{});
    s.io = s.threaded.io();
    // Assembled by hand rather than with `errdefer`, which a Status-returning
    // entry never fires: each failure below unwinds exactly what the steps
    // before it took, so a declined open leaks nothing into a host that keeps
    // running afterwards.
    const at = if (where.len == 0) home.outDir() else where;
    const loaded = persist.loadAt(gpa, s.io, at, false) catch |e| {
        s.threaded.deinit();
        gpa.destroy(s);
        return contract.reportAny(e, .open_failed);
    };
    const p = loaded orelse {
        s.threaded.deinit();
        gpa.destroy(s);
        return .stale;
    };
    s.p = p;
    s.folded = .init(gpa);
    s.homed = std.mem.eql(u8, at, home.outDir());
    slot.* = s;
    return .ok;
}

/// Release the handle and unmap its artifacts. Teardown leaves the fault slot
/// alone, so a host can still read the detail that made it clean up.
pub fn close(s: *Sieve) void {
    s.folded.deinit();
    s.p.deinit();
    s.threaded.deinit();
    gpa.destroy(s);
}

pub fn facts(s: *const Sieve, out: ?*Facts) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    if (slot.struct_size != @sizeOf(Facts)) return .invalid;
    slot.* = .{
        .struct_size = @sizeOf(Facts),
        .doc_count = s.p.idx.doc_count,
        .path_count = @intCast(s.p.paths.items.len),
        .posting_count = s.p.idx.posting_count,
        .root_count = @intCast(s.p.roots.items.len),
        .has_crest = @intFromBool(s.p.crest != null),
        .has_codicil = @intFromBool(s.p.cod != null),
        .reserved = 0,
    };
    return .ok;
}

/// The path a doc id names, borrowed until this handle closes.
///
/// The indirection is the model and is published rather than hidden: a query
/// answers in ascending ids precisely so a host can intersect, subtract, or
/// bitset two answers without ever comparing strings, and resolve to paths only
/// for the survivors it decides to read.
///
/// An id at or past `Facts.path_count` is `.invalid` — every id a host holds
/// came from this handle, so one that does not resolve is a caller bug and not
/// an absence worth a declinature.
pub fn docPath(s: *const Sieve, doc: u32, out: ?*rows.Text) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    if (doc >= s.p.paths.items.len) return .invalid;
    slot.* = .of(s.p.paths.items[doc]);
    return .match;
}

/// The roots the index was built over — the scope any freshness walk covers,
/// and the only honest answer to "what corpus is this?".
pub fn root(s: *const Sieve, i: u32, out: ?*rows.Text) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    if (i >= s.p.roots.items.len) return .invalid;
    slot.* = .of(s.p.roots.items[i]);
    return .match;
}

// ── asking the index ─────────────────────────────────────────────────────────

/// Candidate docs that may contain `needle`, ascending.
///
/// A raw literal probe, for a host that already knows the exact bytes it is
/// hunting — no parse, no plan, no options to get wrong. `.stale` when the
/// tier cannot bound this needle at all (below the trigram floor with no crest
/// sidecar to name the short documents): a declinature meaning "read
/// everything", and it leaves `*written` untouched so it can never be misread
/// as an empty candidate set.
pub fn literal(s: *Sieve, needle: ?[*]const u8, len: usize, out: ?[*]u32, cap: usize, written: ?*usize) Status {
    contract.beginCall();
    const bytes = contract.view(needle, len) orelse return .invalid;
    if (bytes.len == 0) return .invalid;
    const cand = s.p.queryLiteral(gpa, bytes) catch |e| return declined(e);
    defer gpa.free(cand);
    return emit(cand, out, cap, written);
}

/// Candidate docs that may contain ANY of `needles`, ascending — the union of
/// per-branch supersets, which is a superset of the alternation.
///
/// Sound only because it is a UNION: one branch nothing can bound leaves the
/// whole answer unbounded, and the tier declines rather than return the
/// branches it could do.
pub fn alternation(s: *Sieve, needles: ?[*]const rows.Text, n: usize, out: ?[*]u32, cap: usize, written: ?*usize) Status {
    contract.beginCall();
    const set = needles orelse return .invalid;
    if (n == 0) return .invalid; // an empty alternation is not a question
    const flat = gpa.alloc([]const u8, n) catch return contract.report(.{ .code = error.OutOfMemory });
    defer gpa.free(flat);
    for (flat, set[0..n]) |*dst, src| {
        if (src.len == 0) return .invalid; // an empty branch admits everything
        dst.* = src.slice();
    }
    const cand = s.p.queryAny(gpa, flat) catch |e| return declined(e);
    defer gpa.free(cand);
    return emit(cand, out, cap, written);
}

/// Candidate docs for a winnow, ascending: the cover plan if it can be
/// witnessed, else its flat literal fallback, then the crest sieve subtracted
/// from whichever answered.
///
/// **As built, not as now.** Both prunings read artifacts written at build
/// time, so a file changed since then may be missing here. Use `readingList`
/// for a set that is sound against live bytes; use this one for the raw index
/// answer a host wants to intersect with another.
///
/// `.stale` when nothing could narrow at all.
pub fn candidates(s: *Sieve, w: *const Winnow, out: ?[*]u32, cap: usize, written: ?*usize) Status {
    contract.beginCall();
    const table = if (w.sieve.active()) s.p.crest else null;
    const cand = narrow(s, w) catch |e| return contract.reportAny(e, .open_failed);
    defer if (cand) |c| gpa.free(c);
    if (cand == null and table == null) return .stale;

    var sink = Ids.open(out, cap, written) orelse return .invalid;
    if (cand) |c| {
        for (c) |d| if (!prunes(w, table, d)) sink.push(d);
    } else {
        for (0..s.p.paths.items.len) |i| {
            const d: u32 = @intCast(i);
            if (!prunes(w, table, d)) sink.push(d);
        }
    }
    return sink.close();
}

/// Every document a correct search of the CURRENT tree has to open, ascending.
///
/// `candidates` folded together with freshness: the index answer, minus what
/// the crest sieve rules out, plus every file whose clocks cannot prove it
/// predates the build anchor. A file born after the build is appended to this
/// handle's id→path table and comes back as a new id, so `docPath` resolves it
/// like any other.
///
/// A fresh document is admitted UNCONDITIONALLY — it skips the crest sieve as
/// well as the postings, because both artifacts describe bytes it no longer
/// has. That is the whole reason this verb exists and `candidates` is not
/// enough.
///
/// Without a usable anchor the fold stands down and every document is a
/// candidate. That is correct and slow, and `freshness` says so.
pub fn readingList(s: *Sieve, w: *const Winnow, out: ?[*]u32, cap: usize, written: ?*usize) Status {
    contract.beginCall();
    const total = s.p.paths.items.len;
    const anchor = anchorFor(s) orelse {
        var all = Ids.open(out, cap, written) orelse return .invalid;
        for (0..total) |i| all.push(@intCast(i));
        return all.close();
    };

    var ids: std.ArrayList(u32) = .empty;
    defer ids.deinit(gpa);
    const table = if (w.sieve.active()) s.p.crest else null;
    seed(s, w, table, &ids) catch |e| return contract.reportAny(e, .open_failed);

    // The walk's path strings are appended to `s.p.paths` by `widen`, so they
    // are allocated from the handle's fold arena rather than a call-scoped one:
    // an id this verb invents has to stay resolvable for the handle's life.
    var changed: std.ArrayList([]const u8) = .empty;
    fresh.changedSince(gpa, s.io, s.p.roots.items, anchor, s.folded.allocator(), &changed) catch |e|
        return contract.reportAny(e, .open_failed);
    // `widen`'s `fresh_ids` — the docs whose persisted artifacts no longer
    // describe their bytes — is discharged by ORDER here rather than consulted:
    // the sieve already ran, in `seed`, over the pre-fold set only. So a fresh
    // doc cannot have been content-pruned, and there is nothing left to exempt.
    var exempt: std.ArrayList(u32) = .empty;
    defer exempt.deinit(gpa);
    if (changed.items.len > 0)
        fresh.widen(gpa, &s.p.paths, &ids, &exempt, changed.items) catch |e|
            return contract.reportAny(e, .open_failed);

    std.mem.sort(u32, ids.items, {}, comptime std.sort.asc(u32));
    var sink = Ids.open(out, cap, written) orelse return .invalid;
    var last: ?u32 = null;
    for (ids.items) |d| {
        if (last) |prev| if (prev == d) continue;
        sink.push(d);
        last = d;
    }
    return sink.close();
}

/// Which freshness posture is in force. Cheap — it reads the anchor file and
/// asks whether it dates this tree; it does not walk the corpus.
pub fn freshness(s: *const Sieve, out: ?*Freshness) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    if (slot.struct_size != @sizeOf(Freshness)) return .invalid;
    const recorded = fresh.anchorOnDisk(gpa, s.io);
    const state: State = if (recorded == null)
        .unanchored
    else if (!s.homed or !frame.boundHere())
        .foreign
    else
        .anchored;
    slot.* = .{
        .struct_size = @sizeOf(Freshness),
        .state = @intFromEnum(state),
        .anchor_ns = if (recorded) |r| @intCast(r.ns()) else 0,
        .reserved = 0,
    };
    return .match;
}

/// How many files changed at or after the anchor — how far the artifacts have
/// drifted from the tree.
///
/// Its own verb rather than a `Freshness` field because it costs a corpus walk,
/// and a host asking "may I trust elision" should not have to pay for one.
/// `.stale` when there is no usable anchor: with nothing to date against the
/// honest answer is not zero.
pub fn staleCount(s: *const Sieve, out: ?*usize) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    const anchor = anchorFor(s) orelse return .stale;
    slot.* = fresh.staleCount(gpa, s.io, s.p.roots.items, anchor);
    return .match;
}

// ── the winnow: one parse, both prunings ─────────────────────────────────────

/// Both index prunings for one compiled pattern, and the only way to get
/// either.
///
/// The cover plan and the crest swell are read off a SINGLE `lower.parse` of
/// the same bytes under the same options the matcher compiled with. That is the
/// entire safety property of this tier — see `winnowOf`.
pub const Winnow = struct {
    /// Owns the plan, its literals, and the fallback set.
    arena: std.heap.ArenaAllocator,
    /// The conjunctive cover, in the shape `queryPlan` evaluates: AND over
    /// clauses, OR over a clause's atoms, AND over an atom's literals. Null
    /// when the pattern forces nothing provable, or when the arm declines a
    /// cover (caseless, PCRE2).
    plan: ?[]const trigram.Index.Clause,
    /// The flat literal OR — weaker than the plan, and the fallback when a plan
    /// cannot be witnessed. It is also the only tier that reaches the
    /// sub-trigram sliver, since a plan's literals are all ≥ 3 bytes.
    lits: []const []const u8,
    /// The forced crest per top-level alternative. Prunes a document iff the
    /// document falls short of EVERY alternative.
    sieve: crest.Swell,
    /// The pattern flags as RESOLVED — what the pattern turned out to mean, not
    /// what was asked. `IRGX_SMART_CASE` has become `IRGX_IGNORE_CASE` or
    /// nothing; a leading `(?i)` / `(?s)` has been folded in; `IRGX_FIXED` is
    /// absent because an escaped literal is just a regex by the time anything
    /// here can see it. It is the receipt for the whole design: a host can read
    /// back the semantics its narrowing was derived under.
    flags: u32,
};

/// What the winnow can prune by, for a host deciding whether the apparatus is
/// worth running at all.
pub const WinnowFacts = extern struct {
    struct_size: u32,
    /// The resolved pattern semantics — see `Winnow.flags`.
    flags: u32,
    /// Clauses in the cover plan; 0 when there is none.
    clauses: u32,
    /// Atoms summed across every clause — the posting-decode work a plan costs.
    atoms: u32,
    /// Literals in the flat fallback set.
    literals: u32,
    /// Alternatives in the crest swell.
    alternatives: u32,
    /// The swell can prune something. A swell whose every alternative demands
    /// nothing admits the whole corpus, so this is `active` and not `len > 0`.
    sieve_active: u32,
    /// Nothing here prunes anything: no plan, no literals, no live sieve. A
    /// host should skip the index entirely rather than walk a corpus proving
    /// nothing.
    idle: u32,
};

/// Derive both prunings from an already-compiled pattern handle.
///
/// **This signature is the safety property.** A cover derived under different
/// fold / dotall / multiline options than the matcher will run is not merely
/// imprecise, it is UNSOUND: it can require a trigram that no real match
/// contains, and matching files then vanish from the results with nothing
/// anywhere reporting a problem. So there is no entry point here that takes
/// pattern text, and none that takes a flag word:
///
///   * the only input is an `irgx_regex` — a pattern that has already been
///     compiled, which is to say a parse that has already happened;
///   * the bytes parsed are `Pattern.src`, the exact source that handle
///     compiled, `-F` escaping and any leading `(?i)` directive already
///     resolved into it;
///   * the options are projected from `Pattern.sel`, the resolved selection
///     that handle compiled under, never from anything a caller passes here.
///
/// A host therefore cannot hand over a mismatched parse: it has nowhere to put
/// one. The two spellings that would have made this possible — a text+flags
/// constructor, or a `plan` verb taking a pattern — are deliberately absent,
/// and adding either would remove the guarantee.
///
/// The winnow copies what it needs, so it outlives `re`.
pub fn winnowOf(re: ?*pat.Regex, out: ?**Winnow) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    const handle = re orelse return .invalid;

    const w = gpa.create(Winnow) catch return contract.report(.{ .code = error.OutOfMemory });
    w.* = .{
        .arena = .init(gpa),
        .plan = null,
        .lits = &.{},
        .sieve = crest.no_sieve,
        .flags = republish(handle.inner.sel),
    };
    derive(w, handle) catch {
        w.arena.deinit();
        gpa.destroy(w);
        return contract.report(.{ .code = error.OutOfMemory });
    };
    slot.* = w;
    return .ok;
}

pub fn winnowFree(w: *Winnow) void {
    w.arena.deinit();
    gpa.destroy(w);
}

pub fn winnowFacts(w: *const Winnow, out: ?*WinnowFacts) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    if (slot.struct_size != @sizeOf(WinnowFacts)) return .invalid;
    var atoms: usize = 0;
    if (w.plan) |p| for (p) |c| {
        atoms += c.len;
    };
    const live = w.sieve.active();
    slot.* = .{
        .struct_size = @sizeOf(WinnowFacts),
        .flags = w.flags,
        .clauses = if (w.plan) |p| @intCast(p.len) else 0,
        .atoms = @intCast(atoms),
        .literals = @intCast(w.lits.len),
        .alternatives = w.sieve.len,
        .sieve_active = @intFromBool(live),
        .idle = @intFromBool(w.plan == null and w.lits.len == 0 and !live),
    };
    return .ok;
}

// ── internals ────────────────────────────────────────────────────────────────

/// Fill the winnow from the handle's own source and resolved selection. The one
/// place either is read, so no other code path can substitute a different
/// parse.
fn derive(w: *Winnow, re: *const pat.Regex) error{OutOfMemory}!void {
    const a = w.arena.allocator();
    const sel = re.inner.sel;
    // Copied so the winnow outlives the pattern handle.
    const src = try a.dupe(u8, re.inner.src);
    // The `Matcher` seam's literals: the guaranteed required literal, else the
    // per-branch alternation cover. Engine-neutral, so a PCRE2 body and a
    // linear body prune by the identical set.
    var one: [1][]const u8 = undefined;

    if (sel.pcre) {
        // PCRE2 denotes the pattern under its OWN grammar, so neither the cover
        // nor the swell may be read off this package's AST — that is the
        // dual-parser hazard the whole file exists to prevent, and it is worst
        // exactly where a pattern reached PCRE2 *because* the linear grammar
        // could not express it. `-P` keeps the engine-neutral literals and
        // loses the two AST-derived prunings, which costs reads and never a
        // match. Mirrors `exec/cold/writ/gate.zig::winnow`.
        w.lits = try keep(a, qy.matcherPrefilter(&re.inner.engine, &one));
        return;
    }

    // The handle's own resolved selection, projected by the selection itself, so
    // this parse cannot drift from the one the matcher was compiled under. A
    // cover read under different options prunes files a real match was in.
    const opts = sel.lowerOptions();

    // Caseless stands the PLAN down, not the sieve: a folded AST's cover atoms
    // would have to be case-expanded to stay sound, and `caselessVariants` is
    // the one place the Unicode-fold bounds are stated. The sieve needs no such
    // care — the fold happens before the calculus reads the AST.
    const won = qy.winnow(a, src, opts, if (sel.caseless) null else .{});
    w.plan = won.plan;
    w.sieve = won.sieve;
    w.lits = if (!sel.caseless)
        try keep(a, qy.matcherPrefilter(&re.inner.engine, &one))
    else
        try foldedLiterals(a, src, sel);
}

/// The caseless fallback set. The fold erased the matcher's `required`, so the
/// literal is mined from an UNFOLDED twin parse and case-expanded by the one
/// routine that knows which orbits stay inside ASCII. A twin that will not
/// compile, or a literal nothing can expand, yields the empty set — no
/// narrowing, never a wrong narrowing.
fn foldedLiterals(a: std.mem.Allocator, src: []const u8, sel: rx.Caps.Selection) error{OutOfMemory}![]const []const u8 {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    // The selection's own projection, with the fold deliberately dropped: this
    // compiles the UNFOLDED pattern and `caselessVariants` applies the fold after,
    // so a folded program here would enumerate variants of variants. Spelled out
    // rather than omitted, so it reads as a choice instead of an oversight.
    var opts = sel.lowerOptions();
    opts.caseless = false;
    var raw = rx.Regex.compileOpts(scratch.allocator(), src, opts) catch return &.{};
    defer raw.deinit();
    const vars = try qy.caselessVariants(a, raw.required, sel.unicode);
    return vars orelse &.{};
}

/// Copy a borrowed literal set into the arena — the matcher's program owns the
/// bytes, and the winnow outlives it.
fn keep(a: std.mem.Allocator, from: []const []const u8) error{OutOfMemory}![]const []const u8 {
    const out = try a.alloc([]const u8, from.len);
    for (out, from) |*dst, lit| dst.* = try a.dupe(u8, lit);
    return out;
}

/// The resolved semantics as the substrate's pattern bits.
fn republish(sel: rx.Caps.Selection) u32 {
    var f: u32 = 0;
    if (sel.caseless) f |= contract.flag_ignore_case;
    if (!sel.unicode) f |= contract.flag_no_unicode;
    if (sel.word) f |= contract.flag_word;
    if (sel.multiline) f |= contract.flag_multiline;
    if (sel.dotall) f |= contract.flag_dotall;
    if (sel.pcre) f |= contract.flag_pcre;
    return f;
}

/// Put the winnow's question to the index: the conjunctive cover first, then
/// the flat OR, then null for "no candidate set" — which is never "no matches".
///
/// Two spellings of one question, strongest first, exactly as cold's
/// `quarry/elide.zig::askIndex` asks them. Dropping to the WIDER answer can
/// cost reads and never a match, so a plan nothing can witness declines to the
/// weaker tier instead of failing.
fn narrow(s: *const Sieve, w: *const Winnow) trigram.QueryError!?[]u32 {
    if (w.plan) |p| {
        if (p.len > 0) {
            if (s.p.queryPlan(gpa, p)) |c| return c else |e| try benign(e);
        }
    }
    if (w.lits.len > 0) {
        if (s.p.queryAny(gpa, w.lits)) |c| return c else |e| try benign(e);
    }
    return null;
}

/// A needle below the trigram floor whose sliver tier could not pay is not a
/// fault and not an empty answer — returning normally means the caller may ask
/// a weaker question or keep its full scan. Everything else propagates: an
/// untrustworthy artifact crosses this seam as a fault whose name a host can
/// pull, rather than as a declinature that hides a corrupt index.
fn benign(e: trigram.QueryError) trigram.QueryError!void {
    return switch (e) {
        error.NeedleTooShort => {},
        else => e,
    };
}

/// Does the crest sieve rule `d` out? False whenever there is no table, no
/// vector for this id, or the swell is inert — every uncertainty admits.
fn prunes(w: *const Winnow, table: ?[]const crest.Vector, d: u32) bool {
    const vectors = table orelse return false;
    if (d >= vectors.len) return false;
    return w.sieve.prunes(vectors[d]);
}

/// The base candidate set for a reading list: the index answer minus the sieve,
/// or every document when nothing could narrow.
fn seed(s: *const Sieve, w: *const Winnow, table: ?[]const crest.Vector, ids: *std.ArrayList(u32)) !void {
    const cand = try narrow(s, w);
    defer if (cand) |c| gpa.free(c);
    if (cand) |c| {
        for (c) |d| if (!prunes(w, table, d)) try ids.append(gpa, d);
        return;
    }
    for (0..s.p.paths.items.len) |i| {
        const d: u32 = @intCast(i);
        if (!prunes(w, table, d)) try ids.append(gpa, d);
    }
}

/// The anchor a fold may date against, or null for every degradation in the
/// header. An index opened away from the artifact home is refused here rather
/// than dated by an anchor that describes a different set of bytes.
fn anchorFor(s: *const Sieve) ?i128 {
    if (!s.homed) return null;
    const a = fresh.readAnchor(gpa, s.io) orelse return null;
    return a.ns();
}

/// The shared tail of the two raw query verbs.
fn emit(cand: []const u32, out: ?[*]u32, cap: usize, written: ?*usize) Status {
    var sink = Ids.open(out, cap, written) orelse return .invalid;
    for (cand) |d| sink.push(d);
    return sink.close();
}

/// The one mapping from "the index declined" to a status. `NeedleTooShort` is
/// the declinature — this tier cannot bound the question, so the host reads
/// everything — and `*written` stays untouched so it can never read as "zero
/// candidates", which would be the one wrong answer this API could give.
fn declined(e: trigram.QueryError) Status {
    return switch (e) {
        error.NeedleTooShort => .stale,
        else => contract.reportAny(e, .open_failed),
    };
}

// ── tests ────────────────────────────────────────────────────────────────────
//
// The direction under test is soundness, never precision: every document that
// genuinely matches must survive the narrowing. A false positive costs a read;
// a single false negative is a file silently missing from a user's results.

const t = std.testing;

/// A corpus built to make the prunings bite: some documents carry the literal,
/// some carry only its shape, some carry neither.
const corpus = [_][]const u8{
    "func queryPlan(self: *const Index) void {}",
    "pub fn queryLiteral(needle: []const u8) void {}",
    "the quick brown fox jumps over the lazy dog",
    "date 2024-11-05 and 1999-01-31 in one line",
    "color #0a1b2c and #FFEEDD swatches",
    "panic: index out of bounds",
    "0x deadbeef is not a hex literal here",
    "ctx context.Context, pool *pgxpool.Pool",
    "aaa",
    "ab",
    "",
    "HELLO WORLD, hello world, HeLLo WoRlD",
    "pgxpool.Acquire(ctx) then pgxpool.Release()",
    "\xff\xfe binary-ish bytes \x00\x01 and text",
};

const probes = [_]struct { pat: []const u8, flags: u32 }{
    .{ .pat = "queryPlan", .flags = 0 },
    .{ .pat = "func", .flags = 0 },
    .{ .pat = "\\d{4}-\\d{2}-\\d{2}", .flags = 0 },
    .{ .pat = "#[0-9a-fA-F]{6}", .flags = 0 },
    .{ .pat = "panic|0x", .flags = 0 },
    .{ .pat = "pgxpool\\.\\w+", .flags = 0 },
    .{ .pat = "context\\.Context", .flags = 0 },
    .{ .pat = "hello", .flags = contract.flag_ignore_case },
    .{ .pat = "HELLO", .flags = contract.flag_smart_case },
    .{ .pat = "[0-9a-f]{8}", .flags = 0 },
    .{ .pat = "^the", .flags = contract.flag_multiline },
    .{ .pat = "quick.*dog", .flags = contract.flag_dotall },
    .{ .pat = "fox", .flags = contract.flag_word },
    .{ .pat = "a{3}", .flags = 0 },
    .{ .pat = "queryPlan|queryLiteral", .flags = 0 },
    .{ .pat = "(?i)swatch", .flags = 0 },
    .{ .pat = "b", .flags = 0 },
    .{ .pat = "z+", .flags = 0 },
};

/// One compiled pattern plus its winnow, torn down together.
const Probe = struct {
    re: *pat.Regex,
    w: *Winnow,

    fn init(p: []const u8, flags: u32) !Probe {
        var re: *pat.Regex = undefined;
        try t.expectEqual(Status.ok, pat.compile(p.ptr, p.len, flags, &re));
        var w: *Winnow = undefined;
        try t.expectEqual(Status.ok, winnowOf(re, &w));
        return .{ .re = re, .w = w };
    }

    fn deinit(self: *Probe) void {
        winnowFree(self.w);
        pat.free(self.re);
    }

    fn matches(self: *const Probe, doc: []const u8) bool {
        return pat.isMatch(self.re, doc.ptr, doc.len) == .match;
    }
};

/// The narrowing over a freshly built in-memory index, without a `Sieve`: the
/// two soundness properties belong to the plan and the swell, not to the file
/// format they are usually read through.
fn admits(idx: *const trigram.Index, w: *const Winnow, doc: u32) !bool {
    if (w.plan) |p| {
        if (p.len > 0) {
            if (idx.queryPlan(t.allocator, p)) |c| {
                defer t.allocator.free(c);
                return std.mem.indexOfScalar(u32, c, doc) != null;
            } else |e| try benign(e);
        }
    }
    if (w.lits.len > 0) {
        if (idx.queryAny(t.allocator, w.lits)) |c| {
            defer t.allocator.free(c);
            return std.mem.indexOfScalar(u32, c, doc) != null;
        } else |e| try benign(e);
    }
    return true; // no filter ⇒ every document is a candidate
}

test "sieve: a trigram plan admits every document that really matches" {
    var idx = try trigram.Index.build(t.allocator, &corpus);
    defer idx.deinit();

    var planned: usize = 0;
    for (probes) |probe| {
        var p = try Probe.init(probe.pat, probe.flags);
        defer p.deinit();
        if (p.w.plan != null) planned += 1;
        for (corpus, 0..) |doc, i| {
            if (!p.matches(doc)) continue; // false positives are the design
            const in = try admits(&idx, p.w, @intCast(i));
            if (!in) std.debug.print("FALSE NEGATIVE: /{s}/ lost doc {d}\n", .{ probe.pat, i });
            try t.expect(in);
        }
    }
    // Vacuity guard: if nothing planned, the loop above proved nothing.
    try t.expect(planned >= 8);
}

test "sieve: the crest sieve never prunes a document that really matches" {
    var live: usize = 0;
    var pruned_any: usize = 0;
    for (probes) |probe| {
        var p = try Probe.init(probe.pat, probe.flags);
        defer p.deinit();
        if (p.w.sieve.active()) live += 1;
        for (corpus) |doc| {
            const v = crest.crest(doc);
            if (p.w.sieve.prunes(v)) {
                pruned_any += 1;
                try t.expect(!p.matches(doc)); // the only forbidden direction
            }
        }
    }
    // Two vacuity guards: swells that can prune, and pruning that happened.
    try t.expect(live >= 6);
    try t.expect(pruned_any >= 6);
}

test "sieve: a cover plan is CNF over ≥3-byte atoms, and caseless declines one" {
    for (probes) |probe| {
        var p = try Probe.init(probe.pat, probe.flags);
        defer p.deinit();
        var facts_out: WinnowFacts = undefined;
        facts_out.struct_size = @sizeOf(WinnowFacts);
        try t.expectEqual(Status.ok, winnowFacts(p.w, &facts_out));

        if (p.w.plan) |plan| {
            // A caseless pattern must never carry a cover: its atoms would
            // need case expansion to stay sound.
            try t.expect(facts_out.flags & contract.flag_ignore_case == 0);
            // AND over clauses, OR over a clause's atoms, AND over an atom's
            // literals — and every literal clears the trigram floor.
            for (plan) |clause| {
                try t.expect(clause.len > 0); // a clause no atom can filter
                for (clause) |atom| {
                    try t.expect(atom.len > 0);
                    for (atom) |lit| try t.expect(lit.len >= 3);
                }
            }
        }
        for (p.w.lits) |lit| try t.expect(lit.len > 0);
    }
}

test "sieve: the winnow republishes what the pattern RESOLVED to, not what was asked" {
    // `-S` over an all-lowercase pattern resolves to caseless, and the winnow
    // says `IGNORE_CASE` rather than echoing `SMART_CASE` back.
    var p = try Probe.init("hello", contract.flag_smart_case);
    defer p.deinit();
    try t.expect(p.w.flags & contract.flag_ignore_case != 0);
    try t.expect(p.w.flags & contract.flag_smart_case == 0);
    try t.expect(p.w.plan == null); // caseless ⇒ no cover

    // The same flag over a pattern with an uppercase letter resolves the other
    // way, and the cover comes back.
    var q = try Probe.init("HELLO", contract.flag_smart_case);
    defer q.deinit();
    try t.expect(q.w.flags & contract.flag_ignore_case == 0);
    try t.expect(q.w.plan != null);

    // A leading directive is resolved into the source before anything here can
    // see it, so it too reads back as the semantics it became.
    var r = try Probe.init("(?i)swatch", 0);
    defer r.deinit();
    try t.expect(r.w.flags & contract.flag_ignore_case != 0);

    // `-F` is absent by construction: an escaped literal is just a regex.
    var f = try Probe.init("a.b", contract.flag_fixed);
    defer f.deinit();
    try t.expectEqual(@as(u32, 0), f.w.flags & contract.flag_fixed);
}

test "sieve: refusals cross as faults, and a short needle as a declinature" {
    try t.expectEqual(Status.invalid, winnowOf(null, null));
    var w: *Winnow = undefined;
    try t.expectEqual(Status.invalid, winnowOf(null, &w));

    var p = try Probe.init("queryPlan", 0);
    defer p.deinit();
    var bad: WinnowFacts = undefined;
    bad.struct_size = 0;
    try t.expectEqual(Status.invalid, winnowFacts(p.w, &bad));
    try t.expectEqual(Status.invalid, winnowFacts(p.w, null));

    // The declinature `narrow` folds away rather than reporting.
    try benign(error.NeedleTooShort);
    try t.expectError(error.Corrupt, benign(error.Corrupt));
    try t.expectEqual(Status.stale, declined(error.NeedleTooShort));
    try t.expectEqual(Status.open_failed, declined(error.Corrupt));
    try t.expectEqual(Status.out_of_memory, declined(error.OutOfMemory));
}

/// A scratch artifact home, spelled the way this package's other persistence
/// tests spell one: an absolute path under `/tmp`, made and torn down by hand,
/// because `loadAt` takes a directory name and not a handle.
fn scratchDir(io: std.Io, tag: []const u8, buf: []u8) ![]const u8 {
    const dir = try std.fmt.bufPrint(buf, "/tmp/gist_ffi_sieve_{s}_{d}", .{ tag, std.Io.Clock.now(.real, io).nanoseconds });
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

test "sieve: a persisted trigram pair answers in ids that resolve to paths" {
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var buf: [128]u8 = undefined;
    const dir = try scratchDir(io, "pair", &buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var idx = try trigram.Index.build(t.allocator, &corpus);
    defer idx.deinit();
    var paths: [corpus.len][]const u8 = undefined;
    var names: [corpus.len][32]u8 = undefined;
    for (&paths, &names, 0..) |*slot, *cell, i| slot.* = try std.fmt.bufPrint(cell, "doc{d}.zig", .{i});
    var vectors: [corpus.len]crest.Vector = undefined;
    for (&vectors, corpus) |*v, doc| v.* = crest.crest(doc);
    _ = try persist.persistIndexAndPathsAt(t.allocator, io, dir, &idx, &paths, &.{"."}, &vectors, 0);

    var s: *Sieve = undefined;
    try t.expectEqual(Status.ok, open(dir.ptr, dir.len, &s));
    defer close(s);

    var f: Facts = undefined;
    f.struct_size = @sizeOf(Facts);
    try t.expectEqual(Status.ok, facts(s, &f));
    try t.expectEqual(@as(u32, corpus.len), f.path_count);
    try t.expectEqual(@as(u32, 1), f.has_crest);
    try t.expectEqual(@as(u32, 1), f.root_count);

    // The counting probe: `cap = 0` is told the true total and writes nothing.
    const needle = "pgxpool";
    var n: usize = 12345;
    try t.expectEqual(Status.match, literal(s, needle.ptr, needle.len, null, 0, &n));
    const room = try t.allocator.alloc(u32, n);
    defer t.allocator.free(room);
    var again: usize = 0;
    try t.expectEqual(Status.match, literal(s, needle.ptr, needle.len, room.ptr, room.len, &again));
    try t.expectEqual(n, again);

    // Ascending, in range, and every id resolves to the path we persisted.
    var last: ?u32 = null;
    for (room) |d| {
        if (last) |prev| try t.expect(d > prev);
        last = d;
        var text: rows.Text = undefined;
        try t.expectEqual(Status.match, docPath(s, d, &text));
        try t.expect(std.mem.startsWith(u8, text.slice(), "doc"));
    }
    // And the answer is a superset of the truth.
    for (corpus, 0..) |doc, i| {
        if (std.mem.indexOf(u8, doc, needle) == null) continue;
        try t.expect(std.mem.indexOfScalar(u32, room, @intCast(i)) != null);
    }

    var text: rows.Text = undefined;
    try t.expectEqual(Status.invalid, docPath(s, corpus.len, &text));
    try t.expectEqual(Status.match, root(s, 0, &text));
    try t.expectEqual(Status.invalid, root(s, 1, &text));

    // A winnow over the same corpus, through the persisted pair this time.
    var p = try Probe.init("pgxpool\\.\\w+", 0);
    defer p.deinit();
    var cands: usize = 0;
    try t.expectEqual(Status.match, candidates(s, p.w, null, 0, &cands));
    try t.expect(cands > 0 and cands < corpus.len); // it actually narrowed

    // An index opened away from the artifact home cannot be dated by this
    // tree's anchor, so freshness says `foreign` and the fold stands down.
    var fr: Freshness = undefined;
    fr.struct_size = @sizeOf(Freshness);
    try t.expectEqual(Status.match, freshness(s, &fr));
    try t.expect(fr.state != @intFromEnum(State.anchored));
    var stale: usize = 0;
    try t.expectEqual(Status.stale, staleCount(s, &stale));
    var everything: usize = 0;
    try t.expectEqual(Status.match, readingList(s, p.w, null, 0, &everything));
    try t.expectEqual(@as(usize, corpus.len), everything);
}

test "sieve: opening a directory with no index declines rather than faults" {
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var buf: [128]u8 = undefined;
    const dir = try scratchDir(io, "empty", &buf);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    var s: *Sieve = undefined;
    try t.expectEqual(Status.stale, open(dir.ptr, dir.len, &s));
    try t.expectEqual(Status.invalid, open(dir.ptr, dir.len, null));
    // A null pointer carrying a length is the caller's arithmetic bug.
    try t.expectEqual(Status.invalid, open(null, 7, &s));
}

test {
    std.testing.refAllDecls(@This());
}
