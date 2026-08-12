//! gist — "it is not HERE, but it is THERE": the sighting behind the only hint a
//! scoped miss really wants.
//!
//! A search scoped to paths that comes back empty has two very different causes
//! wearing one exit code — the string does not exist, or it exists somewhere the
//! reader did not look — and the pattern's own syntax cannot tell them apart. So
//! the flag-shaped hints used to guess (`-i`, `-F`, `-uu`) while the actual
//! answer, a sibling file holding the exact literal, went unsaid. This module
//! asks the corpus that question and hands `emit/hints.zig` a `Sighting` it can
//! print without qualification.
//!
//! It is the same seam `elide.zig` opens, asked in the opposite direction. There,
//! the index says which files *cannot* match so their reads are skipped; here it
//! nominates files that plausibly *do*, outside the scope the walk was given.
//! And because a trigram answer is a CANDIDATE set — sound in the negative
//! direction only (Cox 2012) — a nomination is never printed on the index's word
//! alone: each one is confirmed against that file's current bytes before it can
//! become a hint. A hint sending someone to a file that turns out not to hold the
//! string would be worse than the guesses it replaces.
//!
//! Everything here is a courtesy on an already-failed run, so every reason to
//! stop is a silent decline: no index, an unreadable candidate, a needle below
//! the trigram floor, `--no-index`, or simply the budget running out. Declining
//! costs the reader one hint they never knew about; being wrong or slow would
//! cost them their trust in the channel.

const std = @import("std");
const assay = @import("../../../assay/assay.zig");
const hints = @import("../emit/hints.zig");
const persist = @import("../../../corpus/index/trigrams/persist.zig");

const Dir = std.Io.Dir;

/// Files opened to confirm a nomination, across the whole sighting. The index
/// usually nominates the right file first — path affinity sorts the codegen
/// sibling to the front — so this is generous rather than tight, and it is a
/// ceiling on a run that already produced nothing.
const max_reads = 8;

/// Largest candidate this will read. A confirmation is a `memmem` over one file;
/// past a few megabytes the courtesy starts costing more than the search did.
const max_read_bytes: usize = 4 << 20;

/// Branches given their own index lookup. A query bundling more probes than this
/// gets the first few explained, which is all a three-line channel can print.
const max_branches = 4;

/// Look for the pattern outside the scope that was searched, and record it on
/// `ev` when a file is found and confirmed to hold it.
///
/// Takes `ev` by pointer because a sighting is one more fact about the same
/// failure, not a separate answer — the caller hands the whole `Evidence` to
/// `hints.noMatches` either way and never has to branch on whether this
/// succeeded. Nothing is allocated on the decline paths.
pub fn sight(a: std.mem.Allocator, io: std.Io, no_index: bool, s: hints.Shape, ev: *hints.Evidence) void {
    // Only a scoped miss has an "elsewhere" — a whole-tree search already read
    // everything the index could nominate, and `-v` makes presence meaningless.
    if (s.scope != .paths or s.invert or no_index) return;
    // A literal wholly present in scope is not a scope problem (`-w`/`-x` can
    // arrange that), and a run whose branches were never probed has no literal to
    // look for.
    if (ev.branches.len == 0) return;

    var p = (persist.loadQuiet(a, io) catch return) orelse return;
    defer p.deinit();

    var reads: usize = 0;
    for (ev.branches[0..@min(ev.branches.len, max_branches)]) |b| {
        // `literal`, not `probed`: an index lookup needs bytes to look up, and it
        // does not care whether anyone had the scope's bytes in hand.
        if (!b.literal) continue;
        var lit_buf: [256]u8 = undefined;
        const lit = hints.literalBytes(b.text, s.fixed, &lit_buf) orelse continue;
        if (found(a, io, &p, s, lit, &reads)) |seen| {
            ev.elsewhere = .{ .branch = b.text, .path = seen.path, .more = seen.more };
            return;
        }
        if (reads >= max_reads) return;
    }
}

