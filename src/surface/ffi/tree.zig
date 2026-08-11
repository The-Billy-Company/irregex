//! Searching a TREE, from C — the verb this ABI has been missing.
//!
//! `irgx_engine_open` has shipped for a while and there has been nothing to do
//! with the handle: a host linking only `libirgx` could open a warm corpus, trip
//! a cancel token at it, and never ask it a question. The engine underneath is
//! not the gap — `api.Engine.search` is complete, tested, cancellable and
//! budgeted — the gap is that its only C face was minted one repo over, in
//! `gist`, so "the library can search a tree" was true of the Zig package and
//! false of the C ABI it publishes.
//!
//! This plane is that face, brought home.
//!
//! ## The shape
//!
//! Roots bind once, at `irgx_engine_open`, and are never repeated per query —
//! an engine IS a corpus, and re-stating its roots at every search is how a
//! warm tier quietly becomes a cold one. What a `Request` carries is the part
//! that changes per question: the pattern and its semantics, the context
//! window, and the three budgets (`cancel`, `timeout_ns`, `max_results`).
//!
//!     irgx_engine_open  →  irgx_tree_search  →  irgx_matches_next*  →  close
//!
//! ## This is NOT the row protocol
//!
//! `irgx_rows_*` (`answer.zig`) walks self-describing ANALYTIC rows — the
//! relate/blast shape, 22 generated schemas, a value union per column. A match
//! line is not that shape and must not borrow it: it is a fixed record of five
//! facts (path, 1-based line number, the line's bytes, the spans inside it, and
//! whether it was selected or is a context neighbor) that every grep in
//! existence already agrees on. Two cursor protocols, named after what they
//! carry, is the whole design — a `Row` decoded through a schema digest would
//! make `path` a lookup where it is a field.
//!
//! ## Lifetime: ONE rule, and it is the arena's
//!
//! **Every byte a `Match` points at — `path`, `line`, and `spans` — belongs to
//! the cursor and stays valid until `irgx_matches_close`.** Nothing a host reads
//! is invalidated by a later pull. That is the single deliberate divergence from
//! the gist shim this ports: gist gives a record TWO lifetimes, because its
//! submatch views alias a scratch buffer refilled on every `next`, so a struct
//! whose other four fields survive until close has two that die at the next
//! call. A C host cannot see that from the struct, and the cost of the fix is a
//! 16-byte span copy per submatch into an arena the records already live in.
//! Buying one rule for that is the trade this plane makes.
//!
//! A pull that fails consumes nothing: the read position is restored, so the
//! host may free memory and ask again for the same record.
//!
//! ## Ownership and threads
//!
//! A cursor is SINGLE-THREADED — it advances a read position and appends to its
//! own arena, so two threads sharing one corrupt a record rather than race a
//! counter. The one operation any thread may run is `irgx_cancel_request` on the
//! token a search was given. Every non-negative status from `search` writes a
//! cursor the host must `close`, `.ok` (no records) included: the status reports
//! the ANSWER, never whether there is a handle to release.

const std = @import("std");
const api = @import("../api.zig");
const contract = @import("contract.zig");
const fault = @import("../../fault.zig");
const pat = @import("pattern.zig");
const portal = @import("../../portal.zig");
const rows = @import("rows.zig");

const Status = contract.Status;

/// `-m`: `max_count` is present. A bit rather than a sentinel because 0 is a
/// real answer here — "cap this file at zero matching lines" — so absence
/// cannot be spelled by the value.
pub const flag_max_count: u32 = 1 << 4;
/// `-v`: select the lines that do NOT match.
pub const flag_invert: u32 = 1 << 7;

/// The flags a tree search accepts. Bit values are the ecosystem's, so
/// "ignore case" means one thing whichever ABI a host hands it to.
///
/// Narrower than `contract.pattern_flags`, and the gap is the point. `IRGX_PCRE`
/// (8), `IRGX_MULTILINE` (9) and `IRGX_DOTALL` (10) have no knob on the warm
/// engine's request to travel in, and bit 3 — gist's `-q`, existence-only early
/// halt — is answered here by `max_results = 1` rather than by a second way to
/// say it. A host that sets one of those has a wrong belief about what it is
/// about to be told, and `IRGX_INVALID` now beats finding out from an answer.
pub const search_flags = contract.flag_fixed | contract.flag_ignore_case |
    contract.flag_word | flag_max_count | contract.flag_smart_case |
    contract.flag_no_unicode | flag_invert;

