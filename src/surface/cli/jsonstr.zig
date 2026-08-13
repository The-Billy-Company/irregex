//! One JSON string escaper for every face over this library that writes JSON/NDJSON.
//!
//! `rg --json` (emit/json.zig), the kinship and composed faces' NDJSON verb rows
//! (surface/cli/emit.zig, re-exported as `jsonStr`), and the `--schema`
//! manifest all need the identical operation: append a byte slice as a JSON
//! string literal, surrounding quotes included. They used to carry three
//! near-copies that had quietly diverged — the schema one emitted RAW control
//! bytes (invalid JSON), the kinship one lacked the `\b`/`\f` short forms — so
//! this is the single source of truth they now share.
//!
//! The escaping is serde_json's / ripgrep's exact discipline (the strictest
//! master, `rg --json` byte-parity): `"` and `\` backslash-escaped; the five C0
//! short forms `\b \t \n \f \r`; every other control (`< 0x20`) as `\u00XX`;
//! valid multi-byte UTF-8 passes through raw (callers that may hold invalid
//! UTF-8 gate to base64 upstream — see emit/json.jsonData). OOM is fatal, the
//! CLI output contract.

const std = @import("std");
const oom = @import("outcome.zig").oom;

const vlen: usize = std.simd.suggestVectorLength(u8) orelse 16;
const Vec = @Vector(vlen, u8);
const Mask = std.meta.Int(.unsigned, vlen);

/// Index of the first byte at/after `from` that JSON must escape — `"`, `\`, or
/// any control (`< 0x20`) — else `s.len`. The overwhelming majority of a source
/// line is none of these, so a vectorized run-scan lets `write` bulk-copy whole
/// spans between escapes instead of touching the ArrayList once per byte.
inline fn nextEscape(s: []const u8, from: usize) usize {
    const quote: Vec = @splat('"');
    const bslash: Vec = @splat('\\');
    const ctl: Vec = @splat(0x20);
    var i = from;
    while (i + vlen <= s.len) : (i += vlen) {
        const blk: Vec = s[i..][0..vlen].*;
        const hit: Mask = @bitCast((blk == quote) | (blk == bslash) | (blk < ctl));
        if (hit != 0) return i + @ctz(hit);
    }
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '"' or c == '\\' or c < 0x20) return i;
    }
    return s.len;
}

/// Emit the escape sequence for one byte `nextEscape` flagged (≤6 bytes; the
/// caller has reserved that headroom, so every write is AssumeCapacity).
inline fn escape(out: *std.ArrayList(u8), c: u8) void {
    switch (c) {
        '"' => out.appendSliceAssumeCapacity("\\\""),
        '\\' => out.appendSliceAssumeCapacity("\\\\"),
        0x08 => out.appendSliceAssumeCapacity("\\b"),
        '\t' => out.appendSliceAssumeCapacity("\\t"),
        '\n' => out.appendSliceAssumeCapacity("\\n"),
        0x0C => out.appendSliceAssumeCapacity("\\f"),
        '\r' => out.appendSliceAssumeCapacity("\\r"),
        else => { // remaining C0 control → \u00XX (c < 0x20, top two nibbles zero)
            const hex = "0123456789abcdef";
            out.appendSliceAssumeCapacity("\\u00");
            out.appendAssumeCapacity(hex[c >> 4]);
            out.appendAssumeCapacity(hex[c & 0xf]);
        },
    }
}

/// Append `s` to `out` as a JSON string literal, surrounding quotes included.
/// Argument order matches the kinship face's `(buf, gpa, s)` convention so
/// `kinship.jsonStr` re-exports this directly.
pub fn write(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) void {
    // Reserve the no-escape size (bytes + both quotes) up front. The bulk copy of
    // each escape-free run self-ensures (one comparison the reserve almost always
    // satisfies, then a single memcpy) instead of appending byte-by-byte; the rare
    // escape tops up its own ≤6-byte headroom and writes through AssumeCapacity.
    out.ensureUnusedCapacity(gpa, s.len + 2) catch oom();
    out.appendAssumeCapacity('"');
    var i: usize = 0;
    while (i < s.len) {
        const j = nextEscape(s, i);
        out.appendSlice(gpa, s[i..j]) catch oom();
        if (j == s.len) break;
        out.ensureUnusedCapacity(gpa, 6) catch oom();
        escape(out, s[j]);
        i = j + 1;
    }
    out.append(gpa, '"') catch oom();
}

const t = std.testing;

/// The definition `nextEscape` is an optimization OF: one byte at a time, no
/// vectors, straight off the contract in this file's header. Restating it here
/// rather than importing it is the point — a differential against the block
/// loop's own tail would prove only that the tail equals itself.
fn firstEscapeByByte(s: []const u8, from: usize) usize {
    var i = from;
    while (i < s.len) : (i += 1) {
        if (s[i] == '"' or s[i] == '\\' or s[i] < 0x20) return i;
    }
    return s.len;
}

