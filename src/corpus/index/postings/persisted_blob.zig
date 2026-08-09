//! Pure codec and validation boundary for the persisted trigram-index blob.
//!
//! This module knows the native-endian CSR layout but owns no allocation, IO,
//! mapping lifetime, or query policy. Untrusted loaders validate every posting;
//! Gist's trusted local-cache loader validates the directory and defers the same
//! bounded group decoder until query time.

const std = @import("std");
const fault = @import("../../../fault.zig");
const varint = @import("varint.zig");
const signet = @import("../frame/signet.zig");

pub const Error = fault.Persist;

/// Local-machine cache format; v2 introduced CSR delta-varint posting bodies,
/// v3 sealed the blob.
pub const format_version: u32 = 3;
const magic = "GISTIDX\x01";
pub const header_len = magic.len + 4 + 4 + 8 + 8;
/// Trailer width. A loader that slices the body by hand — rather than through
/// `parseMapped` — has to stop this far short of the end, or it hands the
/// digest to the posting decoder as if it were the last group.
pub const seal_len = signet.len;

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
    return header_len + (s.dir_tri.len + s.dir_off.len + s.dir_count.len) * @sizeOf(u32) + s.body.len + signet.len;
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
    signet.sealAt(buf, off + s.body.len);
    return off + s.body.len + signet.len;
}

/// Prove a mapped blob is the blob `writeInto` wrote.
///
/// DEFERRED, like the content shard's, and for the same reason: this loader's
/// contract is that it validates the directory in O(distinct trigrams) and
/// leaves the posting bodies untouched until a query reaches one, so the OS
/// faults in a few pages instead of ~42 MB. Digesting at load would undo that
/// on every single invocation to catch a fault that `validateStructure` mostly
/// catches for free. Callers that want the proof ask for it.
pub fn verify(bytes: []const u8) Error!void {
    signet.verify(bytes) catch return Error.Corrupt;
}

pub fn parseHeader(bytes: []const u8) Error!Header {
    if (bytes.len < header_len or !std.mem.eql(u8, bytes[0..magic.len], magic)) return Error.Corrupt;
    // A version the reader doesn't know is not damage — it is an older writer, and
    // the two call for opposite responses: rebuild the index versus distrust the
    // disk. The seal has already passed by the time this runs (`verify` precedes
    // `parseHeader` on the untrusted path), so these bytes are provably intact and
    // reporting them as `Corrupt` would send a caller hunting a fault that isn't.
    if (std.mem.readInt(u32, bytes[magic.len..][0..4], .little) != format_version) return Error.VersionMismatch;
    const n64 = std.mem.readInt(u64, bytes[magic.len + 8 ..][0..8], .little);
    const pc64 = std.mem.readInt(u64, bytes[magic.len + 16 ..][0..8], .little);
    if (n64 > std.math.maxInt(usize) or pc64 > std.math.maxInt(u32)) return Error.Corrupt;
    const n_tri: usize = @intCast(n64);
    const dir_bytes = std.math.mul(usize, n_tri, @sizeOf(u32) * 3) catch return Error.Corrupt;
    // The seal is part of the floor: without it in the minimum, a blob whose
    // directory ends exactly at EOF would let `parseMapped` slice a negative
    // body length out from under the trailer.
    const need = std.math.add(usize, header_len + signet.len, dir_bytes) catch return Error.Corrupt;
    if (bytes.len < need) return Error.Corrupt;
    return .{
        .doc_count = std.mem.readInt(u32, bytes[magic.len + 4 ..][0..4], .little),
        .n_tri = n_tri,
        .posting_count = @intCast(pc64),
    };
}

/// Parse aligned zero-copy directory/body regions; the caller owns `bytes`.
pub fn parseMapped(bytes: []const u8) Error!MappedRegions {
    const header = try parseHeader(bytes);
    if (@intFromPtr(bytes.ptr) % @alignOf(u32) != 0) return Error.Corrupt;
    var off: usize = header_len;
    const dir_bytes = header.n_tri * @sizeOf(u32);
    var dirs: [3][]const u32 = undefined;
    for (&dirs) |*d| {
        d.* = std.mem.bytesAsSlice(u32, @as([]align(@alignOf(u32)) const u8, @alignCast(bytes[off..][0..dir_bytes])));
        off += dir_bytes;
    }
    // The seal is a trailer, not payload: `body` must stop short of it or every
    // last-group bound check would measure the digest as postings.
    return .{ .header = header, .dir_tri = dirs[0], .dir_off = dirs[1], .dir_count = dirs[2], .body = bytes[off .. bytes.len - signet.len] };
}

/// O(distinct trigrams): validate layout/count invariants without reading body.
pub fn validateDirectory(s: Structure) Error!void {
    const n = s.dir_tri.len;
    if (s.dir_off.len != n or s.dir_count.len != n) return Error.Corrupt;
    if (n == 0) {
        if (s.body.len != 0 or s.posting_count != 0) return Error.Corrupt;
        return;
    }
    if (s.dir_off[0] != 0) return Error.Corrupt;
    var sum: u64 = 0;
    for (0..n) |i| {
        if (i > 0 and s.dir_tri[i] <= s.dir_tri[i - 1]) return Error.Corrupt;
        const count: usize = s.dir_count[i];
        if (count == 0 or count > s.doc_count) return Error.Corrupt;
        const start: usize = s.dir_off[i];
        const end: usize = if (i + 1 < n) s.dir_off[i + 1] else s.body.len;
        if (start > end or end > s.body.len) return Error.Corrupt;
        const max_len = std.math.mul(usize, count, varint.max_len) catch return Error.Corrupt;
        if (end - start < count or end - start > max_len) return Error.Corrupt;
        sum += s.dir_count[i];
    }
    if (sum != s.posting_count) return Error.Corrupt;
}

fn decodeBodyGroup(bytes: []const u8, count: u32, doc_count: u32, out: ?[]u32) Error!usize {
    const n: usize = count;
    if (n == 0 or n > doc_count) return Error.Corrupt;
    if (out) |dest| if (n > dest.len) return Error.Corrupt;
    var pos: usize = 0;
    var prev: u32 = 0;
    for (0..n) |i| {
        const decoded = varint.decodeBoundedCanonical(bytes[pos..], varint.max_len) catch return Error.Corrupt;
        pos += decoded.len;
        const doc = if (i == 0) decoded.value else blk: {
            if (decoded.value == 0) return Error.Corrupt;
            break :blk std.math.add(u32, prev, decoded.value) catch return Error.Corrupt;
        };
        if (doc >= doc_count) return Error.Corrupt;
        if (out) |dest| dest[i] = doc;
        prev = doc;
    }
    if (pos != bytes.len) return Error.Corrupt;
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
        return Error.Corrupt;
    const start: usize = s.dir_off[gi];
    const end: usize = if (gi + 1 < s.dir_off.len) s.dir_off[gi + 1] else s.body.len;
    if (start > end or end > s.body.len) return Error.Corrupt;
    return decodeBodyGroup(s.body[start..end], s.dir_count[gi], s.doc_count, out);
}
