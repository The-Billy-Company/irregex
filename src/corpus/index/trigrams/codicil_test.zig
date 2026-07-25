//! Codicil tests — the incremental amendment layer, split per the shape cap and
//! wired via `root.zig`'s test block. Three rungs of the eureka ladder live
//! here: build→decode round-trip identity over real live-byte re-reads,
//! fail-closed decode over adversarial blobs (every malformed byte reads as
//! "no codicil", never garbage), and end-to-end layered-query soundness
//! through the real publish path (`persist.publishCodicil` + `loadAt`):
//! every live-matching doc is a candidate after an amend — dirty, new, and
//! tombstoned docs included — and the merged crest overlay never prunes a tomb.

const std = @import("std");
const codicil = @import("codicil.zig");
const persist = @import("persist.zig");
const crest_sidecar = @import("../crest/sidecar.zig");
const Index = @import("trigram.zig").Index;
const fault = @import("../../../fault.zig");
const Dir = std.Io.Dir;

/// Decode requires the 8-aligned base a real mmap provides; heap blobs from
/// `build` only guarantee byte alignment, so tests re-home them first.
fn alignBlob(gpa: std.mem.Allocator, blob: []const u8) ![]align(8) u8 {
    const out = try gpa.alignedAlloc(u8, comptime .fromByteUnits(8), blob.len);
    @memcpy(out, blob);
    return out;
}

fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

const Fixture = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    f: [4][]const u8,

    fn init(gpa: std.mem.Allocator, io: std.Io, comptime tag: []const u8, salt: usize) !Fixture {
        const root = try std.fmt.allocPrint(gpa, "/tmp/gist_codicil_" ++ tag ++ "_{x}", .{salt});
        errdefer gpa.free(root);
        fault.spare("clear leftover fixture", Dir.cwd().deleteTree(io, root));
        try Dir.cwd().createDirPath(io, root);
        var self: Fixture = .{ .gpa = gpa, .io = io, .root = root, .f = undefined };
        inline for (0..4) |i| self.f[i] = try std.fmt.allocPrint(gpa, "{s}/f{d}.txt", .{ root, i });
        try writeFile(io, self.f[0], "alpha cat purrs");
        try writeFile(io, self.f[1], "beta dog barks");
        try writeFile(io, self.f[2], "gamma eel swims");
        // f3 does not exist yet — it is the "new doc" of every amend below.
        return self;
    }

    fn deinit(self: *Fixture) void {
        fault.spare("remove fixture", Dir.cwd().deleteTree(self.io, self.root));
        for (self.f) |p| self.gpa.free(p);
        self.gpa.free(self.root);
    }

    /// The standard mutation: f1 rewritten, f2 deleted (tombstone), f3 born.
    fn mutate(self: *const Fixture) !void {
        try writeFile(self.io, self.f[1], "zeta quokka hops");
        try Dir.cwd().deleteFile(self.io, self.f[2]);
        try writeFile(self.io, self.f[3], "delta fox trots");
    }
};

test "codicil build→decode: round-trip identity over dirty + tombstone + new docs" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fx = try Fixture.init(gpa, io, "rt", @intFromPtr(&threaded));
    defer fx.deinit();
    try fx.mutate();

    const base_paths = [_][]const u8{ fx.f[0], fx.f[1], fx.f[2] };
    const fresh_paths = [_][]const u8{ fx.f[1], fx.f[2], fx.f[3], fx.f[1] }; // dup on purpose: build dedupes
    var stats: codicil.BuildStats = .{};
    const blob = (try codicil.build(gpa, io, "genA", 777, &base_paths, &fresh_paths, &stats)).?;
    defer gpa.free(blob);
    try std.testing.expectEqual(@as(usize, 3), stats.docs);
    try std.testing.expectEqual(@as(usize, 1), stats.new);
    try std.testing.expectEqual(@as(usize, 1), stats.tombs);

    const aligned = try alignBlob(gpa, blob);
    defer gpa.free(aligned);
    const d = codicil.decode(aligned, 3, "genA").?;

    try std.testing.expectEqual(@as(i128, 777), d.base_ns);
    try std.testing.expectEqual(@as(u32, 1), d.n_new);
    // Dirty existing docs keep base ids (1 dirty, 2 tomb); the new doc is id 3.
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, d.ids);
    try std.testing.expectEqualSlices(u32, &.{2}, d.tombs);
    // Tomb row can never manufacture a prune; live rows are real vectors.
    try std.testing.expectEqual(codicil.never_prune, d.rows[1]);
    // New-doc paths ride the blob NUL-terminated in id order.
    var expected_paths: std.ArrayList(u8) = .empty;
    defer expected_paths.deinit(gpa);
    try expected_paths.appendSlice(gpa, fx.f[3]);
    try expected_paths.append(gpa, 0);
    try std.testing.expectEqualSlices(u8, expected_paths.items, d.new_paths_blob);
    // The embedded index answers over the LIVE re-read bytes, local id order.
    try std.testing.expectEqual(@as(u32, 3), d.idx.doc_count);
    const hits = try d.idx.queryLiteral(gpa, "quokka");
    defer gpa.free(hits);
    try std.testing.expectEqualSlices(u32, &.{0}, hits); // local 0 ≡ global 1
}

