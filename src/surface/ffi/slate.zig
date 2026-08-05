//! The many-patterns-over-one-text plane — `libirgx`'s slate C ABI.
//!
//! The pattern plane next door answers about one pattern. This one answers about
//! N in a single pass over the bytes, and keeps which pattern found what. That
//! last clause is the whole reason it exists: N single-pattern calls produce the
//! same answer at N times the byte cost, and one fused `a|b|c` produces it in one
//! pass while throwing the attribution away.
//!
//! What a host gets is two questions and no cursor:
//!
//!   * `isMatch` — does ANY of them match? The cheapest one, and the one a batch
//!     workload spends its time in. A SIMD literal roll rejects a text nothing
//!     can match without any engine running, and can even answer YES outright
//!     when a pattern's literals decide it.
//!   * `which` — WHICH of them match, ascending. Attribution, not a boolean.
//!
//! There is no per-pattern span verb, and that is a real edge rather than an
//! omission to apologize for: a slate is a *classifier*. Once a host knows
//! pattern 7 is in this text, `irgx_find_all` on pattern 7 is the same walk it
//! would have run anyway, against a text that is now known to be worth walking.
//!
//! **The unit is the whole text**, exactly as it is for the pattern plane. `^`
//! and `$` are the text's ends, `\s` can match a line terminator, and an empty
//! text is a text a nullable pattern matches. Saying that costs one sentence and
//! buys the property that matters: `which` names pattern `i` iff
//! `irgx_is_match` on pattern `i` alone would have said yes, for every pattern
//! and every text. The slate kernel underneath also has a per-LINE face, which
//! is the right unit for a grep walking a corpus and the wrong one here; the two
//! disagree on every anchored pattern, so this plane calls the buffer face
//! (`slate/patterns.zig::bufMask`) and the parity suite there holds it to the
//! single-pattern library oracle with the accelerators both on and off.
//!
//! Two rules it inherits from the pattern plane, for the same reasons:
//!
//!   * **A handle is single-threaded.** It owns the per-scan scratch, so two
//!     threads sharing one would corrupt an answer rather than race a counter.
//!   * **Nothing can `die()` the host.** Every entry returns a `Status` and
//!     leaves the per-incident detail in the thread's fault slot.

const std = @import("std");
const contract = @import("contract.zig");
const fault = @import("../../fault.zig");
const slate = @import("../../kernel/slate/slate.zig");
const pattern_plane = @import("pattern.zig");
const qy = @import("../../kernel/query/query.zig");
const rx = @import("../../kernel/regex/regex.zig");
const verdict = @import("../../exec/cold/argv/verdict.zig");

const Status = contract.Status;
const gpa = std.heap.c_allocator;

/// One pattern of a slate: the bytes, and the same flag word `irgx_compile`
/// takes.
///
/// One flag vocabulary for both planes, rather than a second spelling of
/// "ignore case" — with the two flags a slate cannot honor rejected instead of
/// ignored (`contract.slate_flags`). Extern and append-only, so a later field is
/// a forward-compatible extension.
pub const Pattern = extern struct {
    pattern: ?[*]const u8,
    len: usize,
    flags: u32,
};

/// A compiled slate and the scratch its scans run in. Opaque to C — a host only
/// ever holds the pointer — so it is a plain struct rather than an `extern` one,
/// as `pattern.Regex` is for the same reason.
pub const Slate = struct {
    set: *slate.PatternSet,
    scratch: *slate.PatternSet.Scratch,
    /// Every pattern's bytes, one allocation.
    ///
    /// Copied rather than borrowed, and this field is the copy. `CompiledQuery`
    /// aliases the pattern slice it compiled for the life of the query, which is
    /// a fine contract between two Zig callers and an impossible one to publish
    /// across an ABI: a host is entitled to compile a slate out of a stack
    /// buffer, or a Python `str` that gets collected. The alternative — telling
    /// every host "keep your pattern bytes alive as long as the handle" — is a
    /// rule that is honored right up until it isn't, and the failure is a
    /// use-after-free inside the engine rather than an error a host can see.
    text: []const u8,
    /// `maskWords(len)` words, owned. The kernel answers into a bitmask; `which`
    /// reads it out as ascending ids, so a host never learns the mask exists.
    mask: []u64,
};