/// One complete tree-search shape. Extern and APPEND-ONLY, with a FAIL-CLOSED
/// `struct_size`: a size this build does not recognize is `.invalid`, never a
/// best-effort read of the prefix it thinks it recognizes.
///
/// **Zero is today.** Every field's 0 is its documented default, so a struct a
/// host memsets and stamps `struct_size` onto is an unbudgeted, uncancelled,
/// contextless leftmost search for the empty pattern. The budgets read 0 as
/// "unset" rather than "zero allowed", which is why `max_count` — where 0 IS an
/// allowed ceiling — needs `flag_max_count` instead.
pub const Request = extern struct {
    struct_size: u32,
    flags: u32,
    /// Per-file matching-line cap (`-m`). Read only under `flag_max_count`.
    max_count: u64,
    /// Context neighbors emitted around each selected line (`-B` / `-A`).
    before_context: u64,
    after_context: u64,
    /// The pattern's bytes. Null with a length is a caller bug, not empty text.
    pattern: ?[*]const u8,
    pattern_len: usize,
    /// Monotonic wall-clock budget in nanoseconds, from the start of the
    /// search; 0 = no deadline.
    timeout_ns: u64,
    /// Stop after this many records land, at a record boundary; 0 = unbounded.
    max_results: usize,
    /// Optional `irgx_cancel`, tripped from any thread; null = uncancellable.
    cancel: ?*const api.CancelToken,
};

/// Whether a record is a line the query SELECTED or a context neighbor carried
/// with it. Explicitly numbered: these cross as a `uint32_t` a host switches on.
pub const Kind = enum(u32) { match = 0, context = 1 };

/// One result line. Every pointer borrows the cursor and dies with it — see the
/// lifetime rule at the top of this file, which has no exceptions.
///
/// `path` and `line` are `irgx_text`, and the spans are `irgx_span`, because
/// this ABI already has one string vocabulary and one byte-range vocabulary and
/// a match record is not the place to mint a second of either. (The spans are
/// offsets INTO `line`, so `line.ptr + span.start` is the matched bytes; a
/// context line carries none. They are never the `{-1,-1}` unset form
/// `irgx_captures` can hand back — a selected line has real spans.)
pub const Match = extern struct {
    path: rows.Text,
    line: rows.Text,
    spans: [*]const pat.Span,
    nspans: usize,
    /// 1-based, as every grep reports it.
    line_number: u64,
    kind: Kind,
};

/// Run one search over an open corpus and materialize a pull cursor into `out`.
///
/// `.match` when the cursor holds records, `.ok` when it holds none — and in
/// BOTH cases a cursor was written and the host owns it. `.stale` is the warm
/// tier declining (a pattern outside the linear-time syntax, freshness it cannot
/// prove, a ceiling): nothing is written, no fault is installed, and the caller
/// gets the byte-identical answer by running the query cold. `.invalid` is a
/// caller error; `.out_of_memory` is the only genuine failure on this path.
pub fn search(engine: *api.Engine, req_ptr: ?*const Request, out: ?**api.Cursor) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    const req = req_ptr orelse return .invalid;
    if (req.struct_size != @sizeOf(Request) or req.flags & ~search_flags != 0) return .invalid;
    const pattern = contract.view(req.pattern, req.pattern_len) orelse return .invalid;

    const query = api.SearchQuery{
        .pattern = pattern,
        .fixed = req.flags & contract.flag_fixed != 0,
        .ignore_case = req.flags & contract.flag_ignore_case != 0,
        .smart_case = req.flags & contract.flag_smart_case != 0,
        .word = req.flags & contract.flag_word != 0,
        .invert = req.flags & flag_invert != 0,
        .unicode = req.flags & contract.flag_no_unicode == 0,
        .before = req.before_context,
        .after = req.after_context,
        .max_count = if (req.flags & flag_max_count != 0) req.max_count else null,
    };
    // All three budgets are the engine's own, already enforced at a strided
    // gather checkpoint AND at every emit. Nothing is re-implemented here, and
    // nothing is accepted-and-ignored: each one either lowers onto `RunOptions`
    // or is not a field of this request.
    const run = api.RunOptions{
        .cancel = req.cancel,
        .timeout_ns = if (req.timeout_ns == 0) null else req.timeout_ns,
        .max_results = if (req.max_results == 0) null else req.max_results,
    };

    const answered = engine.search(query, run) catch |e| switch (e) {
        error.OutOfMemory => return contract.report(.{ .code = error.OutOfMemory }),
    };
    const cursor = switch (answered) {
        .got => |c| c,
        // A declinature installs no fault: a tier that stepped aside has
        // nothing to confess, and `.stale` is returned rather than reported.
        .declined => return .stale,
    };
    slot.* = cursor;
    return if (cursor.count() == 0) .ok else .match;
}

