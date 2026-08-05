//! The regex-over-text plane — `libirgx`'s own C ABI.
//!
//! What a host reaches for when it has a pattern and a buffer, and no corpus:
//! compile once, then ask `is_match` / `find_all` / `captures` about bytes it
//! already holds. That is the whole difference from `libgist`, which is about a
//! *tree* — a session, a walk, freshness, an index. Splitting them is what lets
//! a host that only wants a regex link a library that only has one.
//!
//! Every verb here is a shim over `glean.Pattern` — the engine's own consumer
//! face, the same type a Zig caller with a pattern and a string reaches for.
//! Nothing in this file decides what a pattern means, which is the point: the
//! compile, the walk, the zero-width advance and the `-w` lowering are all one
//! layer down, so a host and a Zig caller cannot be told different answers.
//!
//! **Which walk this plane runs, and why it changed.** The package produces two
//! legitimate match sequences for a nullable pattern (see `regex/glean/cursor.zig`):
//! `query`'s grep walk, which suppresses an empty match adjacent to the previous
//! one and at unterminated end-of-text, and `glean`'s library walk, which reports
//! both. This plane used to run the first because it was built out of the CLI's
//! parts. That made `x*` over `abc` three matches here and four in every regex
//! library a host already knew, and all three bindings had to ship an apology
//! note for it — Go's README compared its own output to `regexp`'s and asked the
//! reader to accept the difference. A deviation with no improvement behind it is
//! a defect, so the plane now runs the library walk. `gist` keeps the grep walk,
//! which is rg-parity and correct for a page of line-oriented rows.
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
const mark = @import("../../mark.zig");
const qy = @import("../../kernel/query/query.zig");
const rows = @import("rows.zig");
const rx = @import("../../kernel/regex/regex.zig");
const verdict = @import("../../exec/cold/argv/verdict.zig");

const Status = contract.Status;
const Window = mark.Window;
const gpa = std.heap.c_allocator;

