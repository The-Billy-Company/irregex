//! The regex-over-text plane — `libirgx`'s own C ABI.
//!
//! What a host reaches for when it has a pattern and a buffer, and no corpus:
//! compile once, then ask `is_match` / `find_all` / `captures` about bytes it
//! already holds. That is the whole difference from `libgist`, which is about a
//! *tree* — a session, a walk, freshness, an index. Splitting them is what lets
//! a host that only wants a regex link a library that only has one.
//!
//! Every verb here is a shim over machinery the CLI already runs:
//! `CompiledQuery` (the compile → prefilter → match kernel both engines share)
//! and `Caps` (the one-pass / Pike / PCRE2 capture seam). Nothing in this file
//! decides what a pattern means — which is the point. An in-process
//! `irgx_captures` returns the offsets `gist --json` would print for the
//! same pattern because it is the same arm, reached through the same door.
//!
//! Two rules the whole plane keeps:
//!
//!   * **A handle is single-threaded.** `Regex` owns per-find scratch (the
//!     simulation lists, the slot vector), so two threads sharing one handle
//!     would corrupt a match rather than race a counter. Compile one per
//!     thread; the compile itself is pure and cheap to repeat.
//!   * **Nothing can `die()` the host.** Every entry returns a `Status` and
//!     leaves the per-incident detail in the thread's fault slot, exactly as
//!     the session ABI does.

const std = @import("std");
const contract = @import("contract.zig");
const fault = @import("../../fault.zig");
const qy = @import("../../kernel/query/query.zig");
const rows = @import("rows.zig");
const rx = @import("../../kernel/regex/regex.zig");
const verdict = @import("../../exec/cold/argv/verdict.zig");

const Status = contract.Status;
const gpa = std.heap.c_allocator;

/// The one place a `(pointer, length)` pair becomes a slice. Null with a
/// non-zero length is a caller error; null with zero length is the empty text,
/// which is a question every verb has an answer for.
fn view(text: ?[*]const u8, len: usize) ?[]const u8 {
    if (text) |p| return p[0..len];
    return if (len == 0) &.{} else null;
}

/// Answer a refused pattern with the one thing a host can act on: whether a
/// slower engine here would take it.
///
/// `[fault_domains]` already drew this line and named both channels —
/// `Unsupported` is "a declinature while PCRE2 can still answer it, a fault once
/// PCRE2 has refused", and `BadPattern` is "the grammar itself rejects it, so no
/// slower engine could answer it either". The kernel cannot tell them apart (its
/// parser returns one `BadPattern` for both and the query layer folds that to
/// `Unsupported`), so this seam used to hand a host one opaque answer for two
/// problems, only one of which has a remedy.
///
/// So ask the authority. PCRE2 is definitionally the judge of what PCRE2 can
/// express, and a construct list maintained here would drift from it the first
/// time PCRE2 grew one. It costs a second compile on a path that has already
/// failed, and it yields PCRE2's own error offset for the malformed case.
///
/// The three answers, in the vocabulary that already exists:
///
///   - **`.stale`** — PCRE2 takes it, so this is `unsupported_syntax`, whose
///     declared fallback *is* `pcre2`. `--engine auto` escalates across that
///     same seam in the CLI; here the caller escalates by setting
///     `IRGX_PCRE`. A declinature is not a failure, so per the seam's own
///     law it is returned directly and installs **no** fault — which also means
///     a host decides from the return value alone, with no second call.
///   - **`error.BadPattern` + `at`** — PCRE2 refuses it too. Nothing can answer
///     it, and PCRE2 located the problem.
///   - **`error.Unsupported`** — there is no PCRE2 to escalate to (a build
///     without it, or one that could not answer). A tier that does not exist has
///     refused, which is exactly when the declinature becomes the fault.
///
/// `already_pcre` says PCRE2 is what just refused, so there is nothing left to
/// consult and no tier left to route to.
fn refuse(pattern: []const u8, caseless: bool, unicode: bool, already_pcre: bool) Status {
    if (already_pcre) return contract.report(.{ .code = error.BadPattern, .at = rx.pcre2.lastErrorOffset() });

    var probe = rx.pcre2.Pcre.compileOpts(gpa, pattern, .{ .caseless = caseless, .unicode = unicode }) catch |e| switch (e) {
        error.BadPattern => return contract.report(.{ .code = error.BadPattern, .at = rx.pcre2.lastErrorOffset() }),
        // Out of memory says nothing about the pattern, and a build without
        // PCRE2 has no tier to point at. Either way no escalation exists, so
        // routing the caller to one would be a lie.
        else => return contract.report(.{ .code = error.Unsupported }),
    };
    probe.deinit();
    return .stale;
}

