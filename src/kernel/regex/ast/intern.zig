//! Parse tree → interned AST. The one place `*Node` becomes a DAG, and the only
//! place the tree's associativity is spent.
//!
//! Two rewrites happen on the way in, both licensed by the fact that
//! concatenation and alternation are associative:
//!
//!   * **Spines are flattened and rebuilt balanced.** The parser left-folds, so
//!     `abcd` arrives as `((a·b)·c)·d` — a chain whose every prefix is a
//!     distinct shape, and therefore a chain hash-consing cannot compress at
//!     all. Rebuilt balanced, identical halves become the same node.
//!   * **Runs are raised by squaring.** A flattened spine is run-length
//!     compressed first, so the thousand copies `a{1000}` expands to are one
//!     `power` call and ~19 distinct nodes instead of a thousand.
//!
//! Re-association is safe for everything that reads the interned AST, because
//! every fact computed over it is a property of the flattened sequence rather
//! than of the bracketing — but it is NOT safe for leftmost-first span
//! selection, which depends on alternation ORDER being the order the Thompson
//! split was emitted in. That is why this is an analysis structure and
//! `compile/` still lowers the parser's own tree: the engine keeps the
//! bracketing that decides which match is chosen, and the analyses get the
//! shape that is cheap to ask questions of. `ast_test.zig` holds that claim
//! directly and differentially rather than leaving it as an argument.

const std = @import("std");
const syn = @import("../syntax/syntax.zig");
const dagmod = @import("../../math/dag.zig");

const Node = syn.Node;
const ByteSet = syn.ByteSet;
const ParseError = syn.ParseError;

pub const Id = dagmod.Id;
pub const Stats = dagmod.Stats;

/// A node's operator. Structure lives in the DAG's child slots, so this carries
/// only what distinguishes two nodes of the same shape.
pub const Op = union(enum) {
    empty,
    class: ByteSet,
    uclass: []const [2]u21,
    anchor_start,
    anchor_end,
    anchor_buf_start,
    anchor_buf_end,
    word: syn.Word,
    concat,
    alt,
    star: bool, // the payload is the lazy flag
    plus: bool,
    quest: bool,
    capture: u32,

    /// Declared because `uclass` holds a slice: its identity is the ranges it
    /// names, not the address they happen to sit at, so two parses of `\w` must
    /// reach one node. Without the pair the DAG would fall back to hashing the
    /// payload field-wise and refuse to hash through the pointer at all.
    ///
    /// Both halves read the ranges as *values* rather than as bytes, for the
    /// reason `widen` exists: a `[2]u21` has bytes no bound owns, and they come
    /// from the arena `scalars.finish` duped into.
    pub fn hash(self: Op) u64 {
        var h = std.hash.Wyhash.init(@intFromEnum(std.meta.activeTag(self)));
        switch (self) {
            .uclass => |r| for (r) |x| h.update(std.mem.asBytes(&widen(x))),
            .class => |c| h.update(std.mem.asBytes(&c.bits)),
            .capture => |i| h.update(std.mem.asBytes(&i)),
            .star, .plus, .quest => |lazy| h.update(std.mem.asBytes(&lazy)),
            else => {},
        }
        return h.final();
    }

    pub fn eql(a: Op, b: Op) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .uclass => |ar| ar.len == b.uclass.len and
                for (ar, b.uclass) |x, y| {
                    if (x[0] != y[0] or x[1] != y[1]) break false;
                } else true,
            .class => |ac| std.mem.eql(u64, &ac.bits, &b.class.bits),
            .capture => |ai| ai == b.capture,
            .star => |al| al == b.star,
            .plus => |al| al == b.plus,
            .quest => |al| al == b.quest,
            else => true,
        };
    }
};

