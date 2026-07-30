//! irregex compose — `family`: fork families inside the exact filter.
//!
//! Pure-kernel answer to "of the files that match this symbol, which are forks
//! or structural twins of each other?" The CLI's `relate echoes --matching PAT`
//! is a different composition (narrow-then-echoes on the relate face); this
//! module is the analytic FFI's `.family` op awaiting ADR-377 graduation
//! (`surface/ffi/analytic.zig` still declines it). Running the exact
//! `PatternSet` first (`candidates.select`) and building the kinship graph
//! over ONLY the matching docs turns a whole-tree dedup sweep into a scoped
//! one — the fixture farm behind one handler, the mirrored implementations of
//! one trait.
//!
//! Two edge sources, one component pass (`families.zig` union-find):
//!   • `.dup{T}`  — the verified near-duplicate graph (byte kinship ≤ T), the
//!     same machinery the `copies` channel rides (`pairs.zig`).
//!   • `.echo{E}` — the structural-echo graph: pairs far in bytes but close in
//!     structure (byte−structure gap ≥ E), the renamed-twin signal, with the
//!     same codegen + sub-mass noise drops the `twins` channel applies.
//!
//! Pure kernel: the driver loads the corpus and renders; this sketches the
//! candidate subset, builds the graph, and returns fork families (corpus ids).

const std = @import("std");
const sketch = @import("../kinship/metric/sketch.zig");
const silhouette_mod = @import("../kinship/metric/silhouette.zig");
const pairs = @import("../kinship/cluster/pairs.zig");
const families_mod = @import("../kinship/cluster/families.zig");
const signals = @import("../rank/signals.zig");
const candidates = @import("candidates.zig");

/// A file needs this many structural fingerprints for an echo claim to rest on
/// a real KMV sample, not a handful of shingles — anchored to the seed width,
/// the same floor `relate echoes` uses.
const min_mass = pairs.seed_hashes;

/// Which kinship graph joins the candidates: byte near-duplication (`dup`, edge
/// admitted at distance ≤ T) or structural echo (`echo`, admitted at
/// byte−structure gap ≥ E).
pub const Mode = union(enum) {
    dup: f64,
    structure: f64,
    echo: f64,
};

/// One fork family: member corpus doc ids (path-asc) and the loosest edge
/// admitted into it — the max byte distance for `dup`, the min echo for `echo`.
pub const Family = struct {
    members: []u32,
    edge: f64,
};

pub const Families = struct {
    gpa: std.mem.Allocator,
    list: []Family,
    candidates: usize,
    edges: usize,

    pub fn deinit(self: *Families) void {
        for (self.list) |f| self.gpa.free(f.members);
        self.gpa.free(self.list);
    }
};

const Edge = struct { i: u32, j: u32, w: f64 };

pub const Neighbor = struct {
    member: u32,
    nearest: ?u32,
    byte_distance: f64,
    structure_distance: f64,
};

pub const Analysis = struct {
    gpa: std.mem.Allocator,
    list: []Family,
    distinct: []Neighbor,
    edges: usize,

    pub fn deinit(self: *Analysis) void {
        for (self.list) |f| self.gpa.free(f.members);
        self.gpa.free(self.list);
        self.gpa.free(self.distinct);
    }
};

