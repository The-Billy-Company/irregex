//! content — the persisted corpus-content shard (`content.shard`).
//!
//! The parallel walk's *second* floor, after the phantom snapshot removed the
//! directory-listing syscalls, is the per-file `openat`+`read`+`close`: a
//! full-scan query with no usable trigram filter (a 2-byte literal like `})`,
//! a dense class-count, a bare `-c`) reads EVERY corpus file's bytes — ~20k
//! opens on this repo, the syscall wall that leaves gist behind a static
//! memory-mapped server index (zoekt) on exactly those classes. This artifact
//! removes that floor the same way zoekt does: `gist index` concatenates every
//! corpus body (the SAME membership `corpus.readMember` already computed — non-
//! binary, non-empty, ≤ `per_file_cap`) into one contiguous blob with a doc→
//! offset catalog, and a later query serves each unchanged file's bytes from
//! that ONE mmap instead of opening it. 20k opens collapse to one map + page
//! faults the OS already caches across runs.
//!
//! It is a READ ACCELERATOR, never an authority (same law as every index/
//! artifact). A served slice is byte-identical to the file's bytes ONLY while
//! the file is unchanged, so the shard hands a slice back exactly when the T3
//! rule proves it: `mtime < anchor AND ctime < anchor` (the conservative
//! `bulkstat.needsLiveRead`, equality stales). A changed file — or one the
//! shard never held (new since the build, binary, > cap, outside the indexed
//! roots) — misses the lookup and is read live, so the walk's answer is the
//! walk's answer whether or not a shard is loaded.
//!
//! Self-anchored (its own build instant rides in the header) and fail-open
//! everywhere: a missing/corrupt/foreign/future-dated blob loads as null and
//! every file is read live exactly as before. The freshness gate binds to the
//! shard's OWN anchor, so a stale shard beside a fresh index (or the reverse)
//! only serves fewer slices — never a wrong one.
//!
//! Sealed, and verified only on request (`View.verify`). Layout validation
//! cannot see bit rot inside a body — flip a byte of file content and every
//! offset, length, and name still checks out, yet the served slice is no longer
//! the file's bytes. The seal is the only thing that can say so, and digesting
//! a quarter-gigabyte at load would spend the exact saving this artifact
//! exists to make, so it waits for someone to ask.

const std = @import("std");
const bulkstat = @import("../../tree/bulkstat.zig");
const fault = @import("../../../fault.zig");
const frame = @import("../frame/frame.zig");
const signet = @import("../frame/signet.zig");
const portal = @import("../../../portal.zig");
const home = @import("../frame/home.zig");

/// Open-addressing path→doc table (Wyhash, linear probe, one `slots` alloc).
/// The shard's own copy of the engine's `IndexedPaths` shape — kept here so the
/// index layer never imports the surface engine (the dependency runs the other
/// way). Keys borrow the caller's `paths` slice; only `slots` is owned.
const PathLookup = struct {
    const empty = std.math.maxInt(u32);

    slots: []u32,
    mask: usize,
    gpa: std.mem.Allocator,

    fn init(gpa: std.mem.Allocator, paths: []const []const u8) std.mem.Allocator.Error!PathLookup {
        if (paths.len > std.math.maxInt(usize) / 2) return error.OutOfMemory;
        const capacity = std.math.ceilPowerOfTwo(usize, @max(@as(usize, 8), paths.len * 2)) catch return error.OutOfMemory;
        const slots = try gpa.alloc(u32, capacity);
        @memset(slots, empty);
        const t = PathLookup{ .slots = slots, .mask = capacity - 1, .gpa = gpa };
        for (paths, 0..) |path, doc| {
            var pos = t.slot(path);
            while (slots[pos] != empty) pos = (pos + 1) & t.mask;
            slots[pos] = @intCast(doc);
        }
        return t;
    }

    fn get(self: *const PathLookup, paths: []const []const u8, path: []const u8) ?u32 {
        var pos = self.slot(path);
        while (true) : (pos = (pos + 1) & self.mask) {
            const doc = self.slots[pos];
            if (doc == empty) return null;
            if (std.mem.eql(u8, paths[doc], path)) return doc;
        }
    }

    fn slot(self: *const PathLookup, path: []const u8) usize {
        return @as(usize, @truncate(std.hash.Wyhash.hash(0, path))) & self.mask;
    }

    fn deinit(self: *PathLookup) void {
        self.gpa.free(self.slots);
    }
};