/// Compile `count` patterns as one slate.
///
/// `refused` is the diagnosis a slate needs and a single pattern does not: with
/// two hundred patterns, "one of them is unsupported" is not an actionable
/// answer. On a refusal it receives the index of the pattern that caused it,
/// while the thread's fault slot carries the reason (`Unsupported`, routing the
/// host to `IRGX_PCRE`, versus a located `BadPattern`) exactly as the pattern
/// plane's compile does. It may be null for a host that does not care.
///
/// A slate is all-or-nothing, which is a choice worth naming because the package
/// contains the other one: `Munch` admits patterns by bisection so a single
/// refusal cannot cost the other hundred and fifty. That belongs here too
/// eventually. Until it does, the refusal is total and says which pattern.
pub fn compile(list: ?[*]const Pattern, count: usize, refused: ?*usize, out: ?**Slate) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    // An empty slate is not a degenerate case worth special-casing away — it is
    // the natural answer to a host whose config file listed no patterns, and
    // every verb has an answer for it (nothing matches). Null-with-zero is the
    // same thing said in the only spelling some hosts can produce: Go's
    // `&slice[0]` does not exist for an empty slice, and C's answer for "the
    // address of no array" is conventionally NULL. There is nothing to read
    // either way, so reading it as a caller bug would cost every binding a dummy
    // pointer and buy no safety.
    const items: []const Pattern = if (list) |p|
        p[0..count]
    else if (count == 0)
        &.{}
    else
        return .invalid;

    var total: usize = 0;
    for (items) |item| {
        if (item.flags & ~contract.slate_flags != 0) return .invalid;
        if (item.pattern == null and item.len != 0) return .invalid;
        total += item.len;
    }

    // Assembled by hand rather than with `errdefer`, which a Status-returning
    // entry never fires. Each step unwinds exactly what the steps before it
    // took, so a failed compile leaks nothing into a host that keeps running.
    const text = gpa.alloc(u8, total) catch return contract.report(.{ .code = error.OutOfMemory });
    const specs = gpa.alloc(qy.Spec, count) catch {
        gpa.free(text);
        return contract.report(.{ .code = error.OutOfMemory });
    };
    defer gpa.free(specs); // the SPECS are scratch; `text` is what outlives them

    var at: usize = 0;
    for (items, specs, 0..) |item, *spec, i| {
        const body = text[at..][0..item.len];
        if (item.len != 0) @memcpy(body, item.pattern.?[0..item.len]);
        at += item.len;
        const fixed = item.flags & contract.flag_fixed != 0;
        const pcre = item.flags & contract.flag_pcre != 0;

        // Per pattern, because on a slate that is what a directive is: pattern 3
        // saying `(?i)` is a statement about pattern 3, and the one thing the
        // fused line gate could not have expressed is exactly what this plane's
        // per-pattern confirm makes free. Read on the same two conditions as the
        // pattern plane (never under `-F`, never for the PCRE2 arm) so one
        // pattern means one thing whichever plane compiles it.
        const asked: rx.syntax.Directive = switch (if (fixed or pcre) .none else rx.syntax.preamble(body)) {
            .asks => |d| d,
            .none, .beyond => .{ .rest = body },
        };
        // `(?m)`/`(?s)` are refused rather than dropped, for the reason
        // `slate_flags` refuses their flag-word twins: a `Spec` has nowhere to
        // carry them, and a host that wrote one has a belief about the answer it
        // is about to get. Same status, same `refused` index, so the two
        // spellings of the same request fail the same way.
        if (asked.line_anchors != null or asked.dotall != null) {
            if (refused) |r| r.* = i;
            gpa.free(text);
            return contract.report(.{ .code = error.Unsupported });
        }
        const smart = item.flags & contract.flag_smart_case != 0;
        spec.* = .{
            .pattern = asked.rest,
            .fixed = fixed,
            // Resolved HERE, through the same `hasUpper` predicate the CLI's
            // `-S` runs, so a slate and a shell agree about a pattern's case
            // sensitivity. The kernel never sees `smart_case`; it is a question
            // about the pattern text, and this is where the text is.
            .ignore_case = asked.caseless orelse (item.flags & contract.flag_ignore_case != 0 or
                (smart and !verdict.hasUpper(asked.rest))),
            .unicode = asked.unicode orelse (item.flags & contract.flag_no_unicode == 0),
            .word = item.flags & contract.flag_word != 0,
            .pcre = pcre,
        };
    }

    const set = gpa.create(slate.PatternSet) catch {
        gpa.free(text);
        return contract.report(.{ .code = error.OutOfMemory });
    };
    // `.buffer`, because both verbs here take the text as one unit. It is also
    // what keeps a two-hundred-pattern slate compiling in milliseconds: the line
    // face's fused gate prices the whole alternation at once, and this plane
    // could not use it even if it were free.
    set.* = slate.PatternSet.compileFor(gpa, specs, .buffer) catch |e| {
        gpa.destroy(set);
        // Freed on the way OUT of this block, not before it: `blame` recompiles
        // the specs, whose pattern slices point into `text`.
        defer gpa.free(text);
        return switch (e) {
            error.OutOfMemory => contract.report(.{ .code = e }),
            // `PatternSet.compile` refuses at the first pattern it cannot take
            // and does not say which, so the index is recovered by compiling
            // each alone. Paid only on the error path, where a host is about to
            // print a diagnostic anyway, and it is the only way to answer the
            // question a host actually has.
            error.Unsupported => blame(specs, refused),
        };
    };

    const scratch = gpa.create(slate.PatternSet.Scratch) catch {
        set.deinit(gpa);
        gpa.destroy(set);
        gpa.free(text);
        return contract.report(.{ .code = error.OutOfMemory });
    };
    scratch.* = set.scratch(gpa) catch {
        gpa.destroy(scratch);
        set.deinit(gpa);
        gpa.destroy(set);
        gpa.free(text);
        return contract.report(.{ .code = error.OutOfMemory });
    };

    const mask = gpa.alloc(u64, slate.patterns.maskWords(count)) catch {
        scratch.deinit(gpa);
        gpa.destroy(scratch);
        set.deinit(gpa);
        gpa.destroy(set);
        gpa.free(text);
        return contract.report(.{ .code = error.OutOfMemory });
    };

    const handle = gpa.create(Slate) catch {
        gpa.free(mask);
        scratch.deinit(gpa);
        gpa.destroy(scratch);
        set.deinit(gpa);
        gpa.destroy(set);
        gpa.free(text);
        return contract.report(.{ .code = error.OutOfMemory });
    };
    handle.* = .{ .set = set, .scratch = scratch, .text = text, .mask = mask };
    slot.* = handle;
    return .ok;
}

