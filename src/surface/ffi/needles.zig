//! Many literals, one pass over the haystack — the multi-substring search a host
//! reaches for when it has a wordlist rather than a pattern.
//!
//! This is not a regex question and should not have to be asked as one. A host
//! with four hundred forbidden terms, or a tokenizer with a keyword table, wants
//! to know which of them occur and where, and today its only route through this
//! ABI is to compile an alternation and let the automata road carry a question
//! that never needed a grammar. The machinery is already here — the dragnet SIMD
//! sieve under eighteen literals and the Aho-Corasick trawl at or above it, the
//! two tiers `relate patterns` dispatches between on slate width — and the C ABI
//! exposes neither, so a C host cannot reach the fastest path in the package.
//!
//! The two answers worth separating, because they have different costs:
//!
//!   * **Which needles occur at all** — a set, answerable by the sieve, and the
//!     cheap question a host asks to decide whether to look closer.
//!   * **Where each occurrence is, attributed** — a stream of (needle, span),
//!     which is what `--by pattern` accounting needs and what an alternation
//!     famously loses: a regex alternation reports A match, not which arm.
//!
//! Attribution is the whole point. Do not collapse it into a single boolean or a
//! bitmask that stops at 64 needles — the chorus plane already caps there for its
//! own reasons, and a wordlist is routinely larger than a slate.
//!
//! So the plane is three verbs at three prices, and a host picks the one whose
//! answer it actually needs:
//!
//!   * `isMatch` — does ANY needle occur? Answered by the byte tier's own
//!     dispatcher (`kernel/scan`): one needle is a rare-byte-pair SIMD memmem
//!     with its anchor pair re-priced on the buffer in hand, a handful is a
//!     Teddy bucket pass. The cheapest question here by a wide margin.
//!   * `which` — WHICH needles occur, ascending, as a SET. One striped
//!     Aho-Corasick sweep that abandons the document the moment every needle is
//!     accounted for. Attribution without positions, at throughput.
//!   * `findAll` — WHERE each occurrence is: `(needle, start, end)`, every
//!     occurrence including the overlapping ones, out of one single-stream walk
//!     of the same automaton. The expensive one, and the only one that can
//!     answer "how many times did term 7 appear".
//!
//! **Attribution is carried in the caller's own ordinals** — the index of the
//! needle in the array handed to `compile` — and nothing here is a `u64` mask.
//! `which` writes ascending `uint32` ids through the shared count-versus-capacity
//! window, so its answer is bounded by the needle count and not by a word width;
//! `findAll` writes a row per occurrence carrying the same id.
//!
//! **Order.** Occurrences arrive in ascending END offset, and occurrences sharing
//! an end arrive in ascending needle id. End rather than start because the
//! automaton reports at the end — a needle and the suffix of it that a second
//! needle spells END together and START apart, so end order is the one an online
//! walk can emit without buffering. A host that wants start order reorders inside
//! a window of `longest` bytes, which `describe` publishes for exactly that.
//!
//! **The ceiling is BYTES, not needles**, and it is a refusal rather than a
//! truncation. The automaton's transition table is bounded (`trawl.max_states`),
//! so a set whose needles total more than `max_bytes` is refused whole with
//! `TooManyPatterns` — a wordlist of four thousand seven-byte terms fits and a
//! set that does not is told so, instead of quietly being answered about a prefix
//! of itself.
//!
//! Two rules it inherits from the planes next door, for the same reasons:
//!
//!   * **A handle is single-threaded.** It owns the play set and the per-position
//!     scratch every scan rewrites, so two threads sharing one would corrupt an
//!     answer rather than race a counter.
//!   * **Nothing can `die()` the host, and nothing borrows the host's bytes past
//!     the call.** Needle text is copied at compile; every entry returns a
//!     `Status` and leaves the per-incident detail in the thread's fault slot.

const std = @import("std");
const contract = @import("contract.zig");
const scan = @import("../../kernel/scan/scan.zig");
const slate = @import("../../kernel/slate/slate.zig");

const Status = contract.Status;
const gpa = std.heap.c_allocator;

/// `Trawl`'s "no such state / no such literal" sentinel — the terminator on both
/// the output-list and dictionary-suffix chains `findAll` walks.
///
/// Imported rather than respelled. It was a local copy while the constant was
/// file-private one tier down, guarded by a test that read the real automaton's
/// root; the constant is `pub` now, so the copy is gone and the test below has
/// become a tautology worth keeping anyway — it costs nothing and it is the thing
/// that would notice if the sentinel ever stopped being unreachable as a state.
const none: u32 = slate.trawl.none;

