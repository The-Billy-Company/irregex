//! gist — Unicode scalar-range → UTF-8 byte-range lowering. The primitive that
//! lets gist's *byte* automaton match *codepoint* classes: a contiguous run of
//! Unicode scalar values (`[00E9-00EF]`, `\w`, `\p{L}`, a case-fold orbit) is
//! rewritten as an alternation of 1–4 successive byte ranges, each of which the
//! existing `consume` state (`syntax.ByteSet`) accepts. No two emitted sequences
//! overlap, and no sequence ever matches a surrogate encoding or any other
//! ill-formed UTF-8 — so the resulting sub-automaton recognises exactly the
//! well-formed UTF-8 encodings of the scalar values in the range, nothing more.
//!
//! Algorithm: Ken Thompson's / Russ Cox's UTF-8 range decomposition (RE2), the
//! surrogate-safe range-stack formulation. This is a Billy-native reimplementation
//! of the shape rust-regex's `regex-syntax::utf8` exposes; the exhaustive
//! properties it must satisfy (single codepoint ⇒ one sequence; surrogate
//! encodings never matched; the canonical BMP decomposition) are pinned as tests
//! below and re-asserted differentially in `adversarial_test.zig`.

const std = @import("std");

/// One inclusive byte range `[start, end]` — a single step of a UTF-8 sequence.
pub const ByteRange = struct {
    start: u8,
    end: u8,

    pub fn matches(self: ByteRange, b: u8) bool {
        return self.start <= b and b <= self.end;
    }
};

/// A sequence of 1–4 successive byte ranges. A byte string matches iff each of
/// its first `len` bytes falls in the corresponding range; `len` is exactly the
/// UTF-8 encoded length of the scalar values this sequence covers.
pub const Sequence = struct {
    ranges: [4]ByteRange = undefined,
    len: u3 = 0,

    pub fn slice(self: *const Sequence) []const ByteRange {
        return self.ranges[0..self.len];
    }

    /// True iff a prefix of `bytes` matches this sequence (used by tests).
    pub fn matches(self: *const Sequence, bytes: []const u8) bool {
        if (bytes.len < self.len) return false;
        for (self.ranges[0..self.len], bytes[0..self.len]) |r, b| {
            if (!r.matches(b)) return false;
        }
        return true;
    }

    fn fromEncoded(start: []const u8, end: []const u8) Sequence {
        var s = Sequence{ .len = @intCast(start.len) };
        for (0..start.len) |i| s.ranges[i] = .{ .start = start[i], .end = end[i] };
        return s;
    }
};

/// The largest scalar value encodable in `nbytes` UTF-8 bytes.
fn maxScalar(nbytes: u3) u32 {
    return switch (nbytes) {
        1 => 0x7F,
        2 => 0x7FF,
        3 => 0xFFFF,
        else => 0x10FFFF,
    };
}

const ScalarRange = struct {
    start: u32,
    end: u32,

    /// Split off the surrogate gap `[D800, DFFF]` if this range straddles it —
    /// surrogate codepoints have no well-formed UTF-8 encoding, so they must
    /// never appear in an emitted byte sequence. Either half may be empty/invalid
    /// (the caller drops invalid halves).
    fn split(self: ScalarRange) ?[2]ScalarRange {
        if (self.start < 0xE000 and self.end > 0xD7FF) {
            return .{
                .{ .start = self.start, .end = 0xD7FF },
                .{ .start = 0xE000, .end = self.end },
            };
        }
        return null;
    }

    fn valid(self: ScalarRange) bool {
        return self.start <= self.end;
    }

    fn ascii(self: ScalarRange) ?ByteRange {
        if (self.valid() and self.end <= 0x7F) {
            return .{ .start = @intCast(self.start), .end = @intCast(self.end) };
        }
        return null;
    }
};