/// Which pattern refused, and why — recompiled one at a time.
///
/// Reports through the same `refuse` reasoning the pattern plane uses, so a host
/// gets `.stale` (a declinature: `IRGX_PCRE` would take this pattern) or a
/// located `BadPattern`, rather than one opaque code for two problems with
/// different remedies.
fn blame(specs: []const qy.Spec, refused: ?*usize) Status {
    for (specs, 0..) |spec, i| {
        var one = qy.CompiledQuery.compile(gpa, spec) catch {
            if (refused) |r| r.* = i;
            return pattern_plane.refuse(spec.pattern, spec.ignore_case, spec.unicode, spec.pcre);
        };
        one.deinit(gpa);
    }
    // Unreachable in practice: the set refused, so some pattern must. Answered
    // rather than asserted, because a `die()` here would take down a host over
    // a diagnostic.
    return contract.report(.{ .code = error.Unsupported });
}

/// Release a handle from `compile`. Teardown leaves the fault slot alone, so a
/// host can still read the detail that made it clean up.
pub fn free(handle: *Slate) void {
    gpa.free(handle.mask);
    handle.scratch.deinit(gpa);
    gpa.destroy(handle.scratch);
    handle.set.deinit(gpa);
    gpa.destroy(handle.set);
    gpa.free(handle.text);
    gpa.destroy(handle);
}

