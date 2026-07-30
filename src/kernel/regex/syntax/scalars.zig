//! gist — Unicode scalar ranges: the parse-time accumulator, and the case fold
//! that rewrites a finished tree.
//!
//! `ScalarSet` is scratch, not vocabulary — it exists only between reading a
//! class and lowering it, and no `Node` ever holds one. That is the line between
//! this file and `tree.zig`: everything here builds or rewrites the persistent
//! types, and nothing here is one. `foldCaseAst` sits beside it because the `-i`
//! fold is the same range algebra applied after the parse rather than during it.

const std = @import("std");
const uni = @import("../unicode/tables.zig");
const tree = @import("tree.zig");

const ByteSet = tree.ByteSet;
const Node = tree.Node;
const ParseError = tree.ParseError;

/// A mutable set of Unicode scalar ranges, accumulated while parsing a class in
/// Unicode mode (`.`, a non-ASCII literal, `\w`/`\d`/`\s`, `\p{…}`, `[…]`). Ranges
/// are appended unsorted; `finish` coalesces once and lowers to the leanest node —
/// a fast single-byte `class` when the set is entirely ASCII, else a `uclass`.
/// All allocation is on the parser arena, so nothing is freed piecewise.
pub const ScalarSet = struct {
    list: std.ArrayList([2]u21) = .empty,
    gpa: std.mem.Allocator,

    pub fn addRange(self: *ScalarSet, lo: u21, hi: u21) ParseError!void {
        if (lo > hi) return; // empty/reversed contributes nothing
        try self.list.append(self.gpa, .{ lo, hi });
    }
    pub fn addTable(self: *ScalarSet, t: []const [2]u21) ParseError!void {
        for (t) |r| try self.addRange(r[0], r[1]);
    }
    /// Union the members of an (ASCII) byte set as coalesced runs — the bridge for
    /// POSIX bracket classes, which stay byte-defined even in Unicode mode.
    pub fn addByteSet(self: *ScalarSet, bs: *const ByteSet) ParseError!void {
        var b: u16 = 0;
        while (b <= 0xFF) {
            if (!bs.has(@intCast(b))) {
                b += 1;
                continue;
            }
            const lo = b;
            while (b <= 0xFF and bs.has(@intCast(b))) b += 1;
            try self.addRange(@intCast(lo), @intCast(b - 1));
        }
    }

    /// Sort by low bound and merge overlapping/adjacent ranges in place.
    fn coalesce(self: *ScalarSet) void {
        const items = self.list.items;
        std.mem.sort([2]u21, items, {}, struct {
            fn lt(_: void, a: [2]u21, b: [2]u21) bool {
                return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
            }
        }.lt);
        var w: usize = 0;
        for (items) |r| {
            // `+1` widened to u32: `hi` can be 0x10FFFF, whose successor overflows u21.
            if (w > 0 and r[0] <= @as(u32, items[w - 1][1]) + 1) {
                if (r[1] > items[w - 1][1]) items[w - 1][1] = r[1];
            } else {
                items[w] = r;
                w += 1;
            }
        }
        self.list.shrinkRetainingCapacity(w);
    }

    /// Complement within the whole scalar space `[0, 0x10FFFF]` (the surrogate gap
    /// needn't be excluded — `utf8seq` drops it on lowering).
    pub fn negate(self: *ScalarSet) ParseError!void {
        self.coalesce();
        var out: std.ArrayList([2]u21) = .empty;
        var next: u32 = 0;
        for (self.list.items) |r| {
            if (r[0] > next) try out.append(self.gpa, .{ @intCast(next), r[0] - 1 });
            next = @as(u32, r[1]) + 1;
        }
        if (next <= 0x10FFFF) try out.append(self.gpa, .{ @intCast(next), 0x10FFFF });
        self.list = out;
    }

    /// What a *negated class* means, spelled once for `[^…]`, `\D \W \S`, and
    /// `\P{…}`: the complement, minus `\n` in the per-line model (no thread may
    /// consume a line boundary), keeping `\n` under `multiline` — rg treats only
    /// `.` as newline-special.
    pub fn complement(self: *ScalarSet, multiline: bool) ParseError!void {
        try self.negate();
        if (!multiline) try self.dropCp('\n');
    }

    /// Remove a single codepoint, splitting the range that holds it — strips `\n`
    /// from `.` and negated classes in the per-line model (no thread may cross a
    /// line boundary in the fused doc scan).
    pub fn dropCp(self: *ScalarSet, cp: u21) ParseError!void {
        self.coalesce();
        var out: std.ArrayList([2]u21) = .empty;
        for (self.list.items) |r| {
            if (cp < r[0] or cp > r[1]) {
                try out.append(self.gpa, r);
                continue;
            }
            if (cp > r[0]) try out.append(self.gpa, .{ r[0], cp - 1 });
            if (cp < r[1]) try out.append(self.gpa, .{ cp + 1, r[1] });
        }
        self.list = out;
    }

    fn allAscii(self: *const ScalarSet) bool {
        for (self.list.items) |r| if (r[1] > 0x7F) return false;
        return true;
    }

    /// Expand every codepoint in the set to its simple case-fold orbit (the `-i`
    /// Unicode fold): `k` gains `K` and KELVIN SIGN, `é` gains `É`. Idempotent —
    /// re-applying adds only members already present.
    pub fn foldExpand(self: *ScalarSet) ParseError!void {
        self.coalesce();
        var members: std.ArrayList(u21) = .empty;
        try uni.foldMembers(self.list.items, self.gpa, &members);
        for (members.items) |cp| try self.addRange(cp, cp);
    }

    /// Write the coalesced set into an existing node as the leanest representation:
    /// a fast single-byte `class` when entirely ASCII (trigram extraction + byte
    /// DFA unchanged), else a `uclass`.
    fn writeInto(self: *ScalarSet, gpa: std.mem.Allocator, n: *Node) ParseError!void {
        self.coalesce();
        if (self.allAscii()) {
            var bs = ByteSet{};
            for (self.list.items) |r| bs.setRange(@intCast(r[0]), @intCast(r[1]));
            n.* = .{ .class = bs };
            return;
        }
        n.* = .{ .uclass = try gpa.dupe([2]u21, self.list.items) };
    }

    /// Lower to a fresh node on `arena` (the parse-time entry point).
    pub fn finish(self: *ScalarSet, arena: std.mem.Allocator) ParseError!*Node {
        const n = try arena.create(Node);
        try self.writeInto(arena, n);
        return n;
    }
};

