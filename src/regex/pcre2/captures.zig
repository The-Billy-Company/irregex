//! gist — PCRE2-backed capture extraction for `-P -r`/`--replace`.
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
//! Slots use gist's convention: `out[2k]`/`out[2k+1]` bracket group `k`, `-1`
//! for a group that did not participate (PCRE2's `UNSET`).

const std = @import("std");
const ffi = @import("ffi.zig");
const engine = @import("engine.zig");

pub const Options = engine.Options;
pub const CompileError = engine.CompileError;

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

    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8, opts: Options) CompileError!PcreCaptures {
        var errorcode: c_int = 0;
        var erroroffset: ffi.Size = 0;
        const code = ffi.pcre2_compile_8(pattern.ptr, pattern.len, engine.compileOptionBits(opts), &errorcode, &erroroffset, null) orelse {
            engine.recordError(errorcode);
            return CompileError.BadPattern;
        };
        errdefer ffi.pcre2_code_free_8(code);
        // Best-effort JIT — matching is the hot path even for replacement.
        _ = ffi.pcre2_jit_compile_8(code, ffi.JIT_COMPLETE);

        var count: u32 = 0;
        _ = ffi.pcre2_pattern_info_8(code, ffi.INFO_CAPTURECOUNT, &count);

        const md = ffi.pcre2_match_data_create_from_pattern_8(code, null) orelse return CompileError.OutOfMemory;
        errdefer ffi.pcre2_match_data_free_8(md);
        const mc = ffi.pcre2_match_context_create_8(null) orelse return CompileError.OutOfMemory;
        errdefer ffi.pcre2_match_context_free_8(mc);
        _ = ffi.pcre2_set_match_limit_8(mc, engine.match_limit);
        _ = ffi.pcre2_set_depth_limit_8(mc, engine.depth_limit);

        return .{ .code = code, .md = md, .mc = mc, .nslots = 2 * (@as(usize, count) + 1), .allocator = allocator };
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
    /// A resource fault latches through `engine.recordMatchFault` (so `-P -r`
    /// over catastrophic input still exits 2) and reads as no-match here.
    pub fn find(self: *PcreCaptures, line: []const u8, from: usize, out: []isize) bool {
        if (from > line.len) return false;
        const subject: [*]const u8 = if (line.len == 0) engine.empty_subject else line.ptr;
        const rc = ffi.pcre2_match_8(self.code, subject, line.len, from, engine.match_options, self.md, self.mc);
        if (rc < 0) {
            engine.recordMatchFault(rc);
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