/// One capture group's byte range `[start, end)` within the searched text, or
/// `-1`/`-1` for a group the match did not enter. Signed because absence is a
/// real answer here — `(a)|(b)` always leaves one of the two unset — and a
/// sentinel outside `usize` is how the slot vector already spells it.
pub const Span = extern struct {
    start: i64,
    end: i64,

    const unset: Span = .{ .start = -1, .end = -1 };
};

/// A compiled pattern plus the mutable state its finds run in.
///
/// The two engines are lazily paired, not eagerly: `query` is built at compile
/// time because every verb needs it, and `caps` only when a caller first asks
/// for groups. Most hosts never do — `is_match` and `find_all` are the traffic
/// — and the capture arm is a second lowering plus a determinization attempt.
pub const Regex = struct {
    /// The pattern as given. Owned: `Spec` *aliases* a literal body, so a host
    /// freeing its buffer after `compile` would leave the query dangling.
    pattern: []u8,
    query: qy.CompiledQuery,
    /// One scratch, because every verb here asks the same line-scoped question:
    /// `is_match` is `find_all` stopped at the first span, so it runs on the
    /// same walk and needs the same state.
    spans: qy.MatchScratch,
    found: std.ArrayList(qy.Span),

    caps: ?rx.Caps = null,
    slots: []isize = &.{},
    /// Whether the capture arm has been attempted. A refusal is remembered, so
    /// a host looping over `captures` pays one failed lowering, not N.
    caps_tried: bool = false,
    /// The pattern the capture arm compiles: the escaped spelling under `-F`,
    /// where the raw bytes are data rather than syntax. Empty when unescaped.
    escaped: []u8 = &.{},

    /// Pattern semantics, kept because the capture arm re-derives them and
    /// because `-w` is a post-match rule no engine applies for us.
    caseless: bool,
    unicode: bool,
    word: bool,
    fixed: bool,
    pcre: bool,
};

/// Compile `pattern[0..len]` under `flags` (the substrate's pattern bits) and
/// write the handle to `*out`.
///
/// `smart_case` resolves HERE rather than in the engine, through the same
/// `hasUpper` predicate the CLI's `-S` runs — so an FFI host and a shell get
/// the same case sensitivity for the same pattern.
pub fn compile(pattern: ?[*]const u8, len: usize, flags: u32, out: ?**Regex) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    const bytes = view(pattern, len) orelse return .invalid;
    if (flags & ~contract.pattern_flags != 0) return .invalid;

    const fixed = flags & contract.flag_fixed != 0;
    const smart = flags & contract.flag_smart_case != 0;
    const caseless = flags & contract.flag_ignore_case != 0 or (smart and !verdict.hasUpper(bytes));
    // `-F` wins over `-P` the way the CLI's does: a fixed string needs no
    // engine at all, so the backend selector is inert rather than contradicted.
    const pcre = flags & contract.flag_pcre != 0 and !fixed;

    // Assembled by hand rather than with `errdefer`, which a Status-returning
    // entry never fires: each step below unwinds exactly what the steps before
    // it took, so a failed compile leaks nothing into a host that will keep
    // running afterwards.
    const owned = gpa.dupe(u8, bytes) catch return contract.report(.{ .code = error.OutOfMemory });

    var query = qy.CompiledQuery.compile(gpa, .{
        .pattern = owned,
        .mode = .lines,
        .fixed = fixed,
        .ignore_case = caseless,
        .unicode = flags & contract.flag_no_unicode == 0,
        .word = flags & contract.flag_word != 0,
        .pcre = pcre,
    }) catch |e| {
        gpa.free(owned);
        const unicode = flags & contract.flag_no_unicode == 0;
        return switch (e) {
            error.Unsupported => refuse(bytes, caseless, unicode, pcre),
            else => contract.report(.{ .code = e }),
        };
    };

    var spans = query.matchScratch(gpa) catch |e| {
        query.deinit(gpa);
        gpa.free(owned);
        return contract.report(.{ .code = e });
    };

    const handle = gpa.create(Regex) catch {
        spans.deinit();
        query.deinit(gpa);
        gpa.free(owned);
        return contract.report(.{ .code = error.OutOfMemory });
    };
    handle.* = .{
        .pattern = owned,
        .query = query,
        .spans = spans,
        .found = .empty,
        .caseless = caseless,
        .unicode = flags & contract.flag_no_unicode == 0,
        .word = flags & contract.flag_word != 0,
        .fixed = fixed,
        .pcre = pcre,
    };
    slot.* = handle;
    return .ok;
}