/// One needle: the bytes, and nothing else.
///
/// No per-needle flag word, and no flag word worth having yet — see
/// `needle_flags`. Extern and append-only, so a later field is a
/// forward-compatible extension.
pub const Needle = extern struct {
    needle: ?[*]const u8,
    len: usize,
};

/// One attributed occurrence: which needle, and the half-open span it occupies.
///
/// `needle` is the caller's own compile ordinal, never an internal literal
/// index — a host never learns that the automaton pools its needles. No
/// `struct_size` here, as there is none on `irgx_span`: this is an ARRAY
/// element, and a per-element size negotiation would price every row for a
/// question only the call can answer.
pub const Occurrence = extern struct {
    needle: u32,
    reserved: u32 = 0,
    start: usize,
    end: usize,
};

/// The set is empty — no mechanism is armed and every verb answers "nothing".
pub const tier_none: u32 = 0;
/// One needle: the rare-byte-pair SIMD memmem, with its anchor pair re-priced
/// against the buffer actually in hand.
pub const tier_memmem: u32 = 1;
/// The byte tier's multi-needle dispatcher — a Teddy bucket pass, or its scalar
/// stand-in for needles too short to bucket.
pub const tier_literal_set: u32 = 2;
/// The Aho-Corasick trawl: per-byte cost independent of how many needles there
/// are, and the only mechanism here that can report a position per needle.
pub const tier_trawl: u32 = 3;

/// The flag bits this plane honors — none, today, and that is a statement
/// rather than an omission. Case folding is the one a wordlist host asks for,
/// and it is not free here: the byte tier folds ASCII for a SINGLE needle
/// (`simd.indexOfCaselessPos`) and the automaton folds nothing, so honoring it
/// would mean either a folded copy of every haystack or a second, weaker answer
/// under the same verb. A host that passes `IRGX_IGNORE_CASE` hears
/// `IRGX_INVALID` now, which is strictly better than silently getting a
/// case-sensitive answer to a case-insensitive question.
pub const needle_flags: u32 = 0;

/// The most needle bytes one set may hold. Derived from the automaton's own
/// state bound rather than restated, so the two cannot drift.
pub const max_bytes: usize = slate.trawl.max_states - 1;

/// What a compiled set is, and which machine answers about it.
///
/// `struct_size` is set by the CALLER and the layout is append-only, so an
/// unknown size fails closed exactly like `FaultDetail`'s.
pub const Shape = extern struct {
    struct_size: u32,
    /// Which mechanism `isMatch` reaches — one of the `tier_*` constants.
    presence_tier: u32,
    /// Which mechanism `which` and `findAll` reach. Always `tier_trawl` on a
    /// non-empty set: naming the needle is what that machine is for.
    attributed_tier: u32,
    reserved: u32 = 0,
    /// How many needles the set holds — the exact `cap` `which` never needs to
    /// retry at.
    count: usize,
    /// The longest needle. A host feeding this set a stream in chunks must
    /// overlap consecutive chunks by `longest - 1` bytes, or lose every
    /// occurrence that straddles a boundary. It is also the reorder window that
    /// turns this plane's end-ordered stream into a start-ordered one.
    longest: usize,
    /// Total needle bytes, against `max_bytes`.
    bytes: usize,
};

/// A compiled needle set and the scratch its scans run in. Opaque to C — a host
/// only ever holds the pointer.
pub const Needles = struct {
    /// Every needle's bytes, one allocation. Copied rather than borrowed, for
    /// the reason `slate.Slate` copies its patterns: a host is entitled to
    /// compile out of a stack buffer or a Python `str` that gets collected, and
    /// "keep your bytes alive as long as the handle" is a rule honored right up
    /// until it isn't, with a use-after-free inside the engine as the failure.
    text: []u8,
    /// The needle slices into `text`. The index IS the caller's ordinal.
    list: [][]const u8,
    /// The identity map `0, 1, 2, …`, serving two roles the automaton keeps
    /// apart and this plane does not: it is the trawl's POOL (which literals to
    /// build over) at compile, and its OWNER map (which pattern a literal
    /// belongs to) at every sweep. They coincide because here a needle is its
    /// own pattern, which is the whole difference between this plane and the
    /// slate next door.
    owner: []u32,
    /// Every needle ending at one position, gathered before it is ordered.
    /// Bounded by the needle count: a literal index lives in exactly one state's
    /// output list, so one dictionary-suffix chain cannot name any of them twice.
    ending: []u32,
    /// `maskWords(count)` words — the play set the sweep rolls into. A bit array,
    /// not a `u64`, so the needle count is bounded by the byte budget above and
    /// by nothing else.
    play: []u64,
    /// The Aho-Corasick automaton. Null only for the empty set.
    trawl: ?slate.trawl.Trawl,
    /// The byte tier's dispatcher, armed only while it would NOT build a second
    /// automaton — that is, at or under Teddy's bucket count, which is exactly
    /// the range where it is the faster machine for presence. Past that its own
    /// answer is a sparse Aho-Corasick and we already hold one, so presence
    /// rides the trawl instead.
    set: ?scan.LiteralSet,
    longest: usize,
};

