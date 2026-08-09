//! The anchored-longest-match plane — `libirgx`'s lexer C ABI.
//!
//! The two planes next door answer *search* questions: does this pattern occur
//! somewhere in this text (`pattern`), and which of N patterns occur somewhere
//! in it (`slate`). Both scan forward looking for a place a pattern would fit.
//! A tokenizer needs the opposite question, and it is the one primitive between
//! "does this regex match" and "lex this file": **starting at exactly this
//! offset, which pattern reaches furthest?**
//!
//! That question was already answered inside this library — `regex.Munch`, the
//! anchored determinization — and until now it was reachable only from Zig.
//! Every non-Zig host therefore had two options, both bad: run N anchored
//! `^`-prefixed searches per token and pay N walks for one answer, or ask for
//! the automaton's states and build the maximal-munch rule itself. The second
//! is why this plane exists rather than a `next_state` export: a host stepping
//! states would be a second opinion about what a pattern means, and the one
//! thing this engine will not ship is a second grammar (`charter.zone`'s seal
//! over `kernel/regex`, and the crest sieve incident behind it). So the rule
//! crosses the ABI, not the table.
//!
//! What a host gets is one compile and one scan:
//!
//!   * `compile` — N patterns into as many anchored automata as they need, with
//!     partial refusal. One terminal outside the linear syntax must not cost the
//!     other hundred and fifty, so a group that declines is halved and retried;
//!     what could not be taken is readable through `declined`.
//!   * `scan` — the longest (or shortest) match beginning at the caller's
//!     offset, among the patterns the caller currently permits, reporting every
//!     pattern that reached the winning length.
//!
//! **Ties are not resolved here, and that is the interface.** Longest is only
//! half of a lexer's rule; the tie-break (declared precedence, literal beats
//! regex, first-declared-wins) is a property of the grammar rather than of the
//! automaton. So a scan names *every* pattern that reached the winning length,
//! ascending, and has no opinion about which deserves it.
//!
//! **The permitted set rides the walk.** A real lexer is state-directed — only
//! some terminals are legal where it stands — and that cannot be recovered by
//! filtering the answer, because one long illegal match hides every short legal
//! one behind it. `allow` is therefore part of the scan, and it is addressed in
//! the caller's own pattern ordinals: a host never learns that automata are
//! grouped, because how they group is a consequence of which patterns refused.
//!
//! Three rules it shares with the planes next door, for the same reasons:
//!
//!   * **A handle is single-threaded.** It owns the winner buffer and the
//!     permission set every scan rewrites, so two threads sharing one would
//!     corrupt an answer rather than race a counter.
//!   * **Nothing can `die()` the host.** Every entry returns a `Status` and
//!     leaves the per-incident detail in the thread's fault slot.
//!   * **Nothing borrows the host's bytes past the call.** Pattern text is read
//!     during determinization and never retained, which the test at the bottom
//!     holds by overwriting the buffer it compiled from.

const std = @import("std");
const contract = @import("contract.zig");
const fault = @import("../../fault.zig");
const rx = @import("../../kernel/regex/regex.zig");
const request = @import("request.zig");

const Status = contract.Status;
const gpa = std.heap.c_allocator;

/// The request and its lowering are the pattern plane's — one `irgx_input`
/// judged one way for every face that takes it.
const Input = request.Input;
const Ask = request.Ask;

/// One terminal of a lexer slate: the bytes, and nothing else.
///
/// No per-pattern flag word, which is the one place this plane's shape differs
/// from `slate.Pattern` and the difference is forced rather than chosen: a
/// `Munch` determinizes every pattern *together*, under one set of options, so
/// "pattern 3 is case-insensitive" is not a thing the machine can be. Options
/// are the slate's, passed once to `compile`.
///
/// Extern and append-only, so a later field is a forward-compatible extension.
pub const Pattern = extern struct {
    pattern: ?[*]const u8,
    len: usize,
};

/// One pattern the slate could not take, and why.
///
/// The reason is carried rather than left to be inferred because the four have
/// different owners and different repairs: a syntax refusal is the pattern
/// author's, a state-budget refusal is this build's, a buffer-anchor refusal is
/// the pattern's shape and no build will fix it, and a word-context refusal is a
/// request the caller never made by flag. A host with a fallback engine runs it
/// for exactly these ordinals; a host without one at least knows what it is
/// blind to.
pub const Refusal = extern struct {
    pattern: u32,
    why: u32,
};

