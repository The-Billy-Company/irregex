//! irregex — PCRE2-backed capture extraction for `-P -r`/`--replace`.
//!
//! The `-r` replacement path expands a template (`$1`, `${name}`) against the
//! byte offsets of each capturing group. The linear engine serves those from
//! `../captures.zig` (`Captures`, a save-carrying Pike VM); this is its PCRE2
//! twin, so `-P -r` expands `$1`/`${name}` from real PCRE2 captures (including
//! backreference/lookaround patterns the linear VM can't express).
//!
//! It presents the exact three-primitive surface the replacement expander needs
//! — `nslots` (slot-vector width), `find` (fill the slots from one match), and
//! `groupByName` (`${name}` → group number) — so the `Caps` union in
//! `../captures.zig` dispatches to it with no output-layer knowledge of PCRE2.
//! Slots use this package's convention: `out[2k]`/`out[2k+1]` bracket group
//! `k`, `-1` for a group that did not participate (PCRE2's `UNSET`).

const std = @import("std");
const ffi = @import("ffi.zig");
const engine = @import("engine.zig");

pub const Options = engine.Options;
pub const CompileError = engine.CompileError;
pub const Limits = engine.Limits;

/// A compiled PCRE2 program dedicated to capture extraction. Owns its own match
/// scratch (a match-data block + resource-ceilinged context) — one per run,
/// never shared — mirroring how the linear `Captures` owns its thread lists.
pub const PcreCaptures = struct {
    code: *ffi.Code,
    md: *ffi.MatchData,
    mc: *ffi.MatchContext,
    /// Slot-vector width: `2*(capture_count+1)` — group 0 (whole match) plus
    /// every `(…)`. The replacement expander allocs an `[]isize` of this length.
    nslots: usize,
    allocator: std.mem.Allocator,
    /// The ceilings every `find`/`matchAt` here runs under — the same
    /// `mark.Limits` the search program carries, so `-P -r` is bounded exactly
    /// as the search that produced its spans was. All-null is the arm's own
    /// defaults, so a caller that asks for nothing pays for nothing.
    limits: Limits = .{},

    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8, opts: Options) CompileError!PcreCaptures {
        return compileLimited(allocator, pattern, opts, .{});
    }

    /// `compile` under caller ceilings — the replacement arm's twin of
    /// `Pcre.compileLimited`, so a host cannot bound its search and then run
    /// the capture pass over the same catastrophic input unbounded.
    pub fn compileLimited(allocator: std.mem.Allocator, pattern: []const u8, opts: Options, limits: Limits) CompileError!PcreCaptures {
        // The same `-w` rewrite the search program compiles, so a `-w -r` run
        // replaces the span the search found rather than the greedy one starting
        // where it found it.
        const src = try engine.wordWrapped(allocator, pattern, opts);
        defer if (src.ptr != pattern.ptr) allocator.free(src);

        var errorcode: c_int = 0;
        var erroroffset: ffi.Size = 0;
        const code = ffi.pcre2_compile_8(src.ptr, src.len, engine.compileOptionBits(opts), &errorcode, &erroroffset, null) orelse {
            engine.recordError(errorcode);
            return CompileError.BadPattern;
        };
        errdefer ffi.pcre2_code_free_8(code);
        // Best-effort JIT — matching is the hot path even for replacement — but
        // withdrawn by a depth or heap ceiling for the reason `engine.jitHonors`
        // records: the JIT never reads those two, and a ceiling the fast path
        // ignores is a safety property in name only.
        if (engine.jitHonors(limits)) _ = ffi.pcre2_jit_compile_8(code, ffi.JIT_COMPLETE);

        var count: u32 = 0;
        _ = ffi.pcre2_pattern_info_8(code, ffi.INFO_CAPTURECOUNT, &count);

        const md = ffi.pcre2_match_data_create_from_pattern_8(code, null) orelse return CompileError.OutOfMemory;
        errdefer ffi.pcre2_match_data_free_8(md);
        const mc = ffi.pcre2_match_context_create_8(null) orelse return CompileError.OutOfMemory;
        errdefer ffi.pcre2_match_context_free_8(mc);
        engine.applyLimits(mc, limits);

        return .{ .code = code, .md = md, .mc = mc, .nslots = 2 * (@as(usize, count) + 1), .allocator = allocator, .limits = limits };
    }

    pub fn deinit(self: *PcreCaptures) void {
        ffi.pcre2_match_context_free_8(self.mc);
        ffi.pcre2_match_data_free_8(self.md);
        ffi.pcre2_code_free_8(self.code);
        self.* = undefined;
    }

    /// Leftmost match of the pattern within `line[from..]`. On a match, fills
    /// `out` (length `nslots`) with group byte offsets — `out[2k]`/`out[2k+1]`
    /// bracket group `k`, `-1` for a non-participating group — and returns true.
    /// A resource fault latches through `engine.recordFault` (so `-P -r` over
    /// catastrophic input still exits 2, and a caller ceiling still names
    /// itself) and reads as no-match here.
    pub fn find(self: *PcreCaptures, line: []const u8, from: usize, out: []isize) bool {
        return self.run(line, from, out, engine.match_options);
    }

    /// The anchored twin: the match must BEGIN at `from`, with no forward search
    /// for a later start. `find` answers "is it anywhere after here", which is a
    /// different question from "is it here" — a caller deciding what a byte
    /// position is (a lexer probe, a tokenizer arm) needs the second one, and
    /// getting the first is how a probe silently succeeds on text it never
    /// reached. One compiled program serves both: `PCRE2_ANCHORED` is a
    /// match-time bit.
    pub fn matchAt(self: *PcreCaptures, line: []const u8, from: usize, out: []isize) bool {
        return self.run(line, from, out, engine.match_options | ffi.ANCHORED);
    }

    fn run(self: *PcreCaptures, line: []const u8, from: usize, out: []isize, opts: u32) bool {
        if (from > line.len) return false;
        const subject: [*]const u8 = if (line.len == 0) engine.empty_subject else line.ptr;
        const rc = ffi.pcre2_match_8(self.code, subject, line.len, from, opts, self.md, self.mc);
        if (rc < 0) {
            engine.recordFault(self.limits, rc);
            return false;
        }
        const ov = ffi.pcre2_get_ovector_pointer_8(self.md);
        for (out, 0..) |*slot, i| {
            // Slots beyond this match's ovector, or an UNSET group, are -1.
            const present = i < self.nslots and ov[i] != ffi.UNSET;
            slot.* = if (present) @intCast(ov[i]) else -1;
        }
        return true;
    }

    /// `${name}` → group number (≥1), or null when the name is unknown.
    pub fn groupByName(self: *const PcreCaptures, name: []const u8) ?u32 {
        var buf: [128]u8 = undefined;
        if (name.len >= buf.len) return null;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        // A sentinel-terminated slice yields a `[*:0]u8` pointer directly — no
        // `@ptrCast`; the `:0` on the slice bound proves the NUL to the compiler.
        const n = ffi.pcre2_substring_number_from_name_8(self.code, buf[0..name.len :0].ptr);
        return if (n > 0) @intCast(n) else null;
    }

    /// The inverse: group number → the name it was declared with, or null for a
    /// plain `(…)`. PCRE2 offers no call for this direction, so it is a walk of
    /// the pattern's name table — `count` entries of `width` bytes, each a
    /// big-endian group number followed by a NUL-terminated name.
    ///
    /// The slice borrows the compiled code, so it lives exactly as long as this
    /// `PcreCaptures` does. No copy, which is what lets the C seam hand a host a
    /// pointer instead of asking it for a buffer.
    pub fn nameOfGroup(self: *const PcreCaptures, index: u32) ?[]const u8 {
        if (index == 0) return null; // group 0 is the whole match; never named
        var count: u32 = 0;
        var width: u32 = 0;
        var table: [*]const u8 = undefined;
        _ = ffi.pcre2_pattern_info_8(self.code, ffi.INFO_NAMECOUNT, &count);
        _ = ffi.pcre2_pattern_info_8(self.code, ffi.INFO_NAMEENTRYSIZE, &width);
        if (count == 0 or width < 3) return null;
        _ = ffi.pcre2_pattern_info_8(self.code, ffi.INFO_NAMETABLE, @ptrCast(&table));

        for (0..count) |i| {
            const entry = table[i * width ..][0..width];
            if (std.mem.readInt(u16, entry[0..2], .big) != index) continue;
            return std.mem.sliceTo(entry[2..], 0);
        }
        return null;
    }
};