const BuildFail = std.mem.Allocator.Error || error{TooManyPatterns};

/// Compile `count` needles as one set.
///
/// `refused` receives the index of the needle that caused a refusal, and is the
/// diagnosis a wordlist needs and a single needle does not: with four hundred
/// terms, "one of them is empty" is not an actionable answer. It may be null for
/// a host that does not care.
///
/// **An empty needle is refused, not accepted.** It occurs at every position,
/// so admitting one turns every answer into the haystack's own length and buries
/// the terms the host actually asked about. `NeedleTooShort` is the fault, and
/// `refused` says which.
pub fn compile(list: ?[*]const Needle, count: usize, flags: u32, refused: ?*usize, out: ?**Needles) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    if (flags & ~needle_flags != 0) return .invalid;
    // An empty set is the natural answer to a host whose config file listed no
    // terms, and every verb has an answer for it. Null-with-zero is the same
    // thing in the only spelling some hosts can produce — Go's `&slice[0]` does
    // not exist for an empty slice — while null WITH a count stays a caller bug.
    const items: []const Needle = if (list) |p|
        p[0..count]
    else if (count == 0)
        &.{}
    else
        return .invalid;

    var total: usize = 0;
    for (items, 0..) |item, i| {
        if (item.needle == null and item.len != 0) {
            if (refused) |r| r.* = i;
            return .invalid;
        }
        if (item.len == 0) {
            if (refused) |r| r.* = i;
            return contract.report(.{ .code = error.NeedleTooShort });
        }
        total += item.len;
        // Checked inside the loop rather than after it, which is also what keeps
        // the sum from wrapping on a caller's bogus length: the first term past
        // the budget returns before a second addition can overflow it.
        if (total > max_bytes) return contract.report(.{ .code = error.TooManyPatterns });
    }

    const handle = assemble(items, total) catch |e| return contract.report(.{ .code = e });
    slot.* = handle;
    return .ok;
}

/// Everything `compile` allocates, in one error-returning function so `errdefer`
/// actually fires.
///
/// The entry above cannot use one — it returns a `Status`, not an error union,
/// so an `errdefer` written there is dead code that leaks on every failure. The
/// house answer is to unwind by hand; the better one is to put the fallible half
/// somewhere unwinding is the language's job and translate once at the seam,
/// which is what this is. Nothing here escapes on a failure path.
fn assemble(items: []const Needle, total: usize) BuildFail!*Needles {
    const text = try gpa.alloc(u8, total);
    errdefer gpa.free(text);
    const list = try gpa.alloc([]const u8, items.len);
    errdefer gpa.free(list);

    var at: usize = 0;
    var longest: usize = 0;
    for (items, list) |item, *dst| {
        const body = text[at..][0..item.len];
        @memcpy(body, item.needle.?[0..item.len]);
        dst.* = body;
        at += item.len;
        longest = @max(longest, item.len);
    }

    const owner = try gpa.alloc(u32, items.len);
    errdefer gpa.free(owner);
    for (owner, 0..) |*o, i| o.* = @intCast(i);
    const ending = try gpa.alloc(u32, items.len);
    errdefer gpa.free(ending);
    const play = try gpa.alloc(u64, slate.patterns.maskWords(items.len));
    errdefer gpa.free(play);

    // `compile` already refused anything past the byte budget, so the only
    // decline left is the empty pool — which is the empty set, and has no
    // automaton to build. The `orelse` still answers rather than asserting: a
    // bound that moved underneath us must reach the host as a refusal, never as
    // a `die()` inside somebody's process.
    var trawl: ?slate.trawl.Trawl = null;
    if (items.len != 0) trawl = try slate.trawl.build(gpa, list, owner) orelse
        return error.TooManyPatterns;
    errdefer if (trawl) |*tr| tr.deinit(gpa);

    // A declined dispatcher is a performance choice, never a correctness one:
    // presence simply rides the trawl instead.
    const set: ?scan.LiteralSet = if (items.len != 0 and items.len <= scan.teddy.max_buckets)
        scan.LiteralSet.build(gpa, list, .exact) catch null
    else
        null;

    const handle = try gpa.create(Needles);
    handle.* = .{
        .text = text,
        .list = list,
        .owner = owner,
        .ending = ending,
        .play = play,
        .trawl = trawl,
        .set = set,
        .longest = longest,
    };
    return handle;
}

