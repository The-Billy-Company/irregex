//! CREST v6 persisted columns.
//!
//! Predicate-major, rank-minor dense u8 columns carry the common case; sorted
//! sparse u16 overflow records preserve long runs. All views borrow the mapped
//! blob and decode validates layout, generation binding, and the artifact seal
//! before exposing any pruning data.
const std = @import("std");
const builder = @import("builder.zig");
const columnar = @import("columnar.zig");
const crest = @import("../../../kernel/math/crest.zig");
const planner = @import("planner.zig");
const portal = @import("../../../portal.zig");
const signet = @import("../frame/signet.zig");

pub const file_name = "crest.bin";
pub const magic = "GISTCRS6";
pub const header_len: usize = 192;
pub const overflow_entry_len: usize = 6;
pub const seal_len: usize = signet.len;
pub const base_saturation: u16 = std.math.maxInt(u8);

pub const predicate_count = crest.K;
pub const column_capacity = crest.spectrum_k;
pub const Spectrum = crest.Spectrum;
pub const ColumnMask = crest.ColumnMask;
pub const Digest = [signet.len]u8;
pub const buildSpectra = builder.build;

pub const Binding = struct {
    semantic_hash: Digest,
    dictionary_hash: Digest,
    build_id: Digest,

    pub fn forBuild(build_id: signet.Signet) Binding {
        return .{
            .semantic_hash = crest.SidecarSchema.hash().bytes,
            .dictionary_hash = crest.DictionarySchema.hash().bytes,
            .build_id = build_id.bytes,
        };
    }

    pub fn valid(self: Binding) bool {
        return nonzero(self.semantic_hash) and nonzero(self.dictionary_hash) and nonzero(self.build_id);
    }
};

pub const EncodeOptions = struct {
    q: u8,
    binding: Binding,
};

pub const Expected = struct {
    document_count: u32,
    q: u8,
    binding: Binding,
};

pub const EncodeError = error{
    BufferTooSmall,
    InvalidBinding,
    Overflow,
    TooManyDocuments,
    UnsupportedRank,
};

pub const Offset = struct {
    pub const version = 8;
    pub const header_size = 10;
    pub const flags = 12;
    pub const document_count = 16;
    pub const predicate_count = 20;
    pub const q = 22;
    pub const base_width = 23;
    pub const overflow_width = 24;
    pub const reserved_a = 25;
    pub const column_count = 28;
    pub const overflow_count = 32;
    pub const reserved_b = 36;
    pub const directory = 40;
    pub const base = 48;
    pub const overflow = 56;
    pub const seal = 64;
    pub const semantic_hash = 72;
    pub const dictionary_hash = 104;
    pub const build_id = 136;
    pub const padding = 168;
};

const flags: u32 = 0b111;

const Shape = struct {
    columns: usize,
    directory_offset: usize = header_len,
    base_offset: usize,
    overflow_offset: usize,
    seal_offset: usize,
    total: usize,
};

pub fn supportsQ(q: u8) bool {
    return crest.supportsRank(q);
}

pub fn encodedSize(rows: []const Spectrum, q: u8) EncodeError!usize {
    if (rows.len > std.math.maxInt(u32)) return error.TooManyDocuments;
    const overflows = try countOverflows(rows, q);
    return (shape(@intCast(rows.len), q, overflows) orelse return error.Overflow).total;
}

