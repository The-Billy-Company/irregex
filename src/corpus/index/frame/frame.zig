//! frame — the wire discipline every persisted irregex artifact shares.
//!
//! One home for the framing primitives the index blobs are built from, so the
//! formats can't drift on conventions: little-endian fixed-width ints
//! (`putInt`) read back through a fail-closed byte cursor (`Cursor`),
//! length-prefixed u64-slice payloads (`putWords`/`Cursor.words`), and the
//! NUL-joined string tables every artifact uses for its path/roots catalogs
//! (`nulLen`/`joinNul` to write; `splitNulExact`/`parsePathTable`/
//! `ownedNulTable` to read), the shared `onDisk` deletion gate every folded
//! view checks at emit, the shared `loadQuiet` fail-open artifact loader, and
//! the `tree.root` binding that says which tree the whole directory describes.
//! Consumers: the codex + shelf blobs (`../codex/`), the kinship atlas
//! (`../atlas/`), and the trigram pair loader (`../trigrams/persist.zig`).
//! Framing only — magic bytes, versions, and checksums stay with each format,
//! where the corruption story lives.

const std = @import("std");
const corpus_mod = @import("../../tree/corpus.zig");
const fault = @import("../../../fault.zig");

const tree_root_alias = corpus_mod.ArtifactPath("tree.root");

/// `<artifact dir>/tree.root` — the binding `bindingHolds` proves and the
/// index build publishes (`surface/face/gist/lifecycle/index.zig`).
pub fn treeRootFile() []const u8 {
    return tree_root_alias.get();
}

/// Memoized `bindingHolds(treeRootFile())`: 0 unknown · 1 bound · 2 unbound.
/// The binding cannot change under a running query, so a racing pair of
/// readers just computes the same answer twice.
var bound_state: std.atomic.Value(u8) = .init(0);

/// Do the artifacts beside `treeRootFile()` describe the tree we are about to
/// search? Every persisted accelerator names files by path RELATIVE to its
/// build directory and proves a name still current by comparing that file's
/// clocks against a build anchor. Both halves lie in SILENCE when the
/// artifacts belong to a different tree: the relative paths land on unrelated
/// files here, and the foreign anchor — minted after this tree's files were
/// last touched — "proves" every one of them unchanged. A `GIST_DIR` left
/// pointing at another checkout was enough to serve that tree's `README.md`
/// bytes as this one's, and to hand the phantom walk a root listing naming
/// directories that don't exist. So the binding is what makes an anchor
/// trustworthy at all: the anchor reader (`../trigrams/fresh.zig`), the
/// phantom snapshot (`../phantom/treemap.zig`), and the content shard
/// (`../content/shard.zig`) each decline unless it holds, degrading to the
/// live walk that never needed it.
///
/// An ABSENT binding reads as unbound, not as consent — a pre-binding artifact
/// carries no proof of which tree it came from, and the next `gist index`
/// republishes it.
pub fn boundHere() bool {
    switch (bound_state.load(.monotonic)) {
        1 => return true,
        2 => return false,
        else => {},
    }
    const ok = bindingHolds(treeRootFile());
    bound_state.store(if (ok) 1 else 2, .monotonic);
    return ok;
}

/// `boundHere` against an explicit binding file — the injected seam the unit
/// suite drives (production rides the memoized whole-directory answer).
pub fn bindingHolds(path: []const u8) bool {
    var recorded_buf: [std.fs.max_path_bytes]u8 = undefined;
    var live_buf: [std.fs.max_path_bytes]u8 = undefined;
    const recorded = readSmall(path, &recorded_buf) orelse return false;
    const live = thisTree(&live_buf) orelse return false;
    return std.mem.eql(u8, std.mem.trimEnd(u8, recorded, "\n"), live);
}

/// The absolute directory this process resolves relative paths against — the
/// identity a build records and a query re-proves. Symlinks are resolved, so
/// the two sides agree however the tree was entered; this is the same proof
/// the amend path already requires of the daemon's watch prefix. Identity is
/// the PATH rather than an inode because a path is what the artifacts encode
/// relative to, and it is the one identity `gist status` can print back. A
/// moved or renamed tree therefore reads as unbound — right answers, no
/// acceleration — until the next `gist index`.
pub fn thisTree(buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    return std.mem.span(std.c.realpath(".", buf) orelse return null);
}

/// The tree a published binding names, or null when there is none. Copied out
/// (owned by `gpa`) so `gist status` can report a FOREIGN artifact by name
/// instead of leaving a caller to wonder why nothing is ever warm.
pub fn treeBinding(gpa: std.mem.Allocator) ?[]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const recorded = readSmall(treeRootFile(), &buf) orelse return null;
    const trimmed = std.mem.trimEnd(u8, recorded, "\n");
    if (trimmed.len == 0) return null;
    return gpa.dupe(u8, trimmed) catch null;
}