/// Release a handle from `compile`. Teardown leaves the fault slot alone, so a
/// host can still read the detail that made it clean up.
pub fn free(handle: *Needles) void {
    if (handle.set) |*s| s.deinit();
    if (handle.trawl) |*tr| tr.deinit(gpa);
    gpa.free(handle.play);
    gpa.free(handle.ending);
    gpa.free(handle.owner);
    gpa.free(handle.list);
    gpa.free(handle.text);
    gpa.destroy(handle);
}

/// How many needles the set holds — the exact `cap` `which` never needs to retry
/// at.
pub fn len(handle: *const Needles) usize {
    return handle.list.len;
}

/// Fill `out` with what this set is and which machine answers about it.
///
/// A pure reader: it starts no work, so it opens no fault window and cannot
/// disturb the detail a previous call left for the host.
pub fn describe(handle: *const Needles, out: ?*Shape) Status {
    const slot = out orelse return .invalid;
    if (slot.struct_size != @sizeOf(Shape)) return .invalid;
    slot.* = .{
        .struct_size = @sizeOf(Shape),
        .presence_tier = presenceTier(handle),
        .attributed_tier = if (handle.trawl == null) tier_none else tier_trawl,
        .count = handle.list.len,
        .longest = handle.longest,
        .bytes = handle.text.len,
    };
    return .ok;
}

fn presenceTier(handle: *const Needles) u32 {
    const s = &(handle.set orelse return if (handle.trawl == null) tier_none else tier_trawl);
    // `arity` is the dispatcher's own way of saying which KIND of machine it
    // picked; which of its five arms ran is not its published business, and a
    // report that guessed would be wrong for a set of two-byte needles.
    return switch (s.arity()) {
        .one => tier_memmem,
        .many => tier_literal_set,
    };
}

/// Does ANY needle occur in `text[0..len]`? `.match` yes, `.ok` no.
///
/// The cheap question, and it goes to the cheap machine: the byte tier's
/// dispatcher, priced on the buffer in hand (`findOn`) so a one-needle set gets
/// its anchor pair re-chosen against this document's alphabet rather than the
/// corpus the shipped rarity table was fitted to. Past the dispatcher's range it
/// is the trawl with a budget of one — the same early exit the sweep already
/// has, asked to stop at the first needle instead of the last.
pub fn isMatch(handle: *Needles, text: ?[*]const u8, text_len: usize) Status {
    contract.beginCall();
    const body = contract.view(text, text_len) orelse return .invalid;
    if (handle.set) |*s| {
        const hit = switch (s.findOn(body, 0)) {
            .exact, .candidate => |p| p != null,
        };
        return if (hit) .match else .ok;
    }
    const tr = &(handle.trawl orelse return .ok);
    @memset(handle.play, 0);
    return if (tr.sweep(body, handle.owner, handle.play, 1) == 0) .match else .ok;
}

/// Every needle occurring in `text[0..len]`, ascending, into `out[0..cap]`.
///
/// `*written` is how many occurred, which is the count whether or not `cap` held
/// them — so a host can ask with `cap = 0` purely to be told the size. It never
/// has to: the count can never exceed `irgx_needles_len`.
///
/// `.match` when at least one needle occurred, `.ok` when none did.
pub fn which(handle: *Needles, text: ?[*]const u8, text_len: usize, out: ?[*]u32, cap: usize, written: ?*usize) Status {
    contract.beginCall();
    var sink = contract.Sink(u32).open(out, cap, written) orelse return .invalid;
    const body = contract.view(text, text_len) orelse return .invalid;
    const tr = &(handle.trawl orelse return sink.close());

    @memset(handle.play, 0);
    // The budget is the whole set, so the sweep abandons the document the moment
    // every needle is accounted for — a hot term costs one report and is free
    // for the rest of the bytes.
    _ = tr.sweep(body, handle.owner, handle.play, handle.list.len);
    for (0..handle.list.len) |i|
        if (slate.patterns.maskHas(handle.play, i)) sink.push(@intCast(i));
    return sink.close();
}