pub fn writeInto(rows: []const Spectrum, options: EncodeOptions, buffer: []u8) EncodeError!usize {
    if (!options.binding.valid()) return error.InvalidBinding;
    if (rows.len > std.math.maxInt(u32)) return error.TooManyDocuments;
    const overflow_count = try countOverflows(rows, options.q);
    const layout = shape(@intCast(rows.len), options.q, overflow_count) orelse return error.Overflow;
    if (buffer.len < layout.total) return error.BufferTooSmall;
    const out = buffer[0..layout.total];
    @memset(out, 0);

    @memcpy(out[0..magic.len], magic);
    put(u16, out, Offset.version, crest.SidecarSchema.format_version);
    put(u16, out, Offset.header_size, header_len);
    put(u32, out, Offset.flags, flags);
    put(u32, out, Offset.document_count, rows.len);
    put(u16, out, Offset.predicate_count, predicate_count);
    out[Offset.q] = options.q;
    out[Offset.base_width] = @sizeOf(u8);
    out[Offset.overflow_width] = @sizeOf(u16);
    put(u32, out, Offset.column_count, layout.columns);
    put(u32, out, Offset.overflow_count, overflow_count);
    put(u64, out, Offset.directory, layout.directory_offset);
    put(u64, out, Offset.base, layout.base_offset);
    put(u64, out, Offset.overflow, layout.overflow_offset);
    put(u64, out, Offset.seal, layout.seal_offset);
    @memcpy(out[Offset.semantic_hash..Offset.dictionary_hash], &options.binding.semantic_hash);
    @memcpy(out[Offset.dictionary_hash..Offset.build_id], &options.binding.dictionary_hash);
    @memcpy(out[Offset.build_id..Offset.padding], &options.binding.build_id);

    var overflow_index: u32 = 0;
    for (0..predicate_count) |predicate| for (0..options.q) |rank| {
        const physical = predicate * options.q + rank;
        put(u32, out, layout.directory_offset + physical * 4, overflow_index);
        for (rows, 0..) |row, document| {
            const value = row[crest.spectrumLane(predicate, rank)];
            out[layout.base_offset + physical * rows.len + document] = @intCast(@min(value, base_saturation));
            if (value <= base_saturation) continue;
            const entry = layout.overflow_offset + @as(usize, overflow_index) * overflow_entry_len;
            put(u32, out, entry, document);
            put(u16, out, entry + 4, value);
            overflow_index += 1;
        }
        put(u32, out, layout.directory_offset + (physical + 1) * 4, overflow_index);
    };
    signet.sealAt(out, layout.seal_offset);
    return layout.total;
}

pub const View = struct {
    document_count: u32,
    q: u8,
    base: []const u8,
    directory: []const u8,
    overflow: []const u8,
    binding: Binding,

    pub fn len(self: View) usize {
        return self.document_count;
    }

    pub fn column(self: View, predicate: usize, rank: usize) ?Column {
        if (predicate >= predicate_count or rank >= self.q) return null;
        const physical = predicate * self.q + rank;
        const first: usize = get(u32, self.directory, physical * 4);
        const last: usize = get(u32, self.directory, (physical + 1) * 4);
        return .{
            .base = self.base[physical * self.document_count ..][0..self.document_count],
            .overflow = self.overflow[first * overflow_entry_len .. last * overflow_entry_len],
        };
    }

    pub fn value(self: View, predicate: usize, rank: usize, document: usize) u16 {
        if (document >= self.document_count) return 0;
        return (self.column(predicate, rank) orelse return 0).value(document);
    }

    pub fn row(self: View, document: usize) Spectrum {
        var result = crest.zero_spectrum;
        if (document >= self.document_count) return result;
        for (0..self.q) |rank| {
            for (0..predicate_count) |predicate| {
                result[crest.spectrumLane(predicate, rank)] = self.value(predicate, rank, document);
            }
        }
        return result;
    }

    pub fn touchedColumns(self: View, swell: crest.RankedSwell) ColumnMask {
        if (!self.active(swell)) return 0;
        var touched: ColumnMask = 0;
        for (swell.requirements[0..swell.len]) |requirement| {
            for (0..swell.rank) |rank| for (0..predicate_count) |predicate| {
                if (requirement[crest.spectrumLane(predicate, rank)] != 0)
                    touched |= @as(ColumnMask, 1) << @intCast(predicate * self.q + rank);
            };
        }
        return touched;
    }

    pub fn prunesDoc(self: View, document: usize, swell: crest.RankedSwell) bool {
        if (document >= self.document_count or !self.active(swell)) return false;
        for (swell.requirements[0..swell.len]) |requirement| {
            var failed = false;
            outer: for (0..swell.rank) |rank| for (0..predicate_count) |predicate| {
                const threshold = requirement[crest.spectrumLane(predicate, rank)];
                if (threshold != 0 and self.value(predicate, rank, document) < threshold) {
                    failed = true;
                    break :outer;
                }
            };
            if (!failed) return false;
        }
        return true;
    }

    pub fn retain(self: View, candidates: anytype, swell: crest.RankedSwell) void {
        if (!self.active(swell)) return;
        var iterator = candidates.iterator(.{});
        while (iterator.next()) |document|
            if (self.prunesDoc(document, swell)) candidates.unset(document);
    }

    pub fn retainColumnar(
        self: View,
        gpa: std.mem.Allocator,
        candidates: *std.DynamicBitSet,
        swell: crest.RankedSwell,
    ) std.mem.Allocator.Error!void {
        if (!self.active(swell)) return;
        return columnar.retain(self, gpa, candidates, swell);
    }

    pub fn plan(
        self: View,
        swell: crest.RankedSwell,
        candidates: *const std.DynamicBitSet,
        coefficients: planner.Coefficients,
    ) planner.Decision {
        const touched = self.touchedColumns(swell);
        const candidate_docs = candidates.count();
        const scanned_docs = planner.scannedDocs(candidate_docs, self.document_count);
        if (touched == 0 or candidate_docs == 0)
            return planner.fromMask(touched, candidate_docs, scanned_docs, candidate_docs, coefficients);
        const max_samples = 64;
        const stride = @max(1, (candidate_docs + max_samples - 1) / max_samples);
        var sampled: usize = 0;
        var rejected: usize = 0;
        var seen: usize = 0;
        var iterator = candidates.iterator(.{});
        while (iterator.next()) |document| : (seen += 1) {
            if (seen % stride != 0 or sampled == max_samples) continue;
            sampled += 1;
            rejected += @intFromBool(self.prunesDoc(document, swell));
        }
        const predicted_rejected = if (sampled == 0) 0 else @as(u64, @intCast(@as(u128, rejected) * candidate_docs / sampled));
        return planner.fromMask(touched, candidate_docs, scanned_docs, candidate_docs - predicted_rejected, coefficients);
    }

    fn active(self: View, swell: crest.RankedSwell) bool {
        if (!swell.active() or swell.rank > self.q) return false;
        return true;
    }
};

