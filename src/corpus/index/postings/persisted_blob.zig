//! Pure codec and validation boundary for the persisted trigram-index blob.
//!
//! This module knows the native-endian CSR layout but owns no allocation, IO,
//! mapping lifetime, or query policy. Untrusted loaders validate every posting;
//! Gist's trusted local-cache loader validates the directory and defers the same
//! bounded group decoder until query time.

const std = @import("std");
const varint = @import("varint.zig");

pub const Error = error{BadFormat};

/// Local-machine cache format; v2 introduced CSR delta-varint posting bodies.
pub const format_version: u32 = 2;
const magic = "GISTIDX\x01";
pub const header_len = magic.len + 4 + 4 + 8 + 8;

pub const Header = struct {
    doc_count: u32,
    n_tri: usize,
    posting_count: u32,
};

/// Allocation-free view consumed by serialization and both validation tiers.
pub const Structure = struct {
    dir_tri: []const u32,
    dir_off: []const u32,
    dir_count: []const u32,
    body: []const u8,
    doc_count: u32,
    posting_count: u32,
};

pub const MappedRegions = struct {
    header: Header,
    dir_tri: []const u32,
    dir_off: []const u32,
    dir_count: []const u32,
    body: []const u8,

    pub fn structure(self: MappedRegions) Structure {
        return .{ .dir_tri = self.dir_tri, .dir_off = self.dir_off, .dir_count = self.dir_count, .body = self.body, .doc_count = self.header.doc_count, .posting_count = self.header.posting_count };
    }
};

pub fn serializedSize(s: Structure) usize {
    return header_len + (s.dir_tri.len + s.dir_off.len + s.dir_count.len) * @sizeOf(u32) + s.body.len;
}

pub fn writeInto(s: Structure, buf: []u8) usize {
    @memcpy(buf[0..magic.len], magic);
    std.mem.writeInt(u32, buf[magic.len..][0..4], format_version, .little);
    std.mem.writeInt(u32, buf[magic.len + 4 ..][0..4], s.doc_count, .little);
    std.mem.writeInt(u64, buf[magic.len + 8 ..][0..8], s.dir_tri.len, .little);
    std.mem.writeInt(u64, buf[magic.len + 16 ..][0..8], s.posting_count, .little);
    var off = header_len;
    for ([_][]const u32{ s.dir_tri, s.dir_off, s.dir_count }) |region| {
        const bytes = std.mem.sliceAsBytes(region);
        @memcpy(buf[off..][0..bytes.len], bytes);
        off += bytes.len;
    }
    @memcpy(buf[off..][0..s.body.len], s.body);
    return off + s.body.len;
}

pub fn parseHeader(bytes: []const u8) Error!Header {
    if (bytes.len < header_len or !std.mem.eql(u8, bytes[0..magic.len], magic)) return Error.BadFormat;
    if (std.mem.readInt(u32, bytes[magic.len..][0..4], .little) != format_version) return Error.BadFormat;
    const n64 = std.mem.readInt(u64, bytes[magic.len + 8 ..][0..8], .little);
    const pc64 = std.mem.readInt(u64, bytes[magic.len + 16 ..][0..8], .little);
    if (n64 > std.math.maxInt(usize) or pc64 > std.math.maxInt(u32)) return Error.BadFormat;
    const n_tri: usize = @intCast(n64);
    const dir_bytes = std.math.mul(usize, n_tri, @sizeOf(u32) * 3) catch return Error.BadFormat;
    const need = std.math.add(usize, header_len, dir_bytes) catch return Error.BadFormat;
    if (bytes.len < need) return Error.BadFormat;
    return .{
        .doc_count = std.mem.readInt(u32, bytes[magic.len + 4 ..][0..4], .little),
        .n_tri = n_tri,
        .posting_count = @intCast(pc64),
    };
}