test "pcre captures fill numbered slots and resolve names" {
    const t = std.testing;
    var c = try PcreCaptures.compile(t.allocator, "(?<w>\\w+)\\s+(\\w+)", .{});
    defer c.deinit();
    try t.expectEqual(@as(usize, 6), c.nslots); // group 0 + two groups
    const slots = try t.allocator.alloc(isize, c.nslots);
    defer t.allocator.free(slots);
    try t.expect(c.find("alpha beta", 0, slots));
    try t.expectEqual(@as(isize, 0), slots[0]); // whole match start
    try t.expectEqual(@as(isize, 10), slots[1]); // whole match end
    try t.expectEqual(@as(isize, 0), slots[2]); // group 1 "alpha"
    try t.expectEqual(@as(isize, 5), slots[3]);
    try t.expectEqual(@as(?u32, 1), c.groupByName("w"));
    try t.expectEqual(@as(?u32, null), c.groupByName("nope"));
}

test "pcre captures resolve a backreference the linear VM can't" {
    const t = std.testing;
    var c = try PcreCaptures.compile(t.allocator, "(\\w+)\\1", .{});
    defer c.deinit();
    const slots = try t.allocator.alloc(isize, c.nslots);
    defer t.allocator.free(slots);
    try t.expect(c.find("foofoo", 0, slots));
    try t.expectEqual(@as(isize, 0), slots[2]); // group 1 = "foo"
    try t.expectEqual(@as(isize, 3), slots[3]);
    // "foobar" still matches at the doubled "oo" (group 1 = "o" at [1,2)).
    try t.expect(c.find("foobar", 0, slots));
    try t.expectEqual(@as(isize, 1), slots[2]);
    try t.expectEqual(@as(isize, 2), slots[3]);
    try t.expect(!c.find("abcdef", 0, slots)); // no doubled run at all
}