/// The parser would not accept the pattern's syntax.
pub const why_syntax: u32 = 0;
/// The subset construction reached this build's `max_states` bound. A statement
/// about the build, not about regular languages.
pub const why_states: u32 = 1;
/// A word-boundary assertion was reached through the pattern body, which an
/// anchored automaton has no left context to resolve.
pub const why_word_context: u32 = 2;
/// A buffer anchor (`\A`/`\z`) — undeterminizable at any budget, so unlike
/// `why_states` a bigger build will never admit it. An anchored scan already
/// begins where the caller pointed, which makes `\A` redundant and `\z`
/// unsatisfiable; drop it from the terminal.
pub const why_buffer_anchor: u32 = 3;

/// What a scan found: how far it reached, and how many patterns got there.
///
/// A struct rather than two out-parameters because the two are one answer, and
/// because it keeps the scan's signature to the width of `irgx_find_all_in`'s
/// instead of two past it.
///
/// `len` of zero is a real answer, not an absence: a pattern like `a*` accepts
/// the empty string. The status distinguishes them — `IRGX_MATCH` means
/// something accepted, `IRGX_OK` means nothing starts here — so a lexer that
/// would loop forever on a zero-length token can see it and say so.
///
/// `count` is how many patterns reached `len` whether or not `cap` held them,
/// the same contract `irgx_find_all` keeps, so a short buffer sizes its own
/// retry. Unlike there, the retry is always avoidable: the count can never
/// exceed `irgx_munch_len`.
pub const Token = extern struct {
    len: usize,
    count: usize,
};

/// Take the match that reaches furthest — maximal munch, the lexer's rule.
pub const pick_longest: u32 = 0;
/// Take the shortest non-empty match instead.
///
/// Worth having for the reason the kernel documents: asked over a slate nobody
/// asked for — every terminal a grammar has — longest answers a fact about the
/// grammar's widest regex rather than about the bytes, because such a slate
/// always contains a run-of-anything-but-a-delimiter. A host wanting a *name*
/// for the byte under it asks for the shortest reading instead.
pub const pick_shortest: u32 = 1;

/// The flag bits this plane honors, and it is neither `pattern_flags` nor
/// `slate_flags` but a third mask, because this plane can honor a different set
/// than either.
///
/// Five bits are refused instead of ignored, each because honoring it here would
/// be a lie a host cannot see:
///
///   * `IRGX_PCRE` — the PCRE2 arm has no anchored-longest-over-N automaton at
///     all. There is nothing to determinize, so there is nothing to be longest
///     among.
///   * `IRGX_WORD` — `\b` resolves against the bytes straddling a gap, and the
///     byte before the caller's offset is not in the text this automaton was
///     determinized over. The kernel declines the whole slate for this, so the
///     honest answer is to refuse the request rather than answer it from the
///     wrong context.
///   * `IRGX_SMART_CASE` — smart case is a question about one pattern's text,
///     and this plane's options are the slate's. A slate-wide answer derived
///     from "does *any* terminal have an uppercase letter" is not the rule
///     anyone means by it.
///   * `IRGX_FIXED` — literal patterns are expressible as patterns; a flag that
///     rewrote every terminal's meaning slate-wide is not what a lexer with a
///     mix of literals and regexes wants.
///   * `IRGX_MULTILINE` — the `(?m)` question has no answer an anchored
///     automaton can give, which is a stronger statement than the slate plane's
///     "nowhere to carry it". An automaton determinized to start at the caller's
///     offset has no left context and no view of the buffer's end, so `^` is
///     satisfied at every scan offset whether or not `(?m)` is on, and `$` and
///     `\z` are reachable from neither. Accepting the bit would have let a host
///     ask for line anchors, be told yes, and get the same machine.
///
/// `IRGX_DOTALL` **is** honored, where the slate plane refuses it — and that
/// asymmetry is the point of a third mask rather than an oversight in one of the
/// other two. It also only became honorable once `options` stopped conflating
/// the buffer model with `IRGX_MULTILINE`: before that the per-line parser had
/// already removed the byte this flag exists to put back, so asking for it did
/// nothing unless you asked for line anchors beside it.
pub const munch_flags = contract.flag_ignore_case | contract.flag_no_unicode |
    contract.flag_dotall;

