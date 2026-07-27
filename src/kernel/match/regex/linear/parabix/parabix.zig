//! gist — the Parabix rung: within-document boolean match by bit-parallel
//! marker propagation. The package's front door; `plane.zig`, `stencil.zig`,
//! and `admit.zig` are its floor, its class compiler, and its gate.
//!
//! The whole engine is one inversion. A DFA keeps ONE automaton state and asks
//! "where does this byte take me?", which is a loop-carried L1 load and
//! therefore runs at load LATENCY — the ~4 cycles/byte floor every table-walk
//! matcher shares, and the 0.277 B/cycle this rung is measured against. Here
//! the state is a MARKER STREAM — a bit per haystack position saying "some
//! prefix of the pattern matched up to here" — and a pattern step is a shift
//! and a mask over 512 positions at once. Nothing is loaded per byte, nothing
//! is gathered, and the dependence chain is as long as the PATTERN, not as long
//! as the text.
//!
//! Concretely, for one block:
//!
//!   * every position starts live (the search is unanchored, so every position
//!     is a candidate start);
//!   * a class term advances the marker stream by one — `(m & class) << 1`,
//!     "positions that were live AND whose byte is in the class move forward";
//!   * `?` keeps the old markers alongside the advanced ones;
//!   * `*` and `+` consume a whole run in a single ADDITION — Parabix's
//!     `MatchStar`, `(((m & c) + c) ^ c) | m`, where the hardware's carry chain
//!     does the closure the fixpoint loop would otherwise iterate;
//!   * a surviving marker at the end is a match.
//!
//! Blocks are stitched by carries, one per shift and addition site, so a match
//! straddling a block boundary is seen exactly once and the answer does not
//! depend on where the blocks fall. A final padded block catches a match ending
//! at the last byte.
//!
//! Prior art: Cameron, Lin, Herdy, Wu, Amiri, Lin, Hull et al., "Bitwise Data
//! Parallelism in Regular Expression Matching" (PACT 2014) and the icGrep
//! system at Simon Fraser University. The transposition, the character-class
//! bit-plane compilation, and `MatchStar` are all theirs. What is ours is the
//! Billy-native rebuild — a folding Shannon expansion instead of their
//! multiplexing CC compiler, a fixed-size allocation-free program that embeds
//! in `Regex` by value, GPR carry threading chosen for AArch64's lack of
//! `movemask`, and the compile-time admission gate that keeps their published
//! collapse case away from the kernel entirely. **No novelty is claimed for the
//! technique.**
//!
//! Where this rung does NOT help is published beside where it does, in
//! `README.md` and in `admit.zig`'s gate.

const std = @import("std");
const syn = @import("../../syntax/syntax.zig");
const word = @import("../../syntax/word.zig");
const plane = @import("plane.zig");
const stencil = @import("stencil.zig");
const admit = @import("admit.zig");

/// The bit-plane floor and the class-circuit compiler. Public because the rung's
/// throughput claim is a claim about the RATIO between them — the bench times
/// transposition alone, transposition plus class streams, then the whole scan, so
/// "the transposition is 40% of the work" is measured here rather than quoted
/// from the paper.
pub const plane_floor = plane;
pub const class_circuits = stencil;

pub const Program = admit.Program;
pub const Decline = admit.Decline;
pub const Plan = admit.Plan;
pub const Model = admit.Model;
pub const Economics = admit.Economics;
pub const plan = admit.plan;
pub const starHeight = admit.starHeight;

/// Can this build arm the rung at all? False everywhere but little-endian
/// AArch64 — the throughput claim was measured there and the transposition is
/// written for NEON's byte permutes. Published so a bench can say "declined
/// because of the target" rather than reporting a silent zero.
pub const native = plane.on_neon;

/// Every carry the marker chain threads across a block seam: one per shift
/// site, one per `MatchStar` addition. Zeroed at the start of a scan, which is
/// the only per-call state this engine has.
const Carries = [admit.max_carries]plane.Block;

/// One block's class streams, masked to the block's live bytes.
const Streams = [stencil.max_classes]plane.Block;

/// The parse knobs `compile` forwards — the subset of `lower.Options` that
/// changes what the AST MEANS. Everything else in that struct is about which
/// executor gets built, which is not this rung's business.
pub const Syntax = struct {
    caseless: bool = false,
    multiline: bool = false,
    dotall: bool = false,
    unicode: bool = false,

    pub fn model(self: Syntax) Model {
        return .{
            .grain = if (self.multiline) .buffer else .lines,
            .unicode_words = self.unicode,
        };
    }
};

pub const Build = union(enum) { armed: Parabix, declined: Decline };