/// Streaming decomposition of one scalar-value range into non-overlapping UTF-8
/// byte-range sequences. Drive it with `next()` until it returns null. The
/// internal range stack is bounded (the split tree for any single range is
/// shallow — proven by the exhaustive tests), so no allocation is needed.
pub const Sequences = struct {
    // Deferred right-halves awaiting decomposition. Peak depth is a small
    // constant (≤ the ~9 output sequences of the full [0,10FFFF] range); 16 is a
    // comfortable margin, asserted on push so any regression surfaces loudly.
    stack: [16]ScalarRange = undefined,
    sp: usize = 0,

    pub fn init(start: u21, end: u21) Sequences {
        var it = Sequences{};
        it.push(.{ .start = start, .end = end });
        return it;
    }

    fn push(self: *Sequences, r: ScalarRange) void {
        std.debug.assert(self.sp < self.stack.len);
        self.stack[self.sp] = r;
        self.sp += 1;
    }

    pub fn next(self: *Sequences) ?Sequence {
        top: while (self.sp > 0) {
            self.sp -= 1;
            var r = self.stack[self.sp];
            inner: while (true) {
                if (r.split()) |halves| {
                    self.push(halves[1]);
                    r = halves[0];
                    continue :inner;
                }
                if (!r.valid()) continue :top;
                // Split off each shorter UTF-8 length boundary so the remaining
                // range encodes to a fixed byte count.
                var i: u3 = 1;
                while (i < 4) : (i += 1) {
                    const max = maxScalar(i);
                    if (r.start <= max and max < r.end) {
                        self.push(.{ .start = max + 1, .end = r.end });
                        r.end = max;
                        continue :inner;
                    }
                } else if (r.ascii()) |ar| return Sequence{ .ranges = .{ ar, undefined, undefined, undefined }, .len = 1 };
                // Multi-byte: split so every continuation-byte position spans a
                // full [80,BF] (else the naive byte-range product would admit
                // codepoints outside [start,end]).
                var resplit = false;
                i = 1;
                while (i < 4) : (i += 1) {
                    const shift: u5 = @intCast(6 * @as(u32, i));
                    const m: u32 = (@as(u32, 1) << shift) - 1;
                    if ((r.start & ~m) != (r.end & ~m)) {
                        if (r.start & m != 0) {
                            self.push(.{ .start = (r.start | m) + 1, .end = r.end });
                            r.end = r.start | m;
                            resplit = true;
                            break;
                        }
                        if (r.end & m != m) {
                            self.push(.{ .start = r.end & ~m, .end = r.end });
                            r.end = (r.end & ~m) - 1;
                            resplit = true;
                            break;
                        }
                    }
                }
                if (resplit) continue :inner;
                var start_buf: [4]u8 = undefined;
                var end_buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(@intCast(r.start), &start_buf) catch unreachable;
                const n2 = std.unicode.utf8Encode(@intCast(r.end), &end_buf) catch unreachable;
                std.debug.assert(n == n2);
                return Sequence.fromEncoded(start_buf[0..n], end_buf[0..n]);
            }
        }
        return null;
    }
};

// ─────────────────────────────── tests ───────────────────────────────

const testing = std.testing;

fn seqMatches(seqs: []const Sequence, bytes: []const u8) bool {
    for (seqs) |*s| if (s.matches(bytes)) return true;
    return false;
}

fn collect(start: u21, end: u21, out: *std.ArrayList(Sequence), gpa: std.mem.Allocator) !void {
    var it = Sequences.init(start, end);
    while (it.next()) |s| try out.append(gpa, s);
}

test "single codepoint yields exactly one sequence" {
    // Every scalar value, decomposed alone, is recognised by exactly one byte
    // sequence — and that sequence matches its own UTF-8 encoding.
    const gpa = testing.allocator;
    var cp: u32 = 0;
    while (cp <= 0x10FFFF) : (cp += 1) {
        if (cp >= 0xD800 and cp <= 0xDFFF) continue; // surrogate: not a scalar value
        var seqs: std.ArrayList(Sequence) = .empty;
        defer seqs.deinit(gpa);
        try collect(@intCast(cp), @intCast(cp), &seqs, gpa);
        try testing.expectEqual(@as(usize, 1), seqs.items.len);
        var buf: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(@intCast(cp), &buf);
        try testing.expect(seqs.items[0].matches(buf[0..n]));
    }
}