/// A compiled lexer slate, the permission set its scans read, and the ordinal
/// space they answer in. Opaque to C — a host only ever holds the pointer — so
/// it is a plain struct rather than an `extern` one, as `pattern.Regex` and
/// `slate.Slate` are for the same reason.
pub const Munch = struct {
    inner: rx.Munch,
    /// Refilled by every scan that restricts the slate, sized once to the
    /// slate. Held here rather than allocated per call because a lexer asks a
    /// different question at every token, and a per-token allocation is the one
    /// cost this plane exists to avoid.
    allow: rx.Munch.Allow,
    /// The caller's ordinal space — the number of patterns handed to `compile`,
    /// which stays wider than the seated ordinals exactly when something
    /// declined. Kept because `declined` is read in these terms and the inner
    /// `Munch` records seats rather than the count it was given.
    count: usize,
};

/// Compile `patterns[0..count]` as one anchored slate under `flags`.
///
/// `.ok` with a handle whenever at least one pattern was taken — a partial
/// refusal is normal and is read through `declined`, not reported here, because
/// a slate of a hundred and fifty terminals where one declined is a working
/// lexer and returning an error for it would make the caller's fallback path
/// the common path.
///
/// `.stale` — a declinature, not a fault — when *nothing* could be taken. The
/// kernel discards its per-pattern reasons in that case, so there is no handle
/// to read them from; a host hearing this should ask a different engine rather
/// than inspect this one.
///
/// An empty slate compiles to a working handle that matches nothing, which is
/// the same answer `slate.compile` gives for the same reason: no patterns is
/// what a host whose config file listed none actually has, and every verb has
/// an answer for it.
pub fn compile(list: ?[*]const Pattern, count: usize, flags: u32, out: ?**Munch) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    if (flags & ~munch_flags != 0) return .invalid;

    // Null-with-zero is the empty slate said in the only spelling some hosts
    // can produce: Go's `&slice[0]` does not exist for an empty slice, and C's
    // answer for "the address of no array" is conventionally NULL. Null with a
    // non-zero count is a caller bug.
    const items: []const Pattern = if (list) |p|
        p[0..count]
    else if (count == 0)
        &.{}
    else
        return .invalid;

    const bodies = gpa.alloc([]const u8, items.len) catch
        return contract.report(.{ .code = error.OutOfMemory });
    defer gpa.free(bodies);
    for (items, bodies) |item, *body| {
        if (item.pattern == null and item.len != 0) return .invalid;
        body.* = if (item.pattern) |p| p[0..item.len] else &.{};
    }

    // Not copied, unlike the slate plane's, and the difference is real rather
    // than an oversight: determinization consumes the pattern text and the
    // automata it produces hold none of it, so there is nothing left aliasing
    // the host's buffer once this returns. The test at the bottom is what keeps
    // that true.
    var inner = (rx.Munch.compile(gpa, bodies, options(flags)) catch |e|
        return contract.report(.{ .code = faultOf(e) })) orelse
        // Every pattern refused, or none was offered under a slate the kernel
        // declines wholesale. The empty slate is not one of these — it is
        // handled below by adopting a slate with no voices — so reaching here
        // with `count == 0` is impossible and reaching it otherwise means the
        // kernel took nothing.
        return if (items.len == 0) empty(slot) else .stale;
    errdefer inner.deinit();

    var allow = inner.allowNone(gpa) catch {
        inner.deinit();
        return contract.report(.{ .code = error.OutOfMemory });
    };
    errdefer allow.deinit(gpa);

    // Assembled by hand rather than with a plain `errdefer`, which a
    // Status-returning entry never fires on its own: each step unwinds exactly
    // what the steps before it took, so a failed compile leaks nothing into a
    // host that keeps running.
    const handle = gpa.create(Munch) catch {
        allow.deinit(gpa);
        inner.deinit();
        return contract.report(.{ .code = error.OutOfMemory });
    };
    handle.* = .{ .inner = inner, .allow = allow, .count = items.len };
    slot.* = handle;
    return .ok;
}

/// The handle for a slate with no patterns — assembled rather than compiled,
/// because `Munch.compile` reports "nothing to determinize" and "nothing could
/// be determinized" as the same null and only the second is a declinature.
fn empty(slot: **Munch) Status {
    var none: [0]rx.Munch.Voice = .{};
    var inner = rx.Munch.adopt(gpa, 0, &none, &.{}) catch
        return contract.report(.{ .code = error.OutOfMemory });
    var allow = inner.allowNone(gpa) catch {
        inner.deinit();
        return contract.report(.{ .code = error.OutOfMemory });
    };
    const handle = gpa.create(Munch) catch {
        allow.deinit(gpa);
        inner.deinit();
        return contract.report(.{ .code = error.OutOfMemory });
    };
    handle.* = .{ .inner = inner, .allow = allow, .count = 0 };
    slot.* = handle;
    return .ok;
}