pub const Column = struct {
    base: []const u8,
    overflow: []const u8,

    pub fn value(self: Column, document: usize) u16 {
        if (document >= self.base.len) return 0;
        const compact = self.base[document];
        if (compact < base_saturation) return compact;
        var lo: usize = 0;
        var hi = self.overflow.len / overflow_entry_len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (get(u32, self.overflow, mid * overflow_entry_len) < document) lo = mid + 1 else hi = mid;
        }
        if (lo == self.overflow.len / overflow_entry_len or
            get(u32, self.overflow, lo * overflow_entry_len) != document) return compact;
        return get(u16, self.overflow, lo * overflow_entry_len + 4);
    }
};

pub fn decode(bytes: []const u8, expected: Expected) ?View {
    if (!expected.binding.valid() or bytes.len < header_len + seal_len) return null;
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return null;
    if (get(u16, bytes, Offset.version) != crest.SidecarSchema.format_version or
        get(u16, bytes, Offset.header_size) != header_len or
        get(u32, bytes, Offset.flags) != flags) return null;
    const documents = get(u32, bytes, Offset.document_count);
    const q = bytes[Offset.q];
    if (documents != expected.document_count or q != expected.q or !supportsQ(q)) return null;
    if (get(u16, bytes, Offset.predicate_count) != predicate_count or
        bytes[Offset.base_width] != @sizeOf(u8) or
        bytes[Offset.overflow_width] != @sizeOf(u16)) return null;
    for (bytes[Offset.reserved_a..Offset.column_count]) |byte| if (byte != 0) return null;
    if (get(u32, bytes, Offset.reserved_b) != 0) return null;
    const overflow_count = get(u32, bytes, Offset.overflow_count);
    const layout = shape(documents, q, overflow_count) orelse return null;
    if (get(u32, bytes, Offset.column_count) != layout.columns or
        get(u64, bytes, Offset.directory) != layout.directory_offset or
        get(u64, bytes, Offset.base) != layout.base_offset or
        get(u64, bytes, Offset.overflow) != layout.overflow_offset or
        get(u64, bytes, Offset.seal) != layout.seal_offset or bytes.len != layout.total) return null;
    if (!std.mem.eql(u8, bytes[Offset.semantic_hash..Offset.dictionary_hash], &expected.binding.semantic_hash) or
        !std.mem.eql(u8, bytes[Offset.dictionary_hash..Offset.build_id], &expected.binding.dictionary_hash) or
        !std.mem.eql(u8, bytes[Offset.build_id..Offset.padding], &expected.binding.build_id)) return null;
    for (bytes[Offset.padding..header_len]) |byte| if (byte != 0) return null;

    const directory = bytes[layout.directory_offset..layout.base_offset];
    const base = bytes[layout.base_offset..layout.overflow_offset];
    const overflow = bytes[layout.overflow_offset..layout.seal_offset];
    if (get(u32, directory, 0) != 0 or get(u32, directory, layout.columns * 4) != overflow_count) return null;
    for (0..layout.columns) |physical| {
        const first: usize = get(u32, directory, physical * 4);
        const last: usize = get(u32, directory, (physical + 1) * 4);
        if (first > last or last > overflow_count) return null;
        var previous: ?u32 = null;
        for (first..last) |index| {
            const entry = index * overflow_entry_len;
            const document = get(u32, overflow, entry);
            const value = get(u16, overflow, entry + 4);
            if (document >= documents or value <= base_saturation or
                base[physical * documents + document] != base_saturation) return null;
            if (previous) |last_document| if (document <= last_document) return null;
            previous = document;
        }
    }
    signet.verify(bytes) catch return null;
    return .{
        .document_count = documents,
        .q = q,
        .base = base,
        .directory = directory,
        .overflow = overflow,
        .binding = expected.binding,
    };
}

