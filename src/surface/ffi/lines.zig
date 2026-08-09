//! From a byte offset to a line — the arithmetic every grep-shaped host rebuilds,
//! and gets subtly wrong.
//!
//! A match arrives as a byte span. What a host wants to SHOW is a line number, the
//! line's own bytes, and some lines either side of it. That conversion looks
//! trivial and is not: the line containing an offset, a 1-based number that agrees
//! with what every other tool prints, a final line with no terminator, CRLF, and a
//! context window that must clamp at both ends of the file without renumbering.
//! Every host writes it; this package writes it seven times internally, which is
//! the honest argument that it is a primitive rather than a convenience.
//!
//! THIS TIER IS NOT EMPTY, AND THAT IS THE ASSIGNMENT. There are already seven
//! implementations in four distinct shapes, and they agree on rg's newline rule
//! while disagreeing on data shape, which is why nobody has collapsed them:
//!
//!   * content-only slices — `corpus/read/legible.zig` `collectLines`
//!   * an offset grid — `exec/cold/emit/multiline.zig` `splitLines` + `lineIndexAt`
//!   * a warm iterator — `exec/session/facet/stream.zig` `LineWalk`
//!   * count-only scanners — `exec/session/warm/mirror.zig` `gatedLineCount`,
//!     `kernel/query/query.zig` `countGeneric`, `kernel/scan/classrun.zig`
//!     `countLines` (the last two fused into SIMD class runs)
//!
//! So the primitive must be able to SERVE all four — offsets AND content AND a
//! bare count — or it is a fifth copy wearing the word "shared". Read all four
//! before designing it.
//!
//! DO NOT re-point the existing call sites. They are load-bearing across the
//! cold, warm, query and scan tiers, three of them behind SIMD, and swapping them
//! is its own change with its own profiling and its own risk of moving a hot
//! loop. Land the primitive and the plane; report the collapse as a follow-up
//! naming the exact call sites and any shape your primitive cannot yet serve.
//!
//! LANE: `lines` (Wave 1). Read `contract.zig` for the plane idioms — the shared
//! `view()`, `Sink(T)` for the count-versus-capacity window, `beginCall` on work
//! entries. Do not add an `export fn` here or edit the header; the orchestrator
//! lands the C signature with the three bindings, since an export no binding
//! names fails the parity gate for every lane at once.
//!
//! ## What this plane is, now that it is written
//!
//! Three verbs over `kernel/anatomy/lines.zig`, each a different question and a
//! different cost class rather than three spellings of one walk:
//!
//!   * `count` — how many lines are there. One vectorized pass, no rows.
//!   * `context` — the clamped band of lines around ONE offset. One pass over
//!     the prefix for the number, then a terminator search per band line — so a
//!     three-line window over a megabyte file never materializes the megabyte.
//!   * `split` — every line of the text as a grid, one pass. What a host with
//!     MANY offsets wants, because resolving them one at a time through
//!     `context` is a prefix pass each.
//!
//! **Nothing here allocates**, which is why no entry has an unwind path to get
//! wrong: `count` tallies, and both row verbs stream the walk straight into the
//! caller's buffer through `contract.Sink`. So `cap = 0` with a null buffer is a
//! free sizing probe — it runs the same walk and publishes the same true total
//! without writing a byte.
//!
//! **There is no declinature here.** `.stale` says a tier stepped aside and the
//! caller should answer one tier down; this plane is arithmetic over bytes the
//! host already holds, so there is no lower tier and nothing to step aside from.
//! An offset with no line on it (an empty text, or the phantom position after a
//! trailing terminator) is a RESULT — `.ok` with zero rows — not a refusal.
//!
//! **The terminator is `\n`, fixed.** The primitive underneath is parameterized
//! (`--null-data` splits on `\x00` under the identical rule), but a `uint8_t
//! term` argument on the ABI would make the commonest caller mistake — leaving
//! a field zeroed — silently mean "split this text on NUL bytes". If a host
//! needs it, that is a sibling verb whose name says so, not a defaultable
//! parameter on this one.

const std = @import("std");
const contract = @import("contract.zig");
const anatomy = @import("../../kernel/anatomy/lines.zig");

const Status = contract.Status;