const file_alias = home.ArtifactPath("content.shard");
pub fn shardFile() []const u8 {
    return file_alias.get();
}

const magic = "GISTSHD2";
/// magic(8) · anchor i64 · ndocs u32 · names_len u32 · content_len u64 — 32
/// bytes, so the u64 offset array that follows starts 8-aligned inside any
/// page-aligned mapping.
const header_len = 32;

/// Zero-copy read view over a mapped `content.shard`. `offsets`/`content` alias
/// the mapping; `paths` aliases the mapping's names region; `indexed` is the
/// one heap structure (path→doc), built once at load like the elide oracle's.
pub const View = struct {
    map: frame.Mapping,
    anchor_ns: i128,
    /// `content[offsets[d]..offsets[d+1]]` is doc `d`'s body; len is `ndocs+1`.
    offsets: []const u64,
    content: []const u8,
    paths: std.ArrayList([]const u8),
    indexed: PathLookup,
    gpa: std.mem.Allocator,

    /// The unchanged file's bytes from the mmap, or null — changed (the T3
    /// clock rule), absent metadata, or not a shard member (new/binary/oversize/
    /// out-of-scope). `rel` is the elide-parity key (`stripDot`ped rel path).
    /// Byte-identical to reading the file, so the caller's answer is unchanged.
    pub fn slice(v: *const View, rel: []const u8, mtime_ns: ?i128, ctime_ns: ?i128) ?[]const u8 {
        if (bulkstat.needsLiveRead(v.anchor_ns, mtime_ns, ctime_ns)) return null;
        const doc = v.indexed.get(v.paths.items, rel) orelse return null;
        // `decode` proved every offset ≤ `content.len`, itself a `usize`, so
        // narrowing here cannot be out of range on any address width.
        return v.content[@intCast(v.offsets[doc])..@intCast(v.offsets[doc + 1])];
    }

    /// Prove the mapped bytes are the bytes `build` wrote.
    ///
    /// DEFERRED on purpose. This artifact exists to stop a full-scan query
    /// opening 20k files; digesting all ~215 MB at load would hand that saving
    /// straight back and fault in every page the query was never going to
    /// touch. Correctness does not rest on it either — the tree binding, the
    /// layout validation in `decode`, and the per-file clock proof already fail
    /// closed. So the seal is here for the moment someone ASKS: `gist status`,
    /// a corruption hunt, an integrity sweep after a bad disk.
    pub fn verify(v: *const View) signet.Error!void {
        return signet.verify(v.map);
    }

    pub fn deinit(v: *View) void {
        v.indexed.deinit();
        v.paths.deinit(v.gpa);
        portal.unmap(v.map);
    }
};

/// The shard, through the shared artifact-load protocol
/// (`frame.mapArtifact`): the tree binding is proved, the blob is mapped and
/// layout-validated by `decode`, and a future-dated anchor is refused.
///
/// This artifact is the sharpest reason the binding step exists. `slice`
/// answers by relative path plus a clock proof, so under a `$GIST_DIR` aimed at
/// another checkout, any path the two trees share — `README.md` — is served the
/// OTHER tree's bytes and reported at a real path in this one. Fabricated
/// output, not a missed hit. Every refusal costs the shard read tier and never
/// correctness.
pub fn load(gpa: std.mem.Allocator, io: std.Io) ?View {
    return frame.mapArtifact(View, file_alias, io, gpa, decode);
}