/// How many patterns the slate holds — the exact `cap` `which` never needs to
/// retry at.
pub fn len(handle: *const Slate) usize {
    return handle.set.len();
}

/// Does ANY pattern match `text[0..len]`? `.match` yes, `.ok` no.
pub fn isMatch(handle: *Slate, text: ?[*]const u8, text_len: usize) Status {
    contract.beginCall();
    const body = view(text, text_len) orelse return .invalid;
    const hit = handle.set.bufAnyMatch(body, handle.scratch, gpa) catch |e|
        return contract.report(.{ .code = faultOf(e) });
    return if (hit) .match else .ok;
}

/// Every pattern matching `text[0..len]`, ascending, into `out[0..cap]`.
///
/// `*written` is how many matched, which is the count whether or not `cap` held
/// them — the same contract `irgx_find_all` keeps, so a short buffer sizes its
/// own retry. Unlike there, a host can always avoid the retry: the count can
/// never exceed `irgx_slate_len`.
///
/// `.match` when at least one pattern matched, `.ok` when none did.
pub fn which(handle: *Slate, text: ?[*]const u8, text_len: usize, out: ?[*]u32, cap: usize, written: ?*usize) Status {
    contract.beginCall();
    const count = written orelse return .invalid;
    count.* = 0;
    const body = view(text, text_len) orelse return .invalid;
    if (cap != 0 and out == null) return .invalid;

    const any = handle.set.bufMask(body, handle.scratch, gpa, handle.mask) catch |e|
        return contract.report(.{ .code = faultOf(e) });
    if (!any) return .ok;

    var found: usize = 0;
    for (0..handle.set.len()) |i| {
        if (!slate.patterns.maskHas(handle.mask, i)) continue;
        if (found < cap) out.?[found] = @intCast(i);
        found += 1;
    }
    count.* = found;
    return .match;
}

/// The one place a `(pointer, length)` pair becomes a slice. Null with a
/// non-zero length is a caller error; null with zero length is the empty text,
/// which every verb has an answer for.
fn view(text: ?[*]const u8, text_len: usize) ?[]const u8 {
    if (text) |p| return p[0..text_len];
    return if (text_len == 0) &.{} else null;
}

/// Narrow a kernel error onto the fault vocabulary this ABI publishes. The scan
/// verbs can only fail by exhaustion (materializing the span scratch on first
/// use); `Unsupported` was settled at compile time.
fn faultOf(e: anyerror) fault.Fault {
    return @errorCast(e);
}

// ── tests ──────────────────────────────────────────────────────────────────
//
// The plane's own contract is thin — copy the patterns, read the mask out as
// ids, keep the statuses straight — because what a slate MEANS is settled one
// layer down and proved there against the single-pattern oracle
// (`slate/patterns_test.zig`, the buffer-face section). So these tests are about
// the seam: that the answer here equals the answer the pattern plane gives for
// the same pattern and text, that a host's pattern bytes are not aliased, and
// that every refusal says which pattern and why.

const t = std.testing;

fn open(list: []const Pattern) *Slate {
    var handle: *Slate = undefined;
    var refused: usize = std.math.maxInt(usize);
    const st = compile(list.ptr, list.len, &refused, &handle);
    std.debug.assert(st == .ok);
    return handle;
}

fn spell(text: []const u8, flags: u32) Pattern {
    return .{ .pattern = text.ptr, .len = text.len, .flags = flags };
}

fn ids(handle: *Slate, text: []const u8) []const u32 {
    var buf: [16]u32 = undefined;
    var n: usize = 0;
    _ = which(handle, text.ptr, text.len, &buf, buf.len, &n);
    std.debug.assert(n <= buf.len);
    // Returned from a static so a caller can compare without owning anything;
    // one test at a time, which is the discipline of this whole file's handles.
    const held = struct {
        var slot: [16]u32 = undefined;
    };
    @memcpy(held.slot[0..n], buf[0..n]);
    return held.slot[0..n];
}