/// Release a handle from `compile`. Teardown leaves the fault slot alone, so a
/// host can still read the detail that made it clean up.
pub fn free(handle: *Munch) void {
    handle.allow.deinit(gpa);
    handle.inner.deinit();
    gpa.destroy(handle);
}

/// How many patterns the slate can name at once — the exact `cap` at which a
/// scan's winner buffer never comes up short.
///
/// The admitted count rather than the compile-list count, which the host
/// already knows: a declined pattern can never win, so it can never be
/// written, and sizing a buffer for it would be sizing for an impossibility.
pub fn len(handle: *const Munch) usize {
    return handle.inner.admitted();
}

/// Every pattern the slate could not take, ascending, into `out[0..cap]`.
///
/// `*written` is how many declined whether or not `cap` held them. `.match`
/// when at least one did, `.ok` when the slate took everything — which is the
/// normal case, and the reason this is a separate verb rather than an
/// out-parameter every compile has to pass.
pub fn declined(handle: *const Munch, out: ?[*]Refusal, cap: usize, written: ?*usize) Status {
    const count = written orelse return .invalid;
    count.* = 0;
    if (cap != 0 and out == null) return .invalid;

    const list = handle.inner.declined;
    for (list, 0..) |ordinal, i| {
        if (i < cap) out.?[i] = .{
            .pattern = ordinal,
            // Parallel by construction — the kernel appends to both lists
            // together — so the guard is for the `adopt` shape, which restores
            // automata it did not build and so has no reasons to give. A
            // slate assembled that way reports no refusals at all, making this
            // arm unreachable rather than merely unlikely.
            .why = if (i < handle.inner.because.len) why(handle.inner.because[i]) else why_syntax,
        };
    }
    count.* = list.len;
    return if (list.len == 0) .ok else .match;
}

/// The longest (or shortest) match beginning at exactly `at`.
///
/// `allow` is the patterns the caller will accept here, as its own ordinals;
/// null permits every one. Admitting an ordinal the slate declined is a no-op
/// rather than an error, because a host with a fallback for its blind terminals
/// should not also have to remember which they were.
///
/// `at == text_len` is legal and asks the only question left at the end of the
/// input: does anything accept the empty string.
///
/// `.match` when something accepted, `.ok` when nothing starts here.
pub fn scan(
    handle: *Munch,
    text: ?[*]const u8,
    text_len: usize,
    at: usize,
    allow: ?[*]const u32,
    nallow: usize,
    pick: u32,
    tok: ?*Token,
    out: ?[*]u32,
    cap: usize,
) Status {
    contract.beginCall();
    if (pick != pick_longest and pick != pick_shortest) return .invalid;
    // `at` is the request's `from`, and the whole text is its ceiling: this
    // spelling has never had a bound, so it must not acquire one here.
    const want = request.askOf(text, text_len, at, text_len, if (pick == pick_shortest) request.mode_earliest else 0, null);
    return take(handle, want, allow, nallow, tok, out, cap);
}

/// `scan` asked with the full request.
///
/// The mode word replaces `pick`: `IRGX_MODE_EARLIEST` is the shortest match,
/// which is this plane's one native earliest search — a `Munch` is an anchored
/// automaton, so its first accepting position is a thing it reaches on the way
/// rather than a filter over a leftmost answer. `IRGX_MODE_ANCHORED` is
/// accepted and inert for the same reason: every scan here already is one, so
/// asking for it is asking for what you have, and a zeroed struct that did not
/// ask still gets it.
///
/// `from` is `at`. A live `to` is refused — see `take`.
pub fn scanAsk(
    handle: *Munch,
    in: ?*const Input,
    allow: ?[*]const u32,
    nallow: usize,
    tok: ?*Token,
    out: ?[*]u32,
    cap: usize,
) Status {
    contract.beginCall();
    return take(handle, request.ask(in), allow, nallow, tok, out, cap);
}

