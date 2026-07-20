//! gist resident session — the faithful in-RAM mirror of the walked tree
//! (ADR-352 rung 2.5).
//!
//! `load` reads a pre-selected path list (the certified rg-default walk,
//! `runtime/cold/engine/serial.zig::defaultFileSet`) into resident documents with the
//! SAME per-file ingest the cold engine applies, so the warm corpus is a true
//! mirror of what a cold run would read — not an approximation of it:
//!
//!   • **Full reads, no cap.** ripgrep has no default max file size; only an
//!     explicit `--max-filesize` (ineligible warm) caps a read. The old
//!     `corpus.loadPaths` capped at the 4 MiB indexing budget and silently
//!     dropped anything larger — a >4 MiB text file that matched was missing
//!     from every warm answer. The memory bound is unchanged in kind: cold's
//!     own `collectFiles` reads the whole candidate corpus into RAM on EVERY
//!     query; the mirror just keeps that one corpus resident.
//!   • **BOM ingest (`grepfile.decodeBom`).** A UTF-8 BOM is stripped; a
//!     UTF-16 LE/BE BOM transcodes the whole file to UTF-8 — so a UTF-16 doc
//!     matches a UTF-8 pattern warm exactly as it does cold, instead of being
//!     mis-sniffed as binary (its NULs) and dropped.
//!   • **Binary docs are ADMITTED, with their first-NUL offset recorded.** Cold
//!     does not skip a walked binary file — it searches up to the buffer that
//!     revealed the first NUL (`grepfile.handleBinary`), which can emit for
//!     `-l`/lines. The old 8 KiB-window `isBinary` skip made warm diverge on
//!     any file whose first NUL sits past 8 KiB. The mirror scans the WHOLE
//!     decoded body once at ingest (`nul`, the same `indexOfScalar` the cold
//!     run loop performs per query) and lets each mode apply cold's own rule.
//!   • **Empty docs are skipped.** Cold's emit loop skips a zero-length body in
//!     every mode, so an empty file can never contribute output or a match.
//!
//! Documents and path strings live in one arena (freed as a unit); `docs` is a
//! plain `[][]const u8` so the trigram index builds over it directly.

const std = @import("std");
const grepfile = @import("../cold/read/grepfile.zig");
const Dir = std.Io.Dir;

/// One faithfully ingested document body: decoded bytes plus the byte offset of
/// the first NUL (null ⇒ text). `null` bytes ⇒ the file read empty/unreadable.
pub const Doc = struct { bytes: []const u8, nul: ?usize };

/// Read + ingest one file exactly as the cold engine would: full read (no cap),
/// BOM decode, whole-body NUL scan. Returns null when the file is unreadable or
/// decodes to empty — the two cases that can never produce cold output. All
/// returned bytes are owned by `a`.
pub fn readDoc(a: std.mem.Allocator, io: std.Io, path: []const u8) ?Doc {
    const raw = Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch return null;
    const body = grepfile.decodeBom(a, raw);
    if (body.len == 0) return null;
    return .{ .bytes = body, .nul = std.mem.indexOfScalar(u8, body, 0) };
}

/// A `readDoc` twin for the mutation overlay, whose entries are freed one at a
/// time: `bytes` is always a whole `gpa` allocation (`gpa.free(bytes)`-able),
/// never an interior slice. The three decode outcomes are normalized — an
/// untouched body keeps its read buffer, a stripped UTF-8 BOM re-dupes the
/// suffix, a UTF-16 transcode frees the raw read.
pub const OwnedDoc = struct { bytes: []u8, nul: ?usize };