test "a slate names exactly the patterns the pattern plane would" {
    // The seam's real claim, checked against the OTHER plane rather than against
    // a table: two verbs of one library must not tell a host different things
    // about whether a pattern matches a string. The shapes here are the ones
    // where a line-unit slate would have diverged.
    const spellings = [_][]const u8{ "a\\sb", "^b", "c$", "x*", "b", "q" };
    const texts = [_][]const u8{ "", "abc", "a\nb", "ab\ncd", "\n", "abc\n" };

    var list: [spellings.len]Pattern = undefined;
    for (spellings, &list) |s, *p| p.* = spell(s, 0);
    const handle = open(&list);
    defer free(handle);

    for (texts) |text| {
        const got = ids(handle, text);
        for (spellings, 0..) |s, i| {
            var one: *pattern_plane.Regex = undefined;
            try t.expectEqual(Status.ok, pattern_plane.compile(s.ptr, s.len, 0, &one));
            defer pattern_plane.free(one);
            const want = pattern_plane.isMatch(one, text.ptr, text.len) == .match;

            var named = false;
            for (got) |id| named = named or id == i;
            t.expectEqual(want, named) catch |e| {
                std.debug.print("pattern={s} text={s} plane={} slate={}\n", .{ s, text, want, named });
                return e;
            };
        }
        // And the boolean verb agrees with its own attribution.
        try t.expectEqual(got.len != 0, isMatch(handle, text.ptr, text.len) == .match);
    }
}

test "ids arrive ascending, and the count is the slate's not the buffer's" {
    var list = [_]Pattern{ spell("a", 0), spell("b", 0), spell("c", 0), spell("d", 0) };
    const handle = open(&list);
    defer free(handle);
    try t.expectEqual(@as(usize, 4), len(handle));

    var buf: [4]u32 = undefined;
    var n: usize = 0;
    try t.expectEqual(Status.match, which(handle, "dcba", 4, &buf, buf.len, &n));
    try t.expectEqual(@as(usize, 4), n);
    try t.expectEqualSlices(u32, &.{ 0, 1, 2, 3 }, buf[0..n]);

    // A short buffer fills what it can and still reports the true count, so the
    // retry is sizeable from the answer. It never has to be sized that way here
    // — `len` is the ceiling — but the contract matches `find_all`'s rather than
    // inventing a second one.
    var two: [2]u32 = undefined;
    try t.expectEqual(Status.match, which(handle, "dcba", 4, &two, two.len, &n));
    try t.expectEqual(@as(usize, 4), n);
    try t.expectEqualSlices(u32, &.{ 0, 1 }, &two);

    // No match is `.ok` with a zero count, not an empty `.match`.
    try t.expectEqual(Status.ok, which(handle, "zzz", 3, &buf, buf.len, &n));
    try t.expectEqual(@as(usize, 0), n);
    try t.expectEqual(Status.ok, isMatch(handle, "zzz", 3));
}

test "the flag word means what it means on the other plane" {
    var list = [_]Pattern{
        spell("CAT", contract.flag_fixed | contract.flag_ignore_case),
        spell("cat", contract.flag_word),
        spell("c.t", 0),
        spell("Cat", contract.flag_smart_case), // has upper ⇒ stays sensitive
        spell("cat", contract.flag_smart_case), // no upper ⇒ becomes caseless
    };
    const handle = open(&list);
    defer free(handle);

    // `c.t` is case-SENSITIVE here, so it is absent from the capitalized text
    // and present in the two lowercase ones — the flag word doing nothing is as
    // much of the claim as the flag word doing something.
    try t.expectEqualSlices(u32, &.{ 0, 3, 4 }, ids(handle, "Cat"));
    // `-w` excludes the substring; smart-case on a lowercase pattern does not.
    try t.expectEqualSlices(u32, &.{ 0, 2, 4 }, ids(handle, "concatenate"));
    try t.expectEqualSlices(u32, &.{ 0, 1, 2, 4 }, ids(handle, "a cat sat"));
}

