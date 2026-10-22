//! Checked Image1 persistence. This module owns decoded data, never an FFI
//! worker or an accounting allocator. It does not invoke a determinizer.
const std = @import("std");
const builtin = @import("builtin");
const native = @import("munch.zig");
const signet = @import("../../../../corpus/index/frame/signet.zig");
pub const types = @import("munch_image_types.zig");
pub const Limits = types.Limits;
pub const Budget = types.Budget;
pub const Context = types.Context;
pub const Identity = types.Identity;
pub const Stats = types.Stats;
pub const Error = types.Error;
const Munch = native.Munch;
const Dfa = Munch.Dfa;
const absent = std.math.maxInt(u32);
pub const accepted_flags: u32 = 0x442;
const source_label = "irgx/munch-image/source-input/v1\x00";
const roster_label = "irgx/munch-image/roster-binding/v1\x00";
const frame_label = "irgx/munch-image/frame/v1\x00";
const schema_prefix = "irregex/signet/schema\x00";
const artifact_prefix = "irregex/signet/artifact\x00";

pub const Expected = union(enum) {
    descriptors: []const types.Pattern,
    slices: []const []const u8,

    pub fn count(e: Expected) usize {
        return switch (e) {
            .descriptors => |p| p.len,
            .slices => |p| p.len,
        };
    }
    fn at(e: Expected, i: usize) Error![]const u8 {
        return switch (e) {
            .slices => |p| p[i],
            .descriptors => |p| if (p[i].pattern) |bytes| bytes[0..p[i].len] else if (p[i].len == 0) &.{} else error.InvalidArgument,
        };
    }
};

fn paid(ctx: ?*Context, n: u64) Error!void {
    if (ctx) |c| try c.work(n);
}
fn pushInt(s: *signet.Scribe, comptime T: type, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    s.update(&bytes);
}
fn maskFor(k: usize) u64 {
    return if (k == 64) std.math.maxInt(u64) else (@as(u64, 1) << @as(u6, @intCast(k))) - 1;
}

/// Source construction uses ctx=null: this work is paid by construction, never
/// retroactively charged to a future ImageBudget. No image4096 cap is imposed.
pub fn sourceIdentity(ctx: ?*Context, expected: Expected, flags: u32) Error!Identity {
    if (flags & ~accepted_flags != 0) return error.InvalidArgument;
    if (expected.count() > std.math.maxInt(u32)) return error.Oversized;
    var text_bytes: u64 = 0;
    for (0..expected.count()) |i| {
        try paid(ctx, 1);
        text_bytes = try types.add(text_bytes, (try expected.at(i)).len);
    }
    _ = try types.size(text_bytes);
    const prefixes = schema_prefix.len + source_label.len + 44;
    try paid(ctx, try types.add(prefixes, try types.add(text_bytes, try types.mul(expected.count(), 8))));
    var s = signet.Scribe.init(.schema);
    s.update(source_label);
    inline for (.{ @as(u32, 1), @as(u32, 1), @as(u32, 1), @as(u32, 1), @as(u32, 17), @as(u32, 0), @as(u32, 0) }) |value| pushInt(&s, u32, value);
    pushInt(&s, u32, flags);
    pushInt(&s, u32, @intCast(expected.count()));
    pushInt(&s, u64, text_bytes);
    for (0..expected.count()) |i| {
        try paid(ctx, 1);
        const bytes = try expected.at(i);
        pushInt(&s, u64, bytes.len);
        s.update(bytes);
    }
    return .{ .source = s.finish().bytes, .roster = undefined, .flags = flags, .count = @intCast(expected.count()), .text_bytes = text_bytes };
}

pub fn rosterIdentity(ctx: ?*Context, machine: *const Munch, source: [32]u8) Error![32]u8 {
    if (machine.declined.len != machine.because.len) return error.NonCanonical;
    var bytes = try types.add(schema_prefix.len + roster_label.len + 44, try types.mul(machine.declined.len, 8));
    var admitted: u64 = 0;
    for (machine.voices) |voice| {
        try paid(ctx, 1);
        bytes = try types.add(bytes, try types.add(4, try types.mul(voice.ordinals.len, 4)));
        admitted = try types.add(admitted, voice.ordinals.len);
    }
    try paid(ctx, bytes);
    var s = signet.Scribe.init(.schema);
    s.update(roster_label);
    s.update(&source);
    pushInt(&s, u32, std.math.cast(u32, admitted) orelse return error.Oversized);
    pushInt(&s, u32, std.math.cast(u32, machine.declined.len) orelse return error.Oversized);
    pushInt(&s, u32, std.math.cast(u32, machine.voices.len) orelse return error.Oversized);
    for (machine.declined, machine.because) |ordinal, reason| {
        try paid(ctx, 2);
        pushInt(&s, u32, ordinal);
        pushInt(&s, u32, reasonTag(reason));
    }
    for (machine.voices) |voice| {
        try paid(ctx, 1);
        pushInt(&s, u32, @intCast(voice.ordinals.len));
        for (voice.ordinals) |ordinal| {
            try paid(ctx, 1);
            pushInt(&s, u32, ordinal);
        }
    }
    return s.finish().bytes;
}
fn reasonTag(reason: Munch.Because) u32 {
    return switch (reason) {
        .syntax => 0,
        .states => 1,
        .word_context => 2,
        .buffer_anchor => 3,
    };
}
fn reasonOf(tag: u32) Error!Munch.Because {
    return switch (tag) {
        0 => .syntax,
        1 => .states,
        2 => .word_context,
        3 => .buffer_anchor,
        else => error.NonCanonical,
    };
}

