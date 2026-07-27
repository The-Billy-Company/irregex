//! gist — Thompson construction over **codepoints** instead of bytes.
//!
//! `compile/compile.zig` lowers a `uclass` through `lowerUtf8`: one UTF-8 byte
//! sub-automaton per occurrence, so Unicode `\w` costs ~900 NFA states and
//! `\w{3,8}` clones them eight times. Here the same node is one instruction —
//! `consume{ pred }` — because the alphabet already knows what `\w` means
//! (`alphabet.zig`). The lowering is otherwise instruction-for-instruction the
//! byte compiler's: same split priorities, same `star`/`plus` entry choice, same
//! transparent `capture`, so the two programs recognize the same language and
//! the differential oracle is comparing constructions, not grammars.
//!
//! What it refuses is as load-bearing as what it accepts. A word-boundary
//! assertion is a second determinization axis the byte path resolves with
//! word-refined classes and a doubled table; a buffer anchor only exists under
//! multiline, where no DFA is built at all; a `class` carrying a byte ≥ 0x80 is
//! a *byte* predicate that a codepoint alphabet cannot express. Each of those
//! declines here and the pattern keeps the shipped byte path unchanged.

const std = @import("std");
const syn = @import("../../syntax/syntax.zig");
const alphabet = @import("alphabet.zig");

const Node = syn.Node;

/// Why a pattern cannot be lowered to a codepoint program.
/// File-private control flow (ADR-373): converted to `.declined` at the
/// symbolic module boundary — not members of the declared fault taxonomy.
const Reject = error{
    /// `\b` `\B` `\<` `\>` — the word-context axis, byte-path only here.
    WordContext,
    /// `\A` `\z` — multiline-only, where no eager DFA exists.
    BufferAnchor,
    /// A `class` node with a member ≥ 0x80: a raw byte predicate, not a scalar.
    HighByteClass,
    /// More distinct predicates than the minterm signature holds.
    TooManyPredicates,
};

const Error = Reject || std.mem.Allocator.Error;

/// One instruction of the codepoint program. The byte program's shape minus the
/// word/buffer assertions this lowering rejects, with `consume` carrying an
/// alphabet predicate slot rather than a 256-bit byte set.
pub const CpState = union(enum) {
    consume: struct { pred: u16, out: u32 },
    split: struct { a: u32, b: u32 },
    assert_start: u32, // `^`
    assert_end: u32, // `$`
    match,
};

/// A lowered codepoint program plus the alphabet its predicates index into.
pub const Program = struct {
    gpa: std.mem.Allocator,
    states: []CpState,
    start: u32,
    alpha: alphabet.Alphabet,

    pub fn deinit(p: *Program) void {
        p.gpa.free(p.states);
        p.alpha.deinit();
    }
};

/// Is this AST worth lowering symbolically at all? Only a `uclass` pays the
/// UTF-8 trie tax the symbolic alphabet removes; an all-ASCII program's byte
/// determinization is already the cheapest thing in the engine, and routing it
/// here would trade a known-optimal path for an equal one.
pub fn hasCodepointClass(n: *const Node) bool {
    return switch (n.*) {
        .uclass => true,
        .concat, .alt => |kids| hasCodepointClass(kids[0]) or hasCodepointClass(kids[1]),
        .star, .plus, .quest => |r| hasCodepointClass(r.node),
        .capture => |g| hasCodepointClass(g.child),
        else => false,
    };
}

const Compiler = struct {
    gpa: std.mem.Allocator,
    states: std.ArrayList(CpState) = .empty,
    alpha: alphabet.Builder,

    fn push(c: *Compiler, s: CpState) Error!u32 {
        try c.states.append(c.gpa, s);
        return @intCast(c.states.items.len - 1);
    }

    /// Compile `node` so all its exits flow to `next`; return its entry. The
    /// byte compiler's `compileNode`, arm for arm.
    fn node(c: *Compiler, n: *Node, next: u32) Error!u32 {
        switch (n.*) {
            .empty => return next,
            .anchor_start => return c.push(.{ .assert_start = next }),
            .anchor_end => return c.push(.{ .assert_end = next }),
            .anchor_buf_start, .anchor_buf_end => return Reject.BufferAnchor,
            .word_boundary, .not_word_boundary, .word_start, .word_end => return Reject.WordContext,
            .class => |set| {
                var b: u16 = 0x80;
                while (b <= 0xFF) : (b += 1) if (set.has(@intCast(b))) return Reject.HighByteClass;
                return c.push(.{ .consume = .{ .pred = try c.alpha.internByteSet(&set), .out = next } });
            },
            .uclass => |ranges| return c.push(.{ .consume = .{ .pred = try c.alpha.intern(ranges), .out = next } }),
            .capture => |g| return c.node(g.child, next),
            .concat => |ab| {
                const s2 = try c.node(ab[1], next);
                return c.node(ab[0], s2);
            },
            .alt => |ab| {
                const sa = try c.node(ab[0], next);
                const sb = try c.node(ab[1], next);
                return c.push(.{ .split = .{ .a = sa, .b = sb } });
            },
            .quest => |r| {
                const sx = try c.node(r.node, next);
                return c.push(if (r.lazy) .{ .split = .{ .a = next, .b = sx } } else .{ .split = .{ .a = sx, .b = next } });
            },
            .star, .plus => |r, tag| {
                const sp = try c.push(.{ .split = .{ .a = 0, .b = 0 } });
                const sx = try c.node(r.node, sp);
                c.states.items[sp].split = if (r.lazy) .{ .a = next, .b = sx } else .{ .a = sx, .b = next };
                return if (tag == .star) sp else sx;
            },
        }
    }
};

/// Lower `ast` into a codepoint program over a freshly minted minterm alphabet,
/// or reject. On success the caller owns the returned `Program`.
pub fn lower(gpa: std.mem.Allocator, ast: *Node) Error!Program {
    var c = Compiler{ .gpa = gpa, .alpha = alphabet.Builder.init(gpa) };
    defer c.alpha.deinit();
    errdefer c.states.deinit(gpa);

    const match_idx = try c.push(.match);
    const start = try c.node(ast, match_idx);
    var alpha = try c.alpha.finish();
    errdefer alpha.deinit();
    return .{ .gpa = gpa, .states = try c.states.toOwnedSlice(gpa), .start = start, .alpha = alpha };
}
