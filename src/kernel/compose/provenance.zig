//! irregex compose — `provenance`: quotation attribution, gist-verified.
//!
//! The composed answer to "where did this pasted snippet come from, and is the
//! source still that way?" `relate quote` rewrites the text as maximal verbatim
//! phrases from the codex and attributes each to one exemplar file — but the
//! shelf is a build-time snapshot, so a phrase's byte offset is only as fresh
//! as the last `gist codex build`. This kernel closes the loop: it takes a
//! quoted phrase plus the exemplar file's CURRENT bytes and re-finds the phrase
//! exactly (the MATCH primitive — a literal substring scan, not the shelf's
//! stale row), returning the live offset, line, and a context window.
//!
//! The invariant that makes it honest (ADR-367): a phrase the current bytes
//! cannot verify is NOT located — `verify` returns null, and the driver reports
//! drift instead of a stale line number. Provenance never points at a line that
//! no longer holds the quote.
//!
//! Pure kernel: no I/O, no argv; the driver loads the shelf, parses the query
//! (`cento`), reads each exemplar's live bytes, and renders. `context_lines` of
//! 0 pins the window to the phrase's own line(s).

const std = @import("std");
const simd = @import("../scan/simd.zig");

/// A phrase re-found in the current bytes of its exemplar file: the live byte
/// offset, the 1-based line the phrase starts on, and the byte window
/// `[ctx_start, ctx_end)` covering `context_lines` around it (line-aligned).
pub const Located = struct {
    offset: usize,
    line: usize,
    ctx_start: usize,
    ctx_end: usize,

    /// The context window bytes, sliced from the same `bytes` passed to `verify`.
    pub fn context(self: Located, bytes: []const u8) []const u8 {
        return bytes[self.ctx_start..self.ctx_end];
    }
};

/// Re-find `phrase` in `bytes` (the exemplar file's CURRENT content) and locate
/// it. Returns null when the phrase is absent — the file drifted since the
/// shelf was built, so there is no honest line to report. An empty phrase never
/// verifies (it names no location). The first occurrence is authoritative:
/// quote attributes one exemplar, and any occurrence proves the quote still
/// lives in this file.
pub fn verify(bytes: []const u8, phrase: []const u8, context_lines: usize) ?Located {
    if (phrase.len == 0 or phrase.len > bytes.len) return null;
    if (!simd.contains(bytes, phrase)) return null;
    const offset = std.mem.indexOf(u8, bytes, phrase).?;

    return .{
        .offset = offset,
        .line = 1 + std.mem.count(u8, bytes[0..offset], "\n"),
        .ctx_start = windowStart(bytes, offset, context_lines),
        .ctx_end = windowEnd(bytes, offset + phrase.len, context_lines),
    };
}

/// Byte offset of the line start `back` lines before `at` (0 = `at`'s own line).
fn windowStart(bytes: []const u8, at: usize, back: usize) usize {
    var start = lineStart(bytes, at);
    var n: usize = 0;
    while (n < back and start > 0) : (n += 1) start = lineStart(bytes, start - 1);
    return start;
}

/// Byte offset of the line end `fwd` lines after the line holding `at` (the
/// offset of the terminating newline, or `bytes.len` at EOF). `end + 1 <
/// bytes.len` stops on the last content line: a file's trailing newline is not
/// a further line to include, so the window never grows a spurious empty tail.
fn windowEnd(bytes: []const u8, at: usize, fwd: usize) usize {
    var end = lineEnd(bytes, at);
    var n: usize = 0;
    while (n < fwd and end + 1 < bytes.len) : (n += 1) end = lineEnd(bytes, end + 1);
    return end;
}

fn lineStart(bytes: []const u8, at: usize) usize {
    if (std.mem.lastIndexOfScalar(u8, bytes[0..at], '\n')) |nl| return nl + 1;
    return 0;
}

fn lineEnd(bytes: []const u8, at: usize) usize {
    const from = @min(at, bytes.len);
    return std.mem.indexOfScalarPos(u8, bytes, from, '\n') orelse bytes.len;
}

// ── tests ──────────────────────────────────────────────────────────────────

const t = std.testing;

test "verify: locates a phrase and pins its line and own-line window" {
    const bytes = "line one\nline two has the QUOTE here\nline three\n";
    const v = verify(bytes, "the QUOTE here", 0).?;
    try t.expectEqual(@as(usize, 2), v.line);
    try t.expectEqualStrings("line two has the QUOTE here", v.context(bytes));
}

test "verify: context_lines widens the window symmetrically, clamped at edges" {
    const bytes = "a\nb\nc QUOTE d\ne\nf\n";
    const v = verify(bytes, "QUOTE", 1).?;
    try t.expectEqual(@as(usize, 3), v.line);
    try t.expectEqualStrings("b\nc QUOTE d\ne", v.context(bytes));

    // A window larger than the file clamps to the whole file (no newline tail).
    const wide = verify(bytes, "QUOTE", 100).?;
    try t.expectEqualStrings("a\nb\nc QUOTE d\ne\nf", wide.context(bytes));
}

test "verify: a phrase the current bytes cannot confirm is never located (drift)" {
    const bytes = "the source has since been rewritten entirely\n";
    try t.expectEqual(@as(?Located, null), verify(bytes, "a phrase that used to be here", 0));
    try t.expectEqual(@as(?Located, null), verify(bytes, "", 2)); // empty names nothing
}
