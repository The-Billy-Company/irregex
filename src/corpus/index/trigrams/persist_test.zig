//! irregex T0 persisted index/path-table tests — split per the shape cap, wired
//! via `root.zig`'s test block. Exercises the doc→path integrity invariant
//! (`validatePersistedPair`), the NUL-split (`frame.parsePathTable`), generation
//! matching, and a filesystem concurrency regression for generation publish.

const std = @import("std");
const persist = @import("persist.zig");
const frame = @import("../frame/frame.zig");
const crest = @import("../../../kernel/math/crest.zig");
const crest_builder = @import("../crest/builder.zig");
const crest_sidecar = @import("../crest/sidecar.zig");
const Index = @import("trigram.zig").Index;
const Dir = std.Io.Dir;

test "parsePathTable: splits NUL-separated paths in doc-id order, dropping a trailing NUL" {
    const a = std.testing.allocator;
    var p = try frame.parsePathTable(a, "a\x00bb\x00ccc\x00");
    defer p.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), p.items.len);
    try std.testing.expectEqualStrings("a", p.items[0]);
    try std.testing.expectEqualStrings("bb", p.items[1]);
    try std.testing.expectEqualStrings("ccc", p.items[2]);
}

test "parsePathTable: a coalesced double-NUL drops the empty (a count mismatch then catches it)" {
    const a = std.testing.allocator;
    var p = try frame.parsePathTable(a, "a\x00\x00b");
    defer p.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), p.items.len);
    try std.testing.expectEqualStrings("a", p.items[0]);
    try std.testing.expectEqualStrings("b", p.items[1]);
}

test "validatePersistedPair: accepts exactly doc_count paths" {
    const paths = [_][]const u8{ "a", "b", "c" };
    try persist.validatePersistedPair(3, &paths);
}

test "validatePersistedPair: rejects a shorter or longer path table (the doc-id OOB guard)" {
    const paths = [_][]const u8{ "a", "b", "c" };
    try std.testing.expectError(persist.PairError.Corrupt, persist.validatePersistedPair(4, &paths));
    try std.testing.expectError(persist.PairError.Corrupt, persist.validatePersistedPair(2, &paths));
}

test "validatePersistedPair: an empty table matches only doc_count 0" {
    try persist.validatePersistedPair(0, &.{});
    try std.testing.expectError(persist.PairError.Corrupt, persist.validatePersistedPair(1, &.{}));
}

test "validateGeneration: accepts identical ids and rejects drift" {
    try persist.validateGeneration("abc", "abc");
    try std.testing.expectError(persist.PairError.GenerationMismatch, persist.validateGeneration("abc", "abx"));
}

