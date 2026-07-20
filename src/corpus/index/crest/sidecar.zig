//! Crest sidecar — the persisted per-doc crest-vector table.
//!
//! One fixed-width record per indexed doc: the crest vector ρ(d) ∈ u16^K
//! (`math/crest.zig`), doc-id order, little-endian. The table rides the SAME
//! generation-atomic publish as `index.gist`/`paths.list` (persist.zig stages
//! it under `gens/<id>/` and the seqlock recheck covers it), so a reader can
//! never pair a crest table with a foreign doc-id space.
//!
//! Fail-closed like every other loader tier: a missing, truncated, foreign, or
//! doc-count-mismatched blob decodes to null and the query simply loses the
//! crest sieve for that invocation — elision correctness never depends on this
//! file existing (a legacy cache without it still answers exactly).

const std = @import("std");
const crest = @import("../../../kernel/primitives/crest.zig");

pub const file_name = "crest.bin";

const magic = "GISTCRS1";
/// magic(8) + doc_count u32 + k u8 + elem width u8 + pad(2) → data at 16,
/// which keeps the u16 records naturally aligned inside any page-aligned map.
pub const header_len = 16;

pub fn encodedSize(doc_count: usize) usize {
    return header_len + doc_count * crest.K * @sizeOf(u16);
}

/// Serialize `vectors` into `buf` (caller sizes via `encodedSize`). Explicit
/// little-endian writes so the blob is machine-portable like its siblings.
pub fn writeInto(vectors: []const crest.Vector, buf: []u8) usize {
    @memcpy(buf[0..magic.len], magic);
    std.mem.writeInt(u32, buf[magic.len..][0..4], @intCast(vectors.len), .little);
    buf[magic.len + 4] = @intCast(crest.K);
    buf[magic.len + 5] = @sizeOf(u16);
    buf[magic.len + 6] = 0;
    buf[magic.len + 7] = 0;
    var off: usize = header_len;
    for (vectors) |v| {
        for (v) |x| {
            std.mem.writeInt(u16, buf[off..][0..2], x, .little);
            off += 2;
        }
    }
    return off;
}

/// Borrowed zero-copy view over a mapped/loaded blob, or null when anything —
/// magic, version-bearing K/width, doc count, byte length, alignment —
/// disagrees. `expected_docs` binds the table to the loaded index's doc space.
pub fn decode(bytes: []const u8, expected_docs: u32) ?[]const crest.Vector {
    if (bytes.len < header_len or !std.mem.eql(u8, bytes[0..magic.len], magic)) return null;
    const doc_count = std.mem.readInt(u32, bytes[magic.len..][0..4], .little);
    if (doc_count != expected_docs) return null;
    if (bytes[magic.len + 4] != crest.K or bytes[magic.len + 5] != @sizeOf(u16)) return null;
    const need = encodedSize(doc_count);
    if (bytes.len != need) return null;
    const data = bytes[header_len..];
    if (@intFromPtr(data.ptr) % @alignOf(crest.Vector) != 0) return null;
    const aligned: []align(@alignOf(crest.Vector)) const u8 = @alignCast(data);
    if (comptime @import("builtin").cpu.arch.endian() != .little) return null; // LE readers only; others fall back live
    return std.mem.bytesAsSlice(crest.Vector, aligned);
}

/// Compute the crest table for `docs`, fanned across cores (the pass is
/// embarrassingly parallel and `gist index` is a dogfooded interactive verb).
pub fn build(gpa: std.mem.Allocator, docs: []const []const u8) ![]crest.Vector {
    const out = try gpa.alloc(crest.Vector, docs.len);
    errdefer gpa.free(out);
    const ncpu = std.Thread.getCpuCount() catch 1;
    const nshards = @max(1, @min(ncpu, docs.len / 64)); // tiny corpora: inline
    if (nshards <= 1) {
        for (docs, out) |d, *v| v.* = crest.crest(d);
        return out;
    }
    const Shard = struct {
        docs: []const []const u8,
        out: []crest.Vector,
        fn run(s: *@This()) void {
            for (s.docs, s.out) |d, *v| v.* = crest.crest(d);
        }
    };
    const shards = try gpa.alloc(Shard, nshards);
    defer gpa.free(shards);
    const per = (docs.len + nshards - 1) / nshards;
    for (shards, 0..) |*s, i| {
        const lo = @min(i * per, docs.len);
        const hi = @min(lo + per, docs.len);
        s.* = .{ .docs = docs[lo..hi], .out = out[lo..hi] };
    }
    const threads = try gpa.alloc(std.Thread, nshards - 1);
    defer gpa.free(threads);
    var spawned: usize = 0;
    for (shards[1..]) |*s| {
        threads[spawned] = std.Thread.spawn(.{}, Shard.run, .{s}) catch break;
        spawned += 1;
    }
    for (shards[1 + spawned ..]) |*s| s.run(); // unspawnable shards run inline
    Shard.run(&shards[0]);
    for (threads[0..spawned]) |t| t.join();
    return out;
}
