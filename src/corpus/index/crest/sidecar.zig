//! Crest sidecar — the persisted per-doc crest-vector table.
//!
//! One fixed-width record per indexed doc: the crest vector ρ(d) ∈ u16^K
//! (`kernel/primitives/crest.zig`), doc-id order, little-endian. The table
//! rides the SAME generation-atomic publish as `index.gist`/`paths.list`
//! (persist.zig stages it under `gens/<id>/` and the seqlock recheck covers
//! it), so a reader can never pair a crest table with a foreign doc-id space.
//!
//! Fail-closed like every other loader tier: a missing, truncated, foreign, or
//! doc-count-mismatched blob decodes to null and the query simply loses the
//! crest sieve for that invocation — elision correctness never depends on this
//! file existing (a legacy cache without it still answers exactly).

const std = @import("std");
const crest = @import("../../../kernel/primitives/crest.zig");

pub const file_name = "crest.bin";

const magic = "GISTCRS2";
const version_off = magic.len;
const class_count_off = version_off + @sizeOf(u16);
const element_width_off = class_count_off + 1;
const doc_count_off = element_width_off + 1;
const schema_hash_off = doc_count_off + @sizeOf(u32);
const reserved_off = schema_hash_off + std.crypto.hash.sha2.Sha256.digest_length;
/// v2: magic(8), version(2), K(1), width(1), doc_count(4), schema SHA-256(32),
/// reserved-zero padding(16). Body begins at 64 for page-map alignment.
pub const header_len = 64;
const record_len = crest.K * @sizeOf(u16);
pub const EncodeError = error{ TooManyDocuments, SizeOverflow, BufferTooSmall };

/// Checked form used by the decoder so a hostile count can never wrap into a
/// plausible short body. The encoder adds the u32 document-ID-space bound.
pub fn checkedEncodedSize(doc_count: usize) ?usize {
    const body_len = std.math.mul(usize, doc_count, record_len) catch return null;
    return std.math.add(usize, header_len, body_len) catch null;
}

pub fn encodedSize(doc_count: usize) EncodeError!usize {
    if (doc_count > std.math.maxInt(u32)) return error.TooManyDocuments;
    return checkedEncodedSize(doc_count) orelse error.SizeOverflow;
}

/// Serialize `vectors` into `buf` (caller sizes via `encodedSize`). Explicit
/// little-endian writes so the blob is machine-portable like its siblings.
pub fn writeInto(vectors: []const crest.Vector, buf: []u8) EncodeError!usize {
    const need = try encodedSize(vectors.len);
    if (buf.len < need) return error.BufferTooSmall;

    @memcpy(buf[0..magic.len], magic);
    std.mem.writeInt(u16, buf[version_off..][0..2], crest.SidecarSchema.format_version, .little);
    buf[class_count_off] = @intCast(crest.K);
    buf[element_width_off] = @sizeOf(u16);
    std.mem.writeInt(u32, buf[doc_count_off..][0..4], @intCast(vectors.len), .little);
    const schema_hash = crest.SidecarSchema.hash();
    @memcpy(buf[schema_hash_off..reserved_off], &schema_hash);
    @memset(buf[reserved_off..header_len], 0);

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
/// magic, version, semantic hash, K/width, doc count, padding, byte length, or
/// alignment — disagrees. `expected_docs` binds the table to the loaded
/// index's doc space.
pub fn decode(bytes: []const u8, expected_docs: u32) ?[]const crest.Vector {
    if (bytes.len < header_len or !std.mem.eql(u8, bytes[0..magic.len], magic)) return null;
    if (std.mem.readInt(u16, bytes[version_off..][0..2], .little) != crest.SidecarSchema.format_version) return null;
    if (bytes[class_count_off] != crest.K or bytes[element_width_off] != @sizeOf(u16)) return null;
    const expected_hash = crest.SidecarSchema.hash();
    if (!std.mem.eql(u8, bytes[schema_hash_off..reserved_off], &expected_hash)) return null;
    for (bytes[reserved_off..header_len]) |padding| if (padding != 0) return null;

    const doc_count = std.mem.readInt(u32, bytes[doc_count_off..][0..4], .little);
    if (doc_count != expected_docs) return null;
    const need = checkedEncodedSize(doc_count) orelse return null;
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
