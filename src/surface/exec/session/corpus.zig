//! gist resident session — the faithful in-RAM mirror of the walked tree
//! (ADR-352 rung 2.5).
//!
//! `load` reads a pre-selected path list (the certified rg-default walk,
//! `surface/exec/cold/engine/serial.zig::defaultFileSet`) into resident documents with the
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
//!
//! ## Two-tier byte store (ADR-352 rung 2.5)
//!
//! An unchanged corpus file's bytes need not be re-read into the heap: `gist
//! index` already concatenated every member body into the mmap'd, page-cache-
//! evictable `content.shard` ([content/shard.zig](../../../corpus/index/content/shard.zig)).
//! `load` binds each walked file to that mapping when the T3 freshness gate
//! proves it byte-identical (`View.slice`), and only HEAP-reads the exceptions —
//! a file changed since the shard anchor, new, binary, oversize (> `per_file_cap`),
//! BOM-carrying (the mapping holds RAW bytes; the mirror needs decoded ones), or
//! present only because no shard is on disk. Resident heap thus falls from
//! O(corpus) to O(churn + exceptions), and the mapping's pages evict under
//! pressure. With no shard the store is byte-identical to the old full-heap
//! mirror (fail-open). The `View` lives for the `Mirror`'s lifetime; every
//! `nul`/`lines` invariant is computed the same way over either tier.

const std = @import("std");
const grepfile = @import("../cold/read/grepfile.zig");
const shard = @import("../../../corpus/index/content/shard.zig");
const path_utils = @import("../../../corpus/scope/paths.zig");
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
    /// The `content.shard` mapping backing every shard-tier doc (`docs[i]` may
    /// alias `view.content`). Held for the mirror's lifetime — the shard-bound
    /// slices dangle without it — and `null` when no shard was on disk (every
    /// doc then lives in `arena`, the classic full-heap mirror).
    view: ?shard.View = null,

    pub fn deinit(self: *Mirror) void {
        self.arena.deinit();
        if (self.view) |*v| v.deinit();
    }
};

/// The three BOM prefixes `grepfile.decodeBom` acts on. A shard slice holds RAW
/// bytes; when a file opens with a BOM the mirror's decoded bytes differ from
/// the slice, so that file must take the heap tier (where `readDoc` decodes). A
/// UTF-16 BOM file is never a shard member anyway — its encoding NULs trip
/// binary detection at index time — but checking all three keeps this predicate
/// aligned with `decodeBom` regardless of what a future shard admits.
fn bomAtStart(b: []const u8) bool {
    return std.mem.startsWith(u8, b, "\xEF\xBB\xBF") or
        std.mem.startsWith(u8, b, "\xFF\xFE") or
        std.mem.startsWith(u8, b, "\xFE\xFF");
}

/// Bind one walked path to the shard mapping when it is provably byte-identical:
/// a doc-table member, unchanged since the shard anchor (`View.slice`'s T3 gate
/// over the file's live mtime/ctime), and not BOM-led. The returned bytes ALIAS
/// the mapping (zero heap). Null on any miss — the caller heap-reads via
/// `readDoc`, so the mirror is byte-identical whether or not a shard exists.
fn shardBind(v: *const shard.View, io: std.Io, path: []const u8) ?Doc {
    const st = Dir.cwd().statFile(io, path, .{}) catch return null;
    const raw = v.slice(path_utils.stripDot(path), st.mtime.nanoseconds, st.ctime.nanoseconds) orelse return null;
    if (raw.len == 0 or bomAtStart(raw)) return null;
    return .{ .bytes = raw, .nul = std.mem.indexOfScalar(u8, raw, 0) };
}

/// Load an explicit, pre-selected path list into a faithful corpus (no walk —
/// the caller supplies the authoritative rg-default file set), binding unchanged
/// files to the on-disk `content.shard` and heap-reading the rest. A path that
/// vanished or read empty since selection is simply dropped, exactly as cold's
/// deferred read drops it. Path strings are duped into the arena, so the
/// caller's slice may be freed.
pub fn load(gpa: std.mem.Allocator, io: std.Io, in_paths: []const []const u8) !Mirror {
    return loadWithView(gpa, io, in_paths, shard.load(gpa, io));
}

/// `load` with the shard mapping injected — the seam a test drives with a
/// purpose-built `View` (and `null` reproduces the classic full-heap mirror).
/// Takes ownership of `view_in`: it rides in the returned `Mirror` (freed by
/// `Mirror.deinit`) or is unmapped if the load fails.
pub fn loadWithView(gpa: std.mem.Allocator, io: std.Io, in_paths: []const []const u8, view_in: ?shard.View) !Mirror {
    var view = view_in;
    errdefer if (view) |*v| v.deinit();
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
        // Shard tier (bytes alias the mmap, zero heap) or heap tier — the two
        // are byte-identical for an unchanged, non-BOM member; every downstream
        // invariant is computed the same over whichever the file lands in.
        const doc = (if (view) |*v| shardBind(v, io, p) else null) orelse (readDoc(a, io, p) orelse continue);
        const nlines = gatedLineCount(doc.bytes, doc.nul);
        try docs.append(a, doc.bytes);
        try paths.append(a, try a.dupe(u8, p));
        try nuls.append(a, doc.nul);
        try lines.append(a, nlines);
        total += doc.bytes.len;
        total_lines += nlines;
    }
    return .{ .docs = docs.items, .paths = paths.items, .nuls = nuls.items, .lines = lines.items, .bytes = total, .total_lines = total_lines, .arena = arena, .view = view };
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