/// Record `thisTree()` at `path` — the write side of `bindingHolds`, used by
/// `gist index` for the artifact directory and by `gist serve` for its socket.
/// Atomic (temp + rename) so a concurrent reader sees the old tree or the new
/// one, never a torn path. Best effort: a binding that can't be written simply
/// reads as unbound, which costs acceleration and never correctness.
pub fn publishBinding(io: std.Io, path: []const u8) void {
    fault.spare("publish the tree binding", publishBindingFallible(io, path));
}

fn publishBindingFallible(io: std.Io, path: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tree = thisTree(&buf) orelse return;
    var af = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true, .replace = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, tree);
    try af.replace(io);
}

/// `.<socket>.tree` in `buf` — where a resident daemon records the tree it went
/// resident over, beside the socket it binds.
///
/// The socket lives in the artifact directory, so `GIST_DIR` pointing two trees
/// at one directory aims them at one RENDEZVOUS: without this, a daemon warm
/// over the other tree answers the dial and its resident bytes are served,
/// silently, as if they were this tree's. The default artifact directory is
/// CWD-relative and can't collide; an absolute one can.
///
/// DOTTED deliberately: a socket may be placed anywhere, including inside the
/// corpus itself (embedders and the daemon suite do exactly that), and the
/// daemon's own bookkeeping must never surface as a search result. Hidden is
/// the walk's existing word for "infrastructure, not content". Null when the
/// name won't fit, which the caller treats as unbound.
pub fn socketBindingPath(buf: []u8, socket_path: []const u8) ?[]const u8 {
    const base = std.fs.path.basenamePosix(socket_path);
    const dir = socket_path[0 .. socket_path.len - base.len]; // keeps the separator, empty when bare
    return std.fmt.bufPrint(buf, "{s}.{s}.tree", .{ dir, base }) catch null;
}

/// One tiny artifact file into `buf`, allocator-free — the binding is read on
/// the query's critical path, before any arena exists. Null when unreadable.
fn readSmall(path: []const u8, buf: []u8) ?[]const u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = std.posix.system.close(fd);
    const n = std.posix.read(fd, buf) catch return null;
    return buf[0..n];
}

// ── mapped artifacts: the load protocol, in one place that cannot be partly run ──

/// A read-only, page-aligned file mapping (zero-copy view of the bytes on disk).
pub const Mapping = []align(std.heap.page_size_min) const u8;

/// mmap a whole file read-only. The mapping survives the fd close (POSIX), and
/// the OS faults in only the pages actually touched — so a loader validates a
/// compact directory up front and pays for a posting group, a child list, or a
/// document body only when a query reaches it. A genuinely empty file is
/// rejected (`mmap` cannot map zero length, and a 0-byte artifact is corruption
/// anyway).
pub fn mmapFile(io: std.Io, path: []const u8) !Mapping {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{}); // .read_only default
    defer file.close(io);
    const len: usize = @intCast((try file.stat(io)).size);
    if (len == 0) return error.EmptyFile;
    return std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0);
}