/// `load` from an explicit shard path — the write-side twin of `buildAt`, so a
/// caller minting its own shard (a test, a bench harness) can bind it outside
/// the fixed artifact directory. Carries its own provenance, so the tree
/// binding does not apply; anything reading the shared artifact directory wants
/// `load`, which is the only form that can name it.
pub fn loadFrom(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?View {
    return frame.mapAt(View, io, path, gpa, decode);
}

/// The layout + doc-table half of `load` (fallible; allocates the path table +
/// lookup) — unit-testable on an in-memory blob. Every dangling reference fails
/// closed so `slice` can index `offsets`/`content` freely.
fn decode(gpa: std.mem.Allocator, map: frame.Mapping) !View {
    if (comptime @import("builtin").cpu.arch.endian() != .little) return error.Corrupt;
    if (map.len < header_len or !std.mem.eql(u8, map[0..magic.len], magic)) return error.Corrupt;
    const anchor_ns: i128 = std.mem.readInt(i64, map[8..16], .little);
    const ndocs = std.mem.readInt(u32, map[16..20], .little);
    const names_len = std.mem.readInt(u32, map[20..24], .little);
    // The header records the content span as u64 (the format is width-neutral),
    // but the shard is consumed as a mapping — so on a 32-bit target a value
    // past `usize` is not a truncation to paper over, it is a shard this address
    // space cannot map. Refuse it here like any other layout the loader can't
    // honor, and every later span arithmetic is addressable by construction.
    const content_len = std.math.cast(usize, std.mem.readInt(u64, map[24..32], .little)) orelse return error.Corrupt;
    if (ndocs == 0) return error.Corrupt;

    const offsets_bytes = (@as(usize, ndocs) + 1) * @sizeOf(u64);
    if (map.len != header_len + offsets_bytes + names_len + content_len + signet.len) return error.Corrupt;
    const offsets: []const u64 = @alignCast(std.mem.bytesAsSlice(u64, map[header_len..][0..offsets_bytes]));
    const names = map[header_len + offsets_bytes ..][0..names_len];
    const content = map[header_len + offsets_bytes + names_len ..][0..content_len];

    // Offsets partition `content` exactly: monotone non-decreasing, bracketed
    // by 0 and content_len — so every `slice` sub-range is provably in bounds.
    const content_span: u64 = content_len; // offsets are u64 by format; widen once
    if (offsets[0] != 0 or offsets[ndocs] != content_span) return error.Corrupt;
    for (1..offsets.len) |i| if (offsets[i] < offsets[i - 1] or offsets[i] > content_span) return error.Corrupt;

    var paths = try frame.parsePathTable(gpa, names);
    errdefer paths.deinit(gpa);
    if (paths.items.len != ndocs) return error.Corrupt;
    var indexed = try PathLookup.init(gpa, paths.items);
    errdefer indexed.deinit();
    return .{ .map = map, .anchor_ns = anchor_ns, .offsets = offsets, .content = content, .paths = paths, .indexed = indexed, .gpa = gpa };
}

/// Build + atomically publish the shard from the corpus snapshot `gist index`
/// already loaded (`docs`/`paths` in doc-id order, sharing the trigram index's
/// `anchor_ns` — captured BEFORE the read, so a file touched mid-build reads as
/// `>= anchor` next query and serves live). Best-effort: the caller ignores the
/// error, losing only this tier. A `.` prefix on a path is NOT stripped here —
/// the query keys with `stripDot(rel)`, matching the trigram pair's own table.
/// Takes no allocator: the write streams, so publishing a quarter-gigabyte shard
/// costs one 64 KiB buffer on the stack and no heap at all.
pub fn build(io: std.Io, docs: []const []const u8, paths: []const []const u8, anchor_ns: i128) !void {
    return buildAt(io, shardFile(), docs, paths, anchor_ns);
}

/// `build` to an explicit shard path — the write-side twin of `loadFrom`, so a
/// test can mint a shard outside the fixed artifact directory.
///
/// STREAMED, and that is the point: the blob is a concatenation of the whole
/// corpus, so assembling it in memory to seal it made `gist index` hold a second
/// full copy of every file it had just read. `frame.Quill` reaches the identical
/// bytes and the identical seal through a 64 KiB window, so this tier's cost is
/// the file it writes and nothing more.
pub fn buildAt(io: std.Io, path: []const u8, docs: []const []const u8, paths: []const []const u8, anchor_ns: i128) !void {
    std.debug.assert(docs.len == paths.len);
    if (docs.len == 0 or docs.len > std.math.maxInt(u32)) return;
    return write(io, path, Held{ .docs = docs }, paths, anchor_ns);
}

/// Reading one body back on demand — the streamed build's half of `build`.
/// `read` returns doc `doc`'s bytes in `buf`, and is the same shape
/// `corpus.Census.recall` already has.
pub const Recall = struct {
    ctx: *anyopaque,
    read: *const fn (ctx: *anyopaque, doc: u32, buf: []u8) []const u8,
};

/// Publish the shard for a corpus nobody is holding: bodies come back one at a
/// time through `src`, and `lens` states how long each one is.
///
/// **`lens` must be what the build ACTUALLY read, not what a walk once stated.**
/// The offset catalog is prefix sums of these numbers and is written before the
/// bodies, so a length that disagrees with the bytes would publish a shard whose
/// catalog points into the wrong doc — the one failure mode a content shard must
/// never have, because every reader trusts it without re-checking. The trigram
/// pass already read every doc and can hand over exactly these lengths
/// (`kiln.Witness`).
///
/// A file that changes AGAIN between that pass and this one is caught here and
/// declines the whole shard rather than publishing a skewed catalog. Losing the
/// tier costs a full-scan query its fast path; a skewed one would cost it the
/// right answer. The caller already treats this as best-effort.
pub fn buildRecalled(
    gpa: std.mem.Allocator,
    io: std.Io,
    src: Recall,
    paths: []const []const u8,
    lens: []const u32,
    anchor_ns: i128,
) !fault.Answer(void) {
    std.debug.assert(lens.len == paths.len);
    if (lens.len == 0 or lens.len > std.math.maxInt(u32)) return .{ .got = {} };

    var widest: u32 = 1;
    for (lens) |n| widest = @max(widest, n);
    // At least one whole doc must fit, however big that doc is.
    const buf = try gpa.alloc(u8, @max(window_budget, widest));
    defer gpa.free(buf);
    const nthr = @max(1, portal.cpuCount() catch 1);
    const crew = try gpa.alloc(Slice, nthr);
    defer gpa.free(crew);
    const threads = try gpa.alloc(std.Thread, nthr);
    defer gpa.free(threads);
    write(io, shardFile(), Recalled{
        .src = src,
        .lens = lens,
        .buf = buf,
        .crew = crew,
        .threads = threads,
    }, paths, anchor_ns) catch |err| switch (err) {
        error.CorpusChurned => return .{ .declined = .freshness_unprovable },
        else => return err,
    };
    return .{ .got = {} };
}

/// How much of the corpus is in flight while the shard is written.
///
/// **This window is why a streamed shard costs what a held one does.** Writing
/// is inherently sequential — the bodies are a concatenation in doc order — but
/// READING them is not, and a doc at a time is 175k dependent opens on one
/// thread where the trigram pass had already proven the same reads parallelize.
/// Measured on llvm-project, the serial version spent 30 s re-reading what the
/// parallel pass reads in about 6. So the window is filled by every core at
/// once and then handed to the writer as one region: flat memory, sequential
/// bytes, parallel I/O.
const window_budget: usize = 64 << 20;

fn write(io: std.Io, path: []const u8, bodies: anytype, paths: []const []const u8, anchor_ns: i128) !void {
    var quill = try frame.Quill.init(io, path);
    defer quill.deinit(io);
    var sink = Streamed{ .quill = &quill, .io = io };
    try emit(&sink, bodies, paths, anchor_ns);
    try quill.seal(io);
}

/// Bodies the caller is already holding.
const Held = struct {
    docs: []const []const u8,

    fn count(h: Held) usize {
        return h.docs.len;
    }
    fn len(h: Held, doc: usize) usize {
        return h.docs[doc].len;
    }
    fn emitAll(h: Held, sink: anytype) !void {
        for (h.docs) |d| try sink.put(d);
    }
};

/// `fill`'s own failure mode, PRIVATE to the streamed-write crew below:
/// a body that no longer matches the catalog's length. Never leaves this
/// file — `write` is the module boundary every reader sees, and its `!void`
/// return is unchanged by this name, the same shape as the PCRE2 shadow
/// rewriter's `error.Bail`.
const Err = error{CorpusChurned};

/// One crew member's run of docs within the window, and where they land in it.
const Slice = struct {
    r: *const Recalled = undefined,
    lo: usize = 0,
    hi: usize = 0,
    off: usize = 0,
    ok: bool = true,

    fn run(s: *Slice) void {
        var at = s.off;
        for (s.lo..s.hi) |doc| {
            const want = s.r.lens[doc];
            const got = s.r.src.read(s.r.src.ctx, @intCast(doc), s.r.buf[at..][0..want]);
            // A body that no longer matches the length the catalog was built
            // from would skew every later doc's offset — decline instead.
            if (got.len != want) {
                s.ok = false;
                return;
            }
            at += want;
        }
    }
};

/// Bodies fetched back a window at a time, filled by every core and written as
/// one region.
const Recalled = struct {
    src: Recall,
    lens: []const u32,
    buf: []u8,
    crew: []Slice,
    threads: []std.Thread,

    fn count(r: Recalled) usize {
        return r.lens.len;
    }
    fn len(r: Recalled, doc: usize) usize {
        return r.lens[doc];
    }

    fn emitAll(r: Recalled, sink: anytype) !void {
        var me = r;
        var lo: usize = 0;
        while (lo < me.lens.len) {
            var hi = lo;
            var span: usize = 0;
            while (hi < me.lens.len and (hi == lo or span + me.lens[hi] <= me.buf.len)) : (hi += 1) {
                span += me.lens[hi];
            }
            try me.fill(lo, hi, span);
            try sink.put(me.buf[0..span]);
            lo = hi;
        }
    }

    /// Read docs `[lo, hi)` into the window, byte-balanced across the crew.
    fn fill(r: *const Recalled, lo: usize, hi: usize, span: usize) Err!void {
        const nthr = @min(r.crew.len, @max(1, hi - lo));
        var at: usize = 0;
        var doc = lo;
        for (r.crew[0..nthr], 0..) |*s, t| {
            // Each member takes docs until it holds its share of the window's
            // bytes, so a run of tiny files and a run of large ones cost the
            // same wall time rather than the same doc count.
            const target = span * (t + 1) / nthr;
            const start = doc;
            const off = at;
            while (doc < hi and (at < target or t == nthr - 1)) : (doc += 1) at += r.lens[doc];
            s.* = .{ .r = r, .lo = start, .hi = doc, .off = off };
        }
        var spawned: usize = 0;
        while (spawned < nthr) : (spawned += 1) {
            r.threads[spawned] = std.Thread.spawn(.{}, Slice.run, .{&r.crew[spawned]}) catch break;
        }
        for (spawned..nthr) |t| Slice.run(&r.crew[t]);
        for (r.threads[0..spawned]) |th| th.join();
        for (r.crew[0..nthr]) |s| if (!s.ok) return error.CorpusChurned;
    }
};

/// The layout, in order, written ONCE — `sink` is anything with `put`/`putInt`
/// and `bodies` anything with `count`/`len`/`emitTo`, so the streaming writer,
/// the recalled writer, and the in-memory test encoder cannot drift on the
/// format all three agree about.
fn emit(sink: anytype, bodies: anytype, paths: []const []const u8, anchor_ns: i128) !void {
    const ndocs = bodies.count();
    var content_len: u64 = 0;
    for (0..ndocs) |i| content_len += bodies.len(i);

    try sink.put(magic);
    try sink.putInt(i64, @intCast(anchor_ns));
    try sink.putInt(u32, @intCast(ndocs));
    try sink.putInt(u32, @intCast(frame.nulLen(paths)));
    try sink.putInt(u64, content_len);

    // Offset catalog: prefix sums of the body lengths (offsets[0]=0 …
    // offsets[ndocs]=content_len), so a query maps doc→slice with two reads.
    var acc: u64 = 0;
    for (0..ndocs) |i| {
        try sink.putInt(u64, acc);
        acc += bodies.len(i);
    }
    try sink.putInt(u64, acc);

    for (paths) |p| {
        try sink.put(p);
        try sink.put(&[_]u8{0});
    }
    try bodies.emitAll(sink);
}

/// `emit` → a `frame.Quill`. Binds the `io` the quill needs so `emit` stays a
/// pure description of the layout.
const Streamed = struct {
    quill: *frame.Quill,
    io: std.Io,

    fn put(s: *Streamed, bytes: []const u8) !void {
        return s.quill.put(s.io, bytes);
    }

    fn putInt(s: *Streamed, comptime T: type, v: T) !void {
        return s.quill.putInt(s.io, T, v);
    }
};

// ─────────────────────────── tests ───────────────────────────

/// Encode a shard blob into `gpa` memory (the `build` body without the file
/// write), so `decode`/`slice` are testable with no filesystem. Shares `emit`
/// with the streaming writer, so a test blob is the production blob.
fn encodeForTest(gpa: std.mem.Allocator, docs: []const []const u8, paths: []const []const u8, anchor_ns: i128) ![]u8 {
    const Collected = struct {
        blob: std.ArrayList(u8) = .empty,
        gpa: std.mem.Allocator,

        fn put(s: *@This(), bytes: []const u8) !void {
            return s.blob.appendSlice(s.gpa, bytes);
        }

        fn putInt(s: *@This(), comptime T: type, v: T) !void {
            var scratch: [@divExact(@bitSizeOf(T), 8)]u8 = undefined;
            std.mem.writeInt(T, &scratch, v, .little);
            return s.put(&scratch);
        }
    };
    var sink = Collected{ .gpa = gpa };
    errdefer sink.blob.deinit(gpa);
    try emit(&sink, Held{ .docs = docs }, paths, anchor_ns);
    try signet.sealInto(gpa, &sink.blob);
    return sink.blob.toOwnedSlice(gpa);
}

/// `decode` wants a page-aligned `frame.Mapping`; tests copy the framed bytes
/// into an aligned buffer to mimic mmap (same helper shape as treemap_test).
fn aligned(a: std.mem.Allocator, blob: []const u8) ![]align(std.heap.page_size_min) u8 {
    const buf = try a.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), blob.len);
    @memcpy(buf, blob);
    return buf;
}