/// Release a handle from `compile`. Teardown leaves the fault slot alone, so a
/// host can still read the detail that made it clean up.
pub fn free(re: *Regex) void {
    re.found.deinit(gpa);
    re.spans.deinit();
    re.query.deinit(gpa);
    if (re.caps) |*c| c.deinit();
    if (re.slots.len != 0) gpa.free(re.slots);
    if (re.escaped.len != 0) gpa.free(re.escaped);
    gpa.free(re.pattern);
    gpa.destroy(re);
}

/// Whether `text[0..len]` holds a match: `.match` yes, `.ok` no. The cheapest
/// question the plane answers — the same walk `find_all` runs, stopped at the
/// first span rather than materializing the rest.
///
/// It has to be that walk and not the boolean *document* kernel, which is the
/// faster routine but answers a different question: that one splits a buffer
/// into lines and asks whether ANY line matches, so `^` and `$` become
/// per-line anchors. Here the buffer IS the unit, so they are its ends. While
/// this rode `docMatches`, `c$` over `"abc\n"` was a match to `is_match` and no
/// match to `find_all` — 19 of 54 anchored probes disagreed, and every consumer
/// that noticed had to route its predicate through `find_all` to get one
/// answer.
pub fn isMatch(re: *Regex, text: ?[*]const u8, len: usize) Status {
    contract.beginCall();
    const body = view(text, len) orelse return .invalid;
    return if (re.query.holds(body, false, &re.spans)) .match else .ok;
}

/// Fill `out[0..cap]` with the matches in `text[0..len]`, writing the count to
/// `*written`. Returns `.match` when the TEXT HAS at least one, `.ok` when it
/// holds none — the status is about the text, never about the window, so a
/// count query (`cap = 0`) writes nothing and still returns `.match`.
///
/// Iteration order and the empty-match rules are the engine's, not this file's:
/// the text is handed to `collectSpans` as ONE unterminated unit, so a host
/// walking a buffer gets the same span sequence — zero-width handling,
/// adjacency, `-w` filtering and all — that the same pattern produces inside a
/// line of `gist --json`. That is why there is no cursor here: a `find(from)`
/// loop is precisely where a caller would re-invent those rules and get the
/// nullable patterns wrong.
///
/// `cap` is a window over the answer, not a limit on the search: at most `cap`
/// spans are written, and `*written` reports how many the TEXT HAS — so a short
/// window sizes its own retry, exactly as `captures` does for a short group
/// buffer. The two verbs are siblings and used to disagree here, which cost
/// every binding the same grow-and-rescan loop: with a saturating count, "did I
/// get everything?" was undecidable (`written == cap` is equally a full window
/// and an exact fit), so each one doubled its buffer and searched again until a
/// call came back short. Reporting the true count answers it in one search, and
/// makes `cap = 0` with a null `out` a cheap "how many matches are there?"
pub fn findAll(re: *Regex, text: ?[*]const u8, len: usize, out: ?[*]Span, cap: usize, written: ?*usize) Status {
    contract.beginCall();
    const count = written orelse return .invalid;
    count.* = 0;
    const body = view(text, len) orelse return .invalid;
    if (cap != 0 and out == null) return .invalid;

    re.found.clearRetainingCapacity();
    re.query.collectSpans(gpa, body, false, &re.spans, &re.found) catch |e|
        return contract.report(.{ .code = e });
    if (re.found.items.len == 0) return .ok;

    for (re.found.items[0..@min(cap, re.found.items.len)], 0..) |sp, i|
        out.?[i] = .{ .start = @intCast(sp.start), .end = @intCast(sp.end) };
    count.* = re.found.items.len;
    return .match;
}