/// Write the next record. `.match` when one was written, `.ok` at the end of the
/// stream (`out` untouched), `.invalid` for a null slot.
///
/// The one-record spelling of `nextBatch`, and delegating rather than repeating
/// it is the point: the rollback invariant below — a record that fails to
/// materialize must rewind `cursor.pos` so the stream is not silently short one
/// entry — was written twice, and a cursor advanced past a record nobody
/// received is a MISSING result, the class of bug nothing downstream can see.
/// One implementation, two spellings, so the two cannot drift.
pub fn next(cursor: *api.Cursor, out: ?*Match) Status {
    // `written` is discarded, not omitted: a batch of one lands 0 or 1, which
    // `.ok`/`.match` already says. A null `out` still reaches `.invalid`, since
    // the sink refuses it.
    var landed: usize = undefined;
    return nextBatch(cursor, @ptrCast(out), 1, &landed);
}

/// Fill up to `cap` records into `out[0..cap]` and write how many landed to
/// `written` — one crossing amortized over N records, which is the whole reason
/// a binding batches.
///
/// `*written` is what this call CONSUMED, not a total that exists: a cursor
/// counted past `cap` would be counting records it had already dropped. The
/// count-only probe on this plane is `irgx_matches_count`, which answers without
/// advancing anything. So `cap == 0` is a legal no-op that consumes nothing.
pub fn nextBatch(cursor: *api.Cursor, out: ?[*]Match, cap: usize, written: ?*usize) Status {
    contract.beginCall();
    var sink = contract.Sink(Match).open(out, cap, written) orelse return .invalid;
    const start = cursor.pos;
    while (sink.n < cap) {
        const rec = cursor.next() orelse break;
        sink.push(recordOf(cursor, rec) catch {
            // Unwound by hand: a Status-returning entry returns an enum, so an
            // `errdefer` here would never fire. The whole batch is rolled back
            // rather than half-published, and `written` is still the 0 the sink
            // set on open.
            cursor.pos = start;
            return contract.report(.{ .code = error.OutOfMemory });
        });
    }
    return sink.close();
}

/// How many records the stream holds, asked without advancing it — what
/// `nextBatch`'s `*written` deliberately cannot answer, since a count of what
/// was consumed is not a count of what exists. A read of already-materialized
/// state, so it hands back the number rather than a `Status` to unwrap.
pub fn count(cursor: *const api.Cursor) usize {
    return cursor.count();
}

/// Release the cursor and every byte it lent out — the paths, lines and spans
/// every record borrowed. Every `search` that hands back a handle owes exactly
/// one call, `.ok` with no records included: the status reports the ANSWER,
/// never whether there is a handle to release.
pub fn close(cursor: *api.Cursor) void {
    cursor.deinit();
}

/// Copy one owned record into its C view. The spans are converted into the
/// CURSOR'S arena rather than into reusable scratch — the arena the path and
/// line bytes already live in — which is what buys the record one lifetime
/// instead of two.
fn recordOf(cursor: *api.Cursor, rec: api.OwnedMatch) std.mem.Allocator.Error!Match {
    const spans = try cursor.arena.allocator().alloc(pat.Span, rec.spans.len);
    for (rec.spans, spans) |src, *dst| dst.* = .{ .start = @intCast(src.start), .end = @intCast(src.end) };
    return .{
        .path = rows.Text.of(rec.path),
        .line = rows.Text.of(rec.text),
        .spans = spans.ptr,
        .nspans = spans.len,
        .line_number = rec.line_number,
        .kind = @enumFromInt(@intFromEnum(rec.kind)),
    };
}

// ── tests ────────────────────────────────────────────────────────────────────
// Over a REAL tree through REAL syscalls, as the hosted suite next door is: the
// budgets this plane's whole claim rests on are properties of a live scan, and a
// fake corpus would prove the seam forwards a field rather than that the field
// stops a search.

const Dir = std.Io.Dir;

/// The fixture every test below searches: three files, three matching lines of
/// the literal `needle`, in path order a.txt → b.txt. Absolute, so no test
/// depends on the cwd.
const fixture = [_][2][]const u8{
    .{ "a.txt", "alpha\nneedle one\nomega\n" },
    .{ "b.txt", "needle two\nneedle three\n" },
    .{ "c.txt", "no match here\n" },
};