test "persistIndexAndPathsAt: generation publish keeps readers off a torn pair" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = try std.fmt.allocPrint(gpa, "/tmp/gist_persist_gen_{x}", .{@intFromPtr(&threaded)});
    defer gpa.free(root);
    Dir.cwd().deleteTree(io, root) catch {};
    defer Dir.cwd().deleteTree(io, root) catch {};

    const docs_a = [_][]const u8{ "alpha cat", "beta dog" };
    const paths_a = [_][]const u8{ "a.txt", "b.txt" };
    var idx_a = try Index.build(gpa, &docs_a);
    defer idx_a.deinit();
    const crest_a = try crest_builder.build(gpa, &docs_a);
    defer gpa.free(crest_a);
    _ = try persist.persistIndexAndPathsAt(gpa, io, root, &idx_a, &paths_a, &.{"src"}, crest_a, std.Io.Clock.now(.real, io).nanoseconds);

    var loaded_a = (try persist.loadAt(gpa, io, root, false)).?;
    defer loaded_a.deinit();
    try std.testing.expectEqual(@as(u32, 2), loaded_a.idx.doc_count);
    try std.testing.expectEqualStrings("a.txt", loaded_a.paths.items[0]);
    // Crest sidecar rides the same generation: mapped back doc-for-doc.
    for (crest_a, 0..) |spectrum, document|
        try std.testing.expectEqual(spectrum, loaded_a.crest.?.row(document));
    // Build roots round-trip beside the pair (the un-hardcoded corpus scope).
    try std.testing.expectEqual(@as(usize, 1), loaded_a.roots.items.len);
    try std.testing.expectEqualStrings("src", loaded_a.roots.items[0]);

    // Stage a second generation WITHOUT flipping pair.gen — the classic torn
    // window if the index blob and its path table were published as two
    // independent renames.
    const docs_b = [_][]const u8{ "gamma eel", "delta fox", "epsilon gnu" };
    const paths_b = [_][]const u8{ "c.txt", "d.txt", "e.txt" };
    var idx_b = try Index.build(gpa, &docs_b);
    defer idx_b.deinit();
    const blob_b = try gpa.alloc(u8, idx_b.serializedSize());
    defer gpa.free(blob_b);
    _ = idx_b.writeInto(blob_b);
    var pl_b: std.ArrayList(u8) = .empty;
    defer pl_b.deinit(gpa);
    for (paths_b) |p| {
        try pl_b.appendSlice(gpa, p);
        try pl_b.append(gpa, 0);
    }
    const staged = try std.fmt.allocPrint(gpa, "{s}/gens/staged-torn", .{root});
    defer gpa.free(staged);
    try Dir.cwd().createDirPath(io, staged);
    const staged_index = try std.fmt.allocPrint(gpa, "{s}/index.gist", .{staged});
    defer gpa.free(staged_index);
    const staged_paths = try std.fmt.allocPrint(gpa, "{s}/paths.list", .{staged});
    defer gpa.free(staged_paths);
    try frame.writeAtomic(io, staged_index, blob_b);
    try frame.writeAtomic(io, staged_paths, pl_b.items);
    // Poison the stable aliases the way a non-atomic publisher would mid-flight:
    // new index blob, still-old path table on the stable names.
    const stable_index = try std.fmt.allocPrint(gpa, "{s}/index.gist", .{root});
    defer gpa.free(stable_index);
    try frame.writeAtomic(io, stable_index, blob_b);

    // pair.gen still names generation A → load must keep A's consistent pair,
    // not the poisoned stable index blob + old path table mix.
    var loaded_mid = (try persist.loadAt(gpa, io, root, false)).?;
    defer loaded_mid.deinit();
    try std.testing.expectEqual(@as(u32, 2), loaded_mid.idx.doc_count);
    try std.testing.expectEqual(@as(usize, 2), loaded_mid.paths.items.len);
    try std.testing.expectEqualStrings("a.txt", loaded_mid.paths.items[0]);

    // Completing publish flips the generation; load now sees B. No crest was
    // staged for B, so the loader reports null — never a stale A table.
    _ = try persist.persistIndexAndPathsAt(gpa, io, root, &idx_b, &paths_b, &.{"src"}, null, std.Io.Clock.now(.real, io).nanoseconds);
    var loaded_b = (try persist.loadAt(gpa, io, root, false)).?;
    defer loaded_b.deinit();
    try std.testing.expectEqual(@as(u32, 3), loaded_b.idx.doc_count);
    try std.testing.expectEqual(@as(usize, 3), loaded_b.paths.items.len);
    try std.testing.expectEqualStrings("c.txt", loaded_b.paths.items[0]);
    try std.testing.expect(loaded_b.crest == null);
}