/// How many capture groups the pattern declares, excluding group 0. Forces the
/// capture arm, so it reports the same `.invalid` a `captures` call would for a
/// pattern this build cannot capture.
pub fn groupCount(re: *Regex, out: ?*u32) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    const caps = arm(re) catch |e| return contract.report(.{ .code = e });
    slot.* = @intCast(caps.nslots() / 2 - 1);
    return .ok;
}

/// The number of the group named `name[0..len]`: `.match` with `*out` set when
/// the pattern declares it, `.ok` when it does not. Absence is a result, not a
/// fault — asking is how a host discovers the answer.
pub fn groupIndex(re: *Regex, name: ?[*]const u8, len: usize, out: ?*u32) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    const key = (name orelse return .invalid)[0..len];
    const caps = arm(re) catch |e| return contract.report(.{ .code = e });
    const idx = caps.groupByName(key) orelse return .ok;
    slot.* = idx;
    return .match;
}

/// The name group `index` was declared with: `.match` with `*out` pointing at
/// it, `.ok` when the group is a plain `(…)`. The inverse of `groupIndex`, and
/// the one direction a host cannot get any other way — without it, turning a
/// match into a keyed record means re-parsing the pattern for `(?P<…>)`
/// spellings, which all three bindings had each started to do, in three
/// almost-right ways (an escaped `\(` and a `(?:` both fool the obvious scan).
///
/// The bytes borrow the handle: they are the parser's own name storage, or
/// PCRE2's name table inside the compiled code, so they live until
/// `irgx_free` and cost no copy. An index past the group count is a caller
/// error rather than an absence — the count is knowable (`groupCount`), so a
/// walk off the end is a bug worth naming, where an unnamed group is an answer.
pub fn groupName(re: *Regex, index: u32, out: ?*rows.Text) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    const caps = arm(re) catch |e| return contract.report(.{ .code = e });
    if (index >= caps.nslots() / 2) return .invalid;
    const name = caps.nameOfGroup(index) orelse return .ok;
    slot.* = rows.Text.of(name);
    return .match;
}

/// Fill `out[0..cap]` with the group spans of the leftmost match at or after
/// `from` in `text[0..len]`, writing the group count to `*written`. `out[0]` is
/// the whole match; `out[k]` is group `k`, `-1`/`-1` when it did not
/// participate. Returns `.match` on a match, `.ok` when there is none.
///
/// `cap` short of the group count is not an error — the prefix is written and
/// `*written` reports what the pattern HAS, so a host can size a second call
/// without a separate `groupCount`.
///
/// `-w` is honored the way the rest of the plane honors it: a span the word
/// rule rejects is not a match, and the search resumes past it. Without that,
/// `captures` would be the one verb whose idea of a match differed from
/// `find_all`'s.
pub fn captures(re: *Regex, text: ?[*]const u8, len: usize, from: usize, out: ?[*]Span, cap: usize, written: ?*usize) Status {
    contract.beginCall();
    const count = written orelse return .invalid;
    count.* = 0;
    const body = view(text, len) orelse return .invalid;
    if (from > len) return .invalid;
    if (cap != 0 and out == null) return .invalid;

    const caps = arm(re) catch |e| return contract.report(.{ .code = e });
    const ngroups = caps.nslots() / 2;

    var at = from;
    while (true) {
        if (!caps.find(body, at, re.slots)) return .ok;
        const s: usize = @intCast(re.slots[0]);
        const e: usize = @intCast(re.slots[1]);
        if (!re.word or qy.wordOk(re.unicode, body, s, e)) break;
        // A rejected span must not re-find itself: advance one byte past its
        // start (not its end — an empty span would stand still).
        at = @max(s + 1, at + 1);
        if (at > body.len) return .ok;
    }

    for (0..@min(cap, ngroups)) |g| {
        const lo = re.slots[2 * g];
        const hi = re.slots[2 * g + 1];
        out.?[g] = if (lo < 0 or hi < 0) Span.unset else .{ .start = lo, .end = hi };
    }
    count.* = ngroups;
    return .match;
}