test "shard round-trips bodies and gates on freshness" {
    const t = std.testing;
    const docs = [_][]const u8{ "package main\n", "fn foo() {}\n", "})" };
    const paths = [_][]const u8{ "a/main.go", "b/foo.zig", "c/punct.txt" };
    const anchor: i128 = 1_000_000;
    const blob = try encodeForTest(t.allocator, &docs, &paths, anchor);
    defer t.allocator.free(blob);
    const map = try aligned(t.allocator, blob);
    defer t.allocator.free(map);

    var v = try decode(t.allocator, map);
    defer {
        v.indexed.deinit();
        v.paths.deinit(t.allocator);
    }

    // Unchanged (both clocks strictly before the anchor) ⇒ byte-exact body.
    try t.expectEqualStrings("package main\n", v.slice("a/main.go", anchor - 1, anchor - 1).?);
    try t.expectEqualStrings("})", v.slice("c/punct.txt", 0, 0).?);
    // A changed clock (>= anchor, either axis) forces a live read (null).
    try t.expectEqual(@as(?[]const u8, null), v.slice("b/foo.zig", anchor, anchor - 1));
    try t.expectEqual(@as(?[]const u8, null), v.slice("b/foo.zig", anchor - 1, anchor));
    // Missing metadata is conservative (null); an unknown path misses.
    try t.expectEqual(@as(?[]const u8, null), v.slice("a/main.go", null, anchor - 1));
    try t.expectEqual(@as(?[]const u8, null), v.slice("z/gone.rs", 0, 0));
}