/// Narrow a `glean` error onto the fault vocabulary this ABI publishes.
///
/// A widening-free cast, and the reason it is a named function rather than a
/// bare `@errorCast` at each call site is that the cast carries a claim: every
/// error a `glean` verb can return is a member of `fault.Fault`. That held by
/// inspection before and holds by construction now — `BoundUnsupported`, the
/// one member that used to be translated on the way out, is published in its own
/// right (`fault.Pattern`), so no verb's error set escapes the taxonomy and
/// nothing here has to invent a status on a host's behalf.
fn faultOf(e: anyerror) fault.Fault {
    return @errorCast(e);
}

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
///
/// Public for the slate plane, which has the same three answers to give about a
/// pattern it could not take and must not derive them a second time — a host that
/// got `.stale` from one plane and a bare fault from the other for the same
/// pattern would have no way to know the remedy was the same.
pub fn refuse(pattern: []const u8, caseless: bool, unicode: bool, already_pcre: bool) Status {
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

/// A compiled pattern and the scratch its finds run in.
///
/// Almost all of this is `glean.Pattern`: it owns the program, the pooled
/// scratch and the lazily-built capture arm (most hosts never ask for a group,
/// and that arm is a second lowering plus a determinization attempt). What
/// stays here is only what the ABI itself is answerable for — the escaped
/// spelling `-F` compiles, and the three semantics bits `refuse` needs in order
/// to ask PCRE2 whether a rejected pattern has any remedy.
pub const Regex = struct {
    inner: rx.Pattern,
    /// The `-F` spelling, owned. Under a fixed pattern the raw bytes are data,
    /// so the escaped form is what actually gets compiled — by BOTH arms, which
    /// is why it is escaped once here rather than re-derived for captures.
    escaped: []const u8 = &.{},

    caseless: bool,
    unicode: bool,
    pcre: bool,
};

/// Compile `pattern[0..len]` under `flags` (the substrate's pattern bits) and
/// write the handle to `*out`.
///
/// `smart_case` resolves HERE rather than in the engine, through the same
/// `hasUpper` predicate the CLI's `-S` runs — so an FFI host and a shell get
/// the same case sensitivity for the same pattern.
///
/// A leading `(?i)` / `(?-u)` / `(?ms)` directive resolves here too, for the
/// same reason and with the same consequence: it is a statement about how to
/// compile, made in the only place that holds both the flag word and the pattern
/// text. The pattern's own spelling wins over the argument — `(?-i)` under
/// `IRGX_IGNORE_CASE` is case-sensitive, as it is in rust-regex — because the
/// more specific statement is the one the author wrote next to the pattern.
pub fn compile(pattern: ?[*]const u8, len: usize, flags: u32, out: ?**Regex) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    const bytes = view(pattern, len) orelse return .invalid;
    if (flags & ~contract.pattern_flags != 0) return .invalid;

    const fixed = flags & contract.flag_fixed != 0;
    // `-F` wins over `-P` the way the CLI's does: a fixed string needs no
    // engine at all, so the backend selector is inert rather than contradicted.
    const pcre = flags & contract.flag_pcre != 0 and !fixed;

    // Neither of the two arms that already own the syntax gets it read for them.
    // Under `-F` the bytes `(?i)` are data — a host searching for that literal
    // must find it, which is also rg's and gist's answer — and PCRE2 implements
    // the whole flag grammar itself, scoping and `(?x)` included, so reading it
    // here would only be able to make that arm worse.
    //
    // `.beyond` (`(?x)`, `(?U)`, `(?R)`) is left whole on purpose: the compile
    // below then fails and `refuse` asks PCRE2 — which has all three — turning a
    // flat refusal into the declinature that names the arm which can answer.
    const asked: rx.syntax.Directive = switch (if (fixed or pcre) .none else rx.syntax.preamble(bytes)) {
        .asks => |d| d,
        .none, .beyond => .{ .rest = bytes },
    };

    // Smart case reads the pattern the ENGINE will see, not the directive in
    // front of it: a `(?i)` prefix has no case of its own to be smart about.
    // Resolved before the directive is applied, so an explicit `(?-i)` still
    // wins over an inference — the whole point of the inference is to guess when
    // nobody said, and here somebody did.
    const smart = flags & contract.flag_smart_case != 0;
    const caseless = asked.caseless orelse
        (flags & contract.flag_ignore_case != 0 or (smart and !verdict.hasUpper(asked.rest)));
    const unicode = asked.unicode orelse (flags & contract.flag_no_unicode == 0);
    const line_anchors = asked.line_anchors orelse (flags & contract.flag_multiline != 0);
    const dotall = asked.dotall orelse (flags & contract.flag_dotall != 0);

    // Assembled by hand rather than with `errdefer`, which a Status-returning
    // entry never fires: each step below unwinds exactly what the steps before
    // it took, so a failed compile leaks nothing into a host that will keep
    // running afterwards.
    //
    // `-F` is resolved by escaping ONCE, here, rather than by a `fixed` knob the
    // engine carries: a fixed pattern is exactly the regex that matches its own
    // bytes. Doing it up front is also what makes the capture arm agree, which
    // it previously only did because it re-derived the same escape by itself.
    const escaped = if (!fixed) &.{} else qy.escapeLiteral(gpa, bytes) catch
        return contract.report(.{ .code = error.OutOfMemory });
    const source = if (fixed) escaped else asked.rest;

    const inner = rx.Pattern.compileOpts(gpa, source, .{
        .caseless = caseless,
        .unicode = unicode,
        .word = flags & contract.flag_word != 0,
        .multiline = line_anchors,
        .dotall = dotall,
        .pcre = pcre,
    }) catch |e| {
        if (escaped.len != 0) gpa.free(escaped);
        // Anything but exhaustion is a statement about the PATTERN, and this
        // engine's parser cannot tell "I can't express that" from "that is not
        // a regex" — so `refuse` asks the authority rather than guessing. It
        // answers `.stale` (a declinature routing the host to `IRGX_PCRE`) or a
        // located `BadPattern`.
        return switch (e) {
            error.OutOfMemory => contract.report(.{ .code = e }),
            else => refuse(bytes, caseless, unicode, pcre),
        };
    };

    const handle = gpa.create(Regex) catch {
        var owned = inner;
        owned.deinit();
        if (escaped.len != 0) gpa.free(escaped);
        return contract.report(.{ .code = error.OutOfMemory });
    };
    handle.* = .{
        .inner = inner,
        .escaped = escaped,
        .caseless = caseless,
        .unicode = unicode,
        .pcre = pcre,
    };
    slot.* = handle;
    return .ok;
}

