//! gist `index --incremental` — graft the working tree's *changed* files onto
//! the existing persisted index instead of rebuilding it from scratch.
//!
//! The full build (`index.zig`) reads and trigram-extracts every file under the
//! roots — the dominant cost (the corpus read + extraction, not the sort/fold).
//! But between two builds only a sliver of the tree actually changed. The graft
//! exploits exactly the invariant the freshness overlay (`corpus/fresh.zig`)
//! already trusts — **a file's bytes changing advances its mtime** — to split
//! the corpus at the old build's anchor:
//!
//!   * `mtime < old_anchor` **and** already in the index  → UNCHANGED: reuse the
//!     doc's trigrams straight out of the old index (no disk read, no extract).
//!   * everything else (new file, or `mtime ≥ old_anchor`) → read + re-extract.
//!
//! Docs are then re-emitted in the *current* walk order (deleted files simply
//! never reappear, so they drop out; no tombstones — `persist.parsePathTable`
//! can't carry empty slots), and folded through the SAME counting-sort + CSR
//! path a full build uses (`builder.fromDocMajorPostings`). Because the posting
//! multiset and doc order are identical to what a from-scratch build over the
//! current tree would produce, the graft is **byte-identical** to a full
//! rebuild — the property `graft_test.zig` pins and the reason this is safe to
//! run unattended. It only trades work for correctness in one direction (a
//! touched-but-unchanged file gets needlessly re-read), never the other.
//!
//! Soundness note: the one way this could diverge from a full rebuild is a file
//! whose bytes changed WITHOUT its mtime advancing — the identical assumption
//! `corpus/fresh.zig` is built on, so the graft inherits (does not widen) the
//! system's existing trust boundary.

const std = @import("std");
const corpus_mod = @import("../../corpus/corpus.zig");
const haystack = @import("../../corpus/haystack.zig");
const fresh = @import("../../corpus/fresh.zig");
const persist = @import("../../index/persist.zig");
const ngram = @import("../../index/ngram.zig");
const trigram = @import("../../index/trigram.zig");
const builder = @import("../../index/builder.zig");
const Index = trigram.Index;
const Posting = trigram.Posting;
const Trigram = ngram.Trigram;

/// What the graft did — surfaced by `index.zig` in the one-line report and
/// asserted by the differential tests.
pub const Stats = struct {
    docs: usize, // total docs in the new index (== paths written)
    reused: usize, // docs whose postings came from the old index (no read)
    read: usize, // docs re-read + re-extracted (new or mtime ≥ anchor)
    new_bytes: u64, // bytes actually read this graft
    postings: usize,
    index_bytes: usize,
};

/// Per-old-doc trigram lists, inverted out of the trigram-major CSR index:
/// doc `d`'s trigrams are `tris[off[d]..off[d + 1]]`, ascending (the index is
/// walked in ascending-trigram order, so each doc's grams land sorted — exactly
/// `extractSortedUnique`'s output, which is what makes the reuse byte-exact).
pub const Inverted = struct {
    tris: []Trigram,
    off: []usize,
    pub fn deinit(self: *Inverted, gpa: std.mem.Allocator) void {
        gpa.free(self.tris);
        gpa.free(self.off);
    }
};

/// `pub` for `graft_test.zig`, which pins the invert∘refold round-trip
/// byte-identical without touching the filesystem.
pub fn invertByDoc(gpa: std.mem.Allocator, idx: *const Index) !Inverted {
    const dc: usize = idx.doc_count;
    const off = try gpa.alloc(usize, dc + 1);
    errdefer gpa.free(off);
    @memset(off, 0);

    const all = try idx.debugAllPostings(gpa); // (tri, doc), trigram-major ascending
    defer gpa.free(all);
    for (all) |p| off[@as(usize, p.doc) + 1] += 1;
    for (1..dc + 1) |i| off[i] += off[i - 1];

    const tris = try gpa.alloc(Trigram, all.len);
    errdefer gpa.free(tris);
    const cursor = try gpa.alloc(usize, dc);
    defer gpa.free(cursor);
    @memcpy(cursor, off[0..dc]);
    for (all) |p| {
        tris[cursor[p.doc]] = p.tri;
        cursor[p.doc] += 1;
    }
    return .{ .tris = tris, .off = off };
}