/// Materialize `sub_path` with `data` via the temp-then-rename pattern (POSIX
/// `rename` is atomic on the same filesystem) instead of a plain truncate+write.
/// Up to ~10 agents cowork this repo and any of them can run `gist index` while
/// another is mid-`mmapFile` on the very same blob — a plain overwrite lets that
/// reader observe a torn (truncated / zero-length / half-written) file and
/// silently answer from it. Atomic replace means a concurrent reader always sees
/// either the fully-old or the fully-new bytes.
pub fn writeAtomic(io: std.Io, sub_path: []const u8, data: []const u8) !void {
    var af = try std.Io.Dir.cwd().createFileAtomic(io, sub_path, .{ .make_path = true, .replace = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, data);
    try af.replace(io);
}

/// Load a SELF-ANCHORED artifact from the artifact directory. Four steps, in
/// this order, none of them skippable by a caller:
///
///   1. prove the artifact directory describes THIS tree (`boundHere`);
///   2. map it;
///   3. decode + validate the layout (`decode` owns the format's own magic,
///      version, and bounds story — it must fail closed on every dangling
///      reference so the returned view can be indexed freely);
///   4. refuse a FUTURE-dated anchor, the same rejection `fresh.readAnchor`
///      makes — a clock proof against an anchor newer than now "proves" every
///      file unchanged, so it would trust the whole corpus.
///
/// Steps 1 and 4 are the ones that used to be per-artifact prose. Both fail
/// SILENTLY to null: an artifact that cannot prove itself costs its
/// acceleration tier and never correctness, because the live path it degrades
/// to never needed it. `V` supplies the two things the protocol reads back —
/// an `anchor_ns` field and a `deinit` that releases the mapping — so a new
/// artifact gets the whole discipline by naming its decoder.
///
/// `Artifact` is a `corpus.ArtifactPath` type rather than a path string: the
/// binding answers a question about the artifact DIRECTORY, so the form that
/// proves it is the form that cannot be aimed anywhere else.
pub fn mapArtifact(
    comptime V: type,
    comptime Artifact: type,
    io: std.Io,
    ctx: anytype,
    comptime decode: fn (@TypeOf(ctx), Mapping) anyerror!V,
) ?V {
    if (!boundHere()) return null;
    return mapAt(V, io, Artifact.get(), ctx, decode);
}

/// `mapArtifact` steps 2–4 for a caller that names its own path.
///
/// The tree binding is deliberately absent, not bypassed: it is a property of
/// the artifact directory, and a caller supplying an explicit path has already
/// taken responsibility for that blob's provenance (a test minting a fixture, a
/// bench harness pointing at a scratch build). Anything reading the shared
/// artifact directory wants `mapArtifact`, which is the only form that can name
/// it.
pub fn mapAt(
    comptime V: type,
    io: std.Io,
    path: []const u8,
    ctx: anytype,
    comptime decode: fn (@TypeOf(ctx), Mapping) anyerror!V,
) ?V {
    const map = mmapFile(io, path) catch return null;
    var v = decode(ctx, map) catch {
        std.posix.munmap(map);
        return null;
    };
    if (v.anchor_ns > std.Io.Clock.now(.real, io).nanoseconds) {
        v.deinit(); // releases the mapping along with anything decode allocated
        return null;
    }
    return v;
}

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

test "the tree binding admits only the tree it names" {
    const t = std.testing;
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const Dir = std.Io.Dir;

    const root = try std.fmt.allocPrint(t.allocator, "/tmp/gist_binding_{x}", .{@intFromPtr(&threaded)});
    defer t.allocator.free(root);
    Dir.cwd().deleteTree(io, root) catch {};
    try Dir.cwd().createDirPath(io, root);
    defer Dir.cwd().deleteTree(io, root) catch {};
    const binding = try std.fmt.allocPrint(t.allocator, "{s}/tree.root", .{root});
    defer t.allocator.free(binding);

    // Absent: a pre-binding artifact directory carries no proof of origin, so
    // it reads as foreign rather than as consent.
    try t.expect(!bindingHolds(binding));

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const here = thisTree(&buf).?;
    try Dir.cwd().writeFile(io, .{ .sub_path = binding, .data = here });
    try t.expect(bindingHolds(binding));

    // A trailing newline is the shape a human `echo` leaves behind; the tree
    // is still this one.
    const with_nl = try std.fmt.allocPrint(t.allocator, "{s}\n", .{here});
    defer t.allocator.free(with_nl);
    try Dir.cwd().writeFile(io, .{ .sub_path = binding, .data = with_nl });
    try t.expect(bindingHolds(binding));

    // The regression this exists for: artifacts built somewhere else. A
    // sibling path is enough — the recorded tree simply isn't the live one.
    try Dir.cwd().writeFile(io, .{ .sub_path = binding, .data = root });
    try t.expect(!bindingHolds(binding));

    // A PREFIX of the live tree must not pass either: `/Users/x/billy-old`
    // and `/Users/x/billy` are different checkouts, and every artifact in one
    // names files by a path that resolves inside the other.
    try Dir.cwd().writeFile(io, .{ .sub_path = binding, .data = here[0 .. here.len - 1] });
    try t.expect(!bindingHolds(binding));

    // The daemon's rendezvous binding round-trips through the same proof, and
    // stays HIDDEN: a socket may sit inside the corpus, and the daemon's own
    // bookkeeping must not turn up as somebody's search result.
    var sock_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sock = try std.fmt.allocPrint(t.allocator, "{s}/gistd.sock", .{root});
    defer t.allocator.free(sock);
    const sock_binding = socketBindingPath(&sock_buf, sock).?;
    try t.expectEqualStrings(".gistd.sock.tree", std.fs.path.basenamePosix(sock_binding));
    try t.expect(!bindingHolds(sock_binding));
    publishBinding(io, sock_binding);
    try t.expect(bindingHolds(sock_binding));

    // A bare socket name (no directory) still hides, and never loses the name.
    try t.expectEqualStrings(".s.sock.tree", socketBindingPath(&sock_buf, "s.sock").?);
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