/// Release a handle from `compile`. Teardown leaves the fault slot alone, so a
/// host can still read the detail that made it clean up.
pub fn free(re: *Regex) void {
    re.inner.deinit();
    if (re.escaped.len != 0) gpa.free(re.escaped);
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
    const hit = re.inner.isMatch(body) catch |e| return contract.report(.{ .code = faultOf(e) });
    return if (hit) .match else .ok;
}

/// **What the window plane is for, stated once.**
///
/// A search bounded to `[from, to]` while every zero-width assertion still reads
/// `text[0..len]` end to end. Slicing the text to the same region is a DIFFERENT
/// question and the reason these verbs exist: a slice moves the haystack edges,
/// so `$`, `\b`, `\z` and every lookahead at the cut answer about the slice
/// instead of about the text. `re.compile(p).search(s, pos, endpos)` and
/// `Regex::find_at` are both this question, and neither is expressible on top of
/// the unbounded verbs without changing what the pattern means.
///
/// Two guards a host should know before calling:
///
///   * **`to` is a real bound, so not every engine can honor it.** The linear
///     engine can — the bound is a ceiling on its walk and its closures never
///     stopped reading the true haystack. PCRE2 cannot, structurally: its subject
///     has one length, so stopping a match at `to` means telling the library the
///     subject ends there, which moves the anchors. A pattern on the PCRE arm
///     (`IRGX_PCRE`, or a linear declinature escalated) therefore faults with
///     `BoundUnsupported` rather than quietly answering the sliced question. Ask
///     `irgx_pattern_windows` once after compiling instead of per search.
///   * **An inert bound asks nothing of the engine.** `to == len` is the
///     unbounded case and works on both arms, so a `from`-only windowed search
///     never has to check the capability at all.
///
/// Group spans take a start bound (`captures`'s `from`) and no ceiling: the
/// capture VM has no `to` yet, and a half-honored bound would be worse than an
/// absent one. Said here rather than discovered, because the asymmetry is real.
fn windowOf(text: ?[*]const u8, len: usize, from: usize, to: usize) ?Window {
    const body = view(text, len) orelse return null;
    // Refused rather than clamped. A host that computed `to` past the end, or
    // crossed its bounds, has a bug that a silent `@min` would hide until the
    // answer was quietly wrong somewhere else.
    if (from > to or to > len) return null;
    return .{ .hay = body, .from = from, .to = to };
}

/// Whether the pattern's engine can honor a live `to` bound: `.match` yes,
/// `.ok` no. A static property of the compiled pattern, so a host asks once and
/// caches it — and the reason the windowed verbs can fault at all.
pub fn windows(re: *Regex) Status {
    contract.beginCall();
    return if (re.inner.engineOf().windows()) .match else .ok;
}

/// `isMatch` bounded to `[from, to]`. See `windowOf` for the window contract.
pub fn isMatchIn(re: *Regex, text: ?[*]const u8, len: usize, from: usize, to: usize) Status {
    contract.beginCall();
    const win = windowOf(text, len, from, to) orelse return .invalid;
    const hit = re.inner.isMatchIn(win) catch |e| return contract.report(.{ .code = faultOf(e) });
    return if (hit) .match else .ok;
}

