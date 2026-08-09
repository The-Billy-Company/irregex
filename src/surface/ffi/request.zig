//! The request every search verb takes, and the one lowering that judges it.
//!
//! `Input` is the Zig side of `irgx_input`: one struct a host fills instead of
//! one verb per option, so the next mode is a bit rather than four more names to
//! declare, bind in three languages, and keep true. Three planes ask questions
//! about a buffer — `pattern`, `slate`, `munch` — and every one of them, the
//! shipped `is_match` / `find_all` / `is_match_in` / `find_all_in` included,
//! reaches its engine through `askOf`. A rule stated once therefore cannot hold
//! on four verbs and lapse on the fifth.
//!
//! It lives in its own module for that reason and not for tidiness. The request
//! is vocabulary SHARED by three planes, so housing it inside any one of them
//! makes the other two import a sibling plane to say what they are being asked —
//! which is how `munch` came to depend on `pattern` for a type neither of them
//! owns. This is the same call the C header makes one layer up, where
//! `irgx_cancel` is declared above the plane that opens one because a search
//! takes a token and a corpus makes one.
//!
//! It is NOT in `contract.zig`, which is the other candidate and the wrong one:
//! that module is imported by every plane and holds only what `std` and
//! `fault.zig` can supply. A `Window` and a `CancelToken` would drag `mark` and
//! the whole `exec/session` tier into the substrate underneath planes that never
//! ask a question at all.
//!
//! Read it beside `answer.zig`: the request a host writes, the answer a host
//! reads.

const std = @import("std");
const mark = @import("../../mark.zig");
const answer = @import("../../exec/session/answer/answer.zig");
const contract = @import("contract.zig");

const Window = mark.Window;

/// Trip it from any thread to stop a search that takes it.
pub const CancelToken = answer.CancelToken;

/// Extern and APPEND-ONLY, and `struct_size` is FAIL-CLOSED: a size this build
/// does not recognize is `.invalid`, never a best-effort read of the prefix it
/// thinks it recognizes. A v1 caller and a v2 engine agreeing on a struct whose
/// meaning drifted is exactly the failure `irgx_abi_version` exists to make
/// loud, so it is not quietly absorbed here.
///
/// **Zero is today.** Every field's `0` is its documented default, so a struct a
/// host memsets and stamps `struct_size` onto is the unanchored, leftmost,
/// uncancellable search over the whole text this ABI has always done. `to` is
/// the one field whose zero would have been a trap — it would read as the whole
/// text by accident — which is why `to_end` is spelled and `to == 0` is an
/// EMPTY window.
pub const Input = extern struct {
    struct_size: u32,
    mode: u32,
    /// The WHOLE text. `from`/`to` bound where a match may sit; they never move
    /// the edges `$`, `\b`, `\z` and every look-around read.
    text: ?[*]const u8,
    len: usize,
    from: usize,
    to: usize,
    /// Null is uncancellable, which is what a zeroed struct asks for.
    cancel: ?*const CancelToken,
    pattern: u32,
    reserved: u32,
};

/// A match must START where the search does. **Not** `\A`-rewriting the
/// pattern: it constrains where the search may begin and leaves the pattern's
/// own assertions about `text` alone, which is a difference you can see at any
/// `from > 0`. See `glean.Cursor.anchored` for what it means across a walk.
pub const mode_anchored: u32 = 1 << 0;
/// Report the first accepting position rather than the leftmost-first match.
///
/// A question about how much a host is willing to pay for a yes, so it is
/// honored on the boolean verbs and refused on the span ones — see the pattern
/// plane's `gather`, which is where the honest limit of this build is written
/// down.
pub const mode_earliest: u32 = 1 << 1;
pub const input_modes = mode_anchored | mode_earliest;

/// `to`: search to the end of the text. Spelled rather than inferred, so a
/// zeroed `to` stays the empty window it reads like.
pub const to_end: usize = std.math.maxInt(usize);
/// `pattern`: any pattern may answer. Meaningless to a single-pattern handle,
/// which always answers as pattern 0 — so that plane takes it, takes `0`, and
/// refuses anything else rather than ignoring a number a host meant something by.
pub const pattern_any: u32 = std.math.maxInt(u32);

/// One lowered request: what the engine takes, once the seam has judged it.
pub const Ask = struct {
    win: Window,
    anchored: bool,
    earliest: bool,
    cancel: ?*const CancelToken,

    /// Has the host asked us to stop? Read at every point a verb could give one
    /// back — never mid-search, because a single leftmost search is one call
    /// into an engine that has no checkpoint to offer.
    pub fn stopped(self: Ask) bool {
        return if (self.cancel) |c| c.requested() else false;
    }
};

/// `irgx_input` judged and lowered, or null for a request that does not
/// describe the text it is about.
pub fn ask(in: ?*const Input) ?Ask {
    const req = in orelse return null;
    if (req.struct_size != @sizeOf(Input)) return null;
    // An undeclared mode bit, and a `reserved` a host wrote something into, are
    // both statements this build cannot honor. Refused rather than masked off,
    // for the same reason `compile` refuses an unknown flag.
    if (req.mode & ~input_modes != 0 or req.reserved != 0) return null;
    if (req.pattern != pattern_any and req.pattern != 0) return null;
    // The sentinel resolves HERE and nowhere else. The four shipped verbs take a
    // literal `to`, so `SIZE_MAX` is out of range to them and always has been;
    // teaching it a meaning down in `askOf` would silently turn one of their
    // caller errors into the widest possible search.
    return askOf(req.text, req.len, req.from, if (req.to == to_end) req.len else req.to, req.mode, req.cancel);
}