test "each pattern's own directive is read as that pattern's flags" {
    // The per-pattern statement a fused alternation could not have made: three
    // patterns, three different case rules, one pass. This is also the plane
    // where a host's patterns are least likely to be its own — a slate is what a
    // config file of user-written patterns compiles to — so `(?i)` arriving
    // inside pattern 1 has to work without a flag word the host would have to
    // parse the pattern to know it needed.
    var list = [_]Pattern{
        spell("cat", 0), // sensitive
        spell("(?i)cat", 0), // caseless, by its own spelling
        spell("(?-i)cat", contract.flag_ignore_case), // the exception to the host's own flag
        spell("(?i)dog", contract.flag_fixed), // data, not a directive
    };
    const handle = open(&list);
    defer free(handle);

    try t.expectEqualSlices(u32, &.{ 0, 1, 2 }, ids(handle, "a cat"));
    try t.expectEqualSlices(u32, &.{1}, ids(handle, "a CAT"));
    try t.expectEqualSlices(u32, &.{3}, ids(handle, "the literal (?i)dog"));

    // And it agrees with the other plane pattern for pattern, which is the whole
    // contract of this file: same spelling, same answer, either door.
    for ([_][]const u8{ "a cat", "a CAT", "the literal (?i)dog" }) |text| {
        const named = ids(handle, text);
        for (list, 0..) |item, i| {
            var one: *pattern_plane.Regex = undefined;
            const body = item.pattern.?[0..item.len];
            try t.expectEqual(Status.ok, pattern_plane.compile(body.ptr, body.len, item.flags, &one));
            defer pattern_plane.free(one);
            const want = pattern_plane.isMatch(one, text.ptr, text.len) == .match;
            var found = false;
            for (named) |id| found = found or id == i;
            t.expectEqual(want, found) catch |e| {
                std.debug.print("pattern={s} text={s} plane={} slate={}\n", .{ body, text, want, found });
                return e;
            };
        }
    }
}

test "a directive a slate cannot carry is refused by index, like its flag twin" {
    const sc = fault.scope();
    defer sc.end();
    var handle: *Slate = undefined;

    // `(?m)`/`(?s)` have nowhere to live in a `Spec`, so the two spellings of the
    // same request have to fail the same way — otherwise the flag word is
    // rejected and the pattern text silently isn't honored.
    for ([_][]const u8{ "(?m)^b", "(?s)a.b" }) |p| {
        var list = [_]Pattern{ spell("a", 0), spell(p, 0) };
        var refused: usize = std.math.maxInt(usize);
        try t.expectEqual(Status.invalid, compile(&list, list.len, &refused, &handle));
        try t.expectEqual(@as(usize, 1), refused);
        try t.expectEqual(fault.Fault.Unsupported, fault.last().?.code);
    }

    // A flag this grammar does not have still routes to the arm that does, and
    // still says which pattern asked.
    var wide = [_]Pattern{ spell("a", 0), spell("(?x)a b", 0) };
    var at: usize = std.math.maxInt(usize);
    try t.expectEqual(Status.stale, compile(&wide, wide.len, &at, &handle));
    try t.expectEqual(@as(usize, 1), at);
    wide[1].flags = contract.flag_pcre;
    try t.expectEqual(Status.ok, compile(&wide, wide.len, null, &handle));
    free(handle);
}

test "a slate the host cannot honor is refused, and it says which flag" {
    var handle: *Slate = undefined;
    // The two flags a slate has nowhere to carry. Rejected rather than dropped:
    // a host that passed them believes something about the answer it is about to
    // get.
    for ([_]u32{ contract.flag_multiline, contract.flag_dotall }) |flag| {
        var list = [_]Pattern{ spell("a", 0), spell("b", flag) };
        try t.expectEqual(Status.invalid, compile(&list, list.len, null, &handle));
    }
    // A null body with a length is a caller bug; a null body with no length is
    // the empty pattern, which is a pattern.
    var bad = [_]Pattern{.{ .pattern = null, .len = 3, .flags = 0 }};
    try t.expectEqual(Status.invalid, compile(&bad, 1, null, &handle));
    var empty = [_]Pattern{.{ .pattern = null, .len = 0, .flags = 0 }};
    try t.expectEqual(Status.ok, compile(&empty, 1, null, &handle));
    free(handle);
    // No `out` at all, and a null `written` on the read side.
    try t.expectEqual(Status.invalid, compile(&empty, 1, null, null));
}