/// A compiled Parabix matcher. Immutable, allocation-free, embeddable by value
/// in `Regex`, and safe to share across threads — a scan's only mutable state
/// is the carry array it creates on its own stack.
pub const Parabix = struct {
    prog: Program,
    economics: Economics,

    /// Arm the rung, or decline. THE production seam: `lower.compileOpts` already
    /// holds the AST and the scan model, so it pays nothing to ask. The admission
    /// gate reads only the pattern's own shape and its measured operation price —
    /// sibling economics are the parent's to compare (`ladder/rungs.zig`).
    pub fn build(root: *const syn.Node, model: Model) Build {
        return offer(admit.plan(root, model));
    }

    /// The same decision reached from pattern TEXT, for callers that hold no
    /// AST — the standalone bench and the differential harnesses, which must be
    /// able to arm this rung without the ladder wiring existing yet.
    ///
    /// The arena dies on return: an armed `Program` is fixed-size and owns no
    /// pointers, which is the property that lets it embed in `Regex` by value.
    /// `parabix_test.zig` pins this against `lower.parse` + `build` so the two
    /// entrances cannot drift on what a pattern means.
    pub fn compileOffer(gpa: std.mem.Allocator, pattern: []const u8, opts: Syntax) Build {
        return offer(decide(gpa, pattern, opts));
    }

    /// The raw `Plan` behind `compileOffer` — the admitted `Candidate` (program
    /// plus economics) or the named `Decline`. Only the bench and the gate tests
    /// want the reason; a caller that merely needs the matcher takes `compileOffer`.
    pub fn decide(gpa: std.mem.Allocator, pattern: []const u8, opts: Syntax) Plan {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var parser = syn.Parser{ .src = pattern, .arena = arena, .dotall = opts.dotall, .multiline = opts.multiline, .unicode = opts.unicode };
        const ast = parser.parseAlt() catch return .{ .declined = .too_complex };
        if (parser.pos != pattern.len) return .{ .declined = .too_complex };
        if (opts.caseless) syn.foldCaseAst(arena, ast, opts.unicode) catch return .{ .declined = .too_complex };
        return admit.plan(ast, opts.model());
    }

    fn offer(decision: Plan) Build {
        return switch (decision) {
            .admitted => |armed| .{ .armed = .{ .prog = armed.program, .economics = armed.economics } },
            .declined => |why| .{ .declined = why },
        };
    }

    /// Does the pattern match any substring of `hay`? TOTAL — once armed this
    /// rung always answers, and its answer is the Pike VM's.
    ///
    /// Serves both `lineMatch` and `docMatch` from one implementation. The gate
    /// refuses any class containing `\n`, so no match can cross a line, so
    /// "some line of the buffer matches" and "the buffer matches somewhere" are
    /// the same question — one fused whole-buffer pass, no line splitting.
    pub fn match(self: *const Parabix, hay: []const u8) bool {
        var carry: Carries = @splat(0);
        var pos: usize = 0;
        // The striped bulk: four blocks transposed together so one decoded
        // circuit gate drives 512 positions.
        if (hay.len >= plane.stripe_width) {
            var vals: stencil.Scratch(plane.Wide) = undefined;
            while (pos + plane.stripe_width <= hay.len) : (pos += plane.stripe_width) {
                if (self.stripe(&carry, &vals, hay, pos, hay[pos..][0..plane.stripe_width])) return true;
            }
        }
        var vals: stencil.Scratch(plane.Lane) = undefined;
        while (pos + plane.width <= hay.len) : (pos += plane.width) {
            if (self.block(&carry, &vals, hay, pos, hay[pos..][0..plane.width], plane.width)) return true;
        }
        // One padded block always runs, even on an exact multiple: a match
        // ending at the very last byte leaves its marker at position `len`,
        // which is the first position of the block AFTER the data.
        var pad: [plane.width]u8 = @splat(0);
        const rest = hay.len - pos;
        @memcpy(pad[0..rest], hay[pos..]);
        return self.block(&carry, &vals, hay, pos, &pad, rest);
    }

    /// One full stripe: transpose, evaluate every class circuit across all four
    /// blocks at once, then walk the marker chain block by block (the chain is
    /// inherently sequential — that is what the carries are for).
    fn stripe(self: *const Parabix, carry: *Carries, vals: *stencil.Scratch(plane.Wide), hay: []const u8, base: usize, src: *const [plane.stripe_width]u8) bool {
        const basis = plane.transposeStripe(src);
        var wide: [stencil.max_classes]plane.Wide = undefined;
        for (self.prog.circuits[0..self.prog.nclasses], 0..) |*c, i| wide[i] = c.eval(plane.Wide, &basis, vals);

        var hit = false;
        inline for (0..plane.stripe) |b| {
            var cls: Streams = undefined;
            for (0..self.prog.nclasses) |i| cls[i] = plane.blockOf(wide[i], b);
            hit = self.markers(carry, &cls, hay, base + b * plane.width, plane.width) or hit;
        }
        return hit;
    }

    /// One block, with `live` real bytes (the rest is zero padding).
    fn block(self: *const Parabix, carry: *Carries, vals: *stencil.Scratch(plane.Lane), hay: []const u8, base: usize, src: *const [plane.width]u8, live: usize) bool {
        const basis = plane.transpose(src);
        const keep = plane.liveMask(live);
        var cls: Streams = undefined;
        for (self.prog.circuits[0..self.prog.nclasses], 0..) |*c, i| cls[i] = plane.bits(c.eval(plane.Lane, &basis, vals)) & keep;
        return self.markers(carry, &cls, hay, base, live);
    }

    /// The marker chain over one block. Every branch of a top-level alternation
    /// re-walks the same class streams with its own chain; a match is any
    /// branch's surviving marker inside the block's live positions.
    fn markers(self: *const Parabix, carry: *Carries, cls: *const Streams, hay: []const u8, base: usize, live: usize) bool {
        const reach = plane.spanMask(live);
        var acc: plane.Block = 0;
        for (self.prog.branches[0..self.prog.nbranches]) |br| {
            // Unanchored: every position of the block is a candidate start. A
            // position past the data cannot survive even one term, because the
            // class streams are masked to live bytes and the gate refused
            // nullable patterns.
            var m: plane.Block = ~@as(plane.Block, 0);
            for (self.prog.instrs[br.first..][0..br.len]) |ins| {
                const c = cls[ins.cls];
                switch (ins.op) {
                    .step => for (0..ins.k) |j| {
                        m = plane.shiftIn(m & c, 1, &carry[ins.carry + j]);
                    },
                    .opt => for (0..ins.k) |j| {
                        m |= plane.shiftIn(m & c, 1, &carry[ins.carry + j]);
                    },
                    // MatchStar: the carry chain of one addition consumes an
                    // entire run of class bytes, however long, in one op.
                    .star => {
                        const run = plane.addIn(m & c, c, &carry[ins.carry]);
                        m |= run ^ c;
                    },
                    else => m &= assertionStream(ins, c, carry, hay.len, base),
                }
            }
            acc |= m;
        }
        return acc & reach != 0;
    }

    /// Vector ops one stripe costs — what the rung's place in the ladder is
    /// argued from. Read by the bench and by anyone deciding whether a pattern
    /// is worth this machine.
    pub fn stripeOps(self: *const Parabix) usize {
        return self.prog.stripeOps();
    }
};

