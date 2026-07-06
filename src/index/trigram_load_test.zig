//! gist T0 index-loader ADVERSARIAL suite — split out per the shape cap, wired
//! via `root.zig`'s test block.
//!
//! `trigram_test.zig` round-trips WELL-FORMED indexes; this file does the
//! opposite — it hand-builds malformed CSR + delta-varint blobs and requires
//! `Index.fromBytes` / `Index.fromMappedBytes` to fail closed with
//! `LoadError.BadFormat`, never a panic, a silent accept, or a later
//! out-of-bounds read. The on-disk format is a native-endian, local rebuildable
//! cache (not a portable/untrusted artifact), but even a corrupt one must be
//! rejected rather than walked. Every case is a named hardening acceptance test:
//! read the name, know the invariant.

const std = @import("std");
const tri = @import("trigram.zig");
const vi = @import("varint.zig");

// ── blob builders ──────────────────────────────────────────────────────────

/// Serialize an arbitrary (possibly malformed) index blob. Header is
/// little-endian (matches `writeInto`); the directory arrays are native-endian
/// `u32` (matches `writeInto`'s `sliceAsBytes`).
fn makeBlob(
    a: std.mem.Allocator,
    doc_count: u32,
    posting_count: u64,
    dir_tri: []const u32,
    dir_off: []const u32,
    dir_count: []const u32,
    body: []const u8,
) ![]u8 {
    std.debug.assert(dir_tri.len == dir_off.len and dir_tri.len == dir_count.len);
    const n = dir_tri.len;
    const buf = try a.alloc(u8, tri.header_len + n * 12 + body.len);
    @memcpy(buf[0..8], "GISTIDX\x01");
    std.mem.writeInt(u32, buf[8..][0..4], tri.format_version, .little);
    std.mem.writeInt(u32, buf[12..][0..4], doc_count, .little);
    std.mem.writeInt(u64, buf[16..][0..8], @intCast(n), .little);
    std.mem.writeInt(u64, buf[24..][0..8], posting_count, .little);
    var off: usize = tri.header_len;
    for (dir_tri) |v| {
        std.mem.writeInt(u32, buf[off..][0..4], v, .native);
        off += 4;
    }
    for (dir_off) |v| {
        std.mem.writeInt(u32, buf[off..][0..4], v, .native);
        off += 4;
    }
    for (dir_count) |v| {
        std.mem.writeInt(u32, buf[off..][0..4], v, .native);
        off += 4;
    }
    @memcpy(buf[off..][0..body.len], body);
    return buf;
}

/// Require BOTH loaders to reject `bytes` with `BadFormat` — keeps the copying
/// and zero-copy paths equivalent. `fromMappedBytes` gets a 4-aligned copy so
/// the rejection is about content, not alignment (alignment has its own test).
fn expectBadFormatBoth(bytes: []const u8) !void {
    const a = std.testing.allocator;
    if (tri.Index.fromBytes(a, bytes)) |idx0| {
        var idx = idx0;
        idx.deinit();
        return error.AcceptedCorruptIndex;
    } else |err| try std.testing.expectEqual(tri.LoadError.BadFormat, err);

    const aligned = try a.alignedAlloc(u8, .fromByteUnits(@alignOf(u32)), bytes.len);
    defer a.free(aligned);
    @memcpy(aligned, bytes);
    if (tri.Index.fromMappedBytes(aligned)) |idx0| {
        var idx = idx0;
        idx.deinit();
        return error.AcceptedCorruptIndex;
    } else |err| try std.testing.expectEqual(tri.LoadError.BadFormat, err);
}

