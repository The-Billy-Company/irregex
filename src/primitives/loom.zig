//! irregex — the WEAVE: a closed op set over the attributed match stream.
//!
//! Agent callers never want the raw firehose — they want "which files, top
//! 20", "counts per pattern", "only under services/, sorted". Today every
//! consumer re-implements that shaping downstream in Python over rendered
//! text (parse → filter → group → sort — per tool, per call, at token cost).
//! Loom executes the shaping ENGINE-side, against typed rows, before a byte
//! of output exists: a declared `Plan` — the whole vocabulary is filter →
//! group → sort → limit, deliberately closed, jq-shaped not jq-powered — runs
//! over the attribution rows the pattern set produced.
//!
//! Closed by design: a `Plan` is data (four fields), not a language. Every
//! op is total and deterministic (all orderings tiebreak on the row's full
//! identity), so one plan over one row set has exactly one answer — the
//! property that lets faces (CLI verbs, Python bindings, a future FFI)
//! declare shaping instead of post-processing it.
//!
//! Kernel profile: no I/O; rows alias caller memory; `execute` allocates only
//! the result (caller frees via `Result.deinit`).

const std = @import("std");
const glob = @import("../kernel/scope/glob.zig");

/// One attributed match fact: pattern `pattern` matched `path` at `line`
/// (1-based; 0 = doc-level attribution with no line resolved). The atom both
/// halves of irregex emit and every op consumes. `path` is aliased.
pub const Row = struct {
    pattern: u32,
    path: []const u8,
    line: u32 = 0,
};

/// What to count/group by.
pub const Key = enum { pattern, file };

/// Result orderings. Row orderings are total (path, then line, then pattern);
/// group orderings tiebreak on the group label so equal counts never swap.
pub const Sort = enum { path, count_desc };

/// A declared shaping of the match stream — the closed op vocabulary.
pub const Plan = struct {
    /// Keep only rows whose path matches this rg-shaped glob (basename when
    /// the glob has no `/`, full path otherwise — `scope/glob.zig` semantics).
    filter_glob: ?[]const u8 = null,
    /// Group rows and count them instead of returning them.
    group: ?Key = null,
    sort: Sort = .path,
    /// Keep at most this many rows/groups; 0 = unlimited.
    limit: usize = 0,
};

/// One counted group: the label is a path (`group=.file`) or a pattern index
/// rendered by the face (`group=.pattern`, label = the pattern's source).
pub const Group = struct {
    key: u64,
    label: []const u8,
    count: u64,
};

/// A plan's answer: shaped rows, or counted groups when the plan grouped.
pub const Result = union(enum) {
    rows: []Row,
    groups: []Group,

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .rows => |r| gpa.free(r),
            .groups => |g| gpa.free(g),
        }
    }
};

fn rowLess(_: void, x: Row, y: Row) bool {
    const c = std.mem.order(u8, x.path, y.path);
    if (c != .eq) return c == .lt;
    if (x.line != y.line) return x.line < y.line;
    return x.pattern < y.pattern;
}

fn groupCountDesc(_: void, x: Group, y: Group) bool {
    if (x.count != y.count) return x.count > y.count;
    return std.mem.order(u8, x.label, y.label) == .lt;
}

fn groupLabelAsc(_: void, x: Group, y: Group) bool {
    return std.mem.order(u8, x.label, y.label) == .lt;
}

/// Run `plan` over `rows`. `patterns[i]` is the source text of pattern `i`
/// (labels for `group=.pattern`; pass `&.{}` when the plan doesn't group by
/// pattern). Deterministic: same plan + rows ⇒ same bytes of answer.
pub fn execute(gpa: std.mem.Allocator, plan: Plan, rows: []const Row, patterns: []const []const u8) error{OutOfMemory}!Result {
    // filter
    var kept: std.ArrayList(Row) = .empty;
    defer kept.deinit(gpa);
    for (rows) |r| {
        if (plan.filter_glob) |g| {
            if (!glob.globApplies(g, r.path)) continue;
        }
        try kept.append(gpa, r);
    }

    if (plan.group) |key| {
        // group + count. Paths/pattern-ids hash to u64 group keys; labels
        // alias the first row seen (paths) or the pattern source table.
        var counts: std.AutoArrayHashMapUnmanaged(u64, Group) = .empty;
        defer counts.deinit(gpa);
        for (kept.items) |r| {
            const k: u64 = switch (key) {
                .pattern => r.pattern,
                .file => std.hash.Wyhash.hash(0, r.path),
            };
            const entry = try counts.getOrPut(gpa, k);
            if (!entry.found_existing) entry.value_ptr.* = .{
                .key = k,
                .label = switch (key) {
                    .pattern => if (r.pattern < patterns.len) patterns[r.pattern] else "",
                    .file => r.path,
                },
                .count = 0,
            };
            entry.value_ptr.count += 1;
        }
        const groups = try gpa.dupe(Group, counts.values());
        errdefer gpa.free(groups);
        switch (plan.sort) {
            .count_desc => std.mem.sort(Group, groups, {}, groupCountDesc),
            .path => std.mem.sort(Group, groups, {}, groupLabelAsc),
        }
        if (plan.limit != 0 and groups.len > plan.limit) {
            const cut = try gpa.dupe(Group, groups[0..plan.limit]);
            gpa.free(groups);
            return .{ .groups = cut };
        }
        return .{ .groups = groups };
    }

    // row output: sort + limit. `count_desc` has no meaning for ungrouped
    // rows; it falls back to the total path order (documented, total, never
    // an error — a Plan is data and every datum must execute).
    std.mem.sort(Row, kept.items, {}, rowLess);
    const n = if (plan.limit != 0) @min(plan.limit, kept.items.len) else kept.items.len;
    return .{ .rows = try gpa.dupe(Row, kept.items[0..n]) };
}