/// Does `slice` point INTO `region` — i.e. did this doc bind the shard mapping
/// (the shard tier) rather than a heap read (the arena tier)?
fn within(slice: []const u8, region: []const u8) bool {
    const s = @intFromPtr(slice.ptr);
    const lo = @intFromPtr(region.ptr);
    return region.len != 0 and s >= lo and s < lo + region.len;
}

/// Every mirror invariant must be byte-identical across the two tiers: a
/// shard-backed load and a full-heap load of the SAME walk agree doc-for-doc.
fn expectMirrorParity(a: *Mirror, b: *Mirror) !void {
    const t = std.testing;
    try t.expectEqual(a.docs.len, b.docs.len);
    try t.expectEqual(a.bytes, b.bytes);
    try t.expectEqual(a.total_lines, b.total_lines);
    for (a.docs, a.paths, a.nuls, a.lines, 0..) |ad, ap, an, al, i| {
        try t.expectEqualStrings(ap, b.paths[i]);
        try t.expectEqualStrings(ad, b.docs[i]);
        try t.expectEqual(an, b.nuls[i]);
        try t.expectEqual(al, b.lines[i]);
    }
}

test "loadWithView: current members bind the mmap; BOM/non-member/stale take the heap" {
    const t = std.testing;
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try std.fmt.allocPrint(a, "/tmp/gist_mirror_shard_{x}", .{@intFromPtr(&threaded)});
    Dir.cwd().deleteTree(io, root) catch {};
    try Dir.cwd().createDirPath(io, root);
    defer Dir.cwd().deleteTree(io, root) catch {};
    const P = struct {
        fn p(aa: std.mem.Allocator, r: []const u8, rel: []const u8) ![]const u8 {
            return std.fmt.allocPrint(aa, "{s}/{s}", .{ r, rel });
        }
    };

    // Four walked files. The shard is minted over the first two's CURRENT bytes;
    // `bin`/`extra` are walk members it never held (binary is not a member; a
    // fresh file post-dates the build), so both must take the heap tier.
    const plain = try P.p(a, root, "plain.txt");
    const bom = try P.p(a, root, "bom.txt");
    const bin = try P.p(a, root, "bin.dat");
    const extra = try P.p(a, root, "extra.txt");
    try Dir.cwd().writeFile(io, .{ .sub_path = plain, .data = "package main\nneedle\n" });
    try Dir.cwd().writeFile(io, .{ .sub_path = bom, .data = "\xEF\xBB\xBFhello\n" });
    try Dir.cwd().writeFile(io, .{ .sub_path = bin, .data = "raw\x00bytes" });
    try Dir.cwd().writeFile(io, .{ .sub_path = extra, .data = "fresh\n" });
    const walk = [_][]const u8{ plain, bom, bin, extra };

    // Shard bodies are RAW (as `readMember` stores them): the BOM file keeps its
    // BOM. Membership decisions are the mirror's job, not the shard's.
    const s_docs = [_][]const u8{ "package main\nneedle\n", "\xEF\xBB\xBFhello\n" };
    const s_paths = [_][]const u8{ plain, bom };
    const shard_path = try P.p(a, root, "content.shard");

    // Ground truth: a full-heap mirror (no shard) to assert byte-parity against.
    var heap = try loadWithView(t.allocator, io, &walk, null);
    defer heap.deinit();

    // ── Current: anchor STRICTLY after every file's mtime (a real gap, since a
    //    future-dated shard is rejected on load), so the shard proves each
    //    member unchanged. `plain` binds the mapping; `bom` (needs decoding),
    //    `bin` + `extra` (non-members) take the heap — all still byte-identical.
    {
        try std.Io.sleep(io, std.Io.Duration.fromNanoseconds(40 * std.time.ns_per_ms), .awake);
        const anchor = std.Io.Clock.now(.real, io).nanoseconds;
        try shard.buildAt(t.allocator, io, shard_path, &s_docs, &s_paths, anchor);
        const view = shard.loadFrom(t.allocator, io, shard_path).?;
        var m = try loadWithView(t.allocator, io, &walk, view);
        defer m.deinit();
        try expectMirrorParity(&heap, &m);
        const region = m.view.?.content;
        try t.expect(within(m.docs[0], region)); // plain → shard tier (zero heap)
        try t.expect(!within(m.docs[1], region)); // bom → heap tier (decoded)
        try t.expect(!within(m.docs[2], region)); // bin → heap tier (non-member)
        try t.expect(!within(m.docs[3], region)); // extra → heap tier (non-member)
    }

    // ── Stale: a far-past anchor stales EVERY member (mtime ≥ anchor), so no
    //    doc binds the mapping — the mirror degrades to the full-heap shape and
    //    stays byte-identical. This is the "changed file" path (mtime ≥ anchor).
    {
        try shard.buildAt(t.allocator, io, shard_path, &s_docs, &s_paths, 1);
        const view = shard.loadFrom(t.allocator, io, shard_path).?;
        var m = try loadWithView(t.allocator, io, &walk, view);
        defer m.deinit();
        try expectMirrorParity(&heap, &m);
        const region = m.view.?.content;
        for (m.docs) |d| try t.expect(!within(d, region));
    }
}