test "codicil build: all-non-member fresh set is a pure anchor advance (null)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fx = try Fixture.init(gpa, io, "nul", @intFromPtr(&threaded));
    defer fx.deinit();
    // A brand-new binary file: readMember rejects it, nothing else changed.
    try writeFile(io, fx.f[3], "\x00\x01\x02binary");

    const base_paths = [_][]const u8{ fx.f[0], fx.f[1], fx.f[2] };
    var stats: codicil.BuildStats = .{};
    const blob = try codicil.build(gpa, io, "genA", 777, &base_paths, &.{fx.f[3]}, &stats);
    try std.testing.expectEqual(@as(?[]u8, null), blob);
}

test "codicil decode: every malformed blob fails closed to null" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fx = try Fixture.init(gpa, io, "adv", @intFromPtr(&threaded));
    defer fx.deinit();
    try fx.mutate();

    const base_paths = [_][]const u8{ fx.f[0], fx.f[1], fx.f[2] };
    var stats: codicil.BuildStats = .{};
    const blob = (try codicil.build(gpa, io, "genA", 777, &base_paths, &.{ fx.f[1], fx.f[2], fx.f[3] }, &stats)).?;
    defer gpa.free(blob);
    const aligned = try alignBlob(gpa, blob);
    defer gpa.free(aligned);

    // The pristine blob decodes; every single-fault mutation below must not.
    try std.testing.expect(codicil.decode(aligned, 3, "genA") != null);
    try std.testing.expectEqual(@as(?codicil.Decoded, null), codicil.decode(aligned, 3, "genB")); // foreign generation
    try std.testing.expectEqual(@as(?codicil.Decoded, null), codicil.decode(aligned, 4, "genA")); // foreign doc space
    try std.testing.expectEqual(@as(?codicil.Decoded, null), codicil.decode(aligned[0 .. aligned.len - 1], 3, "genA")); // torn tail
    try std.testing.expectEqual(@as(?codicil.Decoded, null), codicil.decode(aligned[0..16], 3, "genA")); // torn header

    const cases = [_]struct { off: usize, val: u8 }{
        .{ .off = 0, .val = 'X' }, // magic
        .{ .off = 20, .val = 0xFF }, // n_docs — section offsets walk off the blob
        .{ .off = 24, .val = 0xFF }, // n_new > n_docs
        .{ .off = 28, .val = 0xFF }, // n_tomb > n_docs
    };
    for (cases) |c| {
        const mut = try alignBlob(gpa, blob);
        defer gpa.free(mut);
        mut[c.off] = c.val;
        try std.testing.expectEqual(@as(?codicil.Decoded, null), codicil.decode(mut, 3, "genA"));
    }

    // doc_map corruption: descending ids fail the strict-ascent invariant.
    {
        const mut = try alignBlob(gpa, blob);
        defer gpa.free(mut);
        const d = codicil.decode(mut, 3, "genA").?;
        const map_off = @intFromPtr(d.ids.ptr) - @intFromPtr(mut.ptr);
        std.mem.writeInt(u32, mut[map_off..][0..4], 2, .little); // ids become [2,2,3]
        try std.testing.expectEqual(@as(?codicil.Decoded, null), codicil.decode(mut, 3, "genA"));
    }
}