/// The one scan. `.stale` for a request the host stopped, and a live ceiling is
/// the one thing in `irgx_input` this plane cannot honor: `longestAmong` reads
/// forward from `at` to wherever the automaton dies, and the only way to stop
/// it earlier is to hand it a shorter buffer — which moves the end of the text
/// and changes what a terminal like `[^\n]*` means. Refused with the same
/// `BoundUnsupported` the pattern plane raises on the arm that cannot express a
/// bound, rather than answered against a different haystack.
fn take(
    handle: *Munch,
    want: ?Ask,
    allow: ?[*]const u32,
    nallow: usize,
    tok: ?*Token,
    out: ?[*]u32,
    cap: usize,
) Status {
    const found = tok orelse return .invalid;
    found.* = .{ .len = 0, .count = 0 };
    // `Token` carries its own count, so this sink is opened onto that field —
    // the same true-total-versus-window contract every batch verb here keeps.
    var sink = contract.Sink(u32).open(out, cap, &found.count) orelse return .invalid;
    const req = want orelse return .invalid;
    if (allow == null and nallow != 0) return .invalid;
    if (!req.win.unbounded()) return contract.report(.{ .code = error.BoundUnsupported });
    if (req.stopped()) return .stale;

    // A restriction that permits nothing is a question with a knowable answer,
    // not an argument error: a lexer state can legitimately reach a point where
    // no terminal is legal, and hearing "nothing starts here" is what lets it
    // report the error against the bytes rather than against its own tables.
    if (allow) |ordinals| {
        handle.allow.forbidAll();
        for (ordinals[0..nallow]) |ordinal| handle.allow.admit(&handle.inner, ordinal);
    } else {
        handle.allow.admitAll();
    }

    const body = req.win.hay;
    const at = req.win.from;
    const match = if (req.earliest)
        handle.inner.shortestAmong(body, at, &handle.allow)
    else
        handle.inner.longestAmong(body, at, &handle.allow);
    const got = match orelse return .ok;

    found.len = got.len;
    for (got.patterns) |ordinal| sink.push(ordinal);
    _ = sink.close();
    return .match;
}

/// The kernel's refusal reason as the integer the header publishes. Exhaustive
/// rather than defaulted, so a new kernel reason fails to compile here instead
/// of silently arriving at a host as `why_syntax`.
fn why(because: rx.Munch.Because) u32 {
    return switch (because) {
        .syntax => why_syntax,
        .states => why_states,
        .buffer_anchor => why_buffer_anchor,
        .word_context => why_word_context,
    };
}

/// `flags` as the options the whole slate is determinized under.
///
/// **The kernel's `multiline` is not `IRGX_MULTILINE`, and mapping the flag onto
/// it is the bug this function is written around.** Down in `lower.zig`,
/// `multiline` says *the haystack is a buffer rather than one line*, and the
/// whole per-line model hangs off it: under that model the compiler is licensed
/// to assume no haystack contains a `\n`, so it drops `\n` from every class run.
/// `gist` can keep that promise because it feeds one line at a time. A host
/// handing this plane a whole file cannot — and a lexer whose whitespace
/// terminal is `\s+` or `[ \t\n]+` would silently never match a line break,
/// which is not fewer tokens but a wrong tokenization of every multi-line input.
///
/// So the buffer model is forced, exactly as `glean/pattern.zig` forces it for
/// the pattern plane and for the same reason. `line_anchors` is then pinned off
/// rather than left null, because null *inherits* `multiline` — now always true
/// — and this plane refuses `IRGX_MULTILINE` precisely because it cannot answer
/// the `(?m)` question either way. Saying so explicitly is what keeps a future
/// reader from concluding the inheritance was the intent.
///
/// `word` is absent because `munch_flags` refuses its bit, and `crlf`,
/// `force_dfa` and `symbolic` because they are build and engine-selection
/// knobs rather than statements about what a pattern means.
fn options(flags: u32) rx.Munch.Options {
    return .{
        .caseless = flags & contract.flag_ignore_case != 0,
        .multiline = buffer_model,
        .line_anchors = false,
        .dotall = flags & contract.flag_dotall != 0,
        .unicode = flags & contract.flag_no_unicode == 0,
    };
}

/// The haystack is a buffer, always — see `options` for why this is not a knob.
const buffer_model = true;

/// Narrow a kernel error onto the fault vocabulary this ABI publishes.
/// Determinization can fail by exhaustion or by a pattern the parser rejects,
/// and the second is already a per-pattern refusal — so what reaches here is
/// the whole-slate failure, and `@errorCast` is what asserts that.
fn faultOf(e: anyerror) fault.Fault {
    return @errorCast(e);
}