/// One line of the answer: its 1-based number and its three byte offsets.
///
/// Extern and append-only, so a later field is a forward-compatible extension.
/// No `struct_size` here, unlike `FaultDetail` and `SearchRequest`: those are
/// CALLER-built in-structs, where an unrecognized size is the caller telling us
/// about a layout we may not share. This is an out-row written into an array the
/// caller sized in units of it, exactly as `irgx_find_all`'s spans are, and a
/// per-element size word would be a header repeated once per line.
///
/// `u64` rather than `usize` so the row has one layout on a 32-bit host too — a
/// binding decodes one struct, not two.
pub const Line = extern struct {
    /// 1-based, matching what `-n` prints and what an editor jumps to. A clamp
    /// at the top of the file shortens a band; it never renumbers, so this is
    /// always a real line number in the text.
    number: u64,
    /// Byte offset of the line's first byte.
    start: u64,
    /// One past the last CONTENT byte — the terminator excluded, and a CRLF's
    /// `\r` KEPT. That is ripgrep's default without `--crlf`, and it is what the
    /// matching engines in this package see, so a host that strips the `\r` for
    /// display and matches on the unstripped bytes stays consistent with them.
    content_end: u64,
    /// One past the terminator, so the next line's `start`. Equals `text_len`
    /// for a final line with no terminator, which is still a line.
    term_end: u64,
};

fn rowOf(line: anatomy.Line, number: usize) Line {
    return .{
        .number = @intCast(number),
        .start = @intCast(line.start),
        .content_end = @intCast(line.content_end),
        .term_end = @intCast(line.term_end),
    };
}

/// How many lines `text[0..len]` holds: `.match` when it holds at least one,
/// `.ok` when it holds none.
///
/// The rule is ripgrep's, and the two halves a naive `count('\n') + 1` gets
/// wrong are exactly why this is worth a verb: a trailing terminator yields NO
/// phantom final line, and an empty text has zero lines rather than one.
pub fn count(text: ?[*]const u8, len: usize, out: ?*u64) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    // Cleared before the argument guard, so a host that reads the slot after an
    // `.invalid` sees zero rather than whatever its own stack left there.
    slot.* = 0;
    const bytes = contract.view(text, len) orelse return .invalid;
    slot.* = @intCast(anatomy.count(bytes, anatomy.newline));
    return if (slot.* == 0) .ok else .match;
}

/// Fill `out[0..cap]` with the line holding byte `at` plus `before` lines above
/// and `after` below, clamped at both ends of the text, and write the band's
/// true length to `*written`.
///
/// `.match` when the band holds a line, `.ok` when it holds none — and "none" is
/// a real answer, not a failure: an empty text has no lines, and neither does
/// the position immediately after a trailing terminator (ripgrep's phantom
/// position, which it refuses to report a match at). `at == len` DOES answer
/// when the text's final line is unterminated, because that line is real and
/// runs flush to the end.
///
/// `at > len` is `.invalid` rather than clamped, on the same reasoning
/// `irgx_find_all_in` refuses an out-of-range bound: a miscomputed offset is a
/// bug worth hearing about, and silently answering about the last line would
/// hide it behind a plausible number.
///
/// `cap` is a window over the answer, not a limit on the walk: at most `cap`
/// rows are written and `*written` reports how many the band HAS, so `cap = 0`
/// with a null `out` sizes a buffer in one call and a short buffer sizes its own
/// retry. The band is bounded by `before + 1 + after`, so that retry is always
/// avoidable.
///
/// `center` is where the located line landed WITHIN the band, 0-based, and it is
/// the one field a caller cannot re-derive cheaply: after a clamp at the top of
/// the file the requested `before` was not delivered, so "the middle row is the
/// hit" is false and a host that assumed it would point at the wrong line. Null
/// is legal and means the caller does not care — unlike `written`, whose absence
/// is a caller bug because there is no other way to learn the total.
pub fn context(
    text: ?[*]const u8,
    len: usize,
    at: usize,
    before: usize,
    after: usize,
    out: ?[*]Line,
    cap: usize,
    written: ?*usize,
    center: ?*usize,
) Status {
    contract.beginCall();
    if (center) |c| c.* = 0;
    var sink = contract.Sink(Line).open(out, cap, written) orelse return .invalid;
    const bytes = contract.view(text, len) orelse return .invalid;
    if (at > len) return .invalid;

    const band = anatomy.band(bytes, anatomy.newline, at, before, after) orelse return sink.close();
    if (center) |c| c.* = band.center;
    // Walking the text TRUNCATED to the band's end is what makes the loop total:
    // it stops exactly at the last band line with no counter to keep and no
    // `orelse unreachable` that a wrong band could turn into a host-killing
    // panic. Offsets stay absolute because `pos` starts at the band's own start,
    // and the truncation cannot change a line's shape — the band always ends
    // either at a terminator or at the text's end.
    var walk = anatomy.Walk{ .bytes = bytes[0..band.end], .pos = band.start };
    var number = band.number;
    while (walk.next()) |line| : (number += 1) sink.push(rowOf(line, number));
    return sink.close();
}