/// The capture arm, built on first use and remembered — including its refusal.
///
/// Under `-F` the arm compiles the ESCAPED pattern: `-F 'a.b'` means three
/// literal bytes, and handing `a.b` to a regex parser would quietly widen it.
fn arm(re: *Regex) error{ BadPattern, OutOfMemory }!*rx.Caps {
    if (re.caps) |*ready| return ready;
    if (re.caps_tried) return error.BadPattern;
    re.caps_tried = true;

    const body = if (!re.fixed) re.pattern else blk: {
        re.escaped = try qy.escapeLiteral(gpa, re.pattern);
        break :blk re.escaped;
    };
    var built = try rx.Caps.compile(gpa, body, .{
        .caseless = re.caseless,
        .unicode = re.unicode,
        .pcre = re.pcre,
    });
    errdefer built.deinit();
    re.slots = try gpa.alloc(isize, built.nslots());
    re.caps = built;
    return &re.caps.?;
}

// ── tests ────────────────────────────────────────────────────────────────────
// Every case here is about the SEAM — argument guards, the lazy arm, the
// `-F`/`-w`/smart-case resolutions this file performs — never about whether the
// engine matches correctly, which is `query_test.zig`'s and the differential
// oracles' job. A test that re-asserted the engine here would be measuring a
// copy of it.

const t = std.testing;

fn open(pattern: []const u8, flags: u32) !*Regex {
    var re: *Regex = undefined;
    try t.expectEqual(Status.ok, compile(pattern.ptr, pattern.len, flags, &re));
    return re;
}

fn spansOf(re: *Regex, text: []const u8) ![]Span {
    var buf: [16]Span = undefined;
    var n: usize = 0;
    _ = findAll(re, text.ptr, text.len, &buf, buf.len, &n);
    // `n` is the text's true count, which may exceed this window — the clamp is
    // the same one a real host writes.
    return t.allocator.dupe(Span, buf[0..@min(n, buf.len)]);
}

test "the seam refuses what it cannot answer instead of guessing" {
    var re: *Regex = undefined;
    // A null pattern, a null out-slot, and an undeclared flag bit are each a
    // caller error the ABI must name rather than absorb.
    try t.expectEqual(Status.invalid, compile(null, 3, 0, &re));
    try t.expectEqual(Status.invalid, compile("abc", 3, 0, null));
    // But a null pattern of length zero is the EMPTY pattern, which compiles —
    // the same reading every search verb gives a null text of length zero. A
    // language whose empty string has no data pointer (Go's does not) hands
    // that in without meaning anything by it.
    try t.expectEqual(Status.ok, compile(null, 0, 0, &re));
    free(re);
    try t.expectEqual(Status.invalid, compile("abc", 3, 1 << 31, &re));
    // A pattern no engine here accepts is a fault, with detail behind it. (A
    // pattern PCRE2 *would* accept is a declinature instead, which is the two
    // tests below.)
    const sc = fault.scope();
    defer sc.end();
    try t.expectEqual(Status.invalid, compile("[abc", 4, 0, &re));
    try t.expect(fault.last() != null);
}

test "a pattern PCRE2 would take declines instead of failing" {
    const sc = fault.scope();
    defer sc.end();
    var re: *Regex = undefined;

    // The remedy is a flag, so the answer is the routing fact and not an error:
    // `.stale` is `unsupported_syntax`, whose declared fallback is pcre2. A host
    // therefore decides from the return value alone — and because a declinature
    // never comes through `report`, the fault slot stays silent about a tier
    // that merely stepped aside.
    for ([_][]const u8{ "(?=x)", "(?<=x)y", "(a)\\1", "(?>ab)" }) |p| {
        try t.expectEqual(Status.stale, compile(p.ptr, p.len, 0, &re));
        try t.expect(fault.last() == null);
        // And the escalation it points at actually answers.
        try t.expectEqual(Status.ok, compile(p.ptr, p.len, contract.flag_pcre, &re));
        free(re);
    }
}

test "a pattern nothing can take fails, and says where" {
    const sc = fault.scope();
    defer sc.end();
    var re: *Regex = undefined;

    for ([_][]const u8{ "(unclosed", "a{2,1}", "[abc" }) |p| {
        try t.expectEqual(Status.invalid, compile(p.ptr, p.len, 0, &re));
        const d = fault.last().?;
        try t.expectEqual(fault.Fault.BadPattern, d.code);
        // PCRE2's own offset rides along. It indexes the PATTERN, not a file,
        // which is why `path` stays empty — that pairing is what tells a host
        // which of the two `at` can mean.
        try t.expect(d.at != null);
        try t.expect(d.at.? <= p.len);
        try t.expectEqualStrings("", d.path);
        // No escalation rescues it, and it must not masquerade as a declinature.
        try t.expectEqual(Status.invalid, compile(p.ptr, p.len, contract.flag_pcre, &re));
        try t.expectEqual(fault.Fault.BadPattern, fault.last().?.code);
    }
}