pub fn verify(bytes: []const u8) signet.Error!void {
    return signet.verify(bytes);
}

/// q=1 resident table retained for the warm session, whose live documents need
/// no persisted column layout or freshness binding.
pub fn build(gpa: std.mem.Allocator, docs: []const []const u8) ![]crest.Vector {
    const out = try gpa.alloc(crest.Vector, docs.len);
    errdefer gpa.free(out);
    const ncpu = portal.cpuCount() catch 1;
    const nshards = @max(1, @min(ncpu, docs.len / 64));
    if (nshards <= 1) {
        for (docs, out) |document, *vector| vector.* = crest.crest(document);
        return out;
    }
    const Shard = struct {
        docs: []const []const u8,
        out: []crest.Vector,
        fn run(shard: *@This()) void {
            for (shard.docs, shard.out) |document, *vector| vector.* = crest.crest(document);
        }
    };
    const shards = try gpa.alloc(Shard, nshards);
    defer gpa.free(shards);
    const per = (docs.len + nshards - 1) / nshards;
    for (shards, 0..) |*shard, index| {
        const lo = @min(index * per, docs.len);
        const hi = @min(lo + per, docs.len);
        shard.* = .{ .docs = docs[lo..hi], .out = out[lo..hi] };
    }
    const threads = try gpa.alloc(std.Thread, nshards - 1);
    defer gpa.free(threads);
    var spawned: usize = 0;
    for (shards[1..]) |*shard| {
        threads[spawned] = std.Thread.spawn(.{}, Shard.run, .{shard}) catch break;
        spawned += 1;
    }
    for (shards[1 + spawned ..]) |*shard| shard.run();
    Shard.run(&shards[0]);
    for (threads[0..spawned]) |thread| thread.join();
    return out;
}

fn countOverflows(rows: []const Spectrum, q: u8) EncodeError!u32 {
    if (!supportsQ(q)) return error.UnsupportedRank;
    var count: u32 = 0;
    for (rows) |row| for (0..q) |rank| for (0..predicate_count) |predicate| {
        if (row[crest.spectrumLane(predicate, rank)] > base_saturation)
            count = std.math.add(u32, count, 1) catch return error.Overflow;
    };
    return count;
}

fn shape(documents: u32, q: u8, overflows: u32) ?Shape {
    if (!supportsQ(q)) return null;
    const columns = std.math.mul(usize, predicate_count, q) catch return null;
    const directory_len = std.math.mul(usize, columns + 1, @sizeOf(u32)) catch return null;
    const base_len = std.math.mul(usize, documents, columns) catch return null;
    const overflow_len = std.math.mul(usize, overflows, overflow_entry_len) catch return null;
    const base_offset = std.math.add(usize, header_len, directory_len) catch return null;
    const overflow_offset = std.math.add(usize, base_offset, base_len) catch return null;
    const seal_offset = std.math.add(usize, overflow_offset, overflow_len) catch return null;
    const total = std.math.add(usize, seal_offset, seal_len) catch return null;
    return .{ .columns = columns, .base_offset = base_offset, .overflow_offset = overflow_offset, .seal_offset = seal_offset, .total = total };
}

fn put(comptime T: type, bytes: []u8, offset: usize, value: anytype) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], @intCast(value), .little);
}

fn get(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

fn nonzero(bytes: Digest) bool {
    for (bytes) |byte| if (byte != 0) return true;
    return false;
}