pub fn readDocOwned(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?OwnedDoc {
    const raw = Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch return null;
    const body = grepfile.decodeBom(gpa, raw);
    const owned: []u8 = if (body.ptr == raw.ptr and body.len == raw.len)
        raw // untouched
    else blk: {
        // UTF-8 BOM strip: `body` is `raw[3..]` (an interior slice — freeing
        // `raw` frees it) — re-own it as a fresh allocation.
        // UTF-16 transcode: `body` is a fresh allocation typed `[]const u8`
        // (decodeBom). Re-own as `[]u8` without `@constCast` — dupe then free.
        const interior = @intFromPtr(body.ptr) >= @intFromPtr(raw.ptr) and
            @intFromPtr(body.ptr) <= @intFromPtr(raw.ptr) + raw.len;
        defer if (!interior) gpa.free(body);
        defer gpa.free(raw);
        break :blk gpa.dupe(u8, body) catch return null;
    };
    if (owned.len == 0) {
        gpa.free(owned);
        return null;
    }
    return .{ .bytes = owned, .nul = std.mem.indexOfScalar(u8, owned, 0) };
}

/// Count lines over the region cold actually searches, by rg's line model
/// (`\n` terminates; a body not ending in `\n` carries one final partial line;
/// empty ⇒ 0). For a binary doc (`nul` set) that region is the whole complete
/// buffers BEFORE the one that first revealed the NUL — the same cut
/// `grepfile.handleBinary` / the `-l` accumulator apply — so a cached count is
/// directly the `-v` complement denominator with no per-query rescan. This is a
/// CORPUS INVARIANT (base doc bytes never mutate in place; a changed file is
/// re-read into the overlay, which recomputes its own count), so it is paid
/// once at load, ~0 per query.
pub fn gatedLineCount(bytes: []const u8, nul: ?usize) u32 {
    const gated = if (nul) |n| bytes[0 .. (n / grepfile.BUFCAP) * grepfile.BUFCAP] else bytes;
    if (gated.len == 0) return 0;
    var n: u32 = @intCast(std.mem.count(u8, gated, "\n"));
    if (gated[gated.len - 1] != '\n') n += 1;
    return n;
}

/// The warm session's resident corpus: parallel doc/path/nul arrays over one
/// arena. Shape-compatible with `Index.build` (`docs` is the raw slice list).
pub const Mirror = struct {
    docs: [][]const u8,
    paths: [][]const u8,
    nuls: []?usize,
    /// Per-doc cached `gatedLineCount` — the `-v` set-complement denominator
    /// (`non_matching = lines(f) − matching(f)`), so a non-candidate file
    /// answers invert with ZERO scan. Parallel to `docs`/`paths`/`nuls`.
    lines: []u32,
    bytes: u64,
    /// Σ `lines` — the corpus-wide invariant `TOTAL_CORPUS_LINES`.
    total_lines: u64,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Mirror) void {
        self.arena.deinit();
    }
};

/// Load an explicit, pre-selected path list into a faithful corpus (no walk —
/// the caller supplies the authoritative rg-default file set). A path that
/// vanished or read empty since selection is simply dropped, exactly as cold's
/// deferred read drops it. Path strings are duped into the arena, so the
/// caller's slice may be freed.
pub fn load(gpa: std.mem.Allocator, io: std.Io, in_paths: []const []const u8) !Mirror {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var docs: std.ArrayList([]const u8) = .empty;
    var paths: std.ArrayList([]const u8) = .empty;
    var nuls: std.ArrayList(?usize) = .empty;
    var lines: std.ArrayList(u32) = .empty;
    var total: u64 = 0;
    var total_lines: u64 = 0;
    for (in_paths) |p| {
        const doc = readDoc(a, io, p) orelse continue;
        const nlines = gatedLineCount(doc.bytes, doc.nul);
        try docs.append(a, doc.bytes);
        try paths.append(a, try a.dupe(u8, p));
        try nuls.append(a, doc.nul);
        try lines.append(a, nlines);
        total += doc.bytes.len;
        total_lines += nlines;
    }
    return .{ .docs = docs.items, .paths = paths.items, .nuls = nuls.items, .lines = lines.items, .bytes = total, .total_lines = total_lines, .arena = arena };
}

test "readDoc: BOM decode, whole-body NUL offset, empty/unreadable → null" {
    const t = std.testing;
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try std.fmt.allocPrint(a, "/tmp/gist_mirror_{x}", .{@intFromPtr(&threaded)});
    Dir.cwd().deleteTree(io, root) catch {};
    try Dir.cwd().createDirPath(io, root);
    defer Dir.cwd().deleteTree(io, root) catch {};
    const P = struct {
        fn p(aa: std.mem.Allocator, r: []const u8, rel: []const u8) ![]const u8 {
            return std.fmt.allocPrint(aa, "{s}/{s}", .{ r, rel });
        }
    };

    // UTF-16 LE with BOM: decoded to UTF-8, its encoding NULs never counted.
    try Dir.cwd().writeFile(io, .{ .sub_path = try P.p(a, root, "u16.txt"), .data = "\xFF\xFEn\x00e\x00e\x00d\x00l\x00e\x00" });
    const u16doc = readDoc(a, io, try P.p(a, root, "u16.txt")).?;
    try t.expectEqualStrings("needle", u16doc.bytes);
    try t.expectEqual(@as(?usize, null), u16doc.nul);

    // UTF-8 BOM stripped; body indexes are post-BOM (cold's `^` anchor view).
    try Dir.cwd().writeFile(io, .{ .sub_path = try P.p(a, root, "bom8.txt"), .data = "\xEF\xBB\xBFhello\n" });
    try t.expectEqualStrings("hello\n", readDoc(a, io, try P.p(a, root, "bom8.txt")).?.bytes);

    // Binary is ADMITTED with its first-NUL offset (not window-limited).
    try Dir.cwd().writeFile(io, .{ .sub_path = try P.p(a, root, "bin.dat"), .data = "match\x00tail" });
    try t.expectEqual(@as(?usize, 5), readDoc(a, io, try P.p(a, root, "bin.dat")).?.nul);

    // Empty and missing files are dropped.
    try Dir.cwd().writeFile(io, .{ .sub_path = try P.p(a, root, "empty.txt"), .data = "" });
    try t.expectEqual(@as(?Doc, null), readDoc(a, io, try P.p(a, root, "empty.txt")));
    try t.expectEqual(@as(?Doc, null), readDoc(a, io, try P.p(a, root, "gone.txt")));
}