// ── tests ──────────────────────────────────────────────────────────────────
//
// What maximal munch MEANS is settled one layer down and proved there
// (`regex/linear/program/munch_test.zig`). These tests are about the seam: that
// the rule survives the crossing, that a host's pattern bytes are not aliased,
// that the permitted set is read in the caller's ordinals rather than the
// kernel's seats, and that every flag this plane refuses is refused loudly.

const t = std.testing;

fn spell(list: []const []const u8, buf: []Pattern) []const Pattern {
    for (list, buf[0..list.len]) |text, *p| p.* = .{ .pattern = text.ptr, .len = text.len };
    return buf[0..list.len];
}

fn open(list: []const []const u8, flags: u32) *Munch {
    var buf: [16]Pattern = undefined;
    const items = spell(list, &buf);
    var handle: *Munch = undefined;
    const st = compile(items.ptr, items.len, flags, &handle);
    std.debug.assert(st == .ok);
    return handle;
}

/// One token's answer as `(status, len, winners)`, through the same buffer
/// discipline a host would use.
fn token(handle: *Munch, text: []const u8, at: usize, allow: ?[]const u32, pick: u32) struct {
    status: Status,
    len: usize,
    winners: []const u32,
} {
    const held = struct {
        var slot: [16]u32 = undefined;
    };
    var tok: Token = undefined;
    const st = scan(
        handle,
        text.ptr,
        text.len,
        at,
        if (allow) |a| a.ptr else null,
        if (allow) |a| a.len else 0,
        pick,
        &tok,
        &held.slot,
        held.slot.len,
    );
    return .{ .status = st, .len = tok.len, .winners = held.slot[0..@min(tok.count, held.slot.len)] };
}

test "longest wins, and every pattern reaching it is named" {
    // The rule itself, across the seam: `>>=` over `>`, and a tie reported as a
    // tie rather than arbitrated.
    const handle = open(&.{ ">", ">>", ">>=", ">>=" }, 0);
    defer free(handle);

    const got = token(handle, ">>=x", 0, null, pick_longest);
    try t.expectEqual(Status.match, got.status);
    try t.expectEqual(@as(usize, 3), got.len);
    try t.expectEqualSlices(u32, &.{ 2, 3 }, got.winners);
}

test "the scan is anchored — it never finds a token that starts later" {
    // The difference from every other plane in this library, and the reason
    // this one exists: `slate.which` would say `ab` matches this text.
    const handle = open(&.{"ab"}, 0);
    defer free(handle);

    try t.expectEqual(Status.ok, token(handle, "xxab", 0, null, pick_longest).status);
    try t.expectEqual(Status.match, token(handle, "xxab", 2, null, pick_longest).status);
}

test "a host's pattern bytes are not aliased past the compile" {
    // The claim the doc comment on `compile` makes. A host is entitled to
    // compile out of a stack buffer it then reuses; if determinization retained
    // the slice, this would answer about the overwritten bytes.
    var buf = "abc".*;
    var list = [_]Pattern{.{ .pattern = &buf, .len = buf.len }};
    var handle: *Munch = undefined;
    try t.expectEqual(Status.ok, compile(&list, list.len, 0, &handle));
    defer free(handle);

    @memset(&buf, 'z');
    const got = token(handle, "abc", 0, null, pick_longest);
    try t.expectEqual(Status.match, got.status);
    try t.expectEqual(@as(usize, 3), got.len);
}

test "a restriction hides a longer illegal match instead of filtering it out" {
    // Why `allow` is part of the walk rather than a filter over the answer: the
    // identifier reaches further than the keyword at this offset, so filtering
    // afterward would return nothing where the correct answer is `if`.
    const handle = open(&.{ "if", "[a-z]+" }, 0);
    defer free(handle);

    const unrestricted = token(handle, "iffy", 0, null, pick_longest);
    try t.expectEqual(@as(usize, 4), unrestricted.len);
    try t.expectEqualSlices(u32, &.{1}, unrestricted.winners);

    const keyword_only = token(handle, "iffy", 0, &.{0}, pick_longest);
    try t.expectEqual(Status.match, keyword_only.status);
    try t.expectEqual(@as(usize, 2), keyword_only.len);
    try t.expectEqualSlices(u32, &.{0}, keyword_only.winners);
}

test "a slate permitting nothing answers, rather than erroring" {
    const handle = open(&.{"a"}, 0);
    defer free(handle);

    const got = token(handle, "aaa", 0, &.{}, pick_longest);
    try t.expectEqual(Status.ok, got.status);
    try t.expectEqual(@as(usize, 0), got.len);
}