/// Build fork families among `cset`. `paths` are the corpus paths (indexed by
/// doc id) used for deterministic ordering. Families are size-desc then
/// exemplar-path-asc; members path-asc; components below `min_size` (or with no
/// verified edge) are dropped. Caller owns the result.
pub fn families(
    gpa: std.mem.Allocator,
    docs: []const []const u8,
    paths: []const []const u8,
    cset: *const candidates.CandidateSet,
    mode: Mode,
    min_size: usize,
) !Families {
    const m = cset.count();
    const cand_docs = try gpa.alloc([]const u8, m);
    defer gpa.free(cand_docs);
    for (cset.ids, 0..) |id, k| cand_docs[k] = docs[id];
    const labels = try gpa.alloc([]const u8, m);
    defer gpa.free(labels);
    for (cset.ids, 0..) |id, k| labels[k] = paths[id];

    var grouped = try analyze(gpa, cand_docs, labels, mode, min_size, min_mass, false, false);
    defer grouped.deinit();
    const list = try gpa.alloc(Family, grouped.list.len);
    var built: usize = 0;
    errdefer {
        for (list[0..built]) |f| gpa.free(f.members);
        gpa.free(list);
    }
    for (grouped.list, list) |source, *dest| {
        const members = try gpa.alloc(u32, source.members.len);
        for (source.members, members) |sub, *out| out.* = cset.ids[sub];
        dest.* = .{ .members = members, .edge = source.edge };
        built += 1;
    }
    return .{ .gpa = gpa, .list = list, .candidates = m, .edges = grouped.edges };
}

/// Compare arbitrary exact-selected bodies. Unlike file families, callers may
/// request `distinct` receipts: every isolated body is returned with its
/// nearest structural neighbor and both independent distances.
pub fn analyze(
    gpa: std.mem.Allocator,
    bodies: []const []const u8,
    labels: []const []const u8,
    mode: Mode,
    min_size: usize,
    structural_mass: usize,
    include_distinct: bool,
    exhaustive: bool,
) !Analysis {
    std.debug.assert(bodies.len == labels.len);
    const sketches = try sketchAll(sketch.Sketch, sketch.build, gpa, bodies);
    defer gpa.free(sketches);
    const need_structure = include_distinct or mode != .dup;
    const silhouettes = if (need_structure)
        try sketchAll(silhouette_mod.Silhouette, silhouette_mod.build, gpa, bodies)
    else
        null;
    defer if (silhouettes) |values| gpa.free(values);

    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(gpa);
    switch (mode) {
        .dup => |max_dist| {
            const verified = try pairs.verifiedPairs(gpa, labels, sketches, max_dist);
            defer gpa.free(verified);
            for (verified) |p| try edges.append(gpa, .{ .i = p.i, .j = p.j, .w = p.dist });
        },
        .structure, .echo => {
            const structural = silhouettes.?;
            const Ctx = struct {
                gpa: std.mem.Allocator,
                labels: []const []const u8,
                sketches: []const sketch.Sketch,
                silhouettes: []const silhouette_mod.Silhouette,
                mode: Mode,
                structural_mass: usize,
                edges: *std.ArrayList(Edge),

                fn visit(self: *@This(), a: u32, z: u32) error{OutOfMemory}!void {
                    if (isGeneratedLabel(self.labels[a]) or isGeneratedLabel(self.labels[z])) return;
                    if (self.silhouettes[a].len < self.structural_mass or self.silhouettes[z].len < self.structural_mass) return;
                    const ds = silhouette_mod.distance(&self.silhouettes[a], &self.silhouettes[z]);
                    const db = sketch.distance(&self.sketches[a], &self.sketches[z]);
                    const weight = switch (self.mode) {
                        .structure => ds,
                        .echo => db - ds,
                        .dup => unreachable,
                    };
                    const admitted = switch (self.mode) {
                        .structure => |max_dist| ds <= max_dist,
                        .echo => |min_echo| weight >= min_echo,
                        .dup => unreachable,
                    };
                    if (admitted) try self.edges.append(self.gpa, .{ .i = a, .j = z, .w = weight });
                }
            };
            var ctx = Ctx{
                .gpa = gpa,
                .labels = labels,
                .sketches = sketches,
                .silhouettes = structural,
                .mode = mode,
                .structural_mass = structural_mass,
                .edges = &edges,
            };
            if (exhaustive) {
                for (0..structural.len) |a|
                    for (a + 1..structural.len) |z|
                        try ctx.visit(@intCast(a), @intCast(z));
            } else {
                try pairs.forEachCandidatePair(silhouette_mod.Silhouette, gpa, structural, &ctx, Ctx.visit);
            }
        },
    }

    return .{
        .gpa = gpa,
        .list = try components(gpa, labels, edges.items, mode, min_size),
        .distinct = if (include_distinct)
            try isolated(gpa, labels, sketches, silhouettes.?, edges.items)
        else
            try gpa.alloc(Neighbor, 0),
        .edges = edges.items.len,
    };
}