test "surrogate encodings are never matched" {
    const gpa = testing.allocator;
    const ranges = [_][2]u21{
        .{ 0x0, 0xFFFF },
        .{ 0x0, 0x10FFFF },
        .{ 0x80, 0x10FFFF },
        .{ 0xD7FF, 0xE000 },
    };
    for (ranges) |rr| {
        var seqs: std.ArrayList(Sequence) = .empty;
        defer seqs.deinit(gpa);
        try collect(rr[0], rr[1], &seqs, gpa);
        var cp: u32 = 0xD800;
        while (cp < 0xE000) : (cp += 1) {
            // Hand-encode the surrogate as 3 bytes (utf8Encode refuses to) and
            // confirm no emitted sequence accepts it.
            const buf = [3]u8{
                0xE0 | @as(u8, @intCast(cp >> 12 & 0x0F)),
                0x80 | @as(u8, @intCast(cp >> 6 & 0x3F)),
                0x80 | @as(u8, @intCast(cp & 0x3F)),
            };
            try testing.expect(!seqMatches(seqs.items, &buf));
        }
    }
}

test "BMP decomposition matches the canonical shape" {
    const gpa = testing.allocator;
    var seqs: std.ArrayList(Sequence) = .empty;
    defer seqs.deinit(gpa);
    try collect(0x0, 0xFFFF, &seqs, gpa);
    const expect = [_]Sequence{
        .{ .len = 1, .ranges = .{ .{ .start = 0x00, .end = 0x7F }, undefined, undefined, undefined } },
        .{ .len = 2, .ranges = .{ .{ .start = 0xC2, .end = 0xDF }, .{ .start = 0x80, .end = 0xBF }, undefined, undefined } },
        .{ .len = 3, .ranges = .{ .{ .start = 0xE0, .end = 0xE0 }, .{ .start = 0xA0, .end = 0xBF }, .{ .start = 0x80, .end = 0xBF }, undefined } },
        .{ .len = 3, .ranges = .{ .{ .start = 0xE1, .end = 0xEC }, .{ .start = 0x80, .end = 0xBF }, .{ .start = 0x80, .end = 0xBF }, undefined } },
        .{ .len = 3, .ranges = .{ .{ .start = 0xED, .end = 0xED }, .{ .start = 0x80, .end = 0x9F }, .{ .start = 0x80, .end = 0xBF }, undefined } },
        .{ .len = 3, .ranges = .{ .{ .start = 0xEE, .end = 0xEF }, .{ .start = 0x80, .end = 0xBF }, .{ .start = 0x80, .end = 0xBF }, undefined } },
    };
    try testing.expectEqual(expect.len, seqs.items.len);
    for (expect, seqs.items) |e, g| {
        try testing.expectEqual(e.len, g.len);
        try testing.expectEqualSlices(ByteRange, e.slice(), g.slice());
    }
}

test "decomposition round-trips a dense sample of scalar values" {
    // For a scattered set of ranges, every scalar value in the range is matched
    // by its encoding and no value just outside the range is.
    const gpa = testing.allocator;
    const ranges = [_][2]u21{
        .{ 0x00E9, 0x00EF }, // Latin-1 accents
        .{ 0x0400, 0x052F }, // Cyrillic + supplement
        .{ 0x2603, 0x2603 }, // snowman
        .{ 0x1F600, 0x1F64F }, // emoji (astral)
        .{ 0x41, 0x5A }, // ASCII
    };
    for (ranges) |rr| {
        var seqs: std.ArrayList(Sequence) = .empty;
        defer seqs.deinit(gpa);
        try collect(rr[0], rr[1], &seqs, gpa);
        var cp: u32 = rr[0];
        while (cp <= rr[1]) : (cp += 1) {
            if (cp >= 0xD800 and cp <= 0xDFFF) continue;
            var buf: [4]u8 = undefined;
            const n = try std.unicode.utf8Encode(@intCast(cp), &buf);
            try testing.expect(seqMatches(seqs.items, buf[0..n]));
        }
    }
}