test "loadAt: a crest table whose records rotted is refused, so nothing it says can prune" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = try std.fmt.allocPrint(gpa, "/tmp/gist_persist_seal_{x}", .{@intFromPtr(&threaded)});
    defer gpa.free(root);
    Dir.cwd().deleteTree(io, root) catch {};
    defer Dir.cwd().deleteTree(io, root) catch {};

    const docs = [_][]const u8{ "deadbeef0123", "no runs here" };
    const paths = [_][]const u8{ "a.txt", "b.txt" };
    var idx = try Index.build(gpa, &docs);
    defer idx.deinit();
    const vectors = try crest_builder.build(gpa, &docs);
    defer gpa.free(vectors);
    _ = try persist.persistIndexAndPathsAt(gpa, io, root, &idx, &paths, &.{"."}, vectors, std.Io.Clock.now(.real, io).nanoseconds);

    {
        var pristine = (try persist.loadAt(gpa, io, root, false)).?;
        defer pristine.deinit();
        for (vectors, 0..) |spectrum, document|
            try std.testing.expectEqual(spectrum, pristine.crest.?.row(document));
    }

    // Rot ONE class of ONE record downward, in the generation directory the
    // loader actually reads. What is left is a structurally perfect table: right
    // magic, right version, right schema signet, right doc count, right length,
    // right alignment — every check `decode` performs still passes.
    const gen_path = try std.fmt.allocPrint(gpa, "{s}/pair.gen", .{root});
    defer gpa.free(gen_path);
    const gen_blob = try Dir.cwd().readFileAlloc(io, gen_path, gpa, .limited(128));
    defer gpa.free(gen_blob);
    const gen = std.mem.trimEnd(u8, gen_blob, "\r\n");
    const blob_path = try std.fmt.allocPrint(gpa, "{s}/gens/{s}/{s}", .{ root, gen, crest_sidecar.file_name });
    defer gpa.free(blob_path);
    const blob = try Dir.cwd().readFileAlloc(io, blob_path, gpa, .limited(1 << 20));
    defer gpa.free(blob);
    const rotted_doc = 0;
    const vector = crest.crest(docs[rotted_doc]);
    const klass = for (vector, 0..) |run, k| {
        if (run > 0) break k;
    } else return error.FixtureHasNoRunToLose;
    const base: usize = std.mem.readInt(u64, blob[crest_sidecar.Offset.base..][0..8], .little);
    const at = base + klass * crest.max_rank * docs.len + rotted_doc;
    blob[at] -= 1;
    try Dir.cwd().writeFile(io, .{ .sub_path = blob_path, .data = blob });

    // Why that is a soundness bug and not a cosmetic one: a query whose forced
    // crest is the document's own vector must NOT prune it, and one missing unit
    // in one class is enough to flip that. So an unverified table's failure mode
    // is a LOST match — which is what the seal is spent on.
    var sieve: crest.Swell = .{ .len = 1 };
    sieve.crests[0] = vector;
    var rotted = vector;
    rotted[klass] -= 1;
    try std.testing.expect(!sieve.prunes(vector));
    try std.testing.expect(sieve.prunes(rotted));

    var loaded = (try persist.loadAt(gpa, io, root, false)).?;
    defer loaded.deinit();
    // The pair still loads and still answers — only the sieve stands down.
    try std.testing.expectEqual(@as(u32, 2), loaded.idx.doc_count);
    try std.testing.expect(loaded.crest == null);
    // `short_docs` is derived from the same bytes, so it must fall with them:
    // an upward rot there would hide a short document from the sliver tier.
    try std.testing.expectEqual(@as(?[]u32, null), loaded.short_docs);
}