const Reader = struct {
    ctx: *Context,
    bytes: []const u8,
    pos: usize = 0,

    fn take(r: *Reader, n: usize) Error![]const u8 {
        if (n > r.bytes.len - r.pos) return error.Truncated;
        const result = r.bytes[r.pos..][0..n];
        r.pos += n;
        return result;
    }
    fn fixed(r: *Reader, comptime T: type) Error!T {
        return std.mem.readInt(T, (try r.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }
    fn int(r: *Reader, comptime T: type) Error!T {
        try r.ctx.work(1);
        return r.fixed(T);
    }
    fn words(r: *Reader, comptime T: type, n: usize, site: types.Site) Error![]T {
        const bytes = try types.mul(n, @sizeOf(T));
        if (bytes > r.bytes.len - r.pos) return error.Truncated;
        const result = try r.ctx.alloc(T, n, site);
        errdefer r.ctx.free(result);
        for (result) |*slot| {
            const value = try r.int(T);
            try r.ctx.work(@sizeOf(T));
            slot.* = value;
        }
        return result;
    }
};

const Header = struct { stats: Stats, identity: Identity, admitted: u32, declined: u32 };
fn readHeader(ctx: *Context, image: []const u8) Error!Header {
    if (@sizeOf(usize) != 8 or (builtin.cpu.arch != .aarch64 and builtin.cpu.arch != .x86_64)) return error.Unsupported;
    if (image.len > ctx.limits.encoded_bytes) return error.Oversized;
    if (image.len < 208) return error.Truncated;
    try ctx.work(176);
    var r = Reader{ .ctx = ctx, .bytes = image[0..176] };
    if (!std.mem.eql(u8, try r.take(8), "IRGXMCH1")) return error.Corrupt;
    const version = try r.fixed(u32);
    if (try r.fixed(u32) != 176) return error.NonCanonical;
    const scan = try r.fixed(u32);
    const lowering = try r.fixed(u32);
    const unicode = try r.fixed(u32);
    const flags = try r.fixed(u32);
    const encoded = try r.fixed(u64);
    const decoded = try r.fixed(u64);
    const p = try r.fixed(u32);
    const v = try r.fixed(u32);
    const d = try r.fixed(u32);
    const a = try r.fixed(u32);
    const states = try r.fixed(u64);
    const transitions = try r.fixed(u64);
    const auxiliary = try r.fixed(u64);
    const text_bytes = try r.fixed(u64);
    var source: [32]u8 = undefined;
    var roster: [32]u8 = undefined;
    @memcpy(&source, try r.take(32));
    @memcpy(&roster, try r.take(32));
    const major = try r.fixed(u32);
    const minor = try r.fixed(u32);
    const patch = try r.fixed(u32);
    const reserved = try r.fixed(u32);
    if (version != 1 or scan != 1 or lowering != 1 or unicode != 1 or major != 17 or minor != 0 or patch != 0) return error.VersionMismatch;
    if (flags & ~accepted_flags != 0 or reserved != 0) return error.NonCanonical;
    if (encoded > image.len) return error.Truncated;
    if (encoded < image.len) return error.NonCanonical;
    try ctx.work(try types.add(artifact_prefix.len + frame_label.len, image.len - 32));
    var s = signet.Scribe.init(.artifact);
    s.update(frame_label);
    s.update(image[0 .. image.len - 32]);
    const seal = s.finish();
    if (!std.mem.eql(u8, &seal.bytes, image[image.len - 32 ..])) return error.Corrupt;
    const stats = Stats{ .encoded = encoded, .decoded = decoded, .patterns = p, .voices = v, .states = states, .transitions = transitions, .auxiliary = auxiliary };
    try ctx.checkStats(stats);
    if (@as(u64, a) + d != p or v > a or (p > 0 and a == 0) or (p == 0 and (a != 0 or d != 0 or v != 0))) return error.NonCanonical;
    return .{ .stats = stats, .identity = .{ .source = source, .roster = roster, .flags = flags, .count = p, .text_bytes = text_bytes }, .admitted = a, .declined = d };
}

pub const Decoded = struct {
    inner: Munch,
    identity: Identity,
    stats: Stats,
    owned_bytes: u64,

    pub fn deinit(d: *Decoded, ctx: *Context) void {
        d.inner.deinit();
        ctx.released(d.owned_bytes);
        d.* = undefined;
    }
};

fn initialStats(p: u64, a: u64, d: u64, v: u64) Error!Stats {
    return .{ .patterns = p, .voices = v, .encoded = try types.add(208, try types.mul(d, 8)), .decoded = try types.add(208, try types.add(try types.mul(d, 8), try types.add(try types.mul(p, 8), try types.add(try types.mul(a, 4), try types.mul(v, 8))))), .auxiliary = try types.add(try types.add(p, a), try types.add(d, v)) };
}
fn addVoiceStats(s: *Stats, k: u64, n: u64, c: u64, runs: u64, m: u64, q: u64) Error!void {
    const entries = try types.mul(n, c);
    const record = try types.add(336, try types.add(try types.mul(k, 4), try types.add(try types.mul(entries, 8), try types.add(try types.mul(runs, 12), try types.mul(q, 8)))));
    s.encoded = try types.add(s.encoded, record);
    s.decoded = try types.add(s.decoded, try types.add(336, try types.add(try types.mul(k, 4), try types.add(try types.mul(entries, 8), try types.add(try types.mul(m, 8), try types.mul(q, 8))))));
    s.states = try types.add(s.states, n);
    s.transitions = try types.add(s.transitions, try types.mul(entries, 2));
    s.auxiliary = try types.add(s.auxiliary, try types.add(runs, try types.add(m, q)));
}

fn readVoice(r: *Reader, seen: []bool, stats: *Stats) Error!Munch.Voice {
    const ctx = r.ctx;
    const begin = r.pos;
    try ctx.work(80);
    const record = try r.fixed(u64);
    const k = try r.fixed(u32);
    const mode = try r.fixed(u32);
    const c = try r.fixed(u32);
    const n = try r.fixed(u32);
    const match_hi = try r.fixed(u32);
    const start = try r.fixed(u32);
    const dead = try r.fixed(u32);
    const flags = try r.fixed(u32);
    const empty_pats = try r.fixed(u64);
    const ni = try r.fixed(u64);
    const nf = try r.fixed(u64);
    const runs = try r.fixed(u32);
    const q = try r.fixed(u32);
    const reserved = try r.fixed(u64);
    if (k == 0 or k > 64 or c == 0 or c > 256 or n == 0 or reserved != 0 or flags & ~@as(u32, 3) != 0 or flags & 1 == 0) return error.NonCanonical;
    if (n > 8192) return error.Oversized;
    const entries = try types.mul(n, c);
    if (entries > std.math.maxInt(u32)) return error.Oversized;
    if (ni != entries or nf != entries or match_hi > entries or match_hi % c != 0) return error.NonCanonical;
    const m: u32 = if (mode == 1) match_hi / c else 0;
    if ((k == 1 and (mode != 0 or runs != 0 or q != 0)) or (k > 1 and (mode != 1 or q != n))) return error.NonCanonical;
    if (mode == 1 and ((m == 0 and runs != 0) or (m != 0 and (runs == 0 or runs > m)))) return error.NonCanonical;
    const wanted = try types.add(336, try types.add(try types.mul(k, 4), try types.add(try types.mul(entries, 8), try types.add(try types.mul(runs, 12), try types.mul(q, 8)))));
    if (record != wanted) return error.NonCanonical;
    if (record > r.bytes.len - begin) return error.Truncated;
    try addVoiceStats(stats, k, n, c, runs, m, q);
    try ctx.checkStats(stats.*);
    const ordinals = try r.words(u32, k, .voices);
    errdefer ctx.free(ordinals);
    var previous: ?u32 = null;
    for (ordinals) |ordinal| {
        try ctx.work(1);
        if (ordinal >= seen.len or (previous != null and ordinal <= previous.?) or seen[ordinal]) return error.NonCanonical;
        seen[ordinal] = true;
        previous = ordinal;
    }
    var classes: [256]u8 = undefined;
    const raw_classes = try r.take(256);
    try ctx.work(256);
    @memcpy(&classes, raw_classes);
    for (classes) |value| {
        try ctx.work(1);
        if (value >= c) return error.Corrupt;
    }
    const interior = try r.words(u32, try types.size(entries), .transitions);
    errdefer ctx.free(interior);
    const final = try r.words(u32, try types.size(entries), .transitions);
    errdefer ctx.free(final);
    const pats = try ctx.alloc(u64, m, .masks);
    errdefer ctx.free(pats);
    var last: u32 = 0;
    var previous_mask: ?u64 = null;
    for (0..runs) |_| {
        const hi = try r.int(u32);
        const mask = try r.int(u64);
        try ctx.work(1);
        if (hi <= last or hi > match_hi or hi % c != 0 or mask == 0 or mask & ~maskFor(k) != 0 or (previous_mask != null and previous_mask.? == mask)) return error.NonCanonical;
        const slots = pats[last / c .. hi / c];
        try ctx.work(try types.mul(slots.len, 8));
        @memset(slots, mask);
        last = hi;
        previous_mask = mask;
    }
    if (mode == 1 and last != match_hi) return error.NonCanonical;
    const reach = try r.words(u64, q, .reach);
    errdefer ctx.free(reach);
    if (r.pos - begin != record) return error.NonCanonical;
    const dfa = try ctx.create(Dfa, .dfa);
    errdefer ctx.destroy(dfa);
    try ctx.work(@sizeOf(Dfa));
    dfa.* = .{ .class = classes, .ncls = @intCast(c), .nstates = n, .trans_in = interior, .trans_fin = final, .match_hi = match_hi, .pats = pats, .reach = reach, .start = start, .dead = dead, .empty_match = flags & 2 != 0, .empty_pats = empty_pats, .anchored = true, .word_ctx = false, .unicode_word = false, .trans_in_w = &.{}, .start_w = start, .visits = 0, .wide = null, .start_dwell = null, .allocator = ctx.base, .borrowed = false };
    return .{ .dfa = dfa, .ordinals = ordinals };
}

fn voiceOwnedBytes(v: Munch.Voice) u64 {
    return @sizeOf(Dfa) + @as(u64, v.ordinals.len) * 4 +
        @as(u64, v.dfa.trans_in.len + v.dfa.trans_fin.len) * 4 +
        @as(u64, v.dfa.pats.len + v.dfa.reach.len) * 8;
}
fn freeVoice(ctx: *Context, v: Munch.Voice) void {
    const bytes = voiceOwnedBytes(v);
    v.dfa.deinit();
    ctx.base.free(v.ordinals);
    ctx.released(bytes);
}

pub fn load(ctx: *Context, expected: Expected, flags: u32, image: []const u8) Error!Decoded {
    const initial_live = ctx.live;
    const h = try readHeader(ctx, image);
    if (flags != h.identity.flags or expected.count() != h.identity.count) return error.GenerationMismatch;
    const actual = try sourceIdentity(ctx, expected, flags);
    if (actual.text_bytes != h.identity.text_bytes or !std.mem.eql(u8, &actual.source, &h.identity.source)) return error.GenerationMismatch;
    var r = Reader{ .ctx = ctx, .bytes = image[0 .. image.len - 32], .pos = 176 };
    var arrays_owned = true;
    const declined = try ctx.alloc(u32, h.declined, .voices);
    errdefer if (arrays_owned) ctx.free(declined);
    const because = try ctx.alloc(Munch.Because, h.declined, .voices);
    errdefer if (arrays_owned) ctx.free(because);
    const seen = try ctx.alloc(bool, h.identity.count, .validation);
    defer ctx.free(seen);
    try ctx.work(seen.len);
    @memset(seen, false);
    var previous: ?u32 = null;
    for (declined, because) |*ordinal, *reason| {
        const o = try r.int(u32);
        const why = try r.int(u32);
        try ctx.work(1);
        if (o >= seen.len or (previous != null and o <= previous.?) or seen[o]) return error.NonCanonical;
        const value = try reasonOf(why);
        try ctx.work(4 + @sizeOf(Munch.Because));
        ordinal.* = o;
        reason.* = value;
        seen[o] = true;
        previous = o;
    }
    const voices = try ctx.alloc(Munch.Voice, try types.size(h.stats.voices), .voices);
    var completed: usize = 0;
    errdefer if (arrays_owned) {
        for (voices[0..completed]) |v| freeVoice(ctx, v);
        ctx.free(voices);
    };
    var stats = try initialStats(h.identity.count, h.admitted, h.declined, h.stats.voices);
    previous = null;
    for (voices) |*voice| {
        const v = try readVoice(&r, seen, &stats);
        var transferred = false;
        errdefer if (!transferred) freeVoice(ctx, v);
        try ctx.work(1);
        if (previous != null and v.ordinals[0] <= previous.?) return error.NonCanonical;
        previous = v.ordinals[0];
        try ctx.work(@sizeOf(Munch.Voice));
        voice.* = v;
        completed += 1;
        transferred = true;
    }
    for (seen) |present| {
        try ctx.work(1);
        if (!present) return error.NonCanonical;
    }
    if (r.pos != r.bytes.len) return error.NonCanonical;
    if (!std.meta.eql(stats, h.stats)) return error.NonCanonical;
    var inner = try Munch.adoptImage(ctx, h.identity.count, voices, declined, because);
    arrays_owned = false;
    const inner_bytes = ctx.live - initial_live - seen.len;
    errdefer {
        inner.deinit();
        ctx.released(inner_bytes);
    }
    const validated = try validate(ctx, &inner, h.identity);
    if (!std.meta.eql(validated, h.stats)) return error.NonCanonical;
    const roster = try rosterIdentity(ctx, &inner, actual.source);
    if (!std.mem.eql(u8, &roster, &h.identity.roster)) return error.Corrupt;
    // seen is a local defer, excluded from the returned owned allocation tally.
    std.debug.assert(ctx.live - initial_live - seen.len == inner_bytes);
    return .{ .inner = inner, .identity = h.identity, .stats = stats, .owned_bytes = inner_bytes };
}

fn validateGraph(ctx: *Context, d: *const Dfa, k: usize) Error!void {
    if (d.ncls == 0 or d.ncls > 256 or d.nstates == 0) return error.NonCanonical;
    if (d.nstates > 8192) return error.Oversized;
    const n: usize = d.nstates;
    const c: usize = d.ncls;
    const entries = try types.mul(n, c);
    if (entries > std.math.maxInt(u32)) return error.Oversized;
    if (d.trans_in.len != entries or d.trans_fin.len != entries or d.match_hi > entries or d.match_hi % c != 0) return error.NonCanonical;
    if (d.start >= entries or d.start % c != 0 or (d.dead != absent and (d.dead >= entries or d.dead % c != 0))) return error.Corrupt;
    if (!d.anchored or d.word_ctx or d.unicode_word or d.trans_in_w.len != 0 or d.start_w != d.start or d.wide != null or d.start_dwell != null) return error.Unsupported;
    const allowed = maskFor(k);
    if (d.empty_pats & ~allowed != 0 or d.empty_match != (d.empty_pats != 0)) return error.NonCanonical;
    const m = d.match_hi / c;
    if ((k == 1 and (d.pats.len != 0 or d.reach.len != 0)) or (k > 1 and (d.pats.len != m or d.reach.len != n))) return error.NonCanonical;
    for (d.class) |column| {
        try ctx.work(1);
        if (column >= c) return error.Corrupt;
    }
    for (d.pats) |mask| {
        try ctx.work(1);
        if (mask == 0 or mask & ~allowed != 0) return error.NonCanonical;
    }
    for (d.reach) |mask| {
        try ctx.work(1);
        if (mask & ~allowed != 0) return error.NonCanonical;
    }
    const populated = try ctx.alloc(bool, n, .validation);
    defer ctx.free(populated);
    for (0..n) |state| {
        var filled = false;
        var sentinel = false;
        for ([_][]const u32{ d.trans_in, d.trans_fin }) |table| {
            for (table[state * c ..][0..c]) |target| {
                try ctx.work(1);
                if (target == absent) {
                    sentinel = true;
                } else {
                    filled = true;
                    if (target >= entries or target % c != 0) return error.Corrupt;
                }
            }
        }
        if (filled and sentinel) return error.Corrupt;
        try ctx.work(1);
        populated[state] = filled;
    }
    if (d.dead != absent) {
        if (d.dead < d.match_hi) return error.NonCanonical;
        if (populated[d.dead / c]) {
            for ([_][]const u32{ d.trans_in, d.trans_fin }) |table| {
                for (table[d.dead..][0..c]) |target| {
                    try ctx.work(1);
                    if (target != d.dead) return error.NonCanonical;
                }
            }
        }
    }
    const seen = try ctx.alloc(bool, n, .validation);
    defer ctx.free(seen);
    try ctx.work(n);
    @memset(seen, false);
    const queue = try ctx.alloc(u32, n, .validation);
    defer ctx.free(queue);
    var head: usize = 0;
    var tail: usize = 1;
    try ctx.work(5);
    queue[0] = d.start / @as(u32, d.ncls);
    seen[queue[0]] = true;
    while (head < tail) : (head += 1) {
        try ctx.work(1);
        const state = queue[head];
        if (!populated[state]) return error.Corrupt;
        for (d.trans_in[@as(usize, state) * c ..][0..c]) |target| {
            try ctx.work(1);
            const to = target / @as(u32, d.ncls);
            if (!seen[to]) {
                if (tail >= n) return error.Corrupt;
                try ctx.work(5);
                seen[to] = true;
                queue[tail] = to;
                tail += 1;
            }
        }
    }
    if (k > 1) try validateReach(ctx, d, populated);
}

/// The source's least fixpoint over BOTH tables, including final edges to
/// unfilled rows. Checked CSR/worklist replaces the unchecked freeze entry.
fn validateReach(ctx: *Context, d: *const Dfa, populated: []const bool) Error!void {
    const n: usize = d.nstates;
    const c: usize = d.ncls;
    const degree = try ctx.alloc(usize, n, .validation);
    defer ctx.free(degree);
    try ctx.work(try types.mul(n, @sizeOf(usize)));
    @memset(degree, 0);
    var edges: usize = 0;
    for (0..n) |state| {
        try ctx.work(1);
        if (!populated[state]) continue;
        for ([_][]const u32{ d.trans_in, d.trans_fin }) |table| {
            for (table[state * c ..][0..c]) |target| {
                try ctx.work(1);
                const to = target / d.ncls;
                degree[to] = std.math.add(usize, degree[to], 1) catch return error.Oversized;
                edges = std.math.add(usize, edges, 1) catch return error.Oversized;
            }
        }
    }
    const offsets = try ctx.alloc(usize, n + 1, .validation);
    defer ctx.free(offsets);
    try ctx.work(@sizeOf(usize));
    offsets[0] = 0;
    for (degree, 0..) |count, i| {
        try ctx.work(1 + @sizeOf(usize));
        offsets[i + 1] = std.math.add(usize, offsets[i], count) catch return error.Oversized;
    }
    if (offsets[n] != edges) return error.Corrupt;
    const cursor = try ctx.alloc(usize, n, .validation);
    defer ctx.free(cursor);
    try ctx.work(try types.mul(n, @sizeOf(usize)));
    @memcpy(cursor, offsets[0..n]);
    const predecessors = try ctx.alloc(u32, edges, .validation);
    defer ctx.free(predecessors);
    for (0..n) |state| {
        try ctx.work(1);
        if (!populated[state]) continue;
        for ([_][]const u32{ d.trans_in, d.trans_fin }) |table| {
            for (table[state * c ..][0..c]) |target| {
                try ctx.work(1);
                const to = target / d.ncls;
                if (cursor[to] >= offsets[to + 1]) return error.Corrupt;
                try ctx.work(4 + @sizeOf(usize));
                predecessors[cursor[to]] = @intCast(state);
                cursor[to] += 1;
            }
        }
    }
    const masks = try ctx.alloc(u64, n, .validation);
    defer ctx.free(masks);
    try ctx.work(try types.mul(n, 8));
    @memset(masks, 0);
    try ctx.work(try types.mul(d.pats.len, 8));
    @memcpy(masks[0..d.pats.len], d.pats);
    const queue = try ctx.alloc(u32, n, .validation);
    defer ctx.free(queue);
    const queued = try ctx.alloc(bool, n, .validation);
    defer ctx.free(queued);
    try ctx.work(n);
    @memset(queued, false);
    var head: usize = 0;
    var tail: usize = 0;
    var count: usize = 0;
    for (d.pats, 0..) |_, i| {
        try ctx.work(5);
        queue[tail] = @intCast(i);
        tail = (tail + 1) % n;
        count += 1;
        queued[i] = true;
    }
    while (count != 0) {
        try ctx.work(2);
        const target = queue[head];
        head = (head + 1) % n;
        count -= 1;
        queued[target] = false;
        for (predecessors[offsets[target]..offsets[target + 1]]) |from| {
            try ctx.work(1);
            const next = masks[from] | masks[target];
            if (next == masks[from]) continue;
            try ctx.work(8);
            masks[from] = next;
            if (!queued[from]) {
                if (count >= n) return error.Corrupt;
                try ctx.work(5);
                queued[from] = true;
                queue[tail] = from;
                tail = (tail + 1) % n;
                count += 1;
            }
        }
    }
    for (masks, d.reach) |computed, stored| {
        try ctx.work(1);
        if (computed != stored) return error.NonCanonical;
    }
}

fn runCount(ctx: *Context, pats: []const u64) Error!u32 {
    var count: u32 = 0;
    var previous: ?u64 = null;
    for (pats) |mask| {
        try ctx.work(1);
        if (previous == null or previous.? != mask) {
            count += 1;
            previous = mask;
        }
    }
    return count;
}

pub fn validate(ctx: *Context, machine: *const Munch, identity: Identity) Error!Stats {
    const p: usize = identity.count;
    const a = machine.admitted();
    const d = machine.declined.len;
    const v = machine.voices.len;
    if (machine.because.len != d or try types.add(a, d) != p or v > a or (p > 0 and a == 0) or (p == 0 and (a != 0 or d != 0 or v != 0))) return error.NonCanonical;
    var stats = try initialStats(p, a, d, v);
    try ctx.checkStats(stats);
    const seen = try ctx.alloc(bool, p, .validation);
    defer ctx.free(seen);
    try ctx.work(p);
    @memset(seen, false);
    var previous: ?u32 = null;
    for (machine.declined) |ordinal| {
        try ctx.work(1);
        if (ordinal >= p or (previous != null and ordinal <= previous.?) or seen[ordinal]) return error.NonCanonical;
        seen[ordinal] = true;
        previous = ordinal;
    }
    previous = null;
    for (machine.voices) |voice| {
        try ctx.work(1);
        const k = voice.ordinals.len;
        if (k == 0 or k > 64 or (previous != null and voice.ordinals[0] <= previous.?)) return error.NonCanonical;
        previous = voice.ordinals[0];
        var last: ?u32 = null;
        for (voice.ordinals) |ordinal| {
            try ctx.work(1);
            if (ordinal >= p or (last != null and ordinal <= last.?) or seen[ordinal]) return error.NonCanonical;
            seen[ordinal] = true;
            last = ordinal;
        }
        const runs = try runCount(ctx, voice.dfa.pats);
        try addVoiceStats(&stats, k, voice.dfa.nstates, voice.dfa.ncls, runs, voice.dfa.pats.len, voice.dfa.reach.len);
        try ctx.checkStats(stats);
        try validateGraph(ctx, voice.dfa, k);
    }
    for (seen) |present| {
        try ctx.work(1);
        if (!present) return error.NonCanonical;
    }
    return stats;
}

const Writer = struct {
    ctx: *Context,
    bytes: []u8,
    pos: usize = 0,
    fn int(w: *Writer, comptime T: type, value: T) Error!void {
        if (@sizeOf(T) > w.bytes.len - w.pos) return error.NonCanonical;
        try w.ctx.work(@sizeOf(T));
        std.mem.writeInt(T, w.bytes[w.pos..][0..@sizeOf(T)], value, .little);
        w.pos += @sizeOf(T);
    }
    fn put(w: *Writer, bytes: []const u8) Error!void {
        if (bytes.len > w.bytes.len - w.pos) return error.NonCanonical;
        try w.ctx.work(bytes.len);
        @memcpy(w.bytes[w.pos..][0..bytes.len], bytes);
        w.pos += bytes.len;
    }
};
pub const Encoded = struct { bytes: []u8, stats: Stats };

/// Fully encode/hash locally. No worker pending state exists in this module.
pub fn save(ctx: *Context, machine: *const Munch, identity: Identity) Error!Encoded {
    if (identity.flags & ~accepted_flags != 0) return error.InvalidArgument;
    if (identity.image_version != 1 or identity.scan_epoch != 1 or identity.lowering_epoch != 1 or identity.unicode_epoch != 1 or !std.mem.eql(u32, &identity.unicode_version, &.{ 17, 0, 0 })) return error.VersionMismatch;
    const stats = try validate(ctx, machine, identity);
    const roster = try rosterIdentity(ctx, machine, identity.source);
    if (!std.mem.eql(u8, &roster, &identity.roster)) return error.Corrupt;
    const bytes = try ctx.alloc(u8, try types.size(stats.encoded), .pending);
    errdefer ctx.free(bytes);
    var w = Writer{ .ctx = ctx, .bytes = bytes };
    try w.put("IRGXMCH1");
    inline for (.{ @as(u32, 1), @as(u32, 176), @as(u32, 1), @as(u32, 1), @as(u32, 1) }) |value| try w.int(u32, value);
    try w.int(u32, identity.flags);
    try w.int(u64, stats.encoded);
    try w.int(u64, stats.decoded);
    try w.int(u32, identity.count);
    try w.int(u32, @intCast(machine.voices.len));
    try w.int(u32, @intCast(machine.declined.len));
    try w.int(u32, @intCast(machine.admitted()));
    try w.int(u64, stats.states);
    try w.int(u64, stats.transitions);
    try w.int(u64, stats.auxiliary);
    try w.int(u64, identity.text_bytes);
    try w.put(&identity.source);
    try w.put(&identity.roster);
    inline for (.{ @as(u32, 17), @as(u32, 0), @as(u32, 0), @as(u32, 0) }) |value| try w.int(u32, value);
    std.debug.assert(w.pos == 176);
    for (machine.declined, machine.because) |ordinal, reason| {
        try ctx.work(2);
        try w.int(u32, ordinal);
        try w.int(u32, reasonTag(reason));
    }
    for (machine.voices) |voice| {
        try ctx.work(1);
        const d = voice.dfa;
        const k = voice.ordinals.len;
        const attributed = k > 1;
        const runs = try runCount(ctx, d.pats);
        const record = try types.add(336, try types.add(try types.mul(k, 4), try types.add(try types.mul(d.trans_in.len, 8), try types.add(try types.mul(runs, 12), try types.mul(d.reach.len, 8)))));
        const begin = w.pos;
        try w.int(u64, record);
        try w.int(u32, @intCast(k));
        try w.int(u32, if (attributed) 1 else 0);
        try w.int(u32, d.ncls);
        try w.int(u32, d.nstates);
        try w.int(u32, d.match_hi);
        try w.int(u32, d.start);
        try w.int(u32, d.dead);
        try w.int(u32, 1 | @as(u32, if (d.empty_match) 2 else 0));
        try w.int(u64, d.empty_pats);
        try w.int(u64, d.trans_in.len);
        try w.int(u64, d.trans_fin.len);
        try w.int(u32, runs);
        try w.int(u32, @intCast(d.reach.len));
        try w.int(u64, 0);
        for (voice.ordinals) |ordinal| {
            try ctx.work(1);
            try w.int(u32, ordinal);
        }
        try w.put(&d.class);
        for ([_][]const u32{ d.trans_in, d.trans_fin }) |table| {
            for (table) |target| {
                try ctx.work(1);
                try w.int(u32, target);
            }
        }
        var lo: usize = 0;
        while (lo < d.pats.len) {
            try ctx.work(1);
            const mask = d.pats[lo];
            var hi = lo + 1;
            while (hi < d.pats.len) : (hi += 1) {
                try ctx.work(1);
                if (d.pats[hi] != mask) break;
            }
            try w.int(u32, @intCast(try types.mul(hi, d.ncls)));
            try w.int(u64, mask);
            lo = hi;
        }
        for (d.reach) |mask| {
            try ctx.work(1);
            try w.int(u64, mask);
        }
        if (w.pos - begin != record) return error.NonCanonical;
    }
    if (w.pos != bytes.len - 32) return error.NonCanonical;
    try ctx.work(try types.add(artifact_prefix.len + frame_label.len, w.pos));
    var s = signet.Scribe.init(.artifact);
    s.update(frame_label);
    s.update(bytes[0..w.pos]);
    const seal = s.finish();
    try w.put(&seal.bytes);
    std.debug.assert(w.pos == bytes.len);
    return .{ .bytes = bytes, .stats = stats };
}

const t = std.testing;
const fixtures = @import("munch_image_vectors.zig");
fn authored(name: []const u8) *const fixtures.Fixture {
    for (&fixtures.fixtures) |*f| if (std.mem.eql(u8, f.name, name)) return f;
    unreachable;
}

test "munch-image: decoded data survives poisoned and freed caller image" {
    const f = authored("attributed-two");
    const input = try t.allocator.dupe(u8, f.bytes);
    var input_live = true;
    defer if (input_live) t.allocator.free(input);
    var budget = Budget.trial();
    var ctx = try Context.init(t.allocator, Limits.trial(), &budget, 0);
    const before = native.determinizations;
    var decoded = try load(&ctx, .{ .slices = f.patterns }, f.expected_flags, input);
    defer decoded.deinit(&ctx);
    @memset(input, 0xa5);
    t.allocator.free(input);
    input_live = false;
    try t.expect(decoded.inner.gpa.ptr == t.allocator.ptr);
    for (decoded.inner.voices) |voice| try t.expect(voice.dfa.allocator.ptr == t.allocator.ptr);
    const got = decoded.inner.longest("\xff\n", 0).?;
    try t.expectEqual(@as(usize, 2), got.len);
    try t.expectEqualSlices(u32, &.{ 0, 1 }, got.patterns);
    try t.expectEqual(before, native.determinizations);
}

test "munch-image: actual whole decode totals are exact and one short refuses" {
    const f = authored("attributed-two");
    var measured = Budget.trial();
    var measure_ctx = try Context.init(t.allocator, Limits.trial(), &measured, 0);
    var first = try load(&measure_ctx, .{ .slices = f.patterns }, f.expected_flags, f.bytes);
    const allocation = Budget.trial().allocation_left - measured.allocation_left;
    const work = Budget.trial().work_left - measured.work_left;
    first.deinit(&measure_ctx);
    try t.expectEqual(@as(u64, 0), measure_ctx.live);
    try t.expect(allocation > 0 and work > 176);
    var exact = Budget.trial();
    exact.allocation_left = allocation;
    exact.work_left = work;
    var exact_ctx = try Context.init(t.allocator, Limits.trial(), &exact, 0);
    var second = try load(&exact_ctx, .{ .slices = f.patterns }, f.expected_flags, f.bytes);
    second.deinit(&exact_ctx);
    try t.expectEqual(@as(u64, 0), exact.allocation_left);
    try t.expectEqual(@as(u64, 0), exact.work_left);
    try t.expectEqual(@as(u64, 0), exact_ctx.live);
    for ([_]bool{ false, true }) |allocation_short| {
        var short = Budget.trial();
        if (allocation_short) short.allocation_left = allocation - 1 else short.work_left = work - 1;
        var short_ctx = try Context.init(t.allocator, Limits.trial(), &short, 0);
        try t.expectError(error.BudgetExceeded, load(&short_ctx, .{ .slices = f.patterns }, f.expected_flags, f.bytes));
        try t.expectEqual(@as(u64, 0), short_ctx.live);
    }
}

test "munch-image: every decoder allocation failure unwinds without refund" {
    const f = authored("final-only-attributed");
    var successful = t.FailingAllocator.init(t.allocator, .{});
    var measured = Budget.trial();
    var measure_ctx = try Context.init(successful.allocator(), Limits.trial(), &measured, 0);
    var first = try load(&measure_ctx, .{ .slices = f.patterns }, f.expected_flags, f.bytes);
    const allocations = successful.alloc_index;
    first.deinit(&measure_ctx);
    try t.expectEqual(successful.allocated_bytes, successful.freed_bytes);
    for (0..allocations) |failure| {
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = failure });
        var budget = Budget.trial();
        var ctx = try Context.init(failing.allocator(), Limits.trial(), &budget, 0);
        try t.expectError(error.OutOfMemory, load(&ctx, .{ .slices = f.patterns }, f.expected_flags, f.bytes));
        try t.expect(failing.has_induced_failure);
        try t.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        try t.expectEqual(@as(u64, 0), ctx.live);
        try t.expect(budget.allocation_left < Budget.trial().allocation_left);
        try t.expect(budget.work_left < Budget.trial().work_left);
    }
}