/// Load a (presumed well-formed) blob through BOTH paths and require they agree
/// (both accept or both reject); returns whether it was accepted.
fn bothAccept(bytes: []const u8) !bool {
    const a = std.testing.allocator;
    const copy_ok = if (tri.Index.fromBytes(a, bytes)) |idx0| blk: {
        var idx = idx0;
        idx.deinit();
        break :blk true;
    } else |_| false;

    const aligned = try a.alignedAlloc(u8, .fromByteUnits(@alignOf(u32)), bytes.len);
    defer a.free(aligned);
    @memcpy(aligned, bytes);
    const map_ok = if (tri.Index.fromMappedBytes(aligned)) |idx0| blk: {
        var idx = idx0;
        idx.deinit();
        break :blk true;
    } else |_| false;

    try std.testing.expectEqual(copy_ok, map_ok); // the two loaders must never disagree
    return copy_ok;
}

// ── accept cases (round-tripped through the real builder) ────────────────────

test "load accepts a canonical empty index" {
    const a = std.testing.allocator;
    var idx = try tri.Index.build(a, &.{});
    defer idx.deinit();
    const blob = try a.alloc(u8, idx.serializedSize());
    defer a.free(blob);
    _ = idx.writeInto(blob);
    try std.testing.expect(try bothAccept(blob));
}

test "load accepts doc_count > 0 with zero trigrams (all docs < 3 bytes)" {
    const a = std.testing.allocator;
    const docs = [_][]const u8{ "a", "bb", "" };
    var idx = try tri.Index.build(a, &docs);
    defer idx.deinit();
    try std.testing.expectEqual(@as(usize, 0), idx.dir_tri.len);
    try std.testing.expectEqual(@as(u32, 3), idx.doc_count);
    const blob = try a.alloc(u8, idx.serializedSize());
    defer a.free(blob);
    _ = idx.writeInto(blob);
    try std.testing.expect(try bothAccept(blob));
}

test "load accepts a normal multi-trigram index" {
    const a = std.testing.allocator;
    const docs = [_][]const u8{ "hello world", "hello there", "world peace" };
    var idx = try tri.Index.build(a, &docs);
    defer idx.deinit();
    const blob = try a.alloc(u8, idx.serializedSize());
    defer a.free(blob);
    _ = idx.writeInto(blob);
    try std.testing.expect(try bothAccept(blob));
}

// ── header + directory boundary rejects ──────────────────────────────────────

test "load rejects a bad magic / short header" {
    const a = std.testing.allocator;
    try expectBadFormatBoth(&[_]u8{0} ** 8); // shorter than header_len
    const blob = try makeBlob(a, 1, 1, &.{7}, &.{0}, &.{1}, &[_]u8{0x00});
    defer a.free(blob);
    blob[0] = 'X'; // corrupt magic
    try expectBadFormatBoth(blob);
}

test "load rejects a truncated directory" {
    const a = std.testing.allocator;
    const blob = try makeBlob(a, 1, 1, &.{7}, &.{0}, &.{1}, &[_]u8{0x00});
    defer a.free(blob);
    try expectBadFormatBoth(blob[0 .. blob.len - 6]); // chop into the directory
}

test "load rejects posting_count greater than u32 max" {
    const a = std.testing.allocator;
    const blob = try makeBlob(a, 0, @as(u64, 1) << 32, &.{}, &.{}, &.{}, &.{});
    defer a.free(blob);
    try expectBadFormatBoth(blob);
}

test "load rejects a nonempty body when n_tri == 0" {
    const a = std.testing.allocator;
    const blob = try makeBlob(a, 1, 0, &.{}, &.{}, &.{}, &[_]u8{ 0x00, 0x00 });
    defer a.free(blob);
    try expectBadFormatBoth(blob);
}

test "load rejects dir_tri not strictly ascending (and duplicates)" {
    const a = std.testing.allocator;
    const body = [_]u8{ 0x00, 0x00 }; // two 1-posting groups, doc id 0 each
    const desc = try makeBlob(a, 1, 2, &.{ 5, 3 }, &.{ 0, 1 }, &.{ 1, 1 }, &body);
    defer a.free(desc);
    try expectBadFormatBoth(desc);
    const dup = try makeBlob(a, 1, 2, &.{ 5, 5 }, &.{ 0, 1 }, &.{ 1, 1 }, &body);
    defer a.free(dup);
    try expectBadFormatBoth(dup);
}

