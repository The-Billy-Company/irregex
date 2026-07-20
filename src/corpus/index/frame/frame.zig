//! frame — the wire discipline every persisted irregex artifact shares.
//!
//! One home for the framing primitives the index blobs are built from, so the
//! formats can't drift on conventions: little-endian fixed-width ints
//! (`putInt`) read back through a fail-closed byte cursor (`Cursor`),
//! length-prefixed u64-slice payloads (`putWords`/`Cursor.words`), and the
//! NUL-joined string tables every artifact uses for its path/roots catalogs
//! (`nulLen`/`joinNul` to write; `splitNulExact`/`parsePathTable`/
//! `ownedNulTable` to read), the shared `onDisk` deletion gate every folded
//! view checks at emit, and the shared `loadQuiet` fail-open artifact loader.
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

/// FNV-1a 64-bit over `bytes` — the integrity checksum every persisted
/// artifact (atlas, frag, …) appends and re-checks on load.
pub fn fnv64(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| h = (h ^ b) *% 0x100000001b3;
    return h;
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

/// Owned NUL-joined table + borrowing slices — the uniform ownership shape a
/// parsed artifact frees for its path/roots catalog: one heap blob (`nulLen`
/// bytes) plus a slice array that aliases into it. Free `.slices` then `.blob`.
pub fn ownedNulTable(gpa: std.mem.Allocator, entries: []const []const u8) !struct { blob: []u8, slices: []const []const u8 } {
    const blob = try gpa.alloc(u8, nulLen(entries));
    errdefer gpa.free(blob);
    const slices = try gpa.alloc([]const u8, entries.len);
    errdefer gpa.free(slices);
    var off: usize = 0;
    for (entries, slices) |e, *s| {
        @memcpy(blob[off .. off + e.len], e);
        blob[off + e.len] = 0;
        s.* = blob[off .. off + e.len];
        off += e.len + 1;
    }
    return .{ .blob = blob, .slices = slices };
}

/// Does `path` still exist as a file? The emit-time deletion gate every
/// folded-artifact consumer shares (O(results), not O(corpus)).
pub fn onDisk(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

/// Read + parse a persisted artifact, failing OPEN to null — the shared loader
/// every warm index shares. A missing file is the normal cold case (silent, the
/// caller answers live like `gist` without a trigram index); any other read
/// error or a `parse` failure (torn bytes) gets one stderr line naming `what`
/// and returns null so no answer is served from corruption.
pub fn loadQuiet(
    comptime T: type,
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    comptime what: []const u8,
    parse: fn (std.mem.Allocator, []const u8) anyerror!T,
) ?T {
    const blob = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |e| {
        if (e != error.FileNotFound)
            std.debug.print("relate: " ++ what ++ " unreadable ({s}) — answering live; `relate index` rebuilds\n", .{@errorName(e)});
        return null;
    };
    defer gpa.free(blob);
    return parse(gpa, blob) catch {
        std.debug.print("relate: corrupt " ++ what ++ " at {s} — answering live; `relate index` rebuilds\n", .{path});
        return null;
    };
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