/// Fill `out[0..cap]` with EVERY line of `text[0..len]` and write the true count
/// to `*written`. `.match` when the text holds a line, `.ok` when it is empty.
///
/// Not a spelling of `context` with a saturated `after`, though the answer would
/// coincide: this is the question a host asks when it has many offsets to
/// resolve rather than one. Doing that through `context` costs a prefix pass per
/// offset; doing it here costs one pass total, after which the grid is a binary
/// search the host owns. Same reason the offset-grid shape exists inside this
/// package next to the single-offset locator.
///
/// Pair it with `count` when only the total is wanted — but a `cap = 0` probe
/// here answers that too, at the same cost, so `count` is the convenience and
/// this is the primitive.
pub fn split(text: ?[*]const u8, len: usize, out: ?[*]Line, cap: usize, written: ?*usize) Status {
    contract.beginCall();
    var sink = contract.Sink(Line).open(out, cap, written) orelse return .invalid;
    const bytes = contract.view(text, len) orelse return .invalid;
    var walk = anatomy.Walk{ .bytes = bytes };
    var number: usize = 1;
    while (walk.next()) |line| : (number += 1) sink.push(rowOf(line, number));
    return sink.close();
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "the plane's arguments fail closed, and never on a legal probe" {
    const hay = "a\nb\n";
    var n: usize = 0;
    var total: u64 = 0;
    var rows: [4]Line = undefined;

    // A null pointer carrying a length is the caller's arithmetic bug — the one
    // shape that must not read back as an innocent empty text.
    try testing.expectEqual(Status.invalid, count(null, 7, &total));
    try testing.expectEqual(Status.invalid, split(null, 7, &rows, rows.len, &n));
    try testing.expectEqual(Status.invalid, context(null, 7, 0, 0, 0, &rows, rows.len, &n, null));

    // Missing out-slots.
    try testing.expectEqual(Status.invalid, count(hay.ptr, hay.len, null));
    try testing.expectEqual(Status.invalid, split(hay.ptr, hay.len, &rows, rows.len, null));
    // Room promised but not given.
    try testing.expectEqual(Status.invalid, split(hay.ptr, hay.len, null, 4, &n));

    // An offset past the text is refused rather than clamped to the last line.
    try testing.expectEqual(Status.invalid, context(hay.ptr, hay.len, hay.len + 1, 0, 0, &rows, rows.len, &n, null));

    // The legal probes: a null buffer with a zero cap, and an empty text.
    try testing.expectEqual(Status.match, split(hay.ptr, hay.len, null, 0, &n));
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(Status.ok, split(null, 0, null, 0, &n));
    try testing.expectEqual(@as(usize, 0), n);
    try testing.expectEqual(Status.ok, count(null, 0, &total));
    try testing.expectEqual(@as(u64, 0), total);
}

test "count keeps rg's rule at both endings" {
    var total: u64 = 0;
    // Hand-written expectations: a trailing terminator closes the last line and
    // opens no phantom one; an unterminated tail is still a line.
    const cases = [_]struct { []const u8, u64, Status }{
        .{ "", 0, .ok },
        .{ "\n", 1, .match },
        .{ "a", 1, .match },
        .{ "a\n", 1, .match },
        .{ "a\nb", 2, .match },
        .{ "a\nb\n", 2, .match },
        .{ "\n\n\n", 3, .match },
        .{ "a\r\nb\r\n", 2, .match },
    };
    for (cases) |c| {
        try testing.expectEqual(c[2], count(c[0].ptr, c[0].len, &total));
        try testing.expectEqual(c[1], total);
    }
}

test "split publishes the whole grid, and a short buffer sizes its own retry" {
    const hay = "alpha\nbeta\ngamma"; // an unterminated tail
    var n: usize = 0;
    var two: [2]Line = undefined;

    // Three lines found, two stored, and the host is told three — the contract
    // that makes a second call exact instead of a doubling loop.
    try testing.expectEqual(Status.match, split(hay.ptr, hay.len, &two, two.len, &n));
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(Line{ .number = 1, .start = 0, .content_end = 5, .term_end = 6 }, two[0]);
    try testing.expectEqual(Line{ .number = 2, .start = 6, .content_end = 10, .term_end = 11 }, two[1]);

    var all: [3]Line = undefined;
    try testing.expectEqual(Status.match, split(hay.ptr, hay.len, &all, all.len, &n));
    try testing.expectEqual(@as(usize, 3), n);
    // The unterminated tail: content and terminator end together, at the text's
    // end, and it is numbered like any other line.
    try testing.expectEqual(Line{ .number = 3, .start = 11, .content_end = 16, .term_end = 16 }, all[2]);
    // Every row's bytes are addressable straight out of the host's own buffer.
    try testing.expectEqualStrings("gamma", hay[all[2].start..all[2].content_end]);
}

test "context clamps at both ends and says where the hit actually landed" {
    const hay = "1\n2\n3\n4\n5\n";
    var n: usize = 0;
    var center: usize = 999;
    var rows: [8]Line = undefined;

    // Interior: the full window, the hit in the middle.
    try testing.expectEqual(Status.match, context(hay.ptr, hay.len, 4, 1, 1, &rows, rows.len, &n, &center));
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(usize, 1), center);
    try testing.expectEqual(@as(u64, 2), rows[0].number);
    try testing.expectEqual(@as(u64, 4), rows[2].number);

    // Clamped at the top: two rows, and `center` moved to 0 — the field a host
    // cannot re-derive without redoing the clamp.
    try testing.expectEqual(Status.match, context(hay.ptr, hay.len, 0, 3, 1, &rows, rows.len, &n, &center));
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(usize, 0), center);
    try testing.expectEqual(@as(u64, 1), rows[0].number); // clamped, never renumbered

    // Clamped at the bottom: the trailing terminator grows no phantom sixth row.
    try testing.expectEqual(Status.match, context(hay.ptr, hay.len, 8, 1, 4, &rows, rows.len, &n, &center));
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(usize, 1), center);
    try testing.expectEqual(@as(u64, 5), rows[1].number);

    // Wider than the file in BOTH directions: the whole file, once.
    try testing.expectEqual(Status.match, context(hay.ptr, hay.len, 4, 99, 99, &rows, rows.len, &n, &center));
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqual(@as(usize, 2), center);

    // A zero-width window is the located line alone, and `center` is 0.
    try testing.expectEqual(Status.match, context(hay.ptr, hay.len, 4, 0, 0, &rows, rows.len, &n, &center));
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(usize, 0), center);
    try testing.expectEqual(@as(u64, 3), rows[0].number);

    // A null `center` is a legal "don't care", not a caller bug.
    try testing.expectEqual(Status.match, context(hay.ptr, hay.len, 4, 0, 0, &rows, rows.len, &n, null));
}

