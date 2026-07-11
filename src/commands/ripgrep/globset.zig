//! gist `rg` — the compiled fast tier for the CWD/ancestor ignore bucket.
//!
//! Split from `ignore.zig` (which owns the rule model + per-directory walk
//! state): this module owns ONLY `Compiled`, the O(1)-per-entry globset the
//! parallel pipeline builds from the "" bucket. Verdicts are RANKS (rule
//! indices) so last-match-wins collapses to max-rank-wins, turning a
//! literal-basename rule into a single hash probe instead of a glob call.
//! Matching is entity-only (same model as `ignore.ruleMatch`): basename for
//! slash-less rules, full path for anchored ones — ancestor exclusion is the
//! walk's pruning, never re-derived here. Built once before fan-out; immutable
//! and lock-free thereafter.

const std = @import("std");
const gl = @import("../scope/glob.zig");
const ignore = @import("ignore.zig");
const Rule = ignore.Rule;
const Ignore = ignore.Ignore;
const die = @import("args.zig").die;

pub const Compiled = struct {
    rules: []const Rule,
    lit: std.StringHashMap(Slot), // slash-less, meta-free glob → exact basename
    ext: std.StringHashMap(Slot), // slash-less `*.X` (X dot/meta-free) → basename extension
    complex: []const u32, // everything else, ascending rank
    a: std.mem.Allocator,

    /// Best (max) rank per key, split by dir-only: a dir-only rule is
    /// eligible only when the entry itself is a directory.
    const Slot = struct { plain: ?u32 = null, dironly: ?u32 = null };

    /// Compile the "" bucket, or null when this run can't use the fast tier
    /// (case-insensitive matching, or ANY rules bucketed under an explicit
    /// root — e.g. a positional-root repo's `.git/info/exclude`, whose bucket
    /// this tier doesn't model).
    pub fn build(a: std.mem.Allocator, ig: *const Ignore) ?Compiled {
        if (ig.o.ignore_case_insensitive) return null;
        var keys = ig.groups.keyIterator();
        while (keys.next()) |k| if (k.len != 0) return null;
        var self = Compiled{
            .rules = &.{},
            .lit = std.StringHashMap(Slot).init(a),
            .ext = std.StringHashMap(Slot).init(a),
            .complex = &.{},
            .a = a,
        };
        const bucket = ig.groups.getPtr("") orelse return self;
        self.rules = bucket.items;
        var cx: std.ArrayList(u32) = .empty;
        for (bucket.items, 0..) |r, i| {
            const rank: u32 = @intCast(i);
            if (!r.anchored and !hasMeta(r.glob)) {
                slotPut(&self.lit, r.glob, rank, r.dir_only);
            } else if (!r.anchored and extKey(r.glob) != null) {
                slotPut(&self.ext, extKey(r.glob).?, rank, r.dir_only);
            } else {
                cx.append(a, rank) catch die("oom\n", .{});
            }
        }
        self.complex = cx.toOwnedSlice(a) catch die("oom\n", .{});
        return self;
    }

    /// Max rank matching `rel` (stripped, no `./`). Byte-equivalent to folding
    /// the whole bucket through `ruleMatch` (see `decideAt`) — the root-depth
    /// exemption is structural here: every walked entry sits strictly BELOW
    /// its root, so the entry itself is never the exempt root component.
    pub fn matchRank(self: *const Compiled, rel: []const u8, is_dir: bool) ?u32 {
        var best: ?u32 = null;
        const base = if (std.mem.findScalarLast(u8, rel, '/')) |s| rel[s + 1 ..] else rel;
        fold(&best, self.lit.get(base), is_dir);
        if (std.mem.findScalarLast(u8, base, '.')) |dot| {
            if (dot + 1 < base.len) fold(&best, self.ext.get(base[dot + 1 ..]), is_dir);
        }
        // Descending scan with early exit: the first (highest-rank) match wins,
        // and no rule at-or-below `best` can change the verdict.
        var i = self.complex.len;
        while (i > 0) {
            i -= 1;
            const rank = self.complex[i];
            if (best != null and rank <= best.?) break;
            const r = self.rules[rank];
            if (r.dir_only and !is_dir) continue;
            const hit = if (r.anchored) gl.globMatch(r.glob, rel) else gl.globMatch(r.glob, base);
            if (hit) {
                best = rank;
                break;
            }
        }
        return best;
    }

    fn fold(best: *?u32, slot: ?Slot, is_dir: bool) void {
        const s = slot orelse return;
        if (s.plain) |r| if (best.* == null or r > best.*.?) {
            best.* = r;
        };
        if (is_dir) if (s.dironly) |r| if (best.* == null or r > best.*.?) {
            best.* = r;
        };
    }

    fn slotPut(map: *std.StringHashMap(Slot), key: []const u8, rank: u32, dir_only: bool) void {
        const gop = map.getOrPut(key) catch die("oom\n", .{});
        if (!gop.found_existing) gop.value_ptr.* = .{};
        if (dir_only) gop.value_ptr.dironly = rank else gop.value_ptr.plain = rank;
    }

    fn hasMeta(s: []const u8) bool {
        return std.mem.findAny(u8, s, "*?[\\") != null;
    }

    /// `*.X` with a dot/meta-free X — matchable by basename-extension lookup
    /// (a component matches `*.X` iff its final `.`-suffix is exactly X).
    fn extKey(glob: []const u8) ?[]const u8 {
        if (glob.len < 3 or glob[0] != '*' or glob[1] != '.') return null;
        const x = glob[2..];
        if (hasMeta(x) or std.mem.findScalar(u8, x, '.') != null) return null;
        return x;
    }
};