/// One scalar range with every byte of it owned by a field.
///
/// The ranges arrive as `[2]u21`, and `@sizeOf(u21)` is four while a store
/// writes twenty-one bits - so eleven bits per bound are whatever the
/// allocation last held. `scalars.finish` dupes them onto the parser arena, so
/// "whatever it held" is a function of what that arena was used for before,
/// which means the same class parsed twice can differ in two bytes of eight
/// while naming the same set. Hashing or comparing those bytes then splits one
/// node into two, and every later question - alphabet, determinization, the
/// automaton that reaches a folio - is asked of a DAG that failed to intern.
///
/// Widening is the cheap repair: this pair has no slack, so `asBytes` of it is
/// a promise rather than a hope. See `research/seams/RESULT-1-seams.md`.
const Range = extern struct { lo: u32, hi: u32 };

fn widen(r: [2]u21) Range {
    return .{ .lo = r[0], .hi = r[1] };
}

/// The interned AST: a hash-consed DAG of `Op` nodes with at most two children.
pub const Graph = dagmod.Dag(Op, 2);
const none: Id = .none;

/// A pattern's graph and the node its root is.
pub const Interned = struct {
    graph: Graph = .empty,
    root: Id = undefined,

    pub fn deinit(self: *Interned, gpa: std.mem.Allocator) void {
        self.graph.deinit(gpa);
    }

    /// Distinct nodes retained versus tree nodes offered — the compression the
    /// interning found, and the factor a sweep beats a re-walking recursion by.
    pub fn stats(self: *const Interned) Stats {
        return self.graph.stats;
    }
};

/// Intern a parsed pattern. `gpa` owns the graph; `scratch` is working memory
/// for spine flattening and dies with the call.
pub fn intern(gpa: std.mem.Allocator, scratch: std.mem.Allocator, ast: *const Node) ParseError!Interned {
    var w: Interner = .{ .gpa = gpa, .scratch = scratch };
    defer w.memo.deinit(scratch);
    var out: Interned = .{};
    errdefer out.deinit(gpa);
    out.root = try w.node(&out.graph, ast);
    return out;
}