inline fn gapBit(position: usize, base: usize) plane.Block {
    if (position < base or position - base >= plane.width) return 0;
    return @as(plane.Block, 1) << @intCast(position - base);
}

/// Assertion superinstructions over existing class streams. A line assertion
/// reuses the interned newline stream; an ASCII word assertion reuses `\w`.
/// Only "word-before" needs a seam carry. No per-gap interpreter remains.
inline fn assertionStream(
    ins: admit.Instr,
    c: plane.Block,
    carry: *Carries,
    hay_len: usize,
    base: usize,
) plane.Block {
    return switch (ins.op) {
        .line_start => plane.shiftIn(c, 1, &carry[ins.carry]) | gapBit(0, base),
        .line_end => c | gapBit(hay_len, base),
        .slice_start => gapBit(0, base),
        .slice_end => gapBit(hay_len, base),
        .word_boundary, .not_word_boundary, .word_start, .word_end => blk: {
            const before = plane.shiftIn(c, 1, &carry[ins.carry]);
            break :blk switch (ins.op) {
                .word_boundary => before ^ c,
                .not_word_boundary => ~(before ^ c),
                .word_start => ~before & c,
                .word_end => before & ~c,
                else => unreachable,
            };
        },
        else => unreachable,
    };
}

/// The marker semantics, written directly from the instruction list with no
/// bit parallelism at all: walk every start position, walk every branch,
/// consume bytes. Quadratic and obviously correct — the unit-level oracle for
/// the block machinery, below the Pike VM differential that holds the whole
/// rung.
pub fn matchScalar(prog: *const admit.Program, hay: []const u8) bool {
    for (0..hay.len + 1) |start| {
        for (prog.branches[0..prog.nbranches]) |br| {
            if (reaches(prog, hay, start, prog.instrs[br.first..][0..br.len])) return true;
        }
    }
    return false;
}

fn reaches(prog: *const admit.Program, hay: []const u8, at: usize, instrs: []const admit.Instr) bool {
    if (instrs.len == 0) return true;
    const ins = instrs[0];
    const rest = instrs[1..];
    var p = at;
    switch (ins.op) {
        .step => {
            const set = &prog.sets[ins.cls];
            for (0..ins.k) |_| {
                if (p >= hay.len or !set.has(hay[p])) return false;
                p += 1;
            }
            return reaches(prog, hay, p, rest);
        },
        .opt, .star => {
            const set = &prog.sets[ins.cls];
            const cap: usize = if (ins.op == .star) hay.len else ins.k;
            var used: usize = 0;
            while (true) {
                if (reaches(prog, hay, p, rest)) return true;
                if (used == cap or p >= hay.len or !set.has(hay[p])) return false;
                p += 1;
                used += 1;
            }
        },
        else => {
            const before = word.wordBefore(prog.model.unicode_words, hay, p);
            const after = word.wordAt(prog.model.unicode_words, hay, p);
            const yes = switch (ins.op) {
                .line_start => p == 0 or hay[p - 1] == '\n',
                .line_end => p == hay.len or hay[p] == '\n',
                .slice_start => p == 0,
                .slice_end => p == hay.len,
                .word_boundary => before != after,
                .not_word_boundary => before == after,
                .word_start => !before and after,
                .word_end => before and !after,
                else => unreachable,
            };
            return yes and reaches(prog, hay, p, rest);
        },
    }
}