test "is_match answers, and reports absence as a result" {
    const re = try open("wa(l|t)rus", 0);
    defer free(re);
    try t.expectEqual(Status.match, isMatch(re, "a walrus here", 13));
    try t.expectEqual(Status.ok, isMatch(re, "a walnut here", 13));
    // An empty text is a legitimate question, not a null-pointer bug.
    try t.expectEqual(Status.ok, isMatch(re, null, 0));
    try t.expectEqual(Status.invalid, isMatch(re, null, 7));
}

test "is_match and find_all answer about the same unit" {
    // The buffer IS the line here, so `^`, `$`, `\A` and `\z` are its ends and
    // an interior newline is an ordinary byte. Both verbs have to say so: while
    // `is_match` rode the document kernel, which splits on newlines first, this
    // table disagreed on seven of its nine anchored rows, and a host could not
    // use the cheap verb to decide whether to pay for the spans.
    for ([_][]const u8{ "^a", "\\Aa", "c$", "c\\z", "^abc$", "\\Aabc\\z", "b$", "abc", "a*" }) |pat| {
        const re = try open(pat, 0);
        defer free(re);
        for ([_][]const u8{ "\nabc", "abc\n", "x\nabc\ny", "ab\ncd", "abc", "" }) |text| {
            const got = try spansOf(re, text);
            defer t.allocator.free(got);
            const expected: Status = if (got.len == 0) .ok else .match;
            try t.expectEqual(expected, isMatch(re, text.ptr, text.len));
        }
    }
}

test "find_all reports the engine's span sequence, and sizes a short window" {
    const re = try open("a+", 0);
    defer free(re);
    const all = try spansOf(re, "aa b aaa");
    defer t.allocator.free(all);
    try t.expectEqualSlices(Span, &.{ .{ .start = 0, .end = 2 }, .{ .start = 5, .end = 8 } }, all);

    // A window shorter than the answer truncates the WRITE and still reports the
    // true count, so the retry is sized without a second search. This is the
    // half of the contract `captures` always kept and this verb did not.
    var one: [1]Span = undefined;
    var n: usize = 0;
    try t.expectEqual(Status.match, findAll(re, "aa b aaa", 8, &one, 1, &n));
    try t.expectEqual(@as(usize, 2), n);
    try t.expectEqual(Span{ .start = 0, .end = 2 }, one[0]); // the prefix, written
    // Which makes a cap of zero a count, not just a yes/no — the cheapest form
    // of the question, with no buffer at all.
    try t.expectEqual(Status.match, findAll(re, "aa b aaa", 8, null, 0, &n));
    try t.expectEqual(@as(usize, 2), n);
    // And no match is still a count, so a host reads one field either way.
    try t.expectEqual(Status.ok, findAll(re, "bbb", 3, null, 0, &n));
    try t.expectEqual(@as(usize, 0), n);
    try t.expectEqual(Status.invalid, findAll(re, "aa", 2, null, 0, null));
}

test "the fixed flag makes the pattern data, for the capture arm too" {
    const re = try open("a.c", contract.flag_fixed);
    defer free(re);
    try t.expectEqual(Status.ok, isMatch(re, "abc", 3));
    try t.expectEqual(Status.match, isMatch(re, "a.c", 3));

    // The lazily-built arm must agree: an escaped literal, not a wildcard.
    var got: [1]Span = undefined;
    var n: usize = 0;
    try t.expectEqual(Status.ok, captures(re, "abc", 3, 0, &got, 1, &n));
    try t.expectEqual(Status.match, captures(re, "xa.c", 4, 0, &got, 1, &n));
    try t.expectEqual(Span{ .start = 1, .end = 4 }, got[0]);
}

test "smart case resolves at the seam, on the CLI's own predicate" {
    const lower = try open("walrus", contract.flag_smart_case);
    defer free(lower);
    try t.expectEqual(Status.match, isMatch(lower, "WALRUS", 6));

    const mixed = try open("Walrus", contract.flag_smart_case);
    defer free(mixed);
    try t.expectEqual(Status.ok, isMatch(mixed, "WALRUS", 6));
    try t.expectEqual(Status.match, isMatch(mixed, "Walrus", 6));
}

