//! frame — the wire discipline every persisted irregex artifact shares.
//!
//! One home for the framing primitives the index blobs are built from, so the
//! formats can't drift on conventions: little-endian fixed-width ints
//! (`putInt`) read back through a fail-closed byte cursor (`Cursor`),
//! length-prefixed u64-slice payloads (`putWords`/`Cursor.words`), and the
//! NUL-joined string tables every artifact uses for its path/roots catalogs
//! (`nulLen`/`joinNul` to write; `splitNulExact`/`parsePathTable` to read).
//! Consumers: the codex + shelf blobs (`../codex/`), the kinship atlas
//! (`../atlas/`), and the trigram pair loader (`../trigrams/persist.zig`).
//! Framing only — magic bytes, versions, and checksums stay with each format,
//! where the corruption story lives.

const std = @import("std");

pub fn putInt(gpa: std.mem.Allocator, out: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, v, .little);
    try out.appendSlice(gpa, &buf);
}

pub fn putWords(gpa: std.mem.Allocator, out: *std.ArrayList(u8), words: []const u64) !void {
    try putInt(gpa, out, u64, @intCast(words.len));
    for (words) |w| try putInt(gpa, out, u64, w);
}

/// A byte-slice cursor that fails closed instead of reading past the end.
pub const Cursor = struct {
    buf: []const u8,
    pos: usize,

    pub fn int(self: *Cursor, comptime T: type) !T {
        if (self.pos + @sizeOf(T) > self.buf.len) return error.Corrupt;
        defer self.pos += @sizeOf(T);
        return std.mem.readInt(T, self.buf[self.pos..][0..@sizeOf(T)], .little);
    }

    pub fn bytes(self: *Cursor, len: usize) ![]const u8 {
        if (len > self.buf.len - self.pos) return error.Corrupt;
        defer self.pos += len;
        return self.buf[self.pos..][0..len];
    }

    /// Owned u64 slice, length-prefixed, bounded by the remaining buffer.
    pub fn words(self: *Cursor, gpa: std.mem.Allocator) ![]u64 {
        const len = try self.int(u64);
        if (len > (self.buf.len - self.pos) / 8) return error.Corrupt;
        const out = try gpa.alloc(u64, @intCast(len));
        errdefer gpa.free(out);
        for (out) |*w| w.* = try self.int(u64);
        return out;
    }
};

/// Serialized size of `parts` as a NUL-terminated blob (each entry + its NUL).
pub fn nulLen(parts: []const []const u8) u64 {
    var total: u64 = 0;
    for (parts) |p| total += p.len + 1;
    return total;
}

/// Append `parts` as a NUL-terminated blob (the catalog write every artifact
/// shares — `nulLen(parts)` bytes, entry order preserved).
pub fn joinNul(gpa: std.mem.Allocator, out: *std.ArrayList(u8), parts: []const []const u8) !void {
    for (parts) |p| {
        try out.appendSlice(gpa, p);
        try out.append(gpa, 0);
    }
}

/// Split a NUL-terminated path blob into exactly `n` borrowed slices.
/// `require_nonempty` additionally rejects an empty entry (a torn table can
/// coalesce two NULs); either way the count must be exact. Caller frees.
pub fn splitNulExact(gpa: std.mem.Allocator, blob: []const u8, n: usize, comptime require_nonempty: bool) ![]const []const u8 {
    const parts = try gpa.alloc([]const u8, n);
    errdefer gpa.free(parts);
    var it = std.mem.splitScalar(u8, blob, 0);
    for (parts) |*p| {
        const piece = it.next() orelse return error.Corrupt;
        if (require_nonempty and piece.len == 0) return error.Corrupt;
        p.* = piece;
    }
    // exactly n entries: the remainder must be the empty tail after the last NUL
    if (it.next()) |tail| if (tail.len != 0 or it.next() != null) return error.Corrupt;
    return parts;
}

/// Split a mmap'd NUL-separated table (`paths.list` / `roots.list`, doc-id
/// order) into borrowed slices, dropping empties (a trailing NUL, or a
/// coalesced double-NUL). The slices alias `pmap`, which must outlive the
/// returned list. Factored out of the loaders so both the split and the count
/// invariant (`persist.validatePersistedPair`) are unit-testable without
/// touching the filesystem.
pub fn parsePathTable(gpa: std.mem.Allocator, pmap: []const u8) !std.ArrayList([]const u8) {
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer paths.deinit(gpa);
    try paths.ensureTotalCapacity(gpa, std.mem.count(u8, pmap, &[_]u8{0}) + 1);
    var pit = std.mem.splitScalar(u8, pmap, 0);
    while (pit.next()) |p| if (p.len > 0) paths.appendAssumeCapacity(p);
    return paths;
}
