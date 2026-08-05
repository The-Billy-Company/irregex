//! phantom — the persisted directory-membership snapshot (`tree.map`).
//!
//! The parallel walk's floor is syscalls: `openat` + `getattrlistbulk` +
//! `close` for every directory in the corpus (~5k dirs ⇒ ~50 ms wall on this
//! repo), paid on every cold query just to re-learn a tree that almost never
//! changed. This artifact removes that floor. `gist index` walks the tree once
//! with the QUERY engine's default admission semantics (gitignore + hidden +
//! `.git`, never the corpus build's `isSkipDir` policy) and records, for every
//! directory it enters, the raw name+kind membership of ALL direct children —
//! including children the default walk then prunes (a hidden or gitignored
//! subdir), so a query-side whitelist (`-g` forcing an ignored file back in)
//! can detect exactly when the snapshot cannot serve it.
//!
//! A later query proves a directory's snapshot record still true with ONE
//! `lstat`: POSIX bumps a directory's mtime (and ctime) whenever its direct
//! membership changes — create, delete, rename, link — so `mtime < anchor AND
//! ctime < anchor` (the same conservative `needsLiveRead` rule the T3 overlay
//! uses, equality stales) proves the recorded child list is byte-exact. What a
//! directory's clocks can NEVER prove is a child FILE's content (an in-place
//! write bumps only the file's own clocks), so the snapshot deliberately
//! stores no file metadata: an admitted file is `lstat`ed live before index
//! elision may skip it, and read live otherwise — content freshness stays
//! exactly where T3 already proves it, on the file itself.
//!
//! The blob is self-anchored (its own build instant rides in the header), so
//! it never depends on pairing with a particular trigram generation: a stale
//! tree.map next to a fresh index just re-lists more directories live; a fresh
//! tree.map next to a stale index changes nothing about elision. It is NOT
//! self-identifying, though: the anchor dates the build, it doesn't say which
//! tree was built, so `load` proves that separately against the artifact
//! directory's `tree.root` binding. Fail-open everywhere — a missing, corrupt,
//! or foreign blob loads as null and the walk runs exactly as before.

const std = @import("std");
const ignore = @import("../../tree/ignore.zig");
const bulkstat = @import("../../tree/bulkstat.zig");
const frame = @import("../frame/frame.zig");
const signet = @import("../frame/signet.zig");
const portal = @import("../../../portal.zig");
const home = @import("../frame/home.zig");
const Dir = std.Io.Dir;

const file_alias = home.ArtifactPath("tree.map");
pub fn treemapFile() []const u8 {
    return file_alias.get();
}

const magic = "GISTTRE2";
/// magic(8) · anchor i64 · ndirs u32 · nents u32 · names_len u32 · pad u32 —
/// 32 bytes, keeping the u32-aligned record arrays aligned inside any
/// page-aligned mapping.
const header_len = 32;

/// A directory child never descended at build time (a plain file, or a dir the
/// default walk pruned): the query must open that subtree live if it wants it.
pub const not_walked: u32 = std.math.maxInt(u32);

/// One recorded child. `dir_ix` indexes `View.dirs` for a descended child
/// directory (`not_walked` otherwise), so the query-side walk traverses the
/// snapshot by direct link — zero path lookups.
pub const Ent = extern struct {
    name_off: u32,
    name_len: u16,
    kind: u8, // 0 = file, 1 = dir
    _pad: u8 = 0,
    dir_ix: u32,

    pub inline fn isDir(e: Ent) bool {
        return e.kind == 1;
    }
};

/// One walked directory: its children live at `ents[first..first+count]`.
/// Dir 0 is always the walk root; rel paths are reconstructed by joining
/// names during descent, so none are stored.
pub const Rec = extern struct { first: u32, count: u32 };

comptime {
    // Both arrays go to disk through `sliceAsBytes` and come back through
    // `bytesAsSlice`, so every byte of both has to belong to a field - which is
    // what `Ent._pad` is for and why it cannot be deleted as unused. Stated as
    // a build failure rather than as prose, because prose is what it was when
    // outliner's copy of this format shipped four bytes of its own heap into
    // every folio on disk. See `frame.seamless`.
    frame.seamless(Rec);
    frame.seamless(Ent);
}

/// Zero-copy read view over a mapped `tree.map`. All slices alias the mapping.
pub const View = struct {
    map: frame.Mapping,
    anchor_ns: i128,
    dirs: []const Rec,
    ents: []const Ent,
    names: []const u8,

    pub fn children(v: *const View, ix: u32) []const Ent {
        const d = v.dirs[ix];
        return v.ents[d.first..][0..d.count];
    }

    pub fn name(v: *const View, e: Ent) []const u8 {
        return v.names[e.name_off..][0..e.name_len];
    }

    /// Prove the mapped snapshot is the one `build` wrote. Deferred like the
    /// content shard's: `decode` already refuses every dangling reference, so
    /// what the seal adds is the case bounds checking cannot see — a flipped
    /// byte inside a NAME, which yields a valid snapshot listing a directory
    /// child that was never there.
    pub fn verify(v: *const View) signet.Error!void {
        return signet.verify(v.map);
    }

    pub fn deinit(v: *View) void {
        portal.unmap(v.map);
    }
};