/// Fill `out[0..cap]` with the matches in `text[0..len]`, writing the count to
/// `*written`. Returns `.match` when the TEXT HAS at least one, `.ok` when it
/// holds none — the status is about the text, never about the window, so a
/// count query (`cap = 0`) writes nothing and still returns `.match`.
///
/// Iteration order and the empty-match rules are the engine's, not this file's:
/// the walk is `glean.Cursor`, so a host gets the sequence `Regex::find_iter`,
/// `re.finditer` and `FindAll` produce for the same pattern — the empty match
/// adjacent to the previous one and the one at end-of-text both reported. That
/// is why there is still no cursor in the ABI: a `find(from)` loop is precisely
/// where a host would re-invent the advance rule and get nullable patterns
/// wrong, and it is written once, one layer down.
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
    // The whole text IS a window whose bound is inert, so this is the windowed
    // walk with `to = len` rather than a second implementation of it. Which also
    // means the unbounded path cannot drift from the bounded one, and that no
    // backend can decline here: `Window.unbounded` is true, so the arm that
    // cannot express a live bound is never asked to.
    return findAllIn(re, text, len, 0, len, out, cap, written);
}

/// `findAll` bounded to `[from, to]`. See `windowOf` for the window contract:
/// matches must fit inside the region, assertions still read the whole text, and
/// a live bound faults on an engine that cannot express one.
pub fn findAllIn(re: *Regex, text: ?[*]const u8, len: usize, from: usize, to: usize, out: ?[*]Span, cap: usize, written: ?*usize) Status {
    contract.beginCall();
    const count = written orelse return .invalid;
    count.* = 0;
    const win = windowOf(text, len, from, to) orelse return .invalid;
    if (cap != 0 and out == null) return .invalid;

    var cur = re.inner.matchesIn(win) catch |e| return contract.report(.{ .code = faultOf(e) });
    defer cur.deinit();
    // One walk serves both halves of the contract: the window is filled while
    // the tally keeps running past it, so the true count costs no second search
    // and nothing is materialized that the host did not ask for.
    var n: usize = 0;
    while (cur.next()) |sp| : (n += 1)
        if (n < cap) {
            out.?[n] = .{ .start = @intCast(sp.start), .end = @intCast(sp.end) };
        };
    count.* = n;
    return if (n == 0) .ok else .match;
}

/// How many capture groups the pattern declares, excluding group 0. Forces the
/// capture arm, so it reports the same `.invalid` a `captures` call would for a
/// pattern this build cannot capture.
pub fn groupCount(re: *Regex, out: ?*u32) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    const n = re.inner.groupCount() catch |e| return contract.report(.{ .code = faultOf(e) });
    slot.* = @intCast(n - 1);
    return .ok;
}