test "shortest is the other reading of the same offset" {
    const handle = open(&.{ "[a-z]", "[a-z]+" }, 0);
    defer free(handle);

    try t.expectEqual(@as(usize, 3), token(handle, "abc", 0, null, pick_longest).len);
    try t.expectEqual(@as(usize, 1), token(handle, "abc", 0, null, pick_shortest).len);
}

test "a zero-length match is a result, not an absence" {
    // A lexer advancing on this would not terminate, so the seam has to let it
    // tell the two apart: `IRGX_MATCH` with `len == 0` is `a*` accepting the
    // empty string, `IRGX_OK` is nothing starting here at all.
    const handle = open(&.{"a*"}, 0);
    defer free(handle);

    const at_end = token(handle, "", 0, null, pick_longest);
    try t.expectEqual(Status.match, at_end.status);
    try t.expectEqual(@as(usize, 0), at_end.len);
}

test "an empty slate is a working handle that matches nothing" {
    var handle: *Munch = undefined;
    try t.expectEqual(Status.ok, compile(null, 0, 0, &handle));
    defer free(handle);

    try t.expectEqual(@as(usize, 0), len(handle));
    try t.expectEqual(Status.ok, token(handle, "anything", 0, null, pick_longest).status);
}

test "a partial refusal keeps the rest of the slate lexing, and says what it lost" {
    // The property `Munch`'s bisection exists for, asserted at the seam: the
    // backreference cannot be determinized, and the other two terminals must
    // not pay for it.
    const handle = open(&.{ "[a-z]+", "(a)\\1", "[0-9]+" }, 0);
    defer free(handle);

    var refusals: [8]Refusal = undefined;
    var n: usize = 0;
    try t.expectEqual(Status.match, declined(handle, &refusals, refusals.len, &n));
    try t.expectEqual(@as(usize, 1), n);
    try t.expectEqual(@as(u32, 1), refusals[0].pattern);

    // The survivors still answer in the CALLER's ordinals — 2, not the seat the
    // bisection happened to give it.
    const digits = token(handle, "123", 0, null, pick_longest);
    try t.expectEqual(Status.match, digits.status);
    try t.expectEqualSlices(u32, &.{2}, digits.winners);
}

test "a slate that takes everything reports no refusals" {
    const handle = open(&.{ "a", "b" }, 0);
    defer free(handle);

    var n: usize = 1;
    try t.expectEqual(Status.ok, declined(handle, null, 0, &n));
    try t.expectEqual(@as(usize, 0), n);
}

test "the winner count survives a short buffer, so a retry can be sized" {
    const handle = open(&.{ "a", "a", "a" }, 0);
    defer free(handle);

    var tok: Token = undefined;
    var one: [1]u32 = undefined;
    try t.expectEqual(Status.match, scan(handle, "a", 1, 0, null, 0, pick_longest, &tok, &one, one.len));
    try t.expectEqual(@as(usize, 3), tok.count);
    try t.expectEqual(@as(usize, 3), len(handle));
}

test "every flag this plane cannot honor is refused rather than ignored" {
    var list = [_]Pattern{.{ .pattern = "a", .len = 1 }};
    var handle: *Munch = undefined;
    for ([_]u32{
        contract.flag_pcre,
        contract.flag_word,
        contract.flag_smart_case,
        contract.flag_fixed,
        contract.flag_multiline,
    }) |flag| {
        try t.expectEqual(Status.invalid, compile(&list, list.len, flag, &handle));
    }
    // And the ones it does honor still compile.
    try t.expectEqual(Status.ok, compile(&list, list.len, munch_flags, &handle));
    free(handle);
}

test "a class terminal can match a newline, because the buffer model is not a flag" {
    // The bug `options` is written around, and the reason it is pinned here
    // rather than left to the flag test below: nothing a host can pass makes
    // this work or break, so only a test that never mentions a flag can catch
    // it. Under the per-line model the compiler drops `\n` from every class run,
    // which would leave a lexer's whitespace terminal unable to see a line
    // break — a wrong tokenization of every multi-line input, not a smaller one.
    const handle = open(&.{ "[ \t\n]+", "\\s+", "[^x]+" }, 0);
    defer free(handle);

    for ([_][]const u8{ "\n", " \n ", "\t\n\t" }) |text| {
        const got = token(handle, text, 0, null, pick_longest);
        try t.expectEqual(Status.match, got.status);
        try t.expectEqual(text.len, got.len);
    }
}