fn isGeneratedLabel(label: []const u8) bool {
    const path = if (std.mem.lastIndexOf(u8, label, "#L")) |at| label[0..at] else label;
    return signals.isGeneratedPath(path);
}

/// Union-find over the edge list, then materialize components ≥ `min_size` as
/// families of corpus ids, sorted total — the shared `families.components`
/// pass, with the loosest-edge direction chosen by the kinship channel (a
/// bigger byte/structure distance is looser; a smaller echo gap is looser).
fn components(
    gpa: std.mem.Allocator,
    labels: []const []const u8,
    edges: []const Edge,
    mode: Mode,
    min_size: usize,
) ![]Family {
    const graph_edges = try gpa.alloc(families_mod.Edge, edges.len);
    defer gpa.free(graph_edges);
    for (edges, graph_edges) |e, *g| g.* = .{ .i = e.i, .j = e.j, .w = e.w };
    const dir: families_mod.EdgeDir = switch (mode) {
        .dup, .structure => .max,
        .echo => .min,
    };
    const groups = try families_mod.components(gpa, labels, graph_edges, dir, min_size);
    defer gpa.free(groups);
    var list = try gpa.alloc(Family, groups.len);
    for (groups, list) |g, *f| f.* = .{ .members = g.members, .edge = g.edge };
    return list[0..groups.len];
}

fn isolated(
    gpa: std.mem.Allocator,
    labels: []const []const u8,
    sketches: []const sketch.Sketch,
    silhouettes: []const silhouette_mod.Silhouette,
    edges: []const Edge,
) ![]Neighbor {
    const connected = try gpa.alloc(bool, labels.len);
    defer gpa.free(connected);
    @memset(connected, false);
    for (edges) |edge| {
        connected[edge.i] = true;
        connected[edge.j] = true;
    }

    var out: std.ArrayList(Neighbor) = .empty;
    errdefer out.deinit(gpa);
    for (labels, 0..) |_, i| {
        if (connected[i]) continue;
        var nearest: ?usize = null;
        var best_structure = std.math.inf(f64);
        var best_byte = std.math.inf(f64);
        for (labels, 0..) |_, j| {
            if (i == j) continue;
            const ds = silhouette_mod.distance(&silhouettes[i], &silhouettes[j]);
            const db = sketch.distance(&sketches[i], &sketches[j]);
            if (ds < best_structure or (ds == best_structure and db < best_byte) or
                (ds == best_structure and db == best_byte and nearest != null and
                    std.mem.order(u8, labels[j], labels[nearest.?]) == .lt))
            {
                nearest = j;
                best_structure = ds;
                best_byte = db;
            }
        }
        try out.append(gpa, .{
            .member = @intCast(i),
            .nearest = if (nearest) |j| @intCast(j) else null,
            .byte_distance = if (nearest == null) 1.0 else best_byte,
            .structure_distance = if (nearest == null) 1.0 else best_structure,
        });
    }
    std.mem.sort(Neighbor, out.items, labels, struct {
        fn less(paths: []const []const u8, a: Neighbor, b: Neighbor) bool {
            return std.mem.order(u8, paths[a.member], paths[b.member]) == .lt;
        }
    }.less);
    return out.toOwnedSlice(gpa);
}

/// Build a bottom-k record (`Sketch` or `Silhouette`) per candidate doc; a
/// build failure degrades to the maximally-far `.empty` value (it can only hide
/// a relation, never invent one).
fn sketchAll(comptime T: type, comptime buildFn: anytype, gpa: std.mem.Allocator, docs: []const []const u8) ![]T {
    const out = try gpa.alloc(T, docs.len);
    errdefer gpa.free(out);
    for (docs, out) |d, *s| s.* = buildFn(gpa, d) catch T.empty;
    return out;
}