/// The number of the group named `name[0..len]`: `.match` with `*out` set when
/// the pattern declares it, `.ok` when it does not. Absence is a result, not a
/// fault — asking is how a host discovers the answer.
pub fn groupIndex(re: *Regex, name: ?[*]const u8, len: usize, out: ?*u32) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    const key = (name orelse return .invalid)[0..len];
    const idx = re.inner.group(key) catch |e| return contract.report(.{ .code = faultOf(e) });
    slot.* = @intCast(idx orelse return .ok);
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
    const n = re.inner.groupCount() catch |e| return contract.report(.{ .code = faultOf(e) });
    if (index >= n) return .invalid;
    const name = re.inner.groupName(index) catch |e| return contract.report(.{ .code = faultOf(e) });
    slot.* = rows.Text.of(name orelse return .ok);
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
/// `-w` needs no handling here any more, and that is the point: the capture arm
/// is compiled from the same `Options` as the span arm, so the word rule is
/// lowered into both rather than re-applied to one. This verb used to carry its
/// own reject-and-resume loop because the arm it built dropped the flag.
pub fn captures(re: *Regex, text: ?[*]const u8, len: usize, from: usize, out: ?[*]Span, cap: usize, written: ?*usize) Status {
    contract.beginCall();
    const count = written orelse return .invalid;
    count.* = 0;
    const body = view(text, len) orelse return .invalid;
    if (from > len) return .invalid;
    if (cap != 0 and out == null) return .invalid;

    const got = re.inner.groupsFrom(body, from) catch |e|
        return contract.report(.{ .code = faultOf(e) });
    const g = got orelse return .ok;

    for (0..@min(cap, g.len())) |i|
        out.?[i] = if (g.get(i)) |sp|
            .{ .start = @intCast(sp.start), .end = @intCast(sp.end) }
        else
            Span.unset;
    count.* = g.len();
    return .match;
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

test "find_all reports the library walk's empty matches, not the grep walk's" {
    // The sequence a host actually receives for a nullable pattern, pinned to
    // the bar its bindings are measured against rather than to rg's page rules.
    // Both cases below used to come back one span short: `gist`'s walk drops an
    // empty match adjacent to the previous one and an unterminated one at the
    // end of the text, which is right for printed rows and wrong for a library.
    //
    // `x*` over `abc` is the canonical row — 4 in Rust's `regex`, Python's `re`,
    // Go's `regexp` and JS `matchAll`; 3 in ripgrep.
    const re = try open("x*", 0);
    defer free(re);
    const spans = try spansOf(re, "abc");
    defer t.allocator.free(spans);
    try t.expectEqualSlices(Span, &.{
        .{ .start = 0, .end = 0 },
        .{ .start = 1, .end = 1 },
        .{ .start = 2, .end = 2 },
        .{ .start = 3, .end = 3 }, // the end-of-text empty the grep walk suppresses
    }, spans);

    // And the adjacency half of the same rule: `b*` over `abcb` keeps the empty
    // match that immediately follows a consuming one.
    const bstar = try open("b*", 0);
    defer free(bstar);
    const adj = try spansOf(bstar, "abcb");
    defer t.allocator.free(adj);
    try t.expectEqualSlices(Span, &.{
        .{ .start = 0, .end = 0 },
        .{ .start = 1, .end = 2 },
        .{ .start = 2, .end = 2 }, // adjacent to the one before it
        .{ .start = 3, .end = 4 },
        .{ .start = 4, .end = 4 },
    }, adj);
}

/// Every span the window plane reports for `[from, to]` of `text`.
fn windowSpans(re: *Regex, text: []const u8, from: usize, to: usize) ![]Span {
    var buf: [16]Span = undefined;
    var n: usize = 0;
    _ = findAllIn(re, text.ptr, text.len, from, to, &buf, buf.len, &n);
    return t.allocator.dupe(Span, buf[0..@min(n, buf.len)]);
}

test "a window bounds the search without moving the haystack edges" {
    // THE claim the plane exists for. `c$` over "abc" matches; over the SLICE
    // "ab" nothing does, because slicing moved `$` to offset 2. A window to=2
    // has to give the third answer: no match, but for the honest reason — `c`
    // is outside the region — while `$` still means offset 3.
    //
    // The way to prove the edges did not move is to ask a pattern that can only
    // succeed if they didn't. `b$` inside [0,2] must NOT match: `b` fits the
    // region, and `$` is still the text's end at 3, which `b` does not reach.
    // Under a slice it WOULD match, since "ab" ends right after the `b`. So this
    // single row separates a window from a slice.
    const dollar = try open("b$", 0);
    defer free(dollar);
    try t.expectEqual(Status.ok, isMatchIn(dollar, "abc", 3, 0, 2));
    // And the same pattern over the sliced bytes does match, which is the answer
    // a host would have gotten by slicing — the wrong one.
    try t.expectEqual(Status.match, isMatch(dollar, "ab", 2));

    // The mirror on the left edge: `^` stays at 0 even when the region starts
    // later, so an anchored pattern cannot match from inside the window.
    const caret = try open("^b", 0);
    defer free(caret);
    try t.expectEqual(Status.ok, isMatchIn(caret, "abc", 3, 1, 3));
    try t.expectEqual(Status.match, isMatch(caret, "bc", 2));

    // \b reads the byte BEFORE the region too, so a word boundary is judged
    // against the text rather than against the cut.
    const word = try open("\\bbc", 0);
    defer free(word);
    try t.expectEqual(Status.ok, isMatchIn(word, "abc", 3, 1, 3));
    try t.expectEqual(Status.match, isMatch(word, "bc", 2));
}

test "a window restricts which matches are reachable, and nothing else" {
    const re = try open("a", 0);
    defer free(re);
    // Three `a`s at 0, 2, 4. Each window admits exactly the ones that fit.
    const all = try windowSpans(re, "aBaBa", 0, 5);
    defer t.allocator.free(all);
    try t.expectEqualSlices(Span, &.{
        .{ .start = 0, .end = 0 + 1 },
        .{ .start = 2, .end = 3 },
        .{ .start = 4, .end = 5 },
    }, all);

    // A match must END at or before `to`, so to=3 keeps the first two.
    const bounded = try windowSpans(re, "aBaBa", 0, 3);
    defer t.allocator.free(bounded);
    try t.expectEqualSlices(Span, &.{
        .{ .start = 0, .end = 1 },
        .{ .start = 2, .end = 3 },
    }, bounded);

    // And must START at or after `from`.
    const shifted = try windowSpans(re, "aBaBa", 1, 5);
    defer t.allocator.free(shifted);
    try t.expectEqualSlices(Span, &.{
        .{ .start = 2, .end = 3 },
        .{ .start = 4, .end = 5 },
    }, shifted);

    // An empty window is a legitimate question with a legitimate empty answer,
    // not an error.
    var n: usize = 999;
    try t.expectEqual(Status.ok, findAllIn(re, "aBaBa", 5, 2, 2, null, 0, &n));
    try t.expectEqual(@as(usize, 0), n);
}

test "the unbounded verb and an inert window are the same call" {
    // `findAll` IS `findAllIn` with `to = len`, so this is a claim about the
    // delegation rather than about the engine: the two cannot drift because
    // there is only one walk under them. A nullable pattern is the sharp case,
    // since that is where a second implementation would have gotten the
    // empty-match rules wrong.
    const re = try open("x*", 0);
    defer free(re);
    const whole = try spansOf(re, "abc");
    defer t.allocator.free(whole);
    const inert = try windowSpans(re, "abc", 0, 3);
    defer t.allocator.free(inert);
    try t.expectEqualSlices(Span, whole, inert);
}

test "a live bound on the PCRE arm faults instead of answering a different question" {
    const sc = fault.scope();
    defer sc.end();

    // The capability is a property of the compiled pattern, so a host asks once.
    const linear = try open("abc", 0);
    defer free(linear);
    try t.expectEqual(Status.match, windows(linear));

    const pcre = try open("(?=a)b*", contract.flag_pcre);
    defer free(pcre);
    try t.expectEqual(Status.ok, windows(pcre));

    // An INERT bound asks nothing of the engine, so the pcre arm answers it with
    // the search it already has — no fault, and the real answer: the lookahead
    // sees the `a` at 0 and `b*` takes zero bytes, so there is a match at (0,0).
    try t.expectEqual(Status.match, isMatchIn(pcre, "abc", 3, 0, 3));
    try t.expectEqual(Status.match, isMatch(pcre, "abc", 3));

    // A LIVE bound is the one it cannot express. It must fault, and the fault
    // must be `BoundUnsupported` rather than `Unsupported`: a host reading
    // `Unsupported` would retry under PCRE2, which is the one arm guaranteed to
    // refuse again.
    try t.expectEqual(Status.invalid, isMatchIn(pcre, "abc", 3, 0, 2));
    try t.expectEqual(fault.Fault.BoundUnsupported, fault.last().?.code);

    var n: usize = 999;
    try t.expectEqual(Status.invalid, findAllIn(pcre, "abc", 3, 0, 2, null, 0, &n));
    try t.expectEqual(fault.Fault.BoundUnsupported, fault.last().?.code);
}

test "a bound that does not describe the text is refused, not clamped" {
    const re = try open("a", 0);
    defer free(re);
    var n: usize = 999;
    // `to` past the end, and `from` past `to`. Both are caller bugs, and a
    // silent `@min` would hide them until the answer was wrong elsewhere.
    try t.expectEqual(Status.invalid, isMatchIn(re, "abc", 3, 0, 4));
    try t.expectEqual(Status.invalid, isMatchIn(re, "abc", 3, 2, 1));
    try t.expectEqual(Status.invalid, findAllIn(re, "abc", 3, 0, 4, null, 0, &n));
    try t.expectEqual(Status.invalid, findAllIn(re, "abc", 3, 2, 1, null, 0, &n));
    // The whole-text guards still hold on the windowed verb.
    try t.expectEqual(Status.invalid, findAllIn(re, "abc", 3, 0, 3, null, 0, null));
    try t.expectEqual(Status.invalid, findAllIn(re, null, 3, 0, 3, null, 0, &n));
    // And a null text of length zero is still the empty text, not an error.
    try t.expectEqual(Status.ok, isMatchIn(re, null, 0, 0, 0));
}

test "the word rule is lowered into both arms, so captures cannot disagree" {
    // `-w` reaches the capture arm because both arms compile from one options
    // record. This verb used to need its own reject-and-resume loop, and the
    // arm it built dropped the flag entirely — so the loop was load-bearing.
    for ([_]u32{ 0, contract.flag_pcre }) |engine| {
        const re = try open("cat", contract.flag_word | engine);
        defer free(re);
        var got: [1]Span = undefined;
        var n: usize = 0;
        try t.expectEqual(Status.ok, captures(re, "concatenate", 11, 0, &got, 1, &n));
        try t.expectEqual(Status.ok, isMatch(re, "concatenate", 11));
        try t.expectEqual(Status.match, captures(re, "concatenate cat", 15, 0, &got, 1, &n));
        try t.expectEqual(Span{ .start = 12, .end = 15 }, got[0]);
    }
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

test "a leading directive compiles, the way every library a host knows does" {
    // The gap this closes: `(?i)cat` is the documented way to be
    // case-insensitive in `re`, `rust-regex`, `regexp` and PCRE2, and every one
    // of them accepts it with no flag argument at all. This seam used to refuse
    // it, so a host whose patterns came from a config file it does not own had
    // no way to spell what its users had already written.
    const ci = try open("(?i)cat", 0);
    defer free(ci);
    try t.expectEqual(Status.match, isMatch(ci, "a CAT", 5));

    // `(?s)` puts the newline back under `.`, `(?m)` moves `^`/`$` to the line
    // breaks — and each one only where it was asked for.
    const dot = try open("(?s)a.b", 0);
    defer free(dot);
    try t.expectEqual(Status.match, isMatch(dot, "a\nb", 3));
    const plain = try open("a.b", 0);
    defer free(plain);
    try t.expectEqual(Status.ok, isMatch(plain, "a\nb", 3));

    const per_line = try open("(?m)^b", 0);
    defer free(per_line);
    try t.expectEqual(Status.match, isMatch(per_line, "a\nb", 3));
    const per_text = try open("^b", 0);
    defer free(per_text);
    try t.expectEqual(Status.ok, isMatch(per_text, "a\nb", 3));

    // `(?-u)` is the ASCII opt-out, spelled as rg and rust-regex spell it: `\w`
    // stops covering `é`, which the Unicode default does cover.
    const ascii = try open("(?-u)\\w", 0);
    defer free(ascii);
    try t.expectEqual(Status.ok, isMatch(ascii, "é", 2));
    const uni = try open("\\w", 0);
    defer free(uni);
    try t.expectEqual(Status.match, isMatch(uni, "é", 2));

    // A run folds, and a directive with an empty rest is still a pattern — the
    // empty one, which matches anywhere.
    const run = try open("(?i)(?s)A.B", 0);
    defer free(run);
    try t.expectEqual(Status.match, isMatch(run, "a\nb", 3));
    const bare = try open("(?i)", 0);
    defer free(bare);
    try t.expectEqual(Status.match, isMatch(bare, "x", 1));

    // Groups are numbered from the pattern, not from the bytes in front of it.
    const caps = try open("(?i)(a)(b)", 0);
    defer free(caps);
    var groups: [3]Span = undefined;
    var n: usize = 0;
    try t.expectEqual(Status.match, captures(caps, "AB", 2, 0, &groups, 3, &n));
    try t.expectEqual(@as(usize, 3), n);
    try t.expectEqual(Span{ .start = 0, .end = 1 }, groups[1]);
}

test "the pattern's own spelling outranks the flag word, and the inference" {
    // The more specific statement wins, as it does in rust-regex: a host that
    // sets `IRGX_IGNORE_CASE` for its whole config file and one pattern that
    // says `(?-i)` are not in conflict — the pattern is the exception.
    const off = try open("(?-i)cat", contract.flag_ignore_case);
    defer free(off);
    try t.expectEqual(Status.ok, isMatch(off, "CAT", 3));
    try t.expectEqual(Status.match, isMatch(off, "cat", 3));

    // Smart case is a guess for when nobody said; `(?-i)` said. (Lowercase
    // pattern + smart case would otherwise fold.)
    const said = try open("(?-i)cat", contract.flag_smart_case);
    defer free(said);
    try t.expectEqual(Status.ok, isMatch(said, "CAT", 3));

    // And the guess is made about the pattern the engine sees, not the directive
    // in front of it: `(?m)` carries no case of its own.
    const guess = try open("(?m)cat", contract.flag_smart_case);
    defer free(guess);
    try t.expectEqual(Status.match, isMatch(guess, "CAT", 3));
}

test "the two arms that own the flag syntax are not read for" {
    // Under `-F` the bytes are data. A host searching for the literal `(?i)x`
    // must find it — rg and gist answer the same way — and must NOT quietly get
    // a case-insensitive `x`.
    const fixed = try open("(?i)x", contract.flag_fixed);
    defer free(fixed);
    try t.expectEqual(Status.match, isMatch(fixed, "see (?i)x here", 14));
    try t.expectEqual(Status.ok, isMatch(fixed, "X", 1));

    // PCRE2 implements the whole flag grammar itself, scoping included, so the
    // directive is left for it to read.
    const pcre = try open("(?i)x", contract.flag_pcre);
    defer free(pcre);
    try t.expectEqual(Status.match, isMatch(pcre, "X", 1));
    const scoped = try open("(?i:a)b", contract.flag_pcre);
    defer free(scoped);
    try t.expectEqual(Status.match, isMatch(scoped, "Ab", 2));
    try t.expectEqual(Status.ok, isMatch(scoped, "AB", 2));
}

test "a flag from the wider grammar routes to the arm that has it" {
    const sc = fault.scope();
    defer sc.end();
    var re: *Regex = undefined;

    // `x`, `U` and `R` are not this grammar's, and the honest answer is the one
    // the seam already has for every unsupported construct: a declinature that
    // names the arm which can answer, with no fault installed. Reading the `i`
    // out of `(?ix)` and dropping the `x` would be the silent wrong answer.
    for ([_][]const u8{ "(?x)a b", "(?U)a+", "(?ix)a b" }) |p| {
        try t.expectEqual(Status.stale, compile(p.ptr, p.len, 0, &re));
        try t.expect(fault.last() == null);
        try t.expectEqual(Status.ok, compile(p.ptr, p.len, contract.flag_pcre, &re));
        free(re);
    }

    // A directive in front of a genuinely broken pattern still reports an offset
    // measured in the pattern the HOST passed, not in the remainder this seam
    // compiled — `at` is only useful if it indexes the caller's own string.
    const broken = "(?i)(unclosed";
    try t.expectEqual(Status.invalid, compile(broken.ptr, broken.len, 0, &re));
    const d = fault.last().?;
    try t.expectEqual(fault.Fault.BadPattern, d.code);
    try t.expect(d.at.? >= 4);
    try t.expect(d.at.? <= broken.len);
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