/// Rewrite one consuming class through its full simple case-fold orbit, seeding
/// from whichever representation the node currently holds. Promotes `class` →
/// `uclass` when an orbit escapes ASCII (`k` gains KELVIN SIGN); leaves the node
/// alone if it consumes nothing.
fn refold(gpa: std.mem.Allocator, n: *Node) ParseError!void {
    var ss = ScalarSet{ .gpa = gpa };
    switch (n.*) {
        .class => |*s| try ss.addByteSet(s),
        .uclass => |ranges| try ss.addTable(ranges),
        else => return,
    }
    try ss.foldExpand();
    try ss.writeInto(gpa, n);
}

/// Recursively case-fold every consuming class in the AST so the compiled engine
/// (NFA · DFA · Pike alike) matches case-insensitively — the `-i` flag. Zero-width
/// assertions and structure are untouched. The AST is a DAG (`{n,m}` shares its
/// atom pointer across copies); every fold operation here is idempotent, so
/// re-visiting a shared node is harmless.
///
/// ASCII mode (`unicode=false`) is the fast in-place `a`⇄`A` fold on the `ByteSet`.
/// Unicode mode expands each codepoint to its full simple case-fold orbit — `k`
/// also matches `K` and KELVIN SIGN (U+212A), `é`⇄`É`, `ς`⇄`σ`⇄`Σ` — which can
/// promote an ASCII `class` to a `uclass` when the orbit escapes ASCII, exactly
/// rg's default `-i`. Allocation (only on a Unicode promotion) is on `gpa`.
pub fn foldCaseAst(gpa: std.mem.Allocator, n: *Node, unicode: bool) ParseError!void {
    switch (n.*) {
        // ASCII mode folds the byte set in place; Unicode mode goes through the
        // orbit expansion, which may promote the node to a `uclass`.
        .class => |*s| if (unicode) try refold(gpa, n) else s.foldCase(),
        .uclass => try refold(gpa, n),
        .concat, .alt => |kids| {
            try foldCaseAst(gpa, kids[0], unicode);
            try foldCaseAst(gpa, kids[1], unicode);
        },
        .star, .plus, .quest => |r| try foldCaseAst(gpa, r.node, unicode),
        .capture => |g| try foldCaseAst(gpa, g.child, unicode),
        .empty, .anchor_start, .anchor_end, .anchor_buf_start, .anchor_buf_end, .word => {},
    }
}