/// The whole evidence answer for an engine that kept none of the bytes it read.
///
/// The parallel walk streams each file past its worker and retains nothing, so it
/// arrives at the no-match exit with a pattern and no corpus — and it is the
/// engine that serves most real queries, which made it the one place the channel
/// stayed as uninformed as it was before. Two recoveries, in cost order: a scope
/// made of named files is small and bounded, so re-reading it buys the near-miss
/// finding outright; and the sighting never needed the scope's bytes at all.
pub fn afterStreaming(a: std.mem.Allocator, io: std.Io, no_index: bool, s: hints.Shape) hints.Evidence {
    var ev: hints.Evidence = if (scopeFiles(a, io, s)) |files|
        hints.probe(a, s, files)
    else
        .{ .branches = hints.branchesOf(a, s) };
    sight(a, io, no_index, s, &ev);
    return ev;
}

/// A probe-shaped record over bytes this module read itself. Structurally what
/// `hints.probe` wants of an intake record, and nothing more.
const Resident = struct { bytes: []const u8 };

/// The scope's own bytes, when the scope is cheap to materialize: explicit
/// regular-file roots, inside the read budget. Null for a directory or tree
/// scope, where re-walking to explain a miss would cost more than the search did
/// — the near-miss finding is a courtesy, and a courtesy may decline.
fn scopeFiles(a: std.mem.Allocator, io: std.Io, s: hints.Shape) ?[]const Resident {
    const roots = switch (s.scope) {
        .paths => |r| r,
        .tree, .stream => return null,
    };
    if (roots.len == 0 or roots.len > max_reads) return null;
    const out = a.alloc(Resident, roots.len) catch return null;
    for (roots, out) |root, *slot| {
        const st = Dir.cwd().statFile(io, root, .{}) catch return null;
        if (st.kind != .file or st.size > max_read_bytes) return null;
        slot.bytes = Dir.cwd().readFileAlloc(io, root, a, .limited(max_read_bytes)) catch return null;
    }
    return out;
}

/// One branch's answer: the first confirmed file, and how many others were also
/// confirmed before the budget ran out.
const Seen = struct { path: []const u8, more: usize };

/// Ask the index for `lit`, then confirm its nominations against live bytes,
/// nearest-to-the-scope first. `reads` is the shared budget across branches.
fn found(a: std.mem.Allocator, io: std.Io, p: *const persist.Persisted, s: hints.Shape, lit: []const u8, reads: *usize) ?Seen {
    const docs = p.queryLiteral(a, lit) catch return null;
    defer a.free(docs);
    if (docs.len == 0) return null;

    const roots = s.scope.paths;
    // Affinity, not relevance: the file that explains a scoped miss is usually
    // sitting beside the file that was searched — a generated twin, a sibling
    // module, the same package. Sorting by shared path prefix puts it first, so
    // the read budget is spent on the likely answer instead of on whichever
    // document happened to be indexed earliest.
    const order = a.alloc(u32, docs.len) catch return null;
    defer a.free(order);
    @memcpy(order, docs);
    const affinity = a.alloc(usize, docs.len) catch return null;
    defer a.free(affinity);
    for (docs, affinity) |d, *score| {
        const path = p.paths.items[d];
        var best: usize = 0;
        for (roots) |r| best = @max(best, shared(path, trimRoot(r)));
        score.* = best;
    }
    sortByAffinity(order, docs, affinity);

    var first: ?[]const u8 = null;
    var more: usize = 0;
    for (order) |d| {
        if (reads.* >= max_reads) break;
        const path = p.paths.items[d];
        // The scope is where we already know it is not; a "sighting" there would
        // be either a tombstoned index row or a file the walk excluded, and
        // neither is something to send a reader back to.
        if (inScope(path, roots)) continue;
        reads.* += 1;
        const bytes = Dir.cwd().readFileAlloc(io, path, a, .limited(max_read_bytes)) catch continue;
        defer a.free(bytes);
        const hit = if (s.caseless)
            std.ascii.indexOfIgnoreCase(bytes, lit) != null
        else
            std.mem.indexOf(u8, bytes, lit) != null;
        if (!hit) continue;
        if (first == null) first = a.dupe(u8, path) catch return null else more += 1;
    }
    assay.trace(.query, assay.tag ++ "witness lit={s} candidates={d} reads={d} found={d}\n", .{ lit, docs.len, reads.*, @intFromBool(first != null) });
    return if (first) |path| .{ .path = path, .more = more } else null;
}

