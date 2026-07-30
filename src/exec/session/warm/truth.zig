//! Independent filesystem oracle shared by resident-session adversarial tests.

const std = @import("std");
const Dir = std.Io.Dir;

/// Scan the fixture's live-file ledger without calling the search engine.
pub fn files(corpus: anytype, out: *std.ArrayList([]const u8), needle: []const u8) !void {
    for (corpus.live.items) |rel| {
        const path = try std.fmt.allocPrint(corpus.a, "{s}/{s}", .{ corpus.root, rel });
        const bytes = Dir.cwd().readFileAlloc(corpus.io, path, corpus.a, .limited(1 << 20)) catch continue;
        defer corpus.a.free(bytes);
        if (std.mem.indexOf(u8, bytes, needle) != null) try out.append(corpus.a, path);
    }
    std.mem.sort([]const u8, out.items, {}, lessPath);
}

/// Compare a resident file-list answer with the independent disk scan.
pub fn expectFiles(session: anytype, corpus: anytype, gpa: std.mem.Allocator, needle: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var want: std.ArrayList([]const u8) = .empty;
    try files(corpus, &want, needle);
    const got = (try session.query(a, .{ .pattern = needle, .mode = .files, .fixed = true })).got;
    try std.testing.expectEqual(want.items.len, got.files.len);
    const sorted = try a.dupe([]const u8, got.files);
    std.mem.sort([]const u8, sorted, {}, lessPath);
    for (want.items, sorted) |w, g| try std.testing.expectEqualStrings(w, g);
}

fn lessPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