/// Plant the fixture under a root NO OTHER RUN CAN NAME.
///
/// `seed` separates the tests within one process; the pid separates the
/// processes, and it has to, because a fixed path here was actively destructive
/// rather than merely shared: this used to `deleteTree` the root first, so a
/// second concurrent `zig build test` deleted the first one's fixture out from
/// under an in-flight search. Two agents in one tree, two CI jobs on one
/// machine, or a developer testing while anything else does all hit it, and it
/// surfaces as a flake nowhere near its cause. The pair is exhaustive because
/// the runner shards into processes, so no two live roots can collide — which is
/// why there is no pre-delete any more: nothing here can reach another run's
/// bytes, and a leaked directory now names the process that left it.
fn plant(arena: std.mem.Allocator, seed: u32) ![]const u8 {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = try std.fmt.allocPrint(arena, "/tmp/irgx_tree_{x}_{d}", .{ seed, portal.processId() });
    try Dir.cwd().createDirPath(io, root);
    for (fixture) |f| {
        const p = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, f[0] });
        try Dir.cwd().writeFile(io, .{ .sub_path = p, .data = f[1] });
    }
    return root;
}

fn uproot(root: []const u8) void {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    fault.spare("remove fixture", Dir.cwd().deleteTree(threaded.io(), root));
}

/// A request for `needle`, taken literally, with everything else at its default.
fn literal(pattern: []const u8) Request {
    return .{
        .struct_size = @sizeOf(Request),
        .flags = contract.flag_fixed,
        .max_count = 0,
        .before_context = 0,
        .after_context = 0,
        .pattern = pattern.ptr,
        .pattern_len = pattern.len,
        .timeout_ns = 0,
        .max_results = 0,
        .cancel = null,
    };
}

test "tree: a search pulls the whole answer, singly and in batches" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const root = try plant(arena.allocator(), 0xa1);
    defer uproot(root);

    const engine = try api.Engine.open(t.allocator, &.{root});
    defer engine.close();

    var cursor: *api.Cursor = undefined;
    var req = literal("needle");
    // Records exist, so the search itself answers positively — the shipped
    // vocabulary's `.match`, not gist's unconditional `.ok`.
    try t.expectEqual(Status.match, search(engine, &req, &cursor));
    defer cursor.deinit();
    try t.expectEqual(@as(usize, 3), cursor.count());
    try t.expect(cursor.anyMatched());

    var one: Match = undefined;
    try t.expectEqual(Status.match, next(cursor, &one));
    try t.expect(std.mem.endsWith(u8, one.path.slice(), "a.txt"));
    try t.expectEqualStrings("needle one", one.line.slice());
    try t.expectEqual(@as(u64, 2), one.line_number);
    try t.expectEqual(Kind.match, one.kind);
    try t.expectEqual(@as(usize, 1), one.nspans);
    try t.expectEqual(@as(i64, 0), one.spans[0].start);
    try t.expectEqual(@as(i64, 6), one.spans[0].end);

    // The batch resumes where the single step left off — one position, not two.
    var batch: [4]Match = undefined;
    var got: usize = 0;
    try t.expectEqual(Status.match, nextBatch(cursor, &batch, 4, &got));
    try t.expectEqual(@as(usize, 2), got);
    try t.expectEqualStrings("needle two", batch[0].line.slice());
    try t.expectEqualStrings("needle three", batch[1].line.slice());

    // Exhausted is `.ok` with nothing written, repeatably — never an error.
    try t.expectEqual(Status.ok, next(cursor, &one));
    try t.expectEqual(Status.ok, nextBatch(cursor, &batch, 4, &got));
    try t.expectEqual(@as(usize, 0), got);
    // …and a zero-width batch consumes nothing rather than dropping a record.
    try t.expectEqual(Status.ok, nextBatch(cursor, null, 0, &got));
}