/// The snapshot, through the shared artifact-load protocol
/// (`frame.mapArtifact`): the tree binding is proved, the blob is mapped and
/// layout-validated by `decode`, and a future-dated anchor is refused — a
/// snapshot minted ahead of the clock would "prove" every directory unchanged.
///
/// The binding is why this cannot be a bare mmap. Membership is recorded by
/// relative path and proved current against the snapshot's own anchor, and
/// neither half survives a move between checkouts: a foreign anchor is younger
/// than every directory here, so the root's clock test passes and the walk is
/// handed the OTHER tree's child list — `sub`, `t`, names this tree has never
/// had. The observable was a walk error blaming a filter, and behind it zero
/// files searched. Every refusal costs the phantom walk and never correctness.
pub fn load(io: std.Io) ?View {
    return frame.mapArtifact(View, file_alias, io, {}, decode);
}

/// The pure layout half of `load`, unit-testable on an in-memory blob. Takes
/// the protocol's context slot, which this format has no use for — the view
/// aliases the mapping and allocates nothing.
pub fn decode(_: void, map: frame.Mapping) !View {
    if (comptime @import("builtin").cpu.arch.endian() != .little) return error.Corrupt;
    if (map.len < header_len or !std.mem.eql(u8, map[0..magic.len], magic)) return error.Corrupt;
    const anchor_ns: i128 = std.mem.readInt(i64, map[8..16], .little);
    const ndirs = std.mem.readInt(u32, map[16..20], .little);
    const nents = std.mem.readInt(u32, map[20..24], .little);
    const names_len = std.mem.readInt(u32, map[24..28], .little);
    const dirs_bytes = @as(usize, ndirs) * @sizeOf(Rec);
    const ents_bytes = @as(usize, nents) * @sizeOf(Ent);
    if (ndirs == 0 or map.len != header_len + dirs_bytes + ents_bytes + names_len + signet.len) return error.Corrupt;
    const dirs = std.mem.bytesAsSlice(Rec, map[header_len..][0..dirs_bytes]);
    const ents = std.mem.bytesAsSlice(Ent, map[header_len + dirs_bytes ..][0..ents_bytes]);
    const names = map[header_len + dirs_bytes + ents_bytes ..][0..names_len];
    // Fail closed on any dangling reference so consumers can index freely.
    for (dirs) |d| if (@as(usize, d.first) + d.count > ents.len) return error.Corrupt;
    for (ents) |e| {
        if (@as(usize, e.name_off) + e.name_len > names.len) return error.Corrupt;
        if (e.dir_ix != not_walked and e.dir_ix >= ndirs) return error.Corrupt;
    }
    return .{ .map = map, .anchor_ns = anchor_ns, .dirs = @alignCast(dirs), .ents = @alignCast(ents), .names = names };
}

/// Resolve a positional root to its snapshot record by walking name
/// components from dir 0 (the CWD root). Null — root outside the snapshot's
/// path space (absolute, `..`), a component the build never saw, or a dir it
/// recorded but never descended — means that root simply walks live.
pub fn resolve(v: *const View, root: []const u8) ?u32 {
    if (root.len > 0 and root[0] == '/') return null;
    var ix: u32 = 0;
    var it = std.mem.tokenizeScalar(u8, root, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) return null;
        const next: u32 = for (v.children(ix)) |ent| {
            if (ent.isDir() and std.mem.eql(u8, v.name(ent), comp)) break ent.dir_ix;
        } else return null;
        if (next == not_walked) return null;
        ix = next;
    }
    return ix;
}