/// Every occurrence in `text[0..len]`, attributed, into `out[0..cap]`.
///
/// Ascending end offset, ties ascending needle id, overlaps included — a needle
/// that is a suffix of another is reported beside it rather than swallowed by
/// it, which is the difference between this and a leftmost scan. `*written` is
/// the true total, so `cap = 0` sizes a buffer in one pass and the second call
/// allocates once.
///
/// A single stream where `which` runs six interleaved ones: the striped sweep
/// only has to reach the same SET, and can restart each stripe at the root
/// because setting a play bit twice is harmless, while a POSITION reported twice
/// is a wrong answer. So this walk pays the pointer chase that `which` does not,
/// which is the honest reason the two verbs are priced apart.
pub fn findAll(handle: *Needles, text: ?[*]const u8, text_len: usize, out: ?[*]Occurrence, cap: usize, written: ?*usize) Status {
    contract.beginCall();
    var sink = contract.Sink(Occurrence).open(out, cap, written) orelse return .invalid;
    const body = contract.view(text, text_len) orelse return .invalid;
    const tr = &(handle.trawl orelse return sink.close());

    var state: u32 = 0;
    for (body, 0..) |c, i| {
        state = tr.next[state * tr.ncols + tr.xlat[c]];
        if (!tr.reports[state]) continue;
        const here = gather(tr, state, handle.ending);
        std.sort.insertion(u32, here, {}, std.sort.asc(u32));
        for (here) |k| sink.push(.{
            .needle = k,
            .start = i + 1 - handle.list[k].len,
            .end = i + 1,
        });
    }
    return sink.close();
}

/// Every literal ending at `state`: its own output list, then those of every
/// proper suffix of it the dictionary link chains to. Unordered as the automaton
/// stores it — the caller sorts, because the order within one state's list is
/// build order and nothing a host should be able to observe.
fn gather(tr: *const slate.trawl.Trawl, state: u32, room: []u32) []u32 {
    var n: usize = 0;
    var at = state;
    while (at != none) : (at = tr.link[at]) {
        var k = tr.out_head[at];
        while (k != none) : (k = tr.out_next[k]) {
            room[n] = k;
            n += 1;
        }
    }
    return room[0..n];
}

// ── tests ──────────────────────────────────────────────────────────────────
//
// Every claim here is checked against an INDEPENDENT oracle — a naive
// `indexOfPos` loop per needle, sorted into this plane's stated order — and
// never against what the automaton returned, which would only prove the walk
// agrees with itself. The shapes are the ones a multi-substring matcher gets
// wrong: overlapping occurrences of one needle, a needle that is a suffix of
// another (the `she`/`he` case Aho-Corasick's dictionary link exists for),
// duplicates, a needle longer than the haystack, and occurrences planted on the
// 64-byte block edge and on the six-way stripe split, where `which`'s striped
// sweep and `findAll`'s single stream must still agree.

const t = std.testing;

fn open(words: []const []const u8) !*Needles {
    const items = try t.allocator.alloc(Needle, words.len);
    defer t.allocator.free(items);
    for (words, items) |w, *n| n.* = .{ .needle = w.ptr, .len = w.len };
    var handle: *Needles = undefined;
    try t.expectEqual(Status.ok, compile(items.ptr, items.len, 0, null, &handle));
    return handle;
}

/// The oracle: every occurrence of every needle, found without this plane's
/// automaton, in this plane's stated order.
fn oracle(words: []const []const u8, hay: []const u8) ![]Occurrence {
    var found: std.ArrayList(Occurrence) = .empty;
    errdefer found.deinit(t.allocator);
    for (words, 0..) |needle, i| {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, hay, at, needle)) |p| {
            try found.append(t.allocator, .{ .needle = @intCast(i), .start = p, .end = p + needle.len });
            at = p + 1; // +1, not +len: overlapping occurrences are occurrences
        }
    }
    std.mem.sortUnstable(Occurrence, found.items, {}, struct {
        fn lt(_: void, a: Occurrence, b: Occurrence) bool {
            return if (a.end != b.end) a.end < b.end else a.needle < b.needle;
        }
    }.lt);
    return found.toOwnedSlice(t.allocator);
}