test "a refused pattern is named by index, with the reason of the pattern plane" {
    var handle: *Slate = undefined;
    var refused: usize = std.math.maxInt(usize);

    // Lookahead: outside the linear grammar, inside PCRE2's. So this is a
    // DECLINATURE (`.stale` — retry with IRGX_PCRE), not a bad pattern.
    var routable = [_]Pattern{ spell("a", 0), spell("b", 0), spell("c(?=at)", 0) };
    try t.expectEqual(Status.stale, compile(&routable, routable.len, &refused, &handle));
    try t.expectEqual(@as(usize, 2), refused);

    // An unbalanced class is not a regex under any grammar, so no tier can be
    // pointed at and it is a fault.
    var broken = [_]Pattern{ spell("ok", 0), spell("[z-a", 0) };
    try t.expectEqual(Status.invalid, compile(&broken, broken.len, &refused, &handle));
    try t.expectEqual(@as(usize, 1), refused);
    var detail: contract.FaultDetail = .{
        .struct_size = @sizeOf(contract.FaultDetail),
        .status = 0,
        .at_space = 0,
        .name = "",
        .path = null,
        .path_len = 0,
        .at = 0,
    };
    try t.expectEqual(Status.match, contract.lastFault(&detail));
    try t.expectEqualStrings("BadPattern", std.mem.span(detail.name));

    // The same pattern under IRGX_PCRE compiles, which is what `.stale` above
    // was telling the host to do.
    var pcre = [_]Pattern{spell("c(?=at)", contract.flag_pcre)};
    try t.expectEqual(Status.ok, compile(&pcre, 1, &refused, &handle));
    defer free(handle);
    try t.expectEqualSlices(u32, &.{0}, ids(handle, "a cat"));
}

test "the slate copies the patterns it was handed" {
    // A host is entitled to compile out of memory it then reuses. The kernel
    // aliases a spec's pattern slice for the life of the query, so this plane
    // has to copy — and the test has to be a scribble rather than a claim,
    // since an aliasing bug reads as a correct answer right up until the bytes
    // change.
    var scribble: [8]u8 = "cat|dog\x00".*;
    var list = [_]Pattern{spell(scribble[0..7], 0)};
    const handle = open(&list);
    defer free(handle);
    try t.expectEqualSlices(u32, &.{0}, ids(handle, "a dog"));

    @memset(&scribble, 'z');
    try t.expectEqualSlices(u32, &.{0}, ids(handle, "a dog"));
    try t.expectEqual(@as(usize, 0), ids(handle, "zzzzzzz").len);
}

test "an empty slate answers rather than refusing" {
    // The natural shape of a config file that listed no patterns. Nothing
    // matches, and both verbs say so in their own vocabulary.
    var handle: *Slate = undefined;
    const none: [0]Pattern = .{};
    try t.expectEqual(Status.ok, compile(&none, 0, null, &handle));
    defer free(handle);
    try t.expectEqual(@as(usize, 0), len(handle));
    try t.expectEqual(Status.ok, isMatch(handle, "anything", 8));
    var n: usize = 1;
    try t.expectEqual(Status.ok, which(handle, "anything", 8, null, 0, &n));
    try t.expectEqual(@as(usize, 0), n);

    // And said the other way it can be said: a host with no patterns often has
    // no array either, and NULL is the only address it can pass for one. Go's
    // `&slice[0]` does not exist for an empty slice, so refusing this would cost
    // that binding a dummy pointer to satisfy a rule about memory nobody reads.
    var bare: *Slate = undefined;
    try t.expectEqual(Status.ok, compile(null, 0, null, &bare));
    defer free(bare);
    try t.expectEqual(@as(usize, 0), len(bare));
    try t.expectEqual(Status.ok, isMatch(bare, "anything", 8));
    // A null list with a count, though, is a caller bug and stays one.
    var handle2: *Slate = undefined;
    try t.expectEqual(Status.invalid, compile(null, 1, null, &handle2));
}