test "tree: the count is the total that EXISTS, not the remainder still unread" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const root = try plant(arena.allocator(), 0xc7);
    defer uproot(root);

    const engine = try api.Engine.open(t.allocator, &.{root});
    defer engine.close();

    var cursor: *api.Cursor = undefined;
    var req = literal("needle");
    try t.expectEqual(Status.match, search(engine, &req, &cursor));
    // The release path a C host has, exercised as the host would reach it.
    defer close(cursor);

    // The distinction the plane exists to keep: `*written` reports what a pull
    // CONSUMED, and would fall to 0 as the stream drains. `count` is the total
    // the answer holds, so draining must not move it — a host sizing a buffer
    // from it after one pull would otherwise under-allocate.
    try t.expectEqual(@as(usize, 3), count(cursor));
    var one: Match = undefined;
    try t.expectEqual(Status.match, next(cursor, &one));
    try t.expectEqual(@as(usize, 3), count(cursor));

    var batch: [4]Match = undefined;
    var got: usize = 0;
    try t.expectEqual(Status.match, nextBatch(cursor, &batch, 4, &got));
    try t.expectEqual(@as(usize, 2), got);
    try t.expectEqual(@as(usize, 3), count(cursor));

    // Drained, and still the total rather than the zero `got` now reports.
    try t.expectEqual(Status.ok, next(cursor, &one));
    try t.expectEqual(@as(usize, 3), count(cursor));
}

test "tree: every byte a record borrows outlives every later pull" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const root = try plant(arena.allocator(), 0xa2);
    defer uproot(root);

    const engine = try api.Engine.open(t.allocator, &.{root});
    defer engine.close();

    var cursor: *api.Cursor = undefined;
    var req = literal("needle");
    try t.expectEqual(Status.match, search(engine, &req, &cursor));
    defer cursor.deinit();

    // The assertion this plane's whole lifetime rule exists for. Hold the FIRST
    // record's pointers, drain the cursor, and read them again: under gist's
    // two-lifetime shape `first.spans` would by now be pointing at the third
    // record's span, silently and with no way for a C host to notice.
    var first: Match = undefined;
    try t.expectEqual(Status.match, next(cursor, &first));
    const held_path = first.path;
    const held_line = first.line;
    const held_span = first.spans;

    var rest: [8]Match = undefined;
    var got: usize = 0;
    try t.expectEqual(Status.match, nextBatch(cursor, &rest, 8, &got));
    try t.expectEqual(@as(usize, 2), got);

    try t.expect(std.mem.endsWith(u8, held_path.slice(), "a.txt"));
    try t.expectEqualStrings("needle one", held_line.slice());
    try t.expectEqual(@as(i64, 0), held_span[0].start);
    try t.expectEqual(@as(i64, 6), held_span[0].end);
    // Each record's spans are its own storage, not one buffer taking turns.
    try t.expect(held_span != rest[0].spans);
}

test "tree: context neighbors ride the same cursor, distinguishable by kind" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const root = try plant(arena.allocator(), 0xa3);
    defer uproot(root);

    const engine = try api.Engine.open(t.allocator, &.{root});
    defer engine.close();

    var cursor: *api.Cursor = undefined;
    var req = literal("needle one");
    req.before_context = 1;
    req.after_context = 1;
    try t.expectEqual(Status.match, search(engine, &req, &cursor));
    defer cursor.deinit();

    // alpha / needle one / omega — the neighbors carry no spans, which is how
    // a host tells a carried line from a selected one without trusting `kind`.
    var rec: [4]Match = undefined;
    var got: usize = 0;
    try t.expectEqual(Status.match, nextBatch(cursor, &rec, 4, &got));
    try t.expectEqual(@as(usize, 3), got);
    try t.expectEqual(Kind.context, rec[0].kind);
    try t.expectEqualStrings("alpha", rec[0].line.slice());
    try t.expectEqual(@as(usize, 0), rec[0].nspans);
    try t.expectEqual(Kind.match, rec[1].kind);
    try t.expectEqual(Kind.context, rec[2].kind);
    try t.expectEqualStrings("omega", rec[2].line.slice());
}