/// All three verbs, one haystack, one oracle. `isMatch` and `which` reach
/// different machines than `findAll` does, so agreeing with the oracle is also
/// the only thing holding those machines to each other.
fn expectAgreement(words: []const []const u8, hay: []const u8) !void {
    const handle = try open(words);
    defer free(handle);
    const want = try oracle(words, hay);
    defer t.allocator.free(want);

    // The counting probe first: no buffer at all, and a true total.
    var n: usize = 12345;
    const expect: Status = if (want.len == 0) .ok else .match;
    try t.expectEqual(expect, findAll(handle, hay.ptr, hay.len, null, 0, &n));
    try t.expectEqual(want.len, n);

    const got = try t.allocator.alloc(Occurrence, want.len + 1);
    defer t.allocator.free(got);
    try t.expectEqual(expect, findAll(handle, hay.ptr, hay.len, got.ptr, got.len, &n));
    try t.expectEqualSlices(Occurrence, want, got[0..n]);

    // The set the stream implies, and the set the sweep reports, must be equal.
    var ids: std.ArrayList(u32) = .empty;
    defer ids.deinit(t.allocator);
    for (0..words.len) |i| {
        for (want) |o| if (o.needle == i) {
            try ids.append(t.allocator, @intCast(i));
            break;
        };
    }
    const named = try t.allocator.alloc(u32, words.len + 1);
    defer t.allocator.free(named);
    const set_expect: Status = if (ids.items.len == 0) .ok else .match;
    try t.expectEqual(set_expect, which(handle, hay.ptr, hay.len, named.ptr, named.len, &n));
    try t.expectEqualSlices(u32, ids.items, named[0..n]);
    try t.expectEqual(set_expect, isMatch(handle, hay.ptr, hay.len));
}

test "the sentinel this walk respells is still the automaton's" {
    const handle = try open(&.{ "alpha", "beta" });
    defer free(handle);
    const tr = &handle.trawl.?;
    // The root reports nothing (no empty needle can be compiled), so both of the
    // chain terminators this file reads must be the value it assumes.
    try t.expectEqual(none, tr.link[0]);
    try t.expectEqual(none, tr.out_head[0]);
    try t.expectEqual(@as(usize, 5), handle.longest);
}

test "overlaps, suffixes and duplicates are all occurrences" {
    // The classic Aho-Corasick set: `he` is a suffix of `she`, `hers` shares a
    // prefix with `he`, and every one of them has to be named at `ushers`.
    try expectAgreement(&.{ "he", "she", "his", "hers" }, "ushers");
    // One needle overlapping itself — three occurrences in four bytes, which a
    // leftmost-and-advance-by-length walk reports as two.
    try expectAgreement(&.{"aa"}, "aaaa");
    try expectAgreement(&.{ "aa", "aaa", "a" }, "aaaaa");
    // A needle that is a prefix of another, and the same needle listed twice:
    // two ordinals, both reported, because the host asked about both.
    try expectAgreement(&.{ "ab", "abc", "ab" }, "xxabcxxab");
    // Nothing at all, and a needle longer than the whole haystack.
    try expectAgreement(&.{ "zebra", "quagga" }, "xx");
    try expectAgreement(&.{"a-needle-far-longer-than-this"}, "short");
    try expectAgreement(&.{ "a", "b" }, "");
}

test "seams: the 64-byte block edge and the six-way stripe split" {
    // `which` stripes only past `stripes * (longest - 1 + 64)` bytes, so this
    // haystack is deliberately over that line while `findAll` walks it as one
    // stream. Occurrences are planted ON the boundaries the two disagree about.
    const words = [_][]const u8{ "seam", "seams", "ams", "xx" };
    var hay: [1024]u8 = @splat('.');
    const span = hay.len / 6; // the stripe width `sweep` computes
    for ([_]usize{ 0, 63, 64, 127, span - 2, span, span - 1, 2 * span - 3, 5 * span + 1, hay.len - 5 }) |at| {
        @memcpy(hay[at..][0..5], "seams");
    }
    try expectAgreement(&words, &hay);

    // And the degenerate neighbor: short enough that the sweep declines to
    // stripe at all, so both verbs run the same single stream.
    try expectAgreement(&words, hay[0..80]);
}

test "differential fuzz over random needles and random haystacks" {
    var prng = std.Random.DefaultPrng.init(0x9ee_d1e5);
    const r = prng.random();
    var storage: [12][4]u8 = undefined;
    var words: [12][]const u8 = undefined;
    var hay: [512]u8 = undefined;

    for (0..120) |_| {
        const count = 1 + r.uintLessThan(usize, words.len);
        for (0..count) |i| {
            const width = 1 + r.uintLessThan(usize, 4);
            for (storage[i][0..width]) |*b| b.* = 'a' + r.uintLessThan(u8, 3);
            words[i] = storage[i][0..width];
        }
        const n = r.uintLessThan(usize, hay.len);
        for (hay[0..n]) |*b| b.* = 'a' + r.uintLessThan(u8, 3);
        try expectAgreement(words[0..count], hay[0..n]);
    }
}