test "captures reports every group, absence included, and sizes the caller" {
    const re = try open("(\\w+)=(?:(\\d+)|(true))", 0);
    defer free(re);

    var groups: [4]Span = undefined;
    var n: usize = 0;
    try t.expectEqual(Status.match, captures(re, "  n=42", 6, 0, &groups, 4, &n));
    try t.expectEqual(@as(usize, 4), n); // whole match + three declared groups
    try t.expectEqual(Span{ .start = 2, .end = 6 }, groups[0]);
    try t.expectEqual(Span{ .start = 2, .end = 3 }, groups[1]);
    try t.expectEqual(Span{ .start = 4, .end = 6 }, groups[2]);
    try t.expectEqual(Span.unset, groups[3]); // the branch not taken

    // A short window writes its prefix and still reports the true width, so a
    // host can size the retry without asking a second question.
    var one: [1]Span = undefined;
    try t.expectEqual(Status.match, captures(re, "  n=42", 6, 0, &one, 1, &n));
    try t.expectEqual(@as(usize, 4), n);
    try t.expectEqual(Span{ .start = 2, .end = 6 }, one[0]);

    // `from` past the only match is no match; past the end is a caller error.
    try t.expectEqual(Status.ok, captures(re, "  n=42", 6, 3, &groups, 4, &n));
    try t.expectEqual(Status.invalid, captures(re, "  n=42", 6, 7, &groups, 4, &n));
}

test "group names resolve, and an unknown name is an answer not a fault" {
    const re = try open("(?P<key>\\w+)", 0);
    defer free(re);
    var idx: u32 = 0;
    try t.expectEqual(Status.match, groupIndex(re, "key", 3, &idx));
    try t.expectEqual(@as(u32, 1), idx);
    try t.expectEqual(Status.ok, groupIndex(re, "nope", 4, &idx));

    var count: u32 = 0;
    try t.expectEqual(Status.ok, groupCount(re, &count));
    try t.expectEqual(@as(u32, 1), count);
}

test "the name lookup inverts, on both grammars, without re-reading the pattern" {
    const sc = fault.scope();
    defer sc.end();
    // The linear arm and the PCRE2 arm keep their names in different places (the
    // parser's own storage; PCRE2's name table inside the compiled code), so the
    // inverse is asserted against both — a host asking `groupName` must not have
    // to know which arm answered.
    for ([_]u32{ 0, contract.flag_pcre }) |engine| {
        // A named group, a bare one, and — the spelling a textual scan gets
        // wrong — a `\(` that is data and a `(?:` that captures nothing.
        const re = try open("\\((?<key>\\w+)(?:=)(\\d+)\\)", engine);
        defer free(re);

        var name: rows.Text = undefined;
        try t.expectEqual(Status.match, groupName(re, 1, &name));
        try t.expectEqualStrings("key", name.ptr[0..name.len]);
        // Group 2 is the `(\d+)`, not the `(?:=)`, and it has no name: an
        // absence, reported as a result.
        try t.expectEqual(Status.ok, groupName(re, 2, &name));
        // Group 0 is the whole match, which is never named.
        try t.expectEqual(Status.ok, groupName(re, 0, &name));
        // Past the end is a caller error, because the count is knowable.
        try t.expectEqual(Status.invalid, groupName(re, 3, &name));
        try t.expectEqual(Status.invalid, groupName(re, 1, null));

        // And it agrees with the forward lookup, which is the whole point.
        var idx: u32 = 0;
        try t.expectEqual(Status.match, groupIndex(re, "key", 3, &idx));
        try t.expectEqual(@as(u32, 1), idx);
    }
}

test "the word rule reaches captures, not just find_all" {
    const re = try open("cat", contract.flag_word);
    defer free(re);
    var got: [1]Span = undefined;
    var n: usize = 0;
    // `concatenate` holds `cat`, but not as a word — and the search must resume
    // past the rejected span rather than return it or spin on it.
    try t.expectEqual(Status.ok, captures(re, "concatenate", 11, 0, &got, 1, &n));
    try t.expectEqual(Status.match, captures(re, "concatenate cat", 15, 0, &got, 1, &n));
    try t.expectEqual(Span{ .start = 12, .end = 15 }, got[0]);
}

