//! Codicil — the incremental amendment to a published trigram generation.
//!
//! A full `gist index` reads the whole corpus (hundreds of MiB) and rewrites
//! every artifact; when three files changed since the last build that cost is
//! structural waste. A codicil is the LSM-style delta segment (Lucene/zoekt
//! lineage) fused with gist's own machinery: the T3 freshness walk
//! (`fresh.changedSince`) names exactly the paths whose metadata moved since
//! the BASE build instant, and this module re-indexes ONLY those docs into one
//! small blob that rides the existing generation-atomic publish — the base
//! blobs are hardlinked forward unchanged (`persist.publishCodicil`), so an
//! amend writes kilobytes where a rebuild writes ~300 MiB.
//!
//! One blob carries everything the loader needs to answer layered queries
//! (`persist.Persisted.queryLiteral`/`queryAny` = base ∪ codicil ∪ tombstones):
//!   • `doc_map` — the ascending GLOBAL doc ids this codicil re-describes:
//!     dirty existing docs keep their base id; brand-new corpus members are
//!     appended at `base_doc_count..` (their paths ship in `new_paths`);
//!   • an embedded standard `Index` over the re-read LIVE bytes, local ids
//!     0..n_docs-1 ≡ `doc_map` order — reusing the proven CSR codec wholesale;
//!   • recomputed crest vectors per codicil doc, so the loader can overlay the
//!     persisted sieve table and pruning stays sound against the NEW anchor;
//!   • `tombs` — base docs whose live re-read is no longer a corpus member
//!     (deleted / became binary / emptied): their stale base postings are mere
//!     false positives, but they must never be elided or crest-pruned, so the
//!     loader forces them into every candidate set with a never-prune vector.
//!
//! SOUNDNESS: base postings for a dirty doc describe stale bytes — only in the
//! false-POSITIVE direction (the query layer unions, never subtracts, and every
//! candidate is still verified against live bytes). The false-NEGATIVE holes
//! are closed by construction: content gained since the base build is present
//! in the codicil's own postings (read at amend time), and anything newer than
//! the amend is caught by the freshness anchor, which advances to the amend
//! instant. Every decode failure — wrong magic, foreign generation, mismatched
//! doc space, torn section, invalid embedded index — reads as "no codicil":
//! the base answers exactly, degradation is always to the sound side.

const std = @import("std");
const corpus_mod = @import("../../tree/corpus.zig");
const crest = @import("../../../kernel/math/crest.zig");
const fault = @import("../../../fault.zig");
const crest_sidecar = @import("../crest/sidecar.zig");
const trigram = @import("trigram.zig");
const Index = trigram.Index;
const Dir = std.Io.Dir;

pub const file_name = "codicil.bin";
/// The per-generation base-build instant (i64 LE ns, `built.ns` format) an
/// amend measures "changed since" against. Written by the full build, carried
/// forward unchanged by every amend — so codicils always rebuild from the base
/// (no chains, no compounding id spaces).
pub const base_ns_name = "base.ns";

const magic = "GISTCOD1";
/// magic(8) + base_ns i64 + base_doc_count u32 + n_docs u32 + n_new u32 +
/// n_tomb u32 + gen_len u32 + pad u32 + new_paths_len u64 + idx_len u64.
const header_len = 56;
const max_gen_len = 128;

/// The sieve row that can never manufacture a prune: `pruned(v, ĝ)` is
/// `∃C: v[C] < ĝ[C]`, and a saturated vector is ≥ every ĝ component
/// (saturation is monotone on both compare sides — crest.zig's own posture).
pub const never_prune: crest.Vector = @splat(std.math.maxInt(u16));

fn pad8(n: usize) usize {
    return (n + 7) & ~@as(usize, 7);
}