test "a wordlist past the byte tier's bucket count still attributes every needle" {
    // 300 needles: well past Teddy's 64 buckets, so presence rides the trawl and
    // the play set is five `u64` words rather than one. The bitmask-that-stops-
    // at-64 failure mode would lose every id from 64 up.
    var storage: [300][10]u8 = undefined;
    var words: [300][]const u8 = undefined;
    for (&storage, &words, 0..) |*buf, *w, i| w.* = try std.fmt.bufPrint(buf, "term{d:0>5}", .{i});
    try expectAgreement(&words, "nothing of interest here");
    try expectAgreement(&words, "term00299 then term00064 then term00000 and term00299 again");

    const handle = try open(&words);
    defer free(handle);
    var shape: Shape = undefined;
    shape.struct_size = @sizeOf(Shape);
    try t.expectEqual(Status.ok, describe(handle, &shape));
    try t.expectEqual(tier_trawl, shape.presence_tier);
    try t.expectEqual(tier_trawl, shape.attributed_tier);
    try t.expectEqual(@as(usize, 300), shape.count);
    try t.expectEqual(@as(usize, 9), shape.longest);
    try t.expectEqual(@as(usize, 2700), shape.bytes);
    try t.expectEqual(@as(usize, 300), len(handle));
}

test "the tier a set reaches for presence is the one it reports" {
    const single = try open(&.{"solitary"});
    defer free(single);
    const pair = try open(&.{ "alpha", "beta", "gamma" });
    defer free(pair);

    var shape: Shape = undefined;
    shape.struct_size = @sizeOf(Shape);
    try t.expectEqual(Status.ok, describe(single, &shape));
    try t.expectEqual(tier_memmem, shape.presence_tier);
    try t.expectEqual(tier_trawl, shape.attributed_tier);
    try t.expectEqual(Status.ok, describe(pair, &shape));
    try t.expectEqual(tier_literal_set, shape.presence_tier);

    // Fail closed on a size this build does not know, and on no `out` at all.
    shape.struct_size = @sizeOf(Shape) - 4;
    try t.expectEqual(Status.invalid, describe(pair, &shape));
    try t.expectEqual(Status.invalid, describe(pair, null));
}

test "an empty set answers rather than refusing" {
    var handle: *Needles = undefined;
    const nothing: [0]Needle = .{};
    try t.expectEqual(Status.ok, compile(&nothing, 0, 0, null, &handle));
    defer free(handle);
    try t.expectEqual(@as(usize, 0), len(handle));
    try t.expectEqual(Status.ok, isMatch(handle, "anything", 8));

    var shape: Shape = undefined;
    shape.struct_size = @sizeOf(Shape);
    try t.expectEqual(Status.ok, describe(handle, &shape));
    try t.expectEqual(tier_none, shape.presence_tier);
    try t.expectEqual(tier_none, shape.attributed_tier);

    var n: usize = 7;
    try t.expectEqual(Status.ok, which(handle, "anything", 8, null, 0, &n));
    try t.expectEqual(@as(usize, 0), n);
    try t.expectEqual(Status.ok, findAll(handle, "anything", 8, null, 0, &n));
    try t.expectEqual(@as(usize, 0), n);

    // The other spelling of "no needles", which is the only one some hosts have.
    var bare: *Needles = undefined;
    try t.expectEqual(Status.ok, compile(null, 0, 0, null, &bare));
    free(bare);
}

test "a short buffer is filled and the true total still published" {
    const handle = try open(&.{ "he", "she", "hers" });
    defer free(handle);

    var two: [2]Occurrence = undefined;
    var n: usize = 0;
    try t.expectEqual(Status.match, findAll(handle, "ushers", 6, &two, two.len, &n));
    // Three occurrences — `he` and `she` both ending at 4, `hers` at 6 — two
    // stored, and the tie broken by id rather than by start, so the SHORTER of
    // the two ends-together needles comes first.
    try t.expectEqual(@as(usize, 3), n);
    try t.expectEqual(@as(u32, 0), two[0].needle); // `he`, id 0, starts at 2
    try t.expectEqual(@as(usize, 2), two[0].start);
    try t.expectEqual(@as(u32, 1), two[1].needle); // `she`, id 1, starts at 1
    try t.expectEqual(@as(usize, 1), two[1].start);

    var one: [1]u32 = undefined;
    try t.expectEqual(Status.match, which(handle, "ushers", 6, &one, one.len, &n));
    try t.expectEqual(@as(usize, 3), n);
    try t.expectEqual(@as(u32, 0), one[0]);
}