/// The same lowering from a verb's own argument list rather than from a struct.
/// The shipped four reach the engine through here, and so do the `slate` and
/// `munch` planes, so the bound rules are stated in exactly one place and cannot
/// fork across the three faces that publish them.
pub fn askOf(text: ?[*]const u8, len: usize, from: usize, to: usize, mode: u32, cancel: ?*const CancelToken) ?Ask {
    const body = contract.view(text, len) orelse return null;
    // Refused rather than clamped. A host that computed `to` past the end, or
    // crossed its bounds, has a bug that a silent `@min` would hide until the
    // answer was quietly wrong somewhere else.
    if (from > to or to > len) return null;
    return .{
        .win = .{ .hay = body, .from = from, .to = to },
        .anchored = mode & mode_anchored != 0,
        .earliest = mode & mode_earliest != 0,
        .cancel = cancel,
    };
}

test "a zeroed request, size stamped, is the search this ABI has always done" {
    const t = std.testing;
    const hay = "abc";
    var in: Input = std.mem.zeroes(Input);
    in.struct_size = @sizeOf(Input);
    in.text = hay.ptr;
    in.len = hay.len;
    in.to = to_end;

    const got = ask(&in) orelse return error.TestUnexpectedResult;
    try t.expectEqualStrings(hay, got.win.hay);
    try t.expectEqual(@as(usize, 0), got.win.from);
    try t.expectEqual(hay.len, got.win.to);
    try t.expect(!got.anchored);
    try t.expect(!got.earliest);
    try t.expect(!got.stopped());
}

test "the request is fail-closed on every word it does not recognize" {
    const t = std.testing;
    const hay = "abc";
    const base = Input{
        .struct_size = @sizeOf(Input),
        .mode = 0,
        .text = hay.ptr,
        .len = hay.len,
        .from = 0,
        .to = hay.len,
        .cancel = null,
        .pattern = pattern_any,
        .reserved = 0,
    };

    try t.expectEqual(@as(?Ask, null), ask(null));
    // A size from another build, in BOTH directions — a shorter prefix is not
    // read as an older struct, because we cannot know which older one.
    var short = base;
    short.struct_size = @sizeOf(Input) - 4;
    try t.expectEqual(@as(?Ask, null), ask(&short));
    var long = base;
    long.struct_size = @sizeOf(Input) + 4;
    try t.expectEqual(@as(?Ask, null), ask(&long));
    // A mode bit this build never declared.
    var mode = base;
    mode.mode = 1 << 7;
    try t.expectEqual(@as(?Ask, null), ask(&mode));
    // A reserved word a host meant something by.
    var res = base;
    res.reserved = 1;
    try t.expectEqual(@as(?Ask, null), ask(&res));
    // A pattern ordinal a single-pattern handle cannot honor.
    var pat = base;
    pat.pattern = 3;
    try t.expectEqual(@as(?Ask, null), ask(&pat));
    // Bounds that do not describe the text: refused, never clamped.
    var past = base;
    past.to = hay.len + 1;
    try t.expectEqual(@as(?Ask, null), ask(&past));
    var crossed = base;
    crossed.from = 2;
    crossed.to = 1;
    try t.expectEqual(@as(?Ask, null), ask(&crossed));
    // Null text carrying a length is a caller bug; null with zero is empty text.
    var nul = base;
    nul.text = null;
    try t.expectEqual(@as(?Ask, null), ask(&nul));
    nul.len = 0;
    nul.to = 0;
    try t.expect(ask(&nul) != null);
}

test "to_end resolves to the length here, and a zero `to` stays the empty window" {
    const t = std.testing;
    const hay = "abcdef";
    var in = Input{
        .struct_size = @sizeOf(Input),
        .mode = 0,
        .text = hay.ptr,
        .len = hay.len,
        .from = 0,
        .to = to_end,
        .cancel = null,
        .pattern = 0,
        .reserved = 0,
    };
    try t.expectEqual(hay.len, (ask(&in) orelse unreachable).win.to);

    // The trap this sentinel exists to avoid: a memset `to` is EMPTY, not all.
    in.to = 0;
    const empty = ask(&in) orelse unreachable;
    try t.expectEqual(@as(usize, 0), empty.win.to);
    try t.expectEqual(@as(usize, 0), empty.win.from);

    // And a raw `askOf` never learns the sentinel — the shipped verbs pass a
    // literal `to`, so SIZE_MAX must stay the out-of-range bound it always was.
    try t.expectEqual(@as(?Ask, null), askOf(hay.ptr, hay.len, 0, to_end, 0, null));
}

test "each mode bit lowers to its own field, and they compose" {
    const t = std.testing;
    const hay = "abc";
    const anchored = askOf(hay.ptr, hay.len, 0, hay.len, mode_anchored, null) orelse unreachable;
    try t.expect(anchored.anchored and !anchored.earliest);
    const earliest = askOf(hay.ptr, hay.len, 0, hay.len, mode_earliest, null) orelse unreachable;
    try t.expect(earliest.earliest and !earliest.anchored);
    const both = askOf(hay.ptr, hay.len, 0, hay.len, input_modes, null) orelse unreachable;
    try t.expect(both.anchored and both.earliest);
}

test "a tripped token is read through the lowered request" {
    const t = std.testing;
    const hay = "abc";
    var token = CancelToken{};
    const req = askOf(hay.ptr, hay.len, 0, hay.len, 0, &token) orelse unreachable;
    try t.expect(!req.stopped());
    token.cancel();
    try t.expect(req.stopped());
}