/// Borrowed zero-copy view over a decoded codicil blob; all slices alias the
/// caller's mapping, `idx` is a borrowed `Index` (deinit frees nothing).
pub const Decoded = struct {
    base_ns: i128,
    n_new: u32,
    /// Ascending global doc ids, one per codicil doc (local id = position).
    ids: []const u32,
    /// Ascending subset of `ids` (< base_doc_count): docs whose live re-read
    /// left the corpus — always candidates, never crest-pruned.
    tombs: []const u32,
    /// Recomputed crest vectors, `ids` order (tomb rows are `never_prune`).
    rows: []const crest.Vector,
    /// NUL-joined paths for the `n_new` appended docs (ids `base_doc_count..`),
    /// ascending-id order; the loader splits them via `frame.splitNulExact`.
    new_paths_blob: []const u8,
    /// The delta index over local ids 0..ids.len-1 (borrowed, fully validated).
    idx: Index,
};

/// Decode + validate a codicil blob against the exact base doc space it must
/// amend and the generation id it was published AS (the blob embeds its own
/// publish gen, so a blob hardlinked/copied into a foreign generation
/// directory reads as absent). Null on ANY disagreement — fail-closed, the
/// caller just loses the layer.
pub fn decode(bytes: []const u8, expected_base_docs: u32, expected_gen: []const u8) ?Decoded {
    if (bytes.len < header_len or !std.mem.eql(u8, bytes[0..magic.len], magic)) return null;
    if (@intFromPtr(bytes.ptr) % 8 != 0) return null;
    const base_ns: i128 = std.mem.readInt(i64, bytes[8..16], .little);
    const base_docs = std.mem.readInt(u32, bytes[16..20], .little);
    const n_docs = std.mem.readInt(u32, bytes[20..24], .little);
    const n_new = std.mem.readInt(u32, bytes[24..28], .little);
    const n_tomb = std.mem.readInt(u32, bytes[28..32], .little);
    const gen_len = std.mem.readInt(u32, bytes[32..36], .little);
    const paths_len = std.mem.readInt(u64, bytes[40..48], .little);
    const idx_len = std.mem.readInt(u64, bytes[48..56], .little);

    if (base_docs != expected_base_docs) return null;
    if (n_docs == 0 or n_new > n_docs or n_tomb > n_docs) return null;
    if (gen_len == 0 or gen_len > max_gen_len) return null;
    if (paths_len > bytes.len or idx_len > bytes.len) return null;
    _ = std.math.add(u32, base_docs, n_new) catch return null;

    // Section offsets, every section 8-padded so the typed views stay aligned.
    const gen_off: usize = header_len;
    const map_off = gen_off + pad8(gen_len);
    const tomb_off = map_off + pad8(@as(usize, n_docs) * 4);
    const rows_off = tomb_off + pad8(@as(usize, n_tomb) * 4);
    const paths_off = rows_off + @as(usize, n_docs) * @sizeOf(crest.Vector);
    const idx_off = paths_off + pad8(@as(usize, @intCast(paths_len)));
    const total = idx_off + @as(usize, @intCast(idx_len));
    if (bytes.len != total) return null;

    if (!std.mem.eql(u8, bytes[gen_off..][0..gen_len], expected_gen)) return null;

    const ids = std.mem.bytesAsSlice(u32, @as([]align(4) const u8, @alignCast(bytes[map_off..][0 .. @as(usize, n_docs) * 4])));
    const tombs = std.mem.bytesAsSlice(u32, @as([]align(4) const u8, @alignCast(bytes[tomb_off..][0 .. @as(usize, n_tomb) * 4])));
    const rows = std.mem.bytesAsSlice(crest.Vector, @as([]align(2) const u8, @alignCast(bytes[rows_off..][0 .. @as(usize, n_docs) * @sizeOf(crest.Vector)])));
    if (comptime @import("builtin").cpu.arch.endian() != .little) return null; // LE views only, like the crest sidecar

    // doc_map: strictly ascending; the new ids are exactly the contiguous tail.
    const n_old = n_docs - n_new;
    for (ids, 0..) |id, i| {
        if (i > 0 and id <= ids[i - 1]) return null;
        if (i < n_old) {
            if (id >= base_docs) return null;
        } else if (id != base_docs + (i - n_old)) return null;
    }
    // tombs: ascending existing-doc ids, each present in doc_map's old prefix.
    for (tombs, 0..) |t, i| {
        if (i > 0 and t <= tombs[i - 1]) return null;
        if (t >= base_docs) return null;
        if (std.sort.binarySearch(u32, ids[0..n_old], t, orderU32) == null) return null;
    }
    // new_paths: exactly n_new NUL-terminated non-empty entries.
    const paths_blob = bytes[paths_off..][0..@intCast(paths_len)];
    if (n_new == 0) {
        if (paths_blob.len != 0) return null;
    } else {
        if (paths_blob.len == 0 or paths_blob[paths_blob.len - 1] != 0) return null;
        if (std.mem.count(u8, paths_blob, &[_]u8{0}) != n_new) return null;
        if (std.mem.indexOf(u8, paths_blob, "\x00\x00") != null) return null;
    }
    // Embedded index: FULL eager validation (the blob is small) + doc-space bind.
    const idx = Index.fromMappedBytes(bytes[idx_off..][0..@intCast(idx_len)]) catch return null;
    if (idx.doc_count != n_docs) return null;

    return .{ .base_ns = base_ns, .n_new = n_new, .ids = ids, .tombs = tombs, .rows = rows, .new_paths_blob = paths_blob, .idx = idx };
}