test "every argument this plane cannot trust, refused" {
    const handle = try open(&.{"needle"});
    defer free(handle);

    // Null text with a length is a caller's arithmetic bug; null with zero is
    // the empty text, which every verb has an answer for.
    var n: usize = 0;
    var room: [4]Occurrence = undefined;
    try t.expectEqual(Status.invalid, findAll(handle, null, 3, &room, room.len, &n));
    try t.expectEqual(Status.ok, findAll(handle, null, 0, &room, room.len, &n));
    try t.expectEqual(Status.invalid, isMatch(handle, null, 3));
    // No total slot, and room promised but not given.
    try t.expectEqual(Status.invalid, findAll(handle, "x", 1, &room, room.len, null));
    try t.expectEqual(Status.invalid, findAll(handle, "x", 1, null, 4, &n));
    try t.expectEqual(Status.invalid, which(handle, "x", 1, null, 4, &n));

    // A flag bit this plane does not honor is refused, never ignored.
    var out: *Needles = undefined;
    var list = [_]Needle{.{ .needle = "cat", .len = 3 }};
    try t.expectEqual(Status.invalid, compile(&list, 1, contract.flag_ignore_case, null, &out));
    try t.expectEqual(Status.invalid, compile(&list, 1, 0, null, null));
    try t.expectEqual(Status.invalid, compile(null, 1, 0, null, &out));
}

test "an empty needle is refused by index, and so is a null one with a length" {
    const fault = @import("../../fault.zig");
    const sc = fault.scope();
    defer sc.end();

    var out: *Needles = undefined;
    var refused: usize = std.math.maxInt(usize);
    var list = [_]Needle{
        .{ .needle = "ok", .len = 2 },
        .{ .needle = "also ok", .len = 7 },
        .{ .needle = null, .len = 0 },
    };
    try t.expectEqual(Status.invalid, compile(&list, list.len, 0, &refused, &out));
    try t.expectEqual(@as(usize, 2), refused);
    try t.expectEqual(fault.Fault.NeedleTooShort, fault.last().?.code);

    // A live pointer with a zero length is the same empty needle, refused the
    // same way — the emptiness is the problem, not how it was spelled.
    list[2] = .{ .needle = "x", .len = 0 };
    try t.expectEqual(Status.invalid, compile(&list, list.len, 0, &refused, &out));
    try t.expectEqual(@as(usize, 2), refused);

    // Null WITH a length is a different bug and gets no fault, only the index.
    list[2] = .{ .needle = null, .len = 4 };
    try t.expectEqual(Status.invalid, compile(&list, list.len, 0, &refused, &out));
    try t.expectEqual(@as(usize, 2), refused);
}

test "a set past the automaton's byte budget is refused, not truncated" {
    const fault = @import("../../fault.zig");
    const sc = fault.scope();
    defer sc.end();

    // One needle over the line, and then a wordlist over it — the honest
    // failure the brief asks for instead of an answer about a prefix of the set.
    const wide = try t.allocator.alloc(u8, max_bytes + 1);
    defer t.allocator.free(wide);
    @memset(wide, 'q');

    var out: *Needles = undefined;
    var list = [_]Needle{.{ .needle = wide.ptr, .len = wide.len }};
    try t.expectEqual(Status.invalid, compile(&list, 1, 0, null, &out));
    try t.expectEqual(fault.Fault.TooManyPatterns, fault.last().?.code);

    // Exactly at the budget still compiles, which is what makes the refusal a
    // boundary rather than a vibe.
    list[0].len = max_bytes;
    try t.expectEqual(Status.ok, compile(&list, 1, 0, null, &out));
    free(out);
}

test "the set copies the needle bytes it was handed" {
    // A host is entitled to compile out of memory it then reuses. An aliasing
    // bug reads as a correct answer right up until the bytes change, so the test
    // has to be a scribble rather than a claim.
    var scribble: [8]u8 = "forbid\x00\x00".*;
    var list = [_]Needle{.{ .needle = &scribble, .len = 6 }};
    var handle: *Needles = undefined;
    try t.expectEqual(Status.ok, compile(&list, 1, 0, null, &handle));
    defer free(handle);
    try t.expectEqual(Status.match, isMatch(handle, "a forbid b", 10));

    @memset(&scribble, 'z');
    try t.expectEqual(Status.match, isMatch(handle, "a forbid b", 10));
    try t.expectEqual(Status.ok, isMatch(handle, "zzzzzz", 6));
}
