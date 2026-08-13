//! irregex — Unicode scalar ranges: the parse-time accumulator, and the three
//! rewrites a FINISHED tree can still owe its flags.
//!
//! `ScalarSet` is scratch, not vocabulary — it exists only between reading a
//! class and lowering it, and no `Node` ever holds one. That is the line between
//! this file and `tree.zig`: everything here builds or rewrites the persistent
//! types, and nothing here is one. The three passes sit beside it because each is
//! a flag whose meaning is a rewrite rather than an engine mode — `-i` is the
//! same range algebra applied after the parse (`foldCaseAst`), `--crlf` is one
//! codepoint removed from every class (`stripCpAst`), and `-w` is two assertions
//! wrapped around the root (`wordBoundedAst`). One definition each, because both
//! the match engine and the capture VM apply them to their own parse.

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

    /// Keep only what `o` also holds - the `&&` class-set operator.
    ///
    /// A merge walk over both coalesced lists rather than the double complement
    /// the identity would allow: an intersection is the one operator whose
    /// result is never larger than either side, and routing it through two
    /// whole-scalar-space negations would build two ~1.1M-codepoint lists to
    /// answer a question about a handful of ranges.
    pub fn intersect(self: *ScalarSet, o: *ScalarSet) ParseError!void {
        self.coalesce();
        o.coalesce();
        var out: std.ArrayList([2]u21) = .empty;
        var i: usize = 0;
        var j: usize = 0;
        while (i < self.list.items.len and j < o.list.items.len) {
            const a = self.list.items[i];
            const b = o.list.items[j];
            const lo = @max(a[0], b[0]);
            const hi = @min(a[1], b[1]);
            if (lo <= hi) try out.append(self.gpa, .{ lo, hi });
            if (a[1] < b[1]) i += 1 else j += 1;
        }
        self.list = out;
    }

    /// Drop everything `o` holds - the `--` operator, and half of `~~`.
    pub fn subtract(self: *ScalarSet, o: *ScalarSet) ParseError!void {
        var cut: ScalarSet = .{ .gpa = self.gpa };
        try cut.addTable(o.list.items);
        try cut.negate();
        return self.intersect(&cut);
    }

    /// What exactly one side holds - the `~~` operator.
    pub fn symmetric(self: *ScalarSet, o: *ScalarSet) ParseError!void {
        var mine: ScalarSet = .{ .gpa = self.gpa };
        try mine.addTable(self.list.items);
        try mine.subtract(o);
        try o.subtract(self);
        self.list = mine.list;
        try self.addTable(o.list.items);
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

/// `-w` as rg spells it: the whole parse wrapped in the two HALF boundary
/// assertions, so a word-bounded match is what the engine searches for rather
/// than what a later vet accepts.
///
/// The halves, not `\b`: `\b{start-half}` asks only that nothing wordy sit behind
/// the position, which is what lets `-w ' x '` (a pattern whose own first byte is
/// not a word byte) still match — `\b` there would demand a transition the space
/// cannot provide. They are exactly the two conditions the post-match `wordOk`
/// vet applies, so this changes WHICH span an engine settles on, never which
/// spans are admissible: at a start offset whose greedy arm is word-internal, the
/// assertion prunes that arm inside the search and the engine goes on to the
/// shorter admissible one, where the vet could only reject the whole offset and
/// advance past matches rg reports.
///
/// Wrapping the parsed root rather than the pattern text is what makes the
/// precedence free: `-w 'a|bc'` binds the alternation, not its first arm.
pub fn wordBoundedAst(arena: std.mem.Allocator, ast: *Node) ParseError!*Node {
    const lead = try arena.create(Node);
    lead.* = .{ .word = .start_half };
    const trail = try arena.create(Node);
    trail.* = .{ .word = .end_half };
    const tail = try arena.create(Node);
    tail.* = .{ .concat = .{ ast, trail } };
    const root = try arena.create(Node);
    root.* = .{ .concat = .{ lead, tail } };
    return root;
}

/// Remove one codepoint from every consuming class in the AST, so no thread can
/// consume it — `--crlf`'s strip of `\r`, and rg's own rule (`grep-regex`
/// `strip_from_match`): with `\n` as the line terminator, a CR is line furniture
/// rather than content, so `.`, `[…]`, a negated class, and `\S` must all decline
/// it. Without this, `.` glues two CRLF-terminated lines into one match and a
/// lone CR reads as ordinary text.
///
/// A LITERAL `\r` is a class of one by the time the parse finishes, so it
/// empties and the pattern becomes unmatchable. That is deliberate: rg refuses
/// such a pattern outright (exit 2), and this engine answers the same question
/// with the clean no-match its hint channel explains, exactly as it already
/// does for a literal `\n` in the per-line model.
///
/// Zero-width assertions and structure are untouched. Idempotent, so re-visiting
/// a node shared through `{n,m}` is harmless.
pub fn stripCpAst(gpa: std.mem.Allocator, n: *Node, cp: u21) ParseError!void {
    switch (n.*) {
        .class => |*s| if (cp <= 0xFF) s.remove(@intCast(cp)),
        .uclass => |ranges| {
            var ss = ScalarSet{ .gpa = gpa };
            try ss.addTable(ranges);
            try ss.dropCp(cp);
            try ss.writeInto(gpa, n);
        },
        .concat, .alt => |kids| {
            try stripCpAst(gpa, kids[0], cp);
            try stripCpAst(gpa, kids[1], cp);
        },
        .star, .plus, .quest => |r| try stripCpAst(gpa, r.node, cp),
        .capture => |g| try stripCpAst(gpa, g.child, cp),
        .empty, .anchor_start, .anchor_end, .anchor_buf_start, .anchor_buf_end, .word => {},
    }
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