test "load rejects a zero-count directory entry" {
    const a = std.testing.allocator;
    const blob = try makeBlob(a, 1, 0, &.{7}, &.{0}, &.{0}, &.{});
    defer a.free(blob);
    try expectBadFormatBoth(blob);
}

test "load rejects sum(dir_count) != posting_count" {
    const a = std.testing.allocator;
    const blob = try makeBlob(a, 1, 5, &.{7}, &.{0}, &.{1}, &[_]u8{0x00});
    defer a.free(blob);
    try expectBadFormatBoth(blob);
}

test "load rejects dir_off[0] != 0" {
    const a = std.testing.allocator;
    const blob = try makeBlob(a, 1, 1, &.{7}, &.{1}, &.{1}, &[_]u8{0x00});
    defer a.free(blob);
    try expectBadFormatBoth(blob);
}

test "load rejects dir_off past body length / nonmonotonic" {
    const a = std.testing.allocator;
    const past = try makeBlob(a, 1, 1, &.{7}, &.{9}, &.{1}, &[_]u8{0x00});
    defer a.free(past);
    try expectBadFormatBoth(past);
    // two groups whose offsets go backwards
    const body = [_]u8{ 0x00, 0x00 };
    const nonmono = try makeBlob(a, 1, 2, &.{ 3, 7 }, &.{ 1, 0 }, &.{ 1, 1 }, &body);
    defer a.free(nonmono);
    try expectBadFormatBoth(nonmono);
}

test "load rejects a gap between a decoded group end and the next dir_off" {
    const a = std.testing.allocator;
    // group 0 claims count 1 at off 0 but the next group starts at 2, leaving a
    // 1-byte gap the decoder never consumes (pos 1 != group_end 2).
    const body = [_]u8{ 0x00, 0x00, 0x00 };
    const blob = try makeBlob(a, 1, 2, &.{ 3, 7 }, &.{ 0, 2 }, &.{ 1, 1 }, &body);
    defer a.free(blob);
    try expectBadFormatBoth(blob);
}

test "load rejects trailing garbage after the last group" {
    const a = std.testing.allocator;
    const body = [_]u8{ 0x00, 0x77 }; // group consumes 1 byte, 1 trailing byte remains
    const blob = try makeBlob(a, 1, 1, &.{7}, &.{0}, &.{1}, &body);
    defer a.free(blob);
    try expectBadFormatBoth(blob);
}

// ── varint-body rejects ──────────────────────────────────────────────────────

test "load rejects a truncated varint" {
    const a = std.testing.allocator;
    const blob = try makeBlob(a, 4, 1, &.{7}, &.{0}, &.{1}, &[_]u8{0x80}); // continuation, no terminator
    defer a.free(blob);
    try expectBadFormatBoth(blob);
}

test "load rejects a varint longer than five bytes" {
    const a = std.testing.allocator;
    const body = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 };
    const blob = try makeBlob(a, 4, 1, &.{7}, &.{0}, &.{1}, &body);
    defer a.free(blob);
    try expectBadFormatBoth(blob);
}

test "load rejects overlong encodings of zero and one" {
    const a = std.testing.allocator;
    const z = try makeBlob(a, 4, 1, &.{7}, &.{0}, &.{1}, &[_]u8{ 0x80, 0x00 });
    defer a.free(z);
    try expectBadFormatBoth(z);
    const o = try makeBlob(a, 4, 1, &.{7}, &.{0}, &.{1}, &[_]u8{ 0x81, 0x00 });
    defer a.free(o);
    try expectBadFormatBoth(o);
}

test "load rejects a group varint crossing into the next group" {
    const a = std.testing.allocator;
    // group 0 spans body[0..1] = {0x80}: a continuation byte with no terminator
    // inside its own bounds, even though byte 1 would terminate it.
    const body = [_]u8{ 0x80, 0x01 };
    const blob = try makeBlob(a, 4, 2, &.{ 3, 7 }, &.{ 0, 1 }, &.{ 1, 1 }, &body);
    defer a.free(blob);
    try expectBadFormatBoth(blob);
}