test "persistIndexAndPathsAt: publishing retires the generations it supersedes" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = try std.fmt.allocPrint(gpa, "/tmp/gist_persist_lapse_{x}", .{@intFromPtr(&threaded)});
    defer gpa.free(root);
    Dir.cwd().deleteTree(io, root) catch {};
    defer Dir.cwd().deleteTree(io, root) catch {};

    // Four ancient generations (a tiny id is a nanosecond stamp from 1970, so
    // each is far outside any grace window), plus a directory whose name no
    // publish could have minted. Publishing under the DEFAULT policy should
    // collect the oldest two, hold the newest two as reader grace, and never
    // touch the alien — proving `publishGeneration` really runs retention, and
    // runs it under the policy production gets, which testing `lapse` directly
    // cannot show.
    var stale: [4][]const u8 = undefined;
    for (&stale, [_][]const u8{ "10", "20", "30", "40" }) |*slot, id| {
        slot.* = try std.fmt.allocPrint(gpa, "{s}/gens/{s}", .{ root, id });
        try Dir.cwd().createDirPath(io, slot.*);
    }
    defer for (stale) |s| gpa.free(s);
    const alien = try std.fmt.allocPrint(gpa, "{s}/gens/scratch", .{root});
    defer gpa.free(alien);
    try Dir.cwd().createDirPath(io, alien);

    const docs = [_][]const u8{"alpha cat"};
    const paths = [_][]const u8{"a.txt"};
    var idx = try Index.build(gpa, &docs);
    defer idx.deinit();
    _ = try persist.persistIndexAndPathsAt(gpa, io, root, &idx, &paths, &.{"."}, null, std.Io.Clock.now(.real, io).nanoseconds);

    try std.testing.expectError(error.FileNotFound, Dir.cwd().statFile(io, stale[0], .{}));
    try std.testing.expectError(error.FileNotFound, Dir.cwd().statFile(io, stale[1], .{}));
    _ = try Dir.cwd().statFile(io, stale[2], .{}); // reader grace (keep = 2)
    _ = try Dir.cwd().statFile(io, stale[3], .{});
    _ = try Dir.cwd().statFile(io, alien, .{});

    // The pair this publish made live is of course still readable — retention
    // must never cost the generation it was triggered by.
    var loaded = (try persist.loadAt(gpa, io, root, false)).?;
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u32, 1), loaded.idx.doc_count);
    try std.testing.expectEqualStrings("a.txt", loaded.paths.items[0]);
}

test "persistIndexAndPathsAt: concurrent loaders never observe a mixed generation" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = try std.fmt.allocPrint(gpa, "/tmp/gist_persist_race_{x}", .{@intFromPtr(&threaded)});
    defer gpa.free(root);
    Dir.cwd().deleteTree(io, root) catch {};
    defer Dir.cwd().deleteTree(io, root) catch {};

    const docs0 = [_][]const u8{"seed aaa"};
    const paths0 = [_][]const u8{"seed.txt"};
    var idx0 = try Index.build(gpa, &docs0);
    defer idx0.deinit();
    _ = try persist.persistIndexAndPathsAt(gpa, io, root, &idx0, &paths0, &.{"."}, null, std.Io.Clock.now(.real, io).nanoseconds);

    const Worker = struct {
        root: []const u8,
        io: std.Io,
        mismatches: *std.atomic.Value(usize),
        fn run(self: *@This()) void {
            var i: usize = 0;
            while (i < 40) : (i += 1) {
                var loaded = persist.loadAt(std.heap.page_allocator, self.io, self.root, false) catch {
                    _ = self.mismatches.fetchAdd(1, .monotonic);
                    continue;
                } orelse continue;
                defer loaded.deinit();
                if (loaded.paths.items.len != loaded.idx.doc_count) {
                    _ = self.mismatches.fetchAdd(1, .monotonic);
                }
            }
        }
    };

    var mismatches: std.atomic.Value(usize) = .init(0);
    var w1: Worker = .{ .root = root, .io = io, .mismatches = &mismatches };
    var w2: Worker = .{ .root = root, .io = io, .mismatches = &mismatches };
    const t1 = try std.Thread.spawn(.{}, Worker.run, .{&w1});
    const t2 = try std.Thread.spawn(.{}, Worker.run, .{&w2});

    var n: usize = 0;
    while (n < 25) : (n += 1) {
        const docs = [_][]const u8{ "pub one", "pub two", "pub three" };
        // Alternate path-table lengths so a torn stable-path publish would
        // produce a detectable doc_count ≠ paths.len mismatch.
        const paths_odd = [_][]const u8{ "o1.txt", "o2.txt", "o3.txt" };
        const paths_even = [_][]const u8{ "e1.txt", "e2.txt" };
        var idx = try Index.build(gpa, if (n % 2 == 0) docs[0..2] else docs[0..3]);
        defer idx.deinit();
        const paths: []const []const u8 = if (n % 2 == 0) &paths_even else &paths_odd;
        _ = try persist.persistIndexAndPathsAt(gpa, io, root, &idx, paths, &.{"."}, null, std.Io.Clock.now(.real, io).nanoseconds);
    }

    t1.join();
    t2.join();
    try std.testing.expectEqual(@as(usize, 0), mismatches.load(.monotonic));
}