/// Insertion sort on affinity, descending. The candidate list is usually a
/// handful of documents and never worth a comparator allocation; ties keep index
/// order, so the choice stays deterministic across runs.
fn sortByAffinity(order: []u32, docs: []const u32, affinity: []const usize) void {
    var i: usize = 1;
    while (i < order.len) : (i += 1) {
        const doc = order[i];
        const score = affinity[std.mem.indexOfScalar(u32, docs, doc).?];
        var j = i;
        while (j > 0 and affinity[std.mem.indexOfScalar(u32, docs, order[j - 1]).?] < score) : (j -= 1)
            order[j] = order[j - 1];
        order[j] = doc;
    }
}

/// A root as the corpus spells paths: no `./`, no trailing slash.
fn trimRoot(raw: []const u8) []const u8 {
    var r = raw;
    while (std.mem.startsWith(u8, r, "./")) r = r[2..];
    return std.mem.trimEnd(u8, r, "/");
}

/// Bytes of leading path shared by two paths, truncated to a whole segment so
/// `attrs.py` and `attrs.gen.py` score their directory rather than a partial
/// filename — affinity is about neighborhood, not spelling.
fn shared(a_path: []const u8, b_path: []const u8) usize {
    var i: usize = 0;
    while (i < @min(a_path.len, b_path.len) and a_path[i] == b_path[i]) i += 1;
    return if (std.mem.lastIndexOfScalar(u8, a_path[0..i], '/')) |slash| slash else 0;
}

/// Is `path` inside one of the roots the search already covered? A root names
/// either the file itself or a directory prefix ending at a segment boundary, so
/// `services/ai` never claims `services/aibridge`.
fn inScope(path: []const u8, roots: []const []const u8) bool {
    for (roots) |raw| {
        const r = trimRoot(raw);
        if (r.len == 0 or std.mem.eql(u8, r, ".")) return true;
        if (!std.mem.startsWith(u8, path, r)) continue;
        if (path.len == r.len or path[r.len] == '/') return true;
    }
    return false;
}

const t = std.testing;

test "scope containment stops at a segment boundary" {
    try t.expect(inScope("services/ai/main.py", &.{"services/ai"}));
    try t.expect(inScope("services/ai/main.py", &.{"./services/ai/"}));
    try t.expect(inScope("services/ai/main.py", &.{"services/ai/main.py"}));
    // The bug a bare `startsWith` would ship: a sibling directory whose name
    // merely begins with the root's, reported as already-searched.
    try t.expect(!inScope("services/aibridge/x.py", &.{"services/ai"}));
    try t.expect(!inScope("libs/a.zig", &.{"services/ai"}));
    // A whole-tree root means nothing is outside it.
    try t.expect(inScope("anything/at/all", &.{"."}));
}

test "affinity scores the shared directory, not a shared filename stem" {
    const probe = "services/ai/core/telemetry/attrs.py";
    // The generated twin beside it: same directory, so the whole directory counts.
    try t.expectEqual(@as(usize, "services/ai/core/telemetry".len), shared("services/ai/core/telemetry/attrs.gen.py", probe));
    // A cousin two levels up scores only the directory it really shares.
    try t.expectEqual(@as(usize, "services/ai/core".len), shared("services/ai/core/other/attrs.py", probe));
    // A partial filename match must not inflate the score past its directory.
    try t.expectEqual(@as(usize, "services/ai/core/telemetry".len), shared("services/ai/core/telemetry/attrsX", probe));
    try t.expectEqual(@as(usize, 0), shared("libs/x.zig", probe));
}

test "the nearest candidate is confirmed first" {
    const docs = [_]u32{ 7, 3, 9 };
    var order = docs;
    // Doc 3 is the sibling; it must be read before the two strangers even though
    // the index listed it second.
    sortByAffinity(&order, &docs, &.{ 0, 26, 4 });
    try t.expectEqual(@as(u32, 3), order[0]);
    try t.expectEqual(@as(u32, 9), order[1]);
    try t.expectEqual(@as(u32, 7), order[2]);
}

test "equal affinity keeps index order, so the answer is stable across runs" {
    const docs = [_]u32{ 4, 1, 8 };
    var order = docs;
    sortByAffinity(&order, &docs, &.{ 5, 5, 5 });
    try t.expectEqualSlices(u32, &docs, &order);
}