test "shard decode fails closed on a torn blob" {
    const t = std.testing;
    const docs = [_][]const u8{"hello\n"};
    const paths = [_][]const u8{"x.txt"};
    const blob = try encodeForTest(t.allocator, &docs, &paths, 42);
    defer t.allocator.free(blob);

    const truncated = try aligned(t.allocator, blob[0 .. blob.len - 1]);
    defer t.allocator.free(truncated);
    try t.expectError(error.Corrupt, decode(t.allocator, truncated)); // content one byte short

    const bad_magic = try aligned(t.allocator, blob);
    defer t.allocator.free(bad_magic);
    bad_magic[0] = 'X';
    try t.expectError(error.Corrupt, decode(t.allocator, bad_magic));

    const stub = try aligned(t.allocator, blob[0..16]);
    defer t.allocator.free(stub);
    try t.expectError(error.Corrupt, decode(t.allocator, stub)); // shorter than the declared arrays
}

test "the shard seal is deferred, and it catches bit rot decode cannot" {
    const t = std.testing;
    // Two bodies of equal length: every offset, name, and length stays valid
    // under a flipped content byte, so the layout validation in `decode` sees
    // nothing wrong. Only the seal can tell this apart from the real shard —
    // which is the whole reason a served slice needed one.
    const docs = [_][]const u8{ "alpha\n", "bravo\n" };
    const paths = [_][]const u8{ "a.txt", "b.txt" };
    const blob = try encodeForTest(t.allocator, &docs, &paths, 42);
    defer t.allocator.free(blob);

    const map = try aligned(t.allocator, blob);
    defer t.allocator.free(map);
    var v = try decode(t.allocator, map);
    defer {
        v.indexed.deinit();
        v.paths.deinit(t.allocator);
    }
    try v.verify();
    try t.expectEqualStrings("alpha\n", v.slice("a.txt", 0, 0).?);

    const rotted = try aligned(t.allocator, blob);
    defer t.allocator.free(rotted);
    rotted[rotted.len - signet.len - 1] ^= 0x20; // last content byte
    var bad = try decode(t.allocator, rotted); // layout still parses clean…
    defer {
        bad.indexed.deinit();
        bad.paths.deinit(t.allocator);
    }
    try t.expectError(error.Corrupt, bad.verify()); // …and the seal still refuses it
}