fn orderU32(a: u32, b: u32) std.math.Order {
    return std.math.order(a, b);
}

/// What an amend recorded — for the verb's one-line report.
pub const BuildStats = struct { docs: usize = 0, new: usize = 0, tombs: usize = 0 };

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Build the codicil blob for `fresh_paths` (the `changedSince(base_ns)` walk
/// result) against the base doc space `base_paths`. `publish_gen` is the
/// generation id this blob will be published AS (pre-minted via
/// `persist.newGenId`) — decode binds it to the directory the blob is loaded
/// from. Returns null when no fresh path touches the corpus at all (every one
/// is a non-member — then a pure anchor advance is sound and nothing needs
/// publishing). Caller frees the blob.
pub fn build(
    gpa: std.mem.Allocator,
    io: std.Io,
    publish_gen: []const u8,
    base_ns: i128,
    base_paths: []const []const u8,
    fresh_paths: []const []const u8,
    stats: *BuildStats,
) !?[]u8 {
    if (publish_gen.len == 0 or publish_gen.len > max_gen_len) return fault.Persist.GenerationMismatch;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Classify each fresh path (deduped) against the BASE doc space.
    var by_path = std.StringHashMap(u32).init(gpa);
    defer by_path.deinit();
    try by_path.ensureTotalCapacity(@intCast(base_paths.len));
    for (base_paths, 0..) |p, i| by_path.putAssumeCapacity(p, @intCast(i));

    var seen = std.StringHashMap(void).init(gpa);
    defer seen.deinit();
    var dirty_ids: std.ArrayList(u32) = .empty;
    defer dirty_ids.deinit(gpa);
    var new_candidates: std.ArrayList([]const u8) = .empty;
    defer new_candidates.deinit(gpa);
    for (fresh_paths) |fp| {
        if ((try seen.getOrPut(fp)).found_existing) continue;
        if (by_path.get(fp)) |id| try dirty_ids.append(gpa, id) else try new_candidates.append(gpa, fp);
    }
    std.mem.sort(u32, dirty_ids.items, {}, comptime std.sort.asc(u32));
    std.mem.sort([]const u8, new_candidates.items, {}, strLess);

    // Re-read live bytes with the ONE corpus membership rule (`readMember`).
    // A dirty existing doc that fails membership becomes a tombstone; a new
    // path that fails is simply not a corpus member and is dropped.
    var docs: std.ArrayList([]const u8) = .empty;
    defer docs.deinit(gpa);
    var ids: std.ArrayList(u32) = .empty;
    defer ids.deinit(gpa);
    var tombs: std.ArrayList(u32) = .empty;
    defer tombs.deinit(gpa);
    var kept_new: std.ArrayList([]const u8) = .empty;
    defer kept_new.deinit(gpa);

    for (dirty_ids.items) |id| {
        const body = corpus_mod.readMember(io, Dir.cwd(), base_paths[id], a);
        if (body == null) try tombs.append(gpa, id);
        try ids.append(gpa, id);
        try docs.append(gpa, body orelse "");
    }
    const base_docs_n: u32 = @intCast(base_paths.len);
    for (new_candidates.items) |np| {
        const body = corpus_mod.readMember(io, Dir.cwd(), np, a) orelse continue;
        try ids.append(gpa, base_docs_n + @as(u32, @intCast(kept_new.items.len)));
        try docs.append(gpa, body);
        try kept_new.append(gpa, np);
    }
    if (ids.items.len == 0) return null;
    stats.* = .{ .docs = ids.items.len, .new = kept_new.items.len, .tombs = tombs.items.len };

    // Delta index + crest rows over the live bytes (tombs never prune).
    var idx = try Index.build(gpa, docs.items);
    defer idx.deinit();
    const rows = try crest_sidecar.build(gpa, docs.items);
    defer gpa.free(rows);
    var ti: usize = 0;
    for (ids.items, rows) |id, *row| {
        if (ti < tombs.items.len and tombs.items[ti] == id) {
            row.* = never_prune;
            ti += 1;
        }
    }

    return try encode(gpa, publish_gen, base_ns, base_docs_n, ids.items, tombs.items, rows, kept_new.items, &idx);
}

fn encode(
    gpa: std.mem.Allocator,
    publish_gen: []const u8,
    base_ns: i128,
    base_docs: u32,
    ids: []const u32,
    tombs: []const u32,
    rows: []const crest.Vector,
    new_paths: []const []const u8,
    idx: *const Index,
) ![]u8 {
    var paths_len: usize = 0;
    for (new_paths) |p| paths_len += p.len + 1;
    const idx_len = idx.serializedSize();

    const gen_off: usize = header_len;
    const map_off = gen_off + pad8(publish_gen.len);
    const tomb_off = map_off + pad8(ids.len * 4);
    const rows_off = tomb_off + pad8(tombs.len * 4);
    const paths_off = rows_off + rows.len * @sizeOf(crest.Vector);
    const idx_off = paths_off + pad8(paths_len);

    const buf = try gpa.alloc(u8, idx_off + idx_len);
    errdefer gpa.free(buf);
    @memset(buf[0..idx_off], 0); // deterministic padding bytes

    @memcpy(buf[0..magic.len], magic);
    std.mem.writeInt(i64, buf[8..16], @intCast(base_ns), .little);
    std.mem.writeInt(u32, buf[16..20], base_docs, .little);
    std.mem.writeInt(u32, buf[20..24], @intCast(ids.len), .little);
    std.mem.writeInt(u32, buf[24..28], @intCast(new_paths.len), .little);
    std.mem.writeInt(u32, buf[28..32], @intCast(tombs.len), .little);
    std.mem.writeInt(u32, buf[32..36], @intCast(publish_gen.len), .little);
    std.mem.writeInt(u64, buf[40..48], paths_len, .little);
    std.mem.writeInt(u64, buf[48..56], idx_len, .little);

    @memcpy(buf[gen_off..][0..publish_gen.len], publish_gen);
    for (ids, 0..) |id, i| std.mem.writeInt(u32, buf[map_off + i * 4 ..][0..4], id, .little);
    for (tombs, 0..) |t, i| std.mem.writeInt(u32, buf[tomb_off + i * 4 ..][0..4], t, .little);
    var ro = rows_off;
    for (rows) |v| for (v) |x| {
        std.mem.writeInt(u16, buf[ro..][0..2], x, .little);
        ro += 2;
    };
    var po = paths_off;
    for (new_paths) |p| {
        @memcpy(buf[po..][0..p.len], p);
        buf[po + p.len] = 0;
        po += p.len + 1;
    }
    _ = idx.writeInto(buf[idx_off..]);
    return buf;
}