test "readDocOwned: every decode outcome yields a gpa-free-able allocation" {
    const t = std.testing;
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try std.fmt.allocPrint(a, "/tmp/gist_mirror_owned_{x}", .{@intFromPtr(&threaded)});
    Dir.cwd().deleteTree(io, root) catch {};
    try Dir.cwd().createDirPath(io, root);
    defer Dir.cwd().deleteTree(io, root) catch {};

    const plain = try std.fmt.allocPrint(a, "{s}/plain.txt", .{root});
    const bom8 = try std.fmt.allocPrint(a, "{s}/bom8.txt", .{root});
    const u16le = try std.fmt.allocPrint(a, "{s}/u16.txt", .{root});
    try Dir.cwd().writeFile(io, .{ .sub_path = plain, .data = "needle\x00tail" });
    try Dir.cwd().writeFile(io, .{ .sub_path = bom8, .data = "\xEF\xBB\xBFhello" });
    try Dir.cwd().writeFile(io, .{ .sub_path = u16le, .data = "\xFF\xFEh\x00i\x00" });

    // testing.allocator leak-checks every path: a mis-owned interior slice
    // would trip its invalid-free assertion right here.
    const d1 = readDocOwned(t.allocator, io, plain).?;
    try t.expectEqualStrings("needle\x00tail", d1.bytes);
    try t.expectEqual(@as(?usize, 6), d1.nul);
    t.allocator.free(d1.bytes);

    const d2 = readDocOwned(t.allocator, io, bom8).?;
    try t.expectEqualStrings("hello", d2.bytes);
    t.allocator.free(d2.bytes);

    const d3 = readDocOwned(t.allocator, io, u16le).?;
    try t.expectEqualStrings("hi", d3.bytes);
    try t.expectEqual(@as(?usize, null), d3.nul);
    t.allocator.free(d3.bytes);

    // A BOM-only file decodes to empty → dropped, nothing leaked.
    const bomonly = try std.fmt.allocPrint(a, "{s}/bomonly.txt", .{root});
    try Dir.cwd().writeFile(io, .{ .sub_path = bomonly, .data = "\xEF\xBB\xBF" });
    try t.expectEqual(@as(?OwnedDoc, null), readDocOwned(t.allocator, io, bomonly));
}

test "load: admits binary + oversize-decoded docs, drops empties, dupes paths" {
    const t = std.testing;
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try std.fmt.allocPrint(a, "/tmp/gist_mirror_load_{x}", .{@intFromPtr(&threaded)});
    Dir.cwd().deleteTree(io, root) catch {};
    try Dir.cwd().createDirPath(io, root);
    defer Dir.cwd().deleteTree(io, root) catch {};

    const text = try std.fmt.allocPrint(a, "{s}/a.txt", .{root});
    const bin = try std.fmt.allocPrint(a, "{s}/b.dat", .{root});
    const empty = try std.fmt.allocPrint(a, "{s}/c.txt", .{root});
    try Dir.cwd().writeFile(io, .{ .sub_path = text, .data = "needle\n" });
    try Dir.cwd().writeFile(io, .{ .sub_path = bin, .data = "x\x00y" });
    try Dir.cwd().writeFile(io, .{ .sub_path = empty, .data = "" });

    var m = try load(t.allocator, io, &.{ text, bin, empty });
    defer m.deinit();
    try t.expectEqual(@as(usize, 2), m.docs.len);
    try t.expectEqualStrings(text, m.paths[0]);
    try t.expectEqual(@as(?usize, null), m.nuls[0]);
    try t.expectEqualStrings(bin, m.paths[1]);
    try t.expectEqual(@as(?usize, 1), m.nuls[1]);
    try t.expectEqual(@as(u64, "needle\n".len + "x\x00y".len), m.bytes);
    // Cached line counts: the text file is one `\n`-terminated line; the binary
    // file's first NUL sits in the first buffer, so its gated region is empty
    // (zero searchable lines — cold suppresses it), and `total_lines` sums them.
    try t.expectEqual(@as(u32, 1), m.lines[0]);
    try t.expectEqual(@as(u32, 0), m.lines[1]);
    try t.expectEqual(@as(u64, 1), m.total_lines);
}

test "gatedLineCount: rg line model over text and pre-NUL binary regions" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 0), gatedLineCount("", null));
    try t.expectEqual(@as(u32, 3), gatedLineCount("a\nb\nc\n", null)); // trailing \n
    try t.expectEqual(@as(u32, 3), gatedLineCount("a\nb\nc", null)); // partial final line
    try t.expectEqual(@as(u32, 1), gatedLineCount("solo", null));
    try t.expectEqual(@as(u32, 2), gatedLineCount("a\n\n", null)); // blank line counts
    // A NUL inside the first buffer ⇒ empty gated region ⇒ 0 (cold suppresses it).
    try t.expectEqual(@as(u32, 0), gatedLineCount("x\x00y", 1));
}