// ── doc-id rejects ───────────────────────────────────────────────────────────

test "load rejects a first doc id >= doc_count" {
    const a = std.testing.allocator;
    const blob = try makeBlob(a, 1, 1, &.{7}, &.{0}, &.{1}, &[_]u8{0x01}); // doc 1, doc_count 1
    defer a.free(blob);
    try expectBadFormatBoth(blob);
}

test "load rejects a second delta of zero (non-ascending doc ids)" {
    const a = std.testing.allocator;
    const blob = try makeBlob(a, 3, 2, &.{7}, &.{0}, &.{2}, &[_]u8{ 0x00, 0x00 }); // doc 0, then delta 0
    defer a.free(blob);
    try expectBadFormatBoth(blob);
}

test "load rejects a cumulative doc id >= doc_count" {
    const a = std.testing.allocator;
    const blob = try makeBlob(a, 10, 2, &.{7}, &.{0}, &.{2}, &[_]u8{ 0x09, 0x02 }); // 9 then 9+2=11 >= 10
    defer a.free(blob);
    try expectBadFormatBoth(blob);
}

test "load rejects a cumulative doc id overflow" {
    const a = std.testing.allocator;
    var bodybuf: [8]u8 = undefined;
    const n0 = vi.encode(bodybuf[0..], std.math.maxInt(u32) - 1);
    const n1 = vi.encode(bodybuf[n0..], 10); // (maxu32 - 1) + 10 wraps u32
    const blob = try makeBlob(a, std.math.maxInt(u32), 2, &.{7}, &.{0}, &.{2}, bodybuf[0 .. n0 + n1]);
    defer a.free(blob);
    try expectBadFormatBoth(blob);
}

// ── mmap-path alignment ──────────────────────────────────────────────────────

test "fromMappedBytes rejects a misaligned directory start instead of trapping" {
    const a = std.testing.allocator;
    const blob = try makeBlob(a, 3, 1, &.{7}, &.{0}, &.{1}, &[_]u8{0x00});
    defer a.free(blob);
    // fromBytes copies, so it accepts the (valid) content regardless of alignment.
    var ok = try tri.Index.fromBytes(a, blob);
    ok.deinit();
    // A 1-byte-offset slice is not 4-aligned: fromMappedBytes must fail closed.
    const raw = try a.alignedAlloc(u8, .fromByteUnits(4), blob.len + 1);
    defer a.free(raw);
    @memcpy(raw[1..][0..blob.len], blob);
    try std.testing.expectError(tri.LoadError.BadFormat, tri.Index.fromMappedBytes(raw[1..][0..blob.len]));
}

// ── mutation fuzz-lite (CI-safe) ─────────────────────────────────────────────

test "fuzz-lite: mutated serialized indexes are rejected or safely accepted, both loaders agree" {
    const a = std.testing.allocator;
    const corpora = [_][]const []const u8{
        &.{"abcabc"},
        &.{ "hello", "world", "held" },
        &.{ "aaa", "aab", "aac", "aad" },
        &.{ "the quick brown fox", "the lazy dog", "quick brown" },
    };
    var prng = std.Random.DefaultPrng.init(0xBEEF);
    const rng = prng.random();
    for (corpora) |docs| {
        var idx = try tri.Index.build(a, docs);
        defer idx.deinit();
        const blob = try a.alloc(u8, idx.serializedSize());
        defer a.free(blob);
        _ = idx.writeInto(blob);
        try std.testing.expect(try bothAccept(blob)); // pristine loads through both paths

        for (0..400) |_| {
            const m = try a.dupe(u8, blob);
            defer a.free(m);
            const pos = rng.uintLessThan(usize, m.len);
            m[pos] ^= @as(u8, 1) << @intCast(rng.uintLessThan(u32, 8));
            // Either both loaders reject with BadFormat, or both accept a blob the
            // validator proved safe — never a panic, OOB, or silent disagreement.
            _ = try bothAccept(m);
        }
    }
}