test "context: the phantom position and the empty text are results, not faults" {
    var n: usize = 999;
    var center: usize = 999;
    var rows: [4]Line = undefined;

    // A text ending in a terminator has nothing at `len`: the terminator already
    // closed the last line. Zero rows, `.ok`, and no fault installed.
    const closed = "abc\n";
    try testing.expectEqual(Status.ok, context(closed.ptr, closed.len, closed.len, 2, 2, &rows, rows.len, &n, &center));
    try testing.expectEqual(@as(usize, 0), n);
    try testing.expectEqual(@as(usize, 0), center);

    // An UNTERMINATED tail does answer at `len` — that line is real.
    const open = "abc";
    try testing.expectEqual(Status.match, context(open.ptr, open.len, open.len, 0, 0, &rows, rows.len, &n, &center));
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(Line{ .number = 1, .start = 0, .content_end = 3, .term_end = 3 }, rows[0]);

    // An empty text holds no lines, so offset zero is on none of them.
    try testing.expectEqual(Status.ok, context(null, 0, 0, 4, 4, &rows, rows.len, &n, &center));
    try testing.expectEqual(@as(usize, 0), n);

    // A declinature is never this plane's answer: there is no lower tier to fall
    // back to, so nothing here may return `.stale`.
    var tally: u64 = 0;
    for ([_]Status{
        count(closed.ptr, closed.len, &tally),
        split(closed.ptr, closed.len, &rows, rows.len, &n),
        context(closed.ptr, closed.len, 0, 1, 1, &rows, rows.len, &n, &center),
    }) |st| try testing.expect(st != .stale);
}