/// Build + atomically publish the snapshot for the whole-CWD corpus. The walk
/// admission mirrors the query engines' DEFAULT verdict exactly — the shared
/// `ignore.Ignore` (gitignore chain + hidden + `.git`), with NO corpus-only
/// skip policy — so a default-flag query descends precisely the recorded set.
/// Only single-root `.` corpora are snapshotted (the phantom walk engages only
/// for rootless/whole-tree queries); anything else is a silent no-op.
pub fn build(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8) !void {
    // A target with no batched directory listing (`bulkstat.names_supported`)
    // would decline on every `walk` and leave each record at its initialized
    // `{first:0, count:0}` — a snapshot that does not say "unknown" but
    // "childless", which the query then trusts. Publishing nothing instead is
    // exactly the documented fail-open: `load` returns null and the walk runs
    // as before, minus the accelerator this platform cannot feed.
    if (comptime !bulkstat.names_supported) return;
    if (roots.len != 1 or !std.mem.eql(u8, roots[0], ".")) return;
    // The anchor is captured BEFORE the walk (same discipline as T3): a
    // directory touched mid-build reads as `>= anchor` next query and is
    // re-listed live rather than trusted.
    const anchor_ns = std.Io.Clock.now(.real, io).nanoseconds;

    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();

    // Mirror the rootless query walk exactly: `parallel.run` inits its Ignore
    // with the (empty) positional roots and never scopes — parity by identical
    // construction, not by equivalence argument.
    var ig = try ignore.Ignore.init(a, io, .{}, &.{});

    var b = Builder{ .a = a, .io = io, .ig = &ig };
    try b.dirs.append(a, .{ .first = 0, .count = 0 }); // dir 0 = root, filled by walk
    try b.walk(".", "", 0);

    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(gpa);
    try blob.ensureTotalCapacity(gpa, header_len + b.dirs.items.len * @sizeOf(Rec) + b.ents.items.len * @sizeOf(Ent) + b.names.items.len + signet.len);
    blob.appendSliceAssumeCapacity(magic);
    var scratch: [8]u8 = undefined;
    std.mem.writeInt(i64, &scratch, @intCast(anchor_ns), .little);
    blob.appendSliceAssumeCapacity(&scratch);
    std.mem.writeInt(u32, scratch[0..4], @intCast(b.dirs.items.len), .little);
    blob.appendSliceAssumeCapacity(scratch[0..4]);
    std.mem.writeInt(u32, scratch[0..4], @intCast(b.ents.items.len), .little);
    blob.appendSliceAssumeCapacity(scratch[0..4]);
    std.mem.writeInt(u32, scratch[0..4], @intCast(b.names.items.len), .little);
    blob.appendSliceAssumeCapacity(scratch[0..4]);
    blob.appendSliceAssumeCapacity(&[_]u8{0} ** 4);
    blob.appendSliceAssumeCapacity(std.mem.sliceAsBytes(b.dirs.items));
    blob.appendSliceAssumeCapacity(std.mem.sliceAsBytes(b.ents.items));
    blob.appendSliceAssumeCapacity(b.names.items);
    try signet.sealInto(gpa, &blob);
    try frame.writeAtomic(io, treemapFile(), blob.items);
}

/// The recording walk. Depth-first so a parent's gitignore rules are loaded
/// (`Ignore.loadDir`) before any descendant's verdict is computed — the same
/// order both query engines guarantee.
const Builder = struct {
    a: std.mem.Allocator,
    io: std.Io,
    ig: *ignore.Ignore,
    dirs: std.ArrayList(Rec) = .empty,
    ents: std.ArrayList(Ent) = .empty,
    names: std.ArrayList(u8) = .empty,

    fn addName(b: *Builder, s: []const u8) !u32 {
        const off: u32 = @intCast(b.names.items.len);
        try b.names.appendSlice(b.a, s);
        return off;
    }

    /// List `disk` (query-visible rel prefix `rel`), record every child, and
    /// recurse into the ones the default walk admits. `ix` is this directory's
    /// pre-assigned record slot.
    fn walk(b: *Builder, disk: []const u8, rel: []const u8, ix: u32) !void {
        try b.ig.loadDir(disk, rel);
        const fd = portal.openDir(portal.cwd(), disk) catch return;
        // A declined listing means this map cannot be built on this filesystem;
        // the phantom treemap is itself an accelerator, so the directory is
        // simply left unmapped. OOM propagates — the caller aborts the build.
        const listed = switch (blk: {
            defer portal.close(fd);
            break :blk try bulkstat.listNamesOnly(b.a, fd);
        }) {
            .declined => return,
            .got => |v| v,
        };

        const first: u32 = @intCast(b.ents.items.len);
        // Two passes: children are recorded contiguously first (the Rec spans
        // them), then admitted subdirectories recurse with their own slots.
        var descend: std.ArrayList(struct { name: []const u8, ix: u32 }) = .empty;
        defer descend.deinit(b.a);
        for (listed) |e| {
            const off = try b.addName(e.name);
            var ent = Ent{ .name_off = off, .name_len = @intCast(e.name.len), .kind = @intFromBool(e.is_dir), .dir_ix = not_walked };
            if (e.is_dir) {
                const child_rel = try joinRel(b.a, rel, e.name);
                if (!b.ig.shouldSkip(child_rel, true, e.name, false, false)) {
                    ent.dir_ix = @intCast(b.dirs.items.len);
                    try b.dirs.append(b.a, .{ .first = 0, .count = 0 });
                    try descend.append(b.a, .{ .name = e.name, .ix = ent.dir_ix });
                }
            }
            try b.ents.append(b.a, ent);
        }
        b.dirs.items[ix] = .{ .first = first, .count = @intCast(b.ents.items.len - first) };

        for (descend.items) |d| {
            const child = try joinRel(b.a, rel, d.name);
            try b.walk(child, child, d.ix);
        }
    }
};

fn joinRel(a: std.mem.Allocator, prefix: []const u8, name: []const u8) ![]const u8 {
    if (prefix.len == 0) return name;
    const buf = try a.alloc(u8, prefix.len + 1 + name.len);
    @memcpy(buf[0..prefix.len], prefix);
    buf[prefix.len] = '/';
    @memcpy(buf[prefix.len + 1 ..], name);
    return buf;
}