test "tree: each budget bounds the scan rather than being accepted and ignored" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const root = try plant(arena.allocator(), 0xa4);
    defer uproot(root);

    const engine = try api.Engine.open(t.allocator, &.{root});
    defer engine.close();

    // max_results stops at a record boundary — one record, never a torn one.
    var capped = literal("needle");
    capped.max_results = 1;
    var cursor: *api.Cursor = undefined;
    try t.expectEqual(Status.match, search(engine, &capped, &cursor));
    try t.expectEqual(@as(usize, 1), cursor.count());
    // The exit-code boolean survives the cut: files DID match.
    try t.expect(cursor.anyMatched());
    cursor.deinit();

    // max_count is the per-FILE ceiling, so b.txt's second hit is the one that
    // goes — a different question from max_results, and both must reach through.
    var per_file = literal("needle");
    per_file.flags |= flag_max_count;
    per_file.max_count = 1;
    try t.expectEqual(Status.match, search(engine, &per_file, &cursor));
    try t.expectEqual(@as(usize, 2), cursor.count());
    cursor.deinit();

    // A token already tripped: a clean, empty, still-valid cursor. The status
    // reports the ANSWER (no records), and the host still owns a handle.
    var token = api.CancelToken{};
    token.cancel();
    var cancelled = literal("needle");
    cancelled.cancel = &token;
    try t.expectEqual(Status.ok, search(engine, &cancelled, &cursor));
    try t.expectEqual(@as(usize, 0), cursor.count());
    cursor.deinit();

    // A deadline already in the past, checked at the same two places.
    var lapsed = literal("needle");
    lapsed.timeout_ns = 1;
    try t.expectEqual(Status.ok, search(engine, &lapsed, &cursor));
    try t.expectEqual(@as(usize, 0), cursor.count());
    cursor.deinit();

    // And an inverted search is the negation, not the empty set — proof the
    // behavioral bits reach the engine and are not merely admitted by the mask.
    var inverted = literal("needle");
    inverted.flags |= flag_invert;
    try t.expectEqual(Status.match, search(engine, &inverted, &cursor));
    defer cursor.deinit();
    var rec: Match = undefined;
    while (next(cursor, &rec) == .match)
        try t.expect(std.mem.indexOf(u8, rec.line.slice(), "needle") == null);
}

test "tree: a pattern the warm tier cannot take declines, and says nothing" {
    const t = std.testing;
    const sc = fault.scope();
    defer sc.end();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const root = try plant(arena.allocator(), 0xa5);
    defer uproot(root);

    const engine = try api.Engine.open(t.allocator, &.{root});
    defer engine.close();

    // A lookahead is outside the linear-time syntax. The host answers cold and
    // gets the identical result, so the fault slot must stay empty — a
    // declinature has nothing to confess.
    var cursor: *api.Cursor = undefined;
    var req = literal("needle(?=X)");
    req.flags = 0; // not literal: the regex arm has to see the lookahead
    try t.expectEqual(Status.stale, search(engine, &req, &cursor));

    var detail: contract.FaultDetail = undefined;
    detail.struct_size = @sizeOf(contract.FaultDetail);
    try t.expectEqual(Status.ok, contract.lastFault(&detail));
}

test "tree: the request fails closed on every word it cannot honor" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const root = try plant(arena.allocator(), 0xa6);
    defer uproot(root);

    const engine = try api.Engine.open(t.allocator, &.{root});
    defer engine.close();

    var cursor: *api.Cursor = undefined;
    const base = literal("needle");
    try t.expectEqual(Status.invalid, search(engine, &base, null));
    try t.expectEqual(Status.invalid, search(engine, null, &cursor));

    // A size from another build, in BOTH directions — a shorter prefix is not
    // read as an older struct, because we cannot know which older one.
    var short = base;
    short.struct_size = @sizeOf(Request) - 8;
    try t.expectEqual(Status.invalid, search(engine, &short, &cursor));
    var long = base;
    long.struct_size = @sizeOf(Request) + 8;
    try t.expectEqual(Status.invalid, search(engine, &long, &cursor));

    // A bit this build never declared, and three the ecosystem declares but
    // this plane cannot carry: PCRE, multiline, dotall. Refused, not masked off.
    for ([_]u32{ 1 << 31, contract.flag_pcre, contract.flag_multiline, contract.flag_dotall, 1 << 3 }) |bit| {
        var flagged = base;
        flagged.flags |= bit;
        try t.expectEqual(Status.invalid, search(engine, &flagged, &cursor));
    }

    // Null bytes carrying a length is the caller's arithmetic bug; null with
    // zero is the empty pattern, which legitimately matches every line.
    var nul = base;
    nul.pattern = null;
    try t.expectEqual(Status.invalid, search(engine, &nul, &cursor));
    nul.pattern_len = 0;
    nul.flags = 0;
    try t.expectEqual(Status.match, search(engine, &nul, &cursor));
    cursor.deinit();

    // The cursor verbs' own guards.
    try t.expectEqual(Status.match, search(engine, &base, &cursor));
    defer cursor.deinit();
    var got: usize = 0;
    var one: [1]Match = undefined;
    try t.expectEqual(Status.invalid, next(cursor, null));
    try t.expectEqual(Status.invalid, nextBatch(cursor, &one, 1, null));
    try t.expectEqual(Status.invalid, nextBatch(cursor, null, 1, &got));
}