test "the PCRE2 arm captures too, through the same door" {
    const sc = fault.scope();
    defer sc.end();
    // PCRE2 grammar, compiled through the PCRE2 arm: capturing is available.
    const re = try open("(?=w)(\\w+)", contract.flag_pcre);
    defer free(re);
    var got: [2]Span = undefined;
    var n: usize = 0;
    try t.expectEqual(Status.match, captures(re, " walrus", 7, 0, &got, 2, &n));
    try t.expectEqual(Span{ .start = 1, .end = 7 }, got[1]);
    // And the boolean plane answers the same pattern.
    try t.expectEqual(Status.match, isMatch(re, " walrus", 7));
}

// ── adversarial additions: termination + a toxic-pattern soak ──────────────
//
// The suite above proves each verb's contract on well-formed input. These prove
// two properties over ADVERSARIAL input that no single case states: a nullable
// pattern's empty-match storm terminates with a bounded count rather than
// spinning, and no random toxic pattern can make any FFI entry crash or return
// a status outside its own vocabulary. Both stay on the LINEAR engine — which
// is linear-time by construction — so an adversarial pattern over an adversarial
// buffer cannot backtrack catastrophically the way a PCRE2 `(a*)*` could, and
// the soak runs in milliseconds. Deterministic PRNG, the repo's fuzz idiom.

test "find_all terminates on a nullable pattern's empty-match storm, bounded by position" {
    // A pattern that matches the empty string offers a zero-width match at every
    // position; the seam must advance past each rather than re-find it forever.
    // The one hard invariant a host can rely on: no more matches than positions.
    for ([_][]const u8{ "a*", "b*", "(?:)", "x?", "\\d*" }) |pat| {
        const re = try open(pat, 0);
        defer free(re);
        for ([_][]const u8{ "", "aaaa", "abcabc", "zzzzzzzzzzzzzzzz" }) |text| {
            var buf: [64]Span = undefined;
            var n: usize = 0;
            const st = findAll(re, text.ptr, text.len, &buf, buf.len, &n);
            try t.expect(st == .match or st == .ok);
            try t.expect((n == 0) == (st == .ok)); // count and verdict agree
            try t.expect(n <= text.len + 1); // never more matches than positions
        }
    }
}

test "the FFI trust boundary survives a toxic-pattern soak without a crash or a bogus status" {
    // Braces are withheld from the alphabet on purpose: `{` is the one metachar
    // whose bounded repetition could ask the linear engine for a huge state set,
    // and this soak is about the seam's robustness, not the machine's patience.
    const meta = "abc.*+?()[]^$|\\-\t \n";
    const haystacks = [_][]const u8{ "", "abc", "a\nb", "aAbBcC 123", "\x00\x01\xff\x7f", "the quick brown fox" };

    const sc = fault.scope();
    defer sc.end();
    var prng = std.Random.DefaultPrng.init(0xB1A57_ADBE);
    const r = prng.random();
    var compiled: usize = 0;
    var pbuf: [12]u8 = undefined;

    for (0..3000) |_| {
        const plen = r.uintLessThan(usize, pbuf.len + 1);
        for (pbuf[0..plen]) |*c| c.* = meta[r.uintLessThan(usize, meta.len)];
        const pat = pbuf[0..plen];

        var re: *Regex = undefined;
        // A toxic pattern is one of exactly three answers — compiled, declined
        // to PCRE2, or refused — never a fourth thing and never a crash.
        const cs = compile(pat.ptr, pat.len, 0, &re);
        try t.expect(cs == .ok or cs == .stale or cs == .invalid);
        if (cs != .ok) continue;
        defer free(re);
        compiled += 1;

        for (haystacks) |hay| {
            const ms = isMatch(re, hay.ptr, hay.len);
            try t.expect(ms == .match or ms == .ok);

            var buf: [64]Span = undefined;
            var n: usize = 0;
            const fs = findAll(re, hay.ptr, hay.len, &buf, buf.len, &n);
            try t.expect(fs == .match or fs == .ok);
            // The two verbs answer the same question about the same unit, and a
            // zero-width storm still cannot exceed the position count.
            try t.expectEqual(ms, fs);
            try t.expect((n == 0) == (fs == .ok));
            try t.expect(n <= hay.len + 1);
        }
    }
    // The generator is not so hostile that nothing ever compiles — otherwise the
    // match-side asserts above would be vacuous.
    try t.expect(compiled > 100);
}