test "an anchor is the scan offset, which is why line anchors are refused" {
    // The behavior that makes `IRGX_MULTILINE` unanswerable here, pinned so the
    // refusal has a reason on record rather than only a comment. The automaton
    // starts where the caller pointed, so `^` is satisfied at every offset — and
    // an end anchor is satisfiable at none, because a longest-match walk stops at
    // its furthest accepting reach and never learns where the buffer ended.
    const handle = open(&.{ "^b", "a$" }, 0);
    defer free(handle);

    // `^` holds at offset 2, where the buffer's own start is long past.
    try t.expectEqual(Status.match, token(handle, "a\nb", 2, &.{0}, pick_longest).status);
    // `$` is reachable from nowhere, with or without a line to end at.
    try t.expectEqual(Status.ok, token(handle, "a\nb", 0, &.{1}, pick_longest).status);
}

test "a buffer anchor refuses as a wall rather than as a budget" {
    // `why_states` and `why_buffer_anchor` were one value until a test asked why
    // `\Ab` reported a size problem. They are a budget and a wall: the first says
    // a bigger build would take the pattern, the second that none ever will, and
    // a host choosing whether to retune or rewrite needs them apart.
    const handle = open(&.{ "b", "\\Ab", "a\\z" }, 0);
    defer free(handle);

    var refusals: [4]Refusal = undefined;
    var n: usize = 0;
    try t.expectEqual(Status.match, declined(handle, &refusals, refusals.len, &n));
    try t.expectEqual(@as(usize, 2), n);
    for (refusals[0..n], [_]u32{ 1, 2 }) |got, pattern| {
        try t.expectEqual(pattern, got.pattern);
        try t.expectEqual(why_buffer_anchor, got.why);
    }

    // And one refused terminal still does not cost its neighbors.
    try t.expectEqual(Status.match, token(handle, "b", 0, null, pick_longest).status);
}

test "dotall works on its own, as it does on the pattern plane" {
    // It used to need `IRGX_MULTILINE` beside it, which was the visible symptom
    // of the conflation above: the per-line parser had already removed the byte
    // this flag exists to put back.
    const strict = open(&.{"a.b"}, 0);
    defer free(strict);
    try t.expectEqual(Status.ok, token(strict, "a\nb", 0, null, pick_longest).status);

    const loose = open(&.{"a.b"}, contract.flag_dotall);
    defer free(loose);
    try t.expectEqual(Status.match, token(loose, "a\nb", 0, null, pick_longest).status);
}

test "the flags it honors change what a pattern means" {
    const sensitive = open(&.{"abc"}, 0);
    defer free(sensitive);
    try t.expectEqual(Status.ok, token(sensitive, "ABC", 0, null, pick_longest).status);

    const folded = open(&.{"abc"}, contract.flag_ignore_case);
    defer free(folded);
    try t.expectEqual(Status.match, token(folded, "ABC", 0, null, pick_longest).status);
}

test "argument guards answer instead of dying" {
    const handle = open(&.{"a"}, 0);
    defer free(handle);

    var tok: Token = undefined;
    var buf: [4]u32 = undefined;
    // An offset past the end, a null token slot, an unknown pick, a capacity
    // with nowhere to write, and a length with no array.
    try t.expectEqual(Status.invalid, scan(handle, "a", 1, 2, null, 0, pick_longest, &tok, &buf, buf.len));
    try t.expectEqual(Status.invalid, scan(handle, "a", 1, 0, null, 0, pick_longest, null, &buf, buf.len));
    try t.expectEqual(Status.invalid, scan(handle, "a", 1, 0, null, 0, 99, &tok, &buf, buf.len));
    try t.expectEqual(Status.invalid, scan(handle, "a", 1, 0, null, 0, pick_longest, &tok, null, 1));
    try t.expectEqual(Status.invalid, scan(handle, null, 1, 0, null, 0, pick_longest, &tok, &buf, buf.len));
    try t.expectEqual(Status.invalid, scan(handle, "a", 1, 0, null, 1, pick_longest, &tok, &buf, buf.len));

    var out: *Munch = undefined;
    var list = [_]Pattern{.{ .pattern = null, .len = 3 }};
    try t.expectEqual(Status.invalid, compile(&list, list.len, 0, &out));
    try t.expectEqual(Status.invalid, compile(&list, list.len, 0, null));
}