const Interner = struct {
    gpa: std.mem.Allocator,
    scratch: std.mem.Allocator,
    /// Keyed on the parse node's ADDRESS, because the parser's `{n,m}` expansion
    /// points many cells at one atom — the tree is already a DAG. Hash-consing
    /// would collapse the duplicates anyway, so this looks like an optimization;
    /// it is not. Without it a nested bound (`((a{10}){10}){10}`) re-converts
    /// the shared subtree once per path that reaches it, which is exponential in
    /// nesting depth. With it, interning is linear in DISTINCT parse cells.
    memo: std.AutoHashMapUnmanaged(*const Node, Id) = .empty,

    fn node(self: *Interner, g: *Graph, n: *const Node) ParseError!Id {
        if (self.memo.get(n)) |hit| return hit;
        const id = try self.build(g, n);
        try self.memo.put(self.scratch, n, id);
        return id;
    }

    fn build(self: *Interner, g: *Graph, n: *const Node) ParseError!Id {
        return switch (n.*) {
            .empty => g.intern(self.gpa, .empty, .{ none, none }),
            .class => |c| g.intern(self.gpa, .{ .class = c }, .{ none, none }),
            .uclass => |r| g.intern(self.gpa, .{ .uclass = r }, .{ none, none }),
            .anchor_start => g.intern(self.gpa, .anchor_start, .{ none, none }),
            .anchor_end => g.intern(self.gpa, .anchor_end, .{ none, none }),
            .anchor_buf_start => g.intern(self.gpa, .anchor_buf_start, .{ none, none }),
            .anchor_buf_end => g.intern(self.gpa, .anchor_buf_end, .{ none, none }),
            .word => |m| g.intern(self.gpa, .{ .word = m }, .{ none, none }),
            .star => |r| g.intern(self.gpa, .{ .star = r.lazy }, .{ try self.node(g, r.node), none }),
            .plus => |r| g.intern(self.gpa, .{ .plus = r.lazy }, .{ try self.node(g, r.node), none }),
            .quest => |r| g.intern(self.gpa, .{ .quest = r.lazy }, .{ try self.node(g, r.node), none }),
            .capture => |c| g.intern(self.gpa, .{ .capture = c.idx }, .{ try self.node(g, c.child), none }),
            .concat => self.spine(g, n, .concat),
            .alt => self.spine(g, n, .alt),
        };
    }

    /// Flatten a left-folded chain of one operator, raise its repeated runs by
    /// squaring, and rebuild what is left as a balanced tree.
    fn spine(self: *Interner, g: *Graph, top: *const Node, op: Op) ParseError!Id {
        // Both buffers are sized from one pointer walk before either is filled.
        // Growing them as we go would be worse than it looks: two live arena
        // allocations interleave, so neither can ever extend in place, and a
        // thirty-operand spine pays a full copy per doubling.
        const width = count(top, op);
        var flat: std.ArrayList(*const Node) = try .initCapacity(self.scratch, width);
        defer flat.deinit(self.scratch);
        var parts: std.ArrayList(Id) = try .initCapacity(self.scratch, width);
        defer parts.deinit(self.scratch);
        flatten(top, op, &flat);

        // One id per operand, resolved once — the run scan below re-reads them
        // rather than re-interning, which for `a{500}` is 500 array reads in
        // place of 500 hash probes.
        for (flat.items) |n| parts.appendAssumeCapacity(try self.node(g, n));

        var out: usize = 0;
        var i: usize = 0;
        while (i < parts.items.len) {
            const id = parts.items[i];
            var run: usize = 1;
            // Compare by interned id, so `a{500}` is one run even though the
            // parser handed us five hundred separate concat cells pointing at
            // one atom — and so is any other accidental repetition.
            while (i + run < parts.items.len and parts.items[i + run] == id) run += 1;
            i += run;
            // Concatenation of a run is the squaring case. Alternation is
            // idempotent instead: `x|x|x` IS `x`, and hash-consing has already
            // proven the branches identical by handing back one id.
            parts.items[out] = if (op == .concat and run > 1)
                (try g.power(self.gpa, id, run, op, join)).?
            else
                id;
            out += 1;
        }
        return balance(self.gpa, g, op, parts.items[0..out]);
    }
};

/// How many operands a left-folded chain of `op` has. A pointer walk, so the
/// buffers it sizes are each allocated exactly once.
fn count(n: *const Node, op: Op) usize {
    const kids = operands(n, op) orelse return 1;
    return count(kids[0], op) + count(kids[1], op);
}

/// The two operands of `n`, when `n` is another link in an `op` chain.
inline fn operands(n: *const Node, op: Op) ?[2]*Node {
    return switch (n.*) {
        .concat => |ab| if (op == .concat) ab else null,
        .alt => |ab| if (op == .alt) ab else null,
        else => null,
    };
}

fn join(op: Op, g: *Graph, gpa: std.mem.Allocator, a: Id, b: Id) ParseError!Id {
    return g.intern(gpa, op, .{ a, b });
}

/// Collect a left-folded chain of `op` into its operands, left to right.
/// Capacity came from `count` over the same chain, so nothing here can fail.
fn flatten(n: *const Node, op: Op, out: *std.ArrayList(*const Node)) void {
    const kids = operands(n, op) orelse return out.appendAssumeCapacity(n);
    flatten(kids[0], op, out);
    flatten(kids[1], op, out);
}

/// Fold operands into a balanced binary tree. Balance is what lets hash-consing
/// see repetition at all: the left-folded chain the parser emits shares no
/// subtree with itself, while halves of a balanced tree over a repeated operand
/// are the same shape and collapse to one node.
fn balance(gpa: std.mem.Allocator, g: *Graph, op: Op, parts: []const Id) ParseError!Id {
    std.debug.assert(parts.len > 0);
    if (parts.len == 1) return parts[0];
    const mid = parts.len / 2;
    return g.intern(gpa, op, .{
        try balance(gpa, g, op, parts[0..mid]),
        try balance(gpa, g, op, parts[mid..]),
    });
}

