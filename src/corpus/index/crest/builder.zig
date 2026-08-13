//! Parallel index-time construction of exact CREST/Ridge spectra.
const std = @import("std");
const crest = @import("../../../kernel/math/crest.zig");

pub fn build(gpa: std.mem.Allocator, documents: []const []const u8) ![]crest.Spectrum {
    const out = try gpa.alloc(crest.Spectrum, documents.len);
    errdefer gpa.free(out);
    if (documents.len == 0) return out;

    const ncpu = std.Thread.getCpuCount() catch 1;
    const nshards = @max(1, @min(ncpu, @max(1, documents.len / 64)));
    if (nshards == 1) {
        summarize(documents, out);
        return out;
    }

    const Shard = struct {
        documents: []const []const u8,
        out: []crest.Spectrum,

        fn run(shard: *@This()) void {
            summarize(shard.documents, shard.out);
        }
    };
    const shards = try gpa.alloc(Shard, nshards);
    defer gpa.free(shards);
    const per = (documents.len + nshards - 1) / nshards;
    for (shards, 0..) |*shard, index| {
        const lo = @min(index * per, documents.len);
        const hi = @min(lo + per, documents.len);
        shard.* = .{ .documents = documents[lo..hi], .out = out[lo..hi] };
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

fn summarize(documents: []const []const u8, out: []crest.Spectrum) void {
    for (documents, out) |document, *ridge|
        ridge.* = crest.spectrum(document, crest.max_rank);
}