test "nextEscape: the vector block loop agrees with the definition across every seam" {
    // The two escape-discipline tests below run on 11- and 4-byte strings, and
    // `vlen` is at least 16 on every target this builds for — so before this
    // test the `while (i + vlen <= s.len)` block loop never executed once, on
    // any machine, and `nextEscape` was covered only by its scalar tail. The
    // width is also target-chosen (`suggestVectorLength`), so the seam between
    // block and tail sits at a different offset per build and cannot be probed
    // with a fixed-length fixture.
    //
    // Sweeping length × plant-offset × start covers all of it by construction:
    // an escape in the first block, in a later block, in the tail, at the last
    // byte before the seam and the first byte after it, and a `from` that
    // begins mid-block — which is how `write` re-enters after each escape, and
    // therefore the case a naive "scan from 0" test would miss.
    const escapes = [_]u8{ '"', '\\', 0x00, 0x1f, 0x0a, 0x20, 0x7f, 0xc3 };
    var buf: [4 * vlen + 4]u8 = undefined;
    var checked: usize = 0;
    var blocks_entered: usize = 0;

    for (escapes) |e| {
        var len: usize = 0;
        while (len <= buf.len) : (len += 1) {
            var at: usize = 0;
            while (at < @max(len, 1)) : (at += 1) {
                @memset(buf[0..len], 'x');
                if (at < len) buf[at] = e;
                const s = buf[0..len];
                var from: usize = 0;
                while (from <= len) : (from += 1) {
                    try t.expectEqual(firstEscapeByByte(s, from), nextEscape(s, from));
                    if (from + vlen <= len) blocks_entered += 1;
                    checked += 1;
                }
            }
        }
    }
    try t.expect(checked > 100_000);
    // Without this the sweep could pass having only ever run the tail — the
    // exact condition that left this function uncovered in the first place.
    try t.expect(blocks_entered > 10_000);
}

test "nextEscape: agrees with the definition over every byte value, at every start" {
    // The sweep above plants one escape in a field of 'x'. This one lets every
    // byte be anything, so blocks contain several escapes at once and the
    // `@ctz` must pick the FIRST — a mask built with the wrong lane order or a
    // `Mask` narrower than `vlen` returns a later hit and still looks plausible.
    var prng = std.Random.DefaultPrng.init(0x1350_1234);
    const r = prng.random();
    var buf: [3 * vlen + 5]u8 = undefined;
    for (0..4000) |_| {
        const len = r.uintLessThan(usize, buf.len + 1);
        for (buf[0..len]) |*c| c.* = switch (r.uintLessThan(u8, 4)) {
            0 => r.int(u8), // the whole byte range, controls and high bytes alike
            1 => '"',
            2 => '\\',
            else => 'a' + r.uintLessThan(u8, 26),
        };
        const s = buf[0..len];
        var from: usize = 0;
        while (from <= len) : (from += 1)
            try t.expectEqual(firstEscapeByByte(s, from), nextEscape(s, from));
    }
}

test "write: the run-scanning writer equals a byte-at-a-time escaper" {
    // `nextEscape` above is checked in isolation; this checks the loop built on
    // it — the bulk-copy spans, the ≤6-byte headroom top-up, and the `j ==
    // s.len` break — against an escaper that reserves nothing and appends one
    // byte's worth at a time. Inputs are long enough to cross several vector
    // blocks, which the two fixture tests below are not.
    var prng = std.Random.DefaultPrng.init(0xE5CA_9E00);
    const r = prng.random();
    var src: [5 * vlen]u8 = undefined;
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(t.allocator);
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(t.allocator);

    for (0..3000) |_| {
        const len = r.uintLessThan(usize, src.len + 1);
        for (src[0..len]) |*c| c.* = switch (r.uintLessThan(u8, 3)) {
            0 => r.int(u8),
            1 => r.uintLessThan(u8, 0x20), // controls, where the short forms live
            else => 'a' + r.uintLessThan(u8, 26),
        };
        const s = src[0..len];

        got.clearRetainingCapacity();
        write(&got, t.allocator, s);

        want.clearRetainingCapacity();
        try want.append(t.allocator, '"');
        for (s) |c| switch (c) {
            '"' => try want.appendSlice(t.allocator, "\\\""),
            '\\' => try want.appendSlice(t.allocator, "\\\\"),
            0x08 => try want.appendSlice(t.allocator, "\\b"),
            0x09 => try want.appendSlice(t.allocator, "\\t"),
            0x0a => try want.appendSlice(t.allocator, "\\n"),
            0x0c => try want.appendSlice(t.allocator, "\\f"),
            0x0d => try want.appendSlice(t.allocator, "\\r"),
            0x00...0x07, 0x0b, 0x0e...0x1f => {
                const hex = "0123456789abcdef";
                try want.appendSlice(t.allocator, "\\u00");
                try want.append(t.allocator, hex[c >> 4]);
                try want.append(t.allocator, hex[c & 0xf]);
            },
            else => try want.append(t.allocator, c),
        };
        try want.append(t.allocator, '"');
        try t.expectEqualStrings(want.items, got.items);
    }
}

test "write: quotes, backslashes, and every C0 short form escape correctly" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.allocator);
    write(&buf, t.allocator, "a\"b\\c\n\t\r\x08\x0c");
    try t.expectEqualStrings("\"a\\\"b\\\\c\\n\\t\\r\\b\\f\"", buf.items);
}

test "write: other controls become \\u00XX; UTF-8 passes through raw" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.allocator);
    write(&buf, t.allocator, "\x01\x1f\u{00e9}");
    try t.expectEqualStrings("\"\\u0001\\u001f\u{00e9}\"", buf.items);
}