const testing = std.testing;

/// Two allocations holding the same ranges over different rubbish - the shape
/// `scalars.finish` produces twice from one arena that was used in between.
///
/// Poison rather than zero on the second, because zero is the answer a fresh
/// mapping happens to give and testing against it is how this survived: the
/// bytes only differ once an allocator has recycled something.
///
/// Each bound is stored as a literal, which is the one spelling that leaves the
/// slack alone - and is what `ScalarSet.addRange` does. Writing this as
/// `@memcpy` instead makes the whole test vacuous: a copy carries the source's
/// bytes, so a `.rodata` source hands both sides its own zeros and the poison
/// is never read. That is the first draft of this helper, and it passed.
fn twoWays(gpa: std.mem.Allocator, ranges: []const [2]u21) ![2][][2]u21 {
    var out: [2][][2]u21 = undefined;
    for (&out, [_]u8{ 0x00, 0xAA }) |*side, fill| {
        side.* = try gpa.alloc([2]u21, ranges.len);
        @memset(std.mem.sliceAsBytes(side.*), fill);
        for (side.*, ranges) |*dst, src| dst.* = .{ src[0], src[1] };
    }
    return out;
}

test "a scalar class interns by the ranges it names, not by the bytes under them" {
    // What this stands against: `sliceAsBytes` over `[]const [2]u21` hands the
    // hash eight bytes per range of which forty-two bits are the bounds. The
    // rest belonged to whoever held the arena first, so `\p{L}` parsed in two
    // patterns of one slate could hash apart and compare unequal while naming
    // one set - and then the DAG carries two nodes for one class, and the
    // alphabet, the determinization and the automaton in the folio are all a
    // function of an allocator rather than of the pattern.
    const gpa = testing.allocator;
    const sides = try twoWays(gpa, &.{ .{ 'a', 'z' }, .{ 0x100, 0x10FFFF } });
    defer for (sides) |s| gpa.free(s);

    // The two sides must actually differ under the bytes, or everything below
    // is a tautology. This is the assertion the vacuous first draft failed.
    try testing.expect(!std.mem.eql(
        u8,
        std.mem.sliceAsBytes(sides[0]),
        std.mem.sliceAsBytes(sides[1]),
    ));

    const a: Op = .{ .uclass = sides[0] };
    const b: Op = .{ .uclass = sides[1] };
    try testing.expect(a.eql(b));
    try testing.expectEqual(a.hash(), b.hash());

    // And still tells two different sets apart, which a hash that read nothing
    // would also pass the half above by doing.
    const other = try twoWays(gpa, &.{ .{ 'a', 'y' }, .{ 0x100, 0x10FFFF } });
    defer for (other) |s| gpa.free(s);
    try testing.expect(!a.eql(.{ .uclass = other[0] }));

    // The DAG is what actually consumes the pair; one node, not two.
    var g: Graph = .empty;
    defer g.deinit(gpa);
    const x = try g.intern(gpa, a, .{ none, none });
    try testing.expectEqual(x, try g.intern(gpa, b, .{ none, none }));
    try testing.expect(x != try g.intern(gpa, .{ .uclass = other[0] }, .{ none, none }));
    try testing.expectEqual(@as(usize, 2), g.len());
}

test "the range payload really does have bytes no bound owns" {
    // Otherwise the test above is green because there was nothing to get
    // wrong - the shape of every flattering instrument in this tree, and
    // exactly why `dag_test`'s two `.rodata` copies never caught this. If
    // `[2]u21` ever becomes seamless, delete this and say so.
    try testing.expect(!std.meta.hasUniqueRepresentation([2]u21));
    // And the repair is not the same claim restated: `Range` is what `asBytes`
    // is allowed to be pointed at.
    try testing.expect(std.meta.hasUniqueRepresentation(Range));
}