/// Parse aligned zero-copy directory/body regions; the caller owns `bytes`.
pub fn parseMapped(bytes: []const u8) Error!MappedRegions {
    const header = try parseHeader(bytes);
    if (@intFromPtr(bytes.ptr) % @alignOf(u32) != 0) return Error.BadFormat;
    var off: usize = header_len;
    const dir_bytes = header.n_tri * @sizeOf(u32);
    var dirs: [3][]const u32 = undefined;
    for (&dirs) |*d| {
        d.* = std.mem.bytesAsSlice(u32, @as([]align(@alignOf(u32)) const u8, @alignCast(bytes[off..][0..dir_bytes])));
        off += dir_bytes;
    }
    return .{ .header = header, .dir_tri = dirs[0], .dir_off = dirs[1], .dir_count = dirs[2], .body = bytes[off..] };
}

/// O(distinct trigrams): validate layout/count invariants without reading body.
pub fn validateDirectory(s: Structure) Error!void {
    const n = s.dir_tri.len;
    if (s.dir_off.len != n or s.dir_count.len != n) return Error.BadFormat;
    if (n == 0) {
        if (s.body.len != 0 or s.posting_count != 0) return Error.BadFormat;
        return;
    }
    if (s.dir_off[0] != 0) return Error.BadFormat;
    var sum: u64 = 0;
    for (0..n) |i| {
        if (i > 0 and s.dir_tri[i] <= s.dir_tri[i - 1]) return Error.BadFormat;
        const count: usize = s.dir_count[i];
        if (count == 0 or count > s.doc_count) return Error.BadFormat;
        const start: usize = s.dir_off[i];
        const end: usize = if (i + 1 < n) s.dir_off[i + 1] else s.body.len;
        if (start > end or end > s.body.len) return Error.BadFormat;
        const max_len = std.math.mul(usize, count, varint.max_len) catch return Error.BadFormat;
        if (end - start < count or end - start > max_len) return Error.BadFormat;
        sum += s.dir_count[i];
    }
    if (sum != s.posting_count) return Error.BadFormat;
}

fn decodeBodyGroup(bytes: []const u8, count: u32, doc_count: u32, out: ?[]u32) Error!usize {
    const n: usize = count;
    if (n == 0 or n > doc_count) return Error.BadFormat;
    if (out) |dest| if (n > dest.len) return Error.BadFormat;
    var pos: usize = 0;
    var prev: u32 = 0;
    for (0..n) |i| {
        const decoded = varint.decodeBoundedCanonical(bytes[pos..], varint.max_len) catch return Error.BadFormat;
        pos += decoded.len;
        const doc = if (i == 0) decoded.value else blk: {
            if (decoded.value == 0) return Error.BadFormat;
            break :blk std.math.add(u32, prev, decoded.value) catch return Error.BadFormat;
        };
        if (doc >= doc_count) return Error.BadFormat;
        if (out) |dest| dest[i] = doc;
        prev = doc;
    }
    if (pos != bytes.len) return Error.BadFormat;
    return n;
}

/// O(postings): fully validate every canonical bounded posting group.
pub fn validateStructure(s: Structure) Error!void {
    try validateDirectory(s);
    for (0..s.dir_tri.len) |i| {
        const start: usize = s.dir_off[i];
        const end: usize = if (i + 1 < s.dir_off.len) s.dir_off[i + 1] else s.body.len;
        _ = try decodeBodyGroup(s.body[start..end], s.dir_count[i], s.doc_count, null);
    }
}

/// Validate and decode one touched group without escaping its directory region.
pub fn decodeGroup(s: Structure, gi: usize, out: []u32) Error!usize {
    if (s.dir_off.len != s.dir_tri.len or s.dir_count.len != s.dir_tri.len or gi >= s.dir_tri.len)
        return Error.BadFormat;
    const start: usize = s.dir_off[gi];
    const end: usize = if (gi + 1 < s.dir_off.len) s.dir_off[gi + 1] else s.body.len;
    if (start > end or end > s.body.len) return Error.BadFormat;
    return decodeBodyGroup(s.body[start..end], s.dir_count[gi], s.doc_count, out);
}