test "codicil end-to-end: publish + layered load answer soundly for dirty, new, and tombstoned docs" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fx = try Fixture.init(gpa, io, "e2e", @intFromPtr(&threaded));
    defer fx.deinit();
    const out_dir = try std.fmt.allocPrint(gpa, "{s}/cache", .{fx.root});
    defer gpa.free(out_dir);

    // Full build over the pristine corpus (the BASE generation).
    const base_docs = [_][]const u8{ "alpha cat purrs", "beta dog barks", "gamma eel swims" };
    const base_paths = [_][]const u8{ fx.f[0], fx.f[1], fx.f[2] };
    var idx = try Index.build(gpa, &base_docs);
    defer idx.deinit();
    const cv = try crest_sidecar.build(gpa, &base_docs);
    defer gpa.free(cv);
    _ = try persist.persistIndexAndPathsAt(gpa, io, out_dir, &idx, &base_paths, &.{fx.root}, cv, 777);

    var base = (try persist.loadAt(gpa, io, out_dir, false)).?;
    defer base.deinit();
    const gen = try gpa.dupe(u8, base.gen.?);
    defer gpa.free(gen);
    try std.testing.expectEqual(@as(i128, 777), persist.readBaseNs(gpa, io, out_dir, gen).?);

    // Amend: f1 rewritten, f2 tombstoned, f3 born — then generation-publish
    // under a freshly minted id (the blob embeds the gen it publishes as).
    try fx.mutate();
    var gen_buf: [32]u8 = undefined;
    const new_gen = try persist.newGenId(io, &gen_buf);
    var stats: codicil.BuildStats = .{};
    const blob = (try codicil.build(gpa, io, new_gen, 777, &base_paths, &.{ fx.f[1], fx.f[2], fx.f[3] }, &stats)).?;
    defer gpa.free(blob);
    try persist.publishCodicil(io, out_dir, gen, new_gen, blob);

    var p = (try persist.loadAt(gpa, io, out_dir, false)).?;
    defer p.deinit();
    try std.testing.expect(p.cod != null);
    try std.testing.expect(!std.mem.eql(u8, p.gen.?, gen)); // a NEW generation
    // Paths extended with the appended doc; base ids untouched.
    try std.testing.expectEqual(@as(usize, 4), p.paths.items.len);
    try std.testing.expectEqualStrings(fx.f[3], p.paths.items[3]);
    // Merged crest overlay: one row per path, tomb row can never prune.
    try std.testing.expectEqual(@as(usize, 4), p.crest.?.len);
    try std.testing.expectEqual(codicil.never_prune, p.crest.?[2]);

    // SOUNDNESS (the direction that may never fail): every doc whose LIVE
    // bytes contain the probe is a candidate. Stale-base false positives are
    // allowed; a false negative is a wrong answer.
    const live = [_]?[]const u8{ "alpha cat purrs", "zeta quokka hops", null, "delta fox trots" };
    const probes = [_][]const u8{ "cat", "dog", "quokka", "eel", "fox", "purrs", "trots" };
    for (probes) |probe| {
        const ids = try p.queryLiteral(gpa, probe);
        defer gpa.free(ids);
        for (live, 0..) |body, id| {
            if (body != null and std.mem.indexOf(u8, body.?, probe) != null) {
                try std.testing.expect(std.mem.indexOfScalar(u32, ids, @intCast(id)) != null);
            }
        }
        // The tombstone is ALWAYS a candidate: its base postings are stale in
        // the false-positive direction only, so it must be read, never elided.
        try std.testing.expect(std.mem.indexOfScalar(u32, ids, 2) != null);
        // Sorted ascending, deduplicated — the Index.query contract.
        for (ids[1..], ids[0 .. ids.len - 1]) |b, a| try std.testing.expect(a < b);
    }

    // queryAny unions across needles the same way.
    const any = try p.queryAny(gpa, &.{ "quokka", "fox" });
    defer gpa.free(any);
    try std.testing.expect(std.mem.indexOfScalar(u32, any, 1) != null);
    try std.testing.expect(std.mem.indexOfScalar(u32, any, 3) != null);
}
