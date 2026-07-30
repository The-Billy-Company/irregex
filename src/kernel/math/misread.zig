//! How a persisted configuration file reports being misread.
//!
//! The charter (`charter.zig`) and the preferences file
//! (`exec/cold/argv/preference.zig`) are different formats for
//! different readers, but someone mistyping one has exactly the same two
//! questions as someone mistyping the other: **where is it**, and **what did I
//! mean**. Both answers live here, once, because two copies of "did you mean"
//! would drift into two different notions of near — and because the shy
//! behavior below is the whole reason a suggestion can be trusted at all.
//!
//! ripgrep answers neither question. A bad flag in a `.ripgreprc` is passed
//! through to the search, which then behaves oddly with no message at all.

const std = @import("std");

/// Where in a persisted configuration file a fault occurred, and the token that
/// caused it. Zig errors carry no payload, so the reader hands the parser one
/// of these — the std idiom — rather than the parser reaching for module state
/// that two layers would then have to keep consistent.
pub const Diagnostic = struct {
    /// 1-based. Zero means "no particular line" (a whole-file fault such as
    /// `Oversized`), and the renderer prints nothing rather than `:0`.
    line: usize = 0,
    /// The offending token — the thing to quote back and the thing to find a
    /// near-neighbor for. Borrowed from the source bytes until `keepToken`
    /// copies it out of them.
    token: []const u8 = "",
};

/// `":12"` when there is a line to point at, else `""` — so a whole-file fault
/// does not print a `:0` the reader would go hunting for.
pub fn at(buf: []u8, d: Diagnostic) []const u8 {
    if (d.line == 0) return "";
    return std.fmt.bufPrint(buf, ":{d}", .{d.line}) catch "";
}

/// Copy a diagnostic's token out of the source buffer it borrows.
///
/// A parser hands back a slice of the file's bytes, and those bytes are freed
/// the moment the read returns — but the diagnostic outlives the read by
/// design: `gist config check` prints it, and `nearest` is computed from it.
pub fn keepToken(buf: []u8, tok: []const u8) []const u8 {
    const n = @min(tok.len, buf.len);
    @memcpy(buf[0..n], tok[0..n]);
    return buf[0..n];
}

/// The legal name closest to `typo`, or null when nothing is close enough — or
/// when two candidates are equally close, which is a coin flip rather than
/// help. A wrong guess is worse than none: it sends the reader to edit a line
/// that was never the problem, so this stays deliberately shy.
///
/// The budget scales with length, so short names are not "corrected" into each
/// other while a longer one tolerates the second slip that actually happens.
pub fn nearest(typo: []const u8, candidates: []const []const u8) ?[]const u8 {
    const budget = @max(1, typo.len / 4);
    var best: ?[]const u8 = null;
    var best_d: usize = budget + 1;
    var tied = false;
    for (candidates) |c| {
        const d = within(typo, c, budget) orelse continue;
        if (d < best_d) {
            best_d = d;
            best = c;
            tied = false;
        } else if (d == best_d) tied = true;
    }
    return if (tied) null else best;
}

/// Damerau–Levenshtein (optimal string alignment) distance, abandoned as soon
/// as it provably exceeds `cap`.
///
/// Plain Levenshtein charges 2 for a transposition, which is the single most
/// common typing error there is — `--headnig` for `--heading` would score 2 and
/// fall outside a budget that must stay tight enough to reject real
/// non-matches. Counting an adjacent swap as one edit is what lets the budget
/// be shy and the suggestion still fire.
///
/// Three rolling rows over fixed buffers: a configuration key nobody could type
/// is not a key worth suggesting, so names past the buffer simply never match.
fn within(a: []const u8, b: []const u8, cap: usize) ?usize {
    if (a.len -| b.len > cap or b.len -| a.len > cap) return null;
    if (b.len + 1 > 64) return null;
    var two: [64]usize = undefined; // i-2
    var prev: [64]usize = undefined; // i-1
    var cur: [64]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ca, i| {
        cur[0] = i + 1;
        var row_best = cur[0];
        for (b, 0..) |cb, j| {
            var d = @min(
                @min(prev[j + 1] + 1, cur[j] + 1),
                prev[j] + @intFromBool(ca != cb),
            );
            if (i > 0 and j > 0 and ca == b[j - 1] and a[i - 1] == cb) {
                d = @min(d, two[j - 1] + 1);
            }
            cur[j + 1] = d;
            row_best = @min(row_best, d);
        }
        if (row_best > cap) return null; // no completion of this row can recover
        @memcpy(two[0 .. b.len + 1], prev[0 .. b.len + 1]);
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return if (prev[b.len] <= cap) prev[b.len] else null;
}

const t = std.testing;

test "two candidates equally near yields no suggestion" {
    try t.expectEqual(@as(?[]const u8, null), nearest("skop", &.{ "skip", "stop" }));
    try t.expectEqual(@as(?[]const u8, null), nearest("bat", &.{ "cat", "bad" }));
}

test "a location renders only when there is one" {
    var buf: [24]u8 = undefined;
    try t.expectEqualStrings("", at(&buf, .{}));
    try t.expectEqualStrings(":7", at(&buf, .{ .line = 7 }));
    try t.expectEqualStrings(":1204", at(&buf, .{ .line = 1204 }));
}

test "a kept token survives the buffer it was sliced from" {
    var src = [_]u8{ 'r', 'o', 'o', 't', 'z' };
    var keep: [8]u8 = undefined;
    const held = keepToken(&keep, &src);
    @memset(&src, 0); // the file's bytes go away; the diagnostic must not
    try t.expectEqualStrings("rootz", held);

    // A token longer than the buffer is truncated, never overruns it.
    var small: [3]u8 = undefined;
    try t.expectEqualStrings("abc", keepToken(&small, "abcdefgh"));
}