test "an offset ON a terminator belongs to the line that terminator ends" {
    const hay = "abc\ndef\n";
    var n: usize = 0;
    var rows: [1]Line = undefined;
    // Byte 3 is line 1's `\n`. Reporting it as line 2 is the classic off-by-one
    // that puts a caret on the wrong row for every match ending at end-of-line.
    try testing.expectEqual(Status.match, context(hay.ptr, hay.len, 3, 0, 0, &rows, rows.len, &n, null));
    try testing.expectEqual(@as(u64, 1), rows[0].number);
    try testing.expectEqual(Status.match, context(hay.ptr, hay.len, 4, 0, 0, &rows, rows.len, &n, null));
    try testing.expectEqual(@as(u64, 2), rows[0].number);
}

test "CRLF: content keeps the carriage return the matcher sees" {
    const hay = "alpha\r\nbeta\r\n";
    var n: usize = 0;
    var rows: [2]Line = undefined;
    try testing.expectEqual(Status.match, split(hay.ptr, hay.len, &rows, rows.len, &n));
    try testing.expectEqual(@as(usize, 2), n);
    // Six content bytes, not five: rg's default keeps the `\r`, and a plane that
    // silently dropped it would move every `$` anchor on a Windows file.
    try testing.expectEqualStrings("alpha\r", hay[rows[0].start..rows[0].content_end]);
    try testing.expectEqual(@as(u64, 7), rows[0].term_end);
    try testing.expectEqualStrings("beta\r", hay[rows[1].start..rows[1].content_end]);
}

test "context and split agree with each other on every offset of every ending" {
    const texts = [_][]const u8{ "", "\n", "\n\n\n", "a", "a\n", "abc\ndef", "abc\ndef\n", "a\r\nb", "\nlead" };
    var rows: [8]Line = undefined;
    var grid: [8]Line = undefined;
    var n: usize = 0;
    var total: usize = 0;
    var center: usize = 0;

    for (texts) |hay| {
        const ptr: ?[*]const u8 = if (hay.len == 0) null else hay.ptr;
        _ = split(ptr, hay.len, &grid, grid.len, &total);
        // The two row verbs are separate walks; the grid is also checked against
        // the primitive's own oracle-backed suite, so agreement here is a real
        // cross-check rather than a tautology.
        var tally: u64 = 0;
        _ = count(ptr, hay.len, &tally);
        try testing.expectEqual(total, @as(usize, @intCast(tally)));

        for (0..hay.len + 1) |at| {
            const st = context(ptr, hay.len, at, 0, 0, &rows, rows.len, &n, &center);
            if (st == .ok) {
                try testing.expectEqual(@as(usize, 0), n);
                continue;
            }
            try testing.expectEqual(@as(usize, 1), n);
            const row = rows[0];
            // The band's single row must be exactly the grid row whose half-open
            // range holds `at` — or, at the text's end, the unterminated tail.
            try testing.expectEqual(grid[@intCast(row.number - 1)], row);
            try testing.expect(at >= row.start);
            try testing.expect(at < row.term_end or (at == row.term_end and row.term_end == row.content_end));
        }
        // A whole-file band from the first line reproduces the grid exactly.
        if (total > 0) {
            try testing.expectEqual(Status.match, context(ptr, hay.len, 0, 0, total + 3, &rows, rows.len, &n, &center));
            try testing.expectEqual(total, n);
            try testing.expectEqualSlices(Line, grid[0..total], rows[0..n]);
        }
    }
}