const DocEntry = struct { path: []const u8, tris: []const Trigram };

/// Incrementally fold the working tree onto the persisted index. Returns null
/// (no work done, no writes) when there is no prior index/anchor to graft onto
/// — the caller then falls back to a full build. On success the index + path
/// table + freshness anchor are persisted (atomically) exactly as a full build
/// leaves them, and `Stats` describes what happened.
pub fn tryFold(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8) !?Stats {
    const old_anchor = fresh.readAnchor(gpa, io) orelse return null; // pre-T3 / no index
    var loaded = (try persist.loadQuiet(gpa, io)) orelse return null; // no or torn index
    defer loaded.deinit();

    // Anchor for the NEW index — captured before any read, so a file touched
    // mid-graft is mtime ≥ new_anchor ⇒ re-verified by the next query's overlay.
    const new_anchor = std.Io.Clock.now(.real, io).nanoseconds;

    var inv = try invertByDoc(gpa, &loaded.idx);
    defer inv.deinit(gpa);

    var by_path = std.StringHashMap(u32).init(gpa);
    defer by_path.deinit();
    try by_path.ensureTotalCapacity(@intCast(loaded.paths.items.len));
    for (loaded.paths.items, 0..) |p, i| by_path.putAssumeCapacity(p, @intCast(i));

    var arena = std.heap.ArenaAllocator.init(gpa); // owns walk paths + re-read grams
    errdefer arena.deinit();
    const a = arena.allocator();

    var entries: std.ArrayList(DocEntry) = .empty;
    defer entries.deinit(gpa);
    var reused: usize = 0;
    var read: usize = 0;
    var new_bytes: u64 = 0;

    for (roots) |root_path| {
        var w = haystack.Walker.init(io, a, root_path) catch continue;
        defer w.deinit(io);
        while (try w.next(io)) |hay| {
            const old_id = by_path.get(hay.path);
            const reuse = if (old_id != null) blk: {
                const st = hay.dir.statFile(io, hay.name, .{}) catch break :blk false;
                break :blk st.mtime.nanoseconds < old_anchor;
            } else false;

            if (reuse) {
                const oid = old_id.?;
                try entries.append(gpa, .{ .path = hay.path, .tris = inv.tris[inv.off[oid]..inv.off[oid + 1]] });
                reused += 1;
            } else {
                // New file, or touched since the old build: read + re-extract,
                // applying the exact skip rules `corpus.load` uses.
                const buf = hay.dir.readFileAlloc(io, hay.name, gpa, .limited(corpus_mod.per_file_cap)) catch continue;
                defer gpa.free(buf);
                if (buf.len == 0 or corpus_mod.isBinary(buf)) continue;
                const scratch = try gpa.alloc(Trigram, buf.len);
                defer gpa.free(scratch);
                const k = ngram.extractSortedUnique(buf, scratch);
                try entries.append(gpa, .{ .path = hay.path, .tris = try a.dupe(Trigram, scratch[0..k]) });
                read += 1;
                new_bytes += buf.len;
            }
        }
    }

    // Emit doc-major postings (doc id = final walk-order index), fold via the
    // shared counting-sort/CSR path → byte-identical to a from-scratch build.
    var total_postings: usize = 0;
    for (entries.items) |e| total_postings += e.tris.len;
    const postings = try gpa.alloc(Posting, total_postings);
    defer gpa.free(postings);
    var w: usize = 0;
    for (entries.items, 0..) |e, i| {
        const doc: u32 = @intCast(i);
        for (e.tris) |t| {
            postings[w] = .{ .tri = t, .doc = doc };
            w += 1;
        }
    }

    var idx = try builder.fromDocMajorPostings(gpa, @intCast(entries.items.len), postings);
    defer idx.deinit();

    const paths = try gpa.alloc([]const u8, entries.items.len);
    defer gpa.free(paths);
    for (entries.items, 0..) |e, i| paths[i] = e.path;

    const index_bytes = try persist.persistIndexAndPaths(gpa, io, &idx, paths);
    try fresh.writeAnchor(io, new_anchor);

    return .{
        .docs = entries.items.len,
        .reused = reused,
        .read = read,
        .new_bytes = new_bytes,
        .postings = total_postings,
        .index_bytes = index_bytes,
    };
}