// ── tests ──────────────────────────────────────────────────────────────────

const t = std.testing;
const compileSet = candidates.compileSet;

test "family dup: every emitted member satisfied the exact selector" {
    const gpa = t.allocator;
    // Two byte-identical forks that both contain the pattern, one matching file
    // that is unique, and a byte-twin of the forks that does NOT match.
    const fork = "fn handler(req) { validate(req); route(req); log(req); return ok }  // MARKER";
    const docs = [_][]const u8{
        fork,
        fork ++ " trailing drift here",
        "unique MARKER file with nothing else in common at all",
        "fn handler(req) { validate(req); route(req); log(req); return ok }  // no marker here", // twin, no MARKER
    };
    const paths = [_][]const u8{ "a.zig", "b.zig", "c.zig", "d.zig" };
    var set = try compileSet(gpa, &.{"MARKER"});
    defer set.deinit(gpa);
    var cs = try select(gpa, &docs, &set, .any);
    defer cs.deinit();
    // d.zig lacks MARKER → not a candidate.
    try t.expectEqualSlices(u32, &.{ 0, 1, 2 }, cs.ids);

    var fams = try families(gpa, &docs, &paths, &cs, .{ .dup = 0.25 }, 2);
    defer fams.deinit();

    // The two forks cluster; the unique file is a singleton (dropped). Every
    // member is a candidate id (satisfied the selector) and never d.zig (3).
    try t.expectEqual(@as(usize, 1), fams.list.len);
    try t.expectEqualSlices(u32, &.{ 0, 1 }, fams.list[0].members);
    for (fams.list) |f| for (f.members) |mem| {
        try t.expect(mem != 3);
        var is_cand = false;
        for (cs.ids) |id| is_cand = is_cand or id == mem;
        try t.expect(is_cand);
    };
}

test "family: an empty candidate set yields no families, never a crash" {
    const gpa = t.allocator;
    const docs = [_][]const u8{ "alpha here", "beta there" };
    const paths = [_][]const u8{ "a.zig", "b.zig" };
    var set = try compileSet(gpa, &.{"gamma"}); // matches nothing
    defer set.deinit(gpa);
    var cs = try select(gpa, &docs, &set, .any);
    defer cs.deinit();
    try t.expectEqual(@as(usize, 0), cs.count());

    inline for (.{ Mode{ .dup = 0.25 }, Mode{ .echo = 0.1 } }) |mode| {
        var fams = try families(gpa, &docs, &paths, &cs, mode, 2);
        defer fams.deinit();
        try t.expectEqual(@as(usize, 0), fams.list.len);
        try t.expectEqual(@as(usize, 0), fams.edges);
    }
}

test "region analysis groups renamed implementations and receipts the genuinely distinct one" {
    const gpa = t.allocator;
    const bodies = [_][]const u8{
        "fn alpha(value: usize) usize { const next = value + 1; return next * 2; }",
        "fn beta(input: usize) usize { const result = input + 9; return result * 7; }",
        "fn gamma(key: []const u8) bool { while (cache.next()) |entry| if (eql(entry, key)) return true; return false; }",
    };
    const labels = [_][]const u8{ "a.zig#L1", "b.zig#L8", "c.zig#L20" };
    var result = try analyze(gpa, &bodies, &labels, .{ .structure = 0.1 }, 2, 1, true, true);
    defer result.deinit();

    try t.expectEqual(@as(usize, 1), result.list.len);
    try t.expectEqualSlices(u32, &.{ 0, 1 }, result.list[0].members);
    try t.expectEqual(@as(usize, 1), result.distinct.len);
    try t.expectEqual(@as(u32, 2), result.distinct[0].member);
    try t.expect(result.distinct[0].nearest != null);
    try t.expect(result.distinct[0].structure_distance > 0.1);
}

const select = candidates.select;
