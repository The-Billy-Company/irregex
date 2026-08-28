//! irregex — the Parabix rung's admission gate: who this kernel is allowed to
//! serve, decided entirely at compile time.
//!
//! Bit-parallel matching has a cliff, and it is not gentle. A flat pattern runs
//! at 3–4½ bytes per cycle; a NESTED Kleene (`(a*)*`, `(\w+)+`) turns the
//! marker step into a fixpoint iteration whose trip count depends on the data,
//! and this lane measured it at 0.061 B/cycle — four times SLOWER than the
//! byte-at-a-time baseline it is supposed to replace. A rung that merely
//! degrades on its bad case is a latency bug waiting for the wrong corpus. So
//! this one is a DECIDER: it refuses at compile time, the field stays null, and
//! the pattern never learns the kernel existed. Star-height ≥ 2 does not reach
//! the executor — not as a slow path, not at all.
//!
//! Admission now answers only what this package can know: representability and
//! its own measured operation price. It does not accept booleans describing
//! other engines. The parent compares the published `Economics` with its public
//! prefilter economics and chooses the rung; representation never changes when
//! a sibling happens to have been built first.
//!
//! What survives the gates is a chain of character classes/assertions with at most
//! single-level repetition: `\w+@\w+\.\w+`, `[a-z]+[0-9]+`, `.{4}[a-z]+`,
//! `[a-z]{2,8}_[a-z]+`. That is the family the lane measured, and it is the
//! family where the dispatch below is the fastest sound machine we have.

const std = @import("std");
const syn = @import("../../syntax/syntax.zig");
const plane = @import("plane.zig");
const stencil = @import("stencil.zig");

/// Instructions in one branch's marker program, summed over all branches.
pub const max_terms: usize = 24;

/// Top-level alternatives. Each costs a full marker chain over the same class
/// streams, so the streams amortize but the chains do not.
pub const max_branches: usize = 4;

/// Shift and addition sites, each of which carries one block's worth of state
/// across the seam. A `step` of k needs k, an `opt` of r needs r, a `star` one.
pub const max_carries: usize = 64;

/// Unbounded repetition sentinel for a term's `max`.
pub const inf: u8 = 255;

/// The scan model is explicit because assertions are properties of gaps, not
/// bytes. `lines` means a fused document scan with newline as an impassable
/// separator; `buffer` permits consuming newline. In both models `^`/`$` denote
/// line gaps, while `\A`/`\z` denote slice gaps.
pub const Model = struct {
    grain: enum { lines, buffer } = .lines,
    unicode_words: bool = false,
};

/// Why the rung stood down. Every one of these is a compile-time verdict; none
/// can be reached from a scan.
pub const Decline = enum {
    /// Not a little-endian AArch64 build. The throughput claim was measured
    /// here and nowhere else.
    target,
    /// The pattern can match the empty string, which `eol_empty` owns.
    nullable,
    /// Star-height ≥ 2 — the collapse case. THE gate.
    star_height,
    /// A Unicode codepoint class: multi-byte, so membership is not a function
    /// of one byte's eight bits and the whole basis-plane model does not apply.
    unicode,
    /// A Unicode word assertion needs a decoded scalar/property stream. The
    /// byte-word superinstruction is sound only in ASCII mode; a scalar gap
    /// loop measured below Pike and is therefore not a costable fallback.
    unicode_assertion,
    /// A quantifier over something that is not a single class.
    group_repeat,
    /// An alternation somewhere other than the top level.
    nested_alt,
    /// A class carrying `\n`, which would let one match span two lines and
    /// break the equivalence between a whole-buffer scan and the per-line model.
    newline_class,
    /// More distinct byte sets, terms, branches, gates, repetitions, or seam
    /// carries than the fixed-size program holds.
    too_complex,
    /// Representable, but its finite catalogue/fallback plus marker work is
    /// above the operation ceiling. The parent receives this reason rather than
    /// a false "unsupported" verdict.
    uncostable,
};

/// A `step`/`opt`/`star` in the marker chain.
pub const Op = enum(u8) {
    /// Consume exactly `k` bytes of the class.
    step,
    /// Consume up to `k` bytes of the class.
    opt,
    /// Consume any number of bytes of the class — the `MatchStar` closure.
    star,
    line_start,
    line_end,
    slice_start,
    slice_end,
    // One opcode per word predicate rather than one carrying `syn.Word`'s mask:
    // each is a two-gate circuit over the same pair of bit planes, where
    // evaluating the mask generally would cost a sum of four products per block.
    // The mask is the vocabulary; these are its circuits.
    word_boundary,
    not_word_boundary,
    word_start,
    word_end,
    word_start_half,
    word_end_half,
};

pub const Instr = struct {
    op: Op,
    cls: u8,
    /// Repetition count. Always 1 for `star`.
    k: u8,
    /// First seam-carry slot this instruction owns; it uses `k` of them.
    carry: u8,
};

/// One top-level alternative: a contiguous run of the instruction table.
pub const Branch = struct { first: u8, len: u8 };

/// The admitted pattern, lowered. Fixed-size and self-contained — it embeds by
/// value in `Regex`, allocates nothing, and is thread-safe to share.
pub const Program = struct {
    circuits: [stencil.max_classes]stencil.Circuit = undefined,
    /// The byte sets the circuits were compiled from. Kept so the program is
    /// self-describing: the scalar oracle reads membership straight from here
    /// rather than re-deriving it from the AST it is supposed to check.
    sets: [stencil.max_classes]syn.ByteSet = undefined,
    nclasses: u8 = 0,
    instrs: [max_terms]Instr = undefined,
    ninstrs: u8 = 0,
    branches: [max_branches]Branch = undefined,
    nbranches: u8 = 0,
    ncarries: u8 = 0,
    model: Model = .{},

    /// Vector ops one stripe costs: the eight transpositions, the class
    /// circuits, and the marker chains. The rung publishes this so its place in
    /// the ladder can be argued from a number rather than from a hope.
    pub fn stripeOps(self: *const Program) usize {
        var n: usize = transpose_ops;
        for (self.circuits[0..self.nclasses]) |*c| n += c.ops();
        for (self.instrs[0..self.ninstrs]) |i| n += switch (i.op) {
            .step, .opt => @as(usize, i.k) * 5 * plane.stripe,
            .star => 7 * plane.stripe,
            else => 2 * plane.stripe,
        };
        return n;
    }
};

/// The share of `stripeOps` every admitted program pays identically: eight
/// bit-plane transpositions per block, before a single marker op runs.
///
/// Named and exported because it is the ONLY part of the count that does not
/// vary with the pattern, which makes it the intercept of any honest cost model
/// over that count — `ladder/price.zig` subtracts it to recover the variable
/// half. Pricing it as if it scaled with a pattern's op count charged small
/// programs for a constant and, on a host where the transposition is dear
/// relative to a marker op, extrapolated ~1.6× too dear over the `\b` shapes.
pub const transpose_ops: usize = 104 * plane.stripe;

pub const Economics = struct {
    stripe_ops: usize,
    catalogue_classes: u8,
    fallback_classes: u8,
    marker_ops: u16,
    carries: u8,
};

pub const Candidate = struct { program: Program, economics: Economics };
pub const Plan = union(enum) { admitted: Candidate, declined: Decline };
pub const max_stripe_ops: usize = 4096;

/// Kleene closure nesting depth. `?` is bounded, so it does not count; `*` and
/// `+` do. Exposed because "the gate refused it" and "the pattern really is
/// star-height 2" are two different claims and the test asserts both.
pub fn starHeight(n: *const syn.Node) u32 {
    return switch (n.*) {
        .star, .plus => |r| 1 + starHeight(r.node),
        .quest => |r| starHeight(r.node),
        .concat, .alt => |kids| @max(starHeight(kids[0]), starHeight(kids[1])),
        .capture => |g| starHeight(g.child),
        else => 0,
    };
}

/// Decide, and on admission lower. Pure: same AST and scan model in, same
/// verdict out, no allocation and no I/O.
pub fn plan(root: *const syn.Node, model: Model) Plan {
    return planFor(plane.vectorized, root, model);
}

/// `plan` with the target predicate passed in. The refusal is a comptime
/// branch, so on any one machine it is unreachable and untestable in place —
/// this seam lets the gate test drive the verdict the OTHER build produces, and
/// the cross-compile check proves that build still compiles.
pub fn planFor(comptime vector: bool, root: *const syn.Node, model: Model) Plan {
    if (!vector) return .{ .declined = .target };
    if (starHeight(root) > 1) return .{ .declined = .star_height };

    var b = Builder{ .model = model };
    b.prog.model = model;
    var alts: [max_branches]*const syn.Node = undefined;
    var nalts: usize = 0;
    flattenAlt(root, &alts, &nalts);
    if (nalts == 0 or nalts > max_branches) return .{ .declined = .too_complex };

    for (alts[0..nalts]) |branch| {
        const first = b.prog.ninstrs;
        b.terms = 0;
        if (b.lowerSeq(branch, 0)) |d| return .{ .declined = d };
        if (b.mandatory == 0) return .{ .declined = .nullable };
        if (b.prog.ninstrs == first) return .{ .declined = .nullable };
        b.prog.branches[b.prog.nbranches] = .{ .first = first, .len = b.prog.ninstrs - first };
        b.prog.nbranches += 1;
        b.mandatory = 0;
        b.last_cls = null;
    }
    const cost = economics(&b.prog);
    if (cost.stripe_ops > max_stripe_ops) return .{ .declined = .uncostable };
    return .{ .admitted = .{ .program = b.prog, .economics = cost } };
}

fn economics(prog: *const Program) Economics {
    var catalogue: u8 = 0;
    var fallback: u8 = 0;
    for (prog.circuits[0..prog.nclasses]) |*c| {
        if (c.usesFallback()) fallback += 1 else catalogue += 1;
    }
    var marker: usize = 0;
    for (prog.instrs[0..prog.ninstrs]) |i| marker += switch (i.op) {
        .step, .opt => @as(usize, i.k) * 5 * plane.stripe,
        .star => 7 * plane.stripe,
        else => 2 * plane.stripe,
    };
    return .{
        .stripe_ops = prog.stripeOps(),
        .catalogue_classes = catalogue,
        .fallback_classes = fallback,
        .marker_ops = @intCast(@min(marker, std.math.maxInt(u16))),
        .carries = prog.ncarries,
    };
}

/// Left-folded `alt` chains flatten to a branch list; anything else is one
/// branch. Overflow leaves `nalts` past the cap for the caller to reject.
fn flattenAlt(n: *const syn.Node, out: *[max_branches]*const syn.Node, count: *usize) void {
    switch (n.*) {
        .alt => |kids| {
            flattenAlt(kids[0], out, count);
            flattenAlt(kids[1], out, count);
        },
        .capture => |g| flattenAlt(g.child, out, count),
        else => {
            if (count.* < max_branches) out[count.*] = n;
            count.* += 1;
        },
    }
}

/// Walks one branch's concat spine, interning classes and emitting the marker
/// chain with peephole fusion — which is what turns the parser's desugaring of
/// `a{3,6}` (three classes then three `quest` nodes) back into two
/// instructions instead of six.
const Builder = struct {
    prog: Program = .{},
    /// Bytes this branch must consume. Zero at the end ⇒ nullable ⇒ decline.
    mandatory: u32 = 0,
    /// Class of the instruction fusion is allowed to extend, if any.
    last_cls: ?u8 = null,
    terms: u32 = 0,
    model: Model,

    fn lowerSeq(b: *Builder, n: *const syn.Node, depth: u32) ?Decline {
        if (depth > 64) return .too_complex;
        switch (n.*) {
            .concat => |kids| {
                if (b.lowerSeq(kids[0], depth + 1)) |d| return d;
                return b.lowerSeq(kids[1], depth + 1);
            },
            .capture => |g| return b.lowerSeq(g.child, depth + 1),
            .empty => return null,
            .alt => return .nested_alt,
            else => return b.lowerAtom(n),
        }
    }

    fn lowerAtom(b: *Builder, n: *const syn.Node) ?Decline {
        b.terms += 1;
        if (b.terms > max_terms) return .too_complex;
        switch (n.*) {
            .class => |set| return b.term(&set, 1, 1),
            .uclass => return .unicode,
            .star => |r| return b.repeat(r.node, 0, inf),
            .plus => |r| return b.repeat(r.node, 1, inf),
            .quest => |r| return b.repeat(r.node, 0, 1),
            .anchor_start => return b.assertion(.line_start),
            .anchor_end => return b.assertion(.line_end),
            .anchor_buf_start => return b.assertion(.slice_start),
            .anchor_buf_end => return b.assertion(.slice_end),
            .word => |mask| return b.assertion(switch (mask) {
                .boundary => .word_boundary,
                .not_boundary => .not_word_boundary,
                .start => .word_start,
                .end => .word_end,
                .start_half => .word_start_half,
                .end_half => .word_end_half,
            }),
            .concat, .alt, .capture, .empty => unreachable, // `lowerSeq` owns these
        }
    }

    fn assertion(b: *Builder, op: Op) ?Decline {
        b.last_cls = null;
        var set = syn.ByteSet{};
        const cls = switch (op) {
            .line_start, .line_end => blk: {
                set.set('\n');
                break :blk b.intern(&set) orelse return .too_complex;
            },
            .word_boundary, .not_word_boundary, .word_start, .word_end, .word_start_half, .word_end_half => blk: {
                if (b.model.unicode_words) return .unicode_assertion;
                set.setRange('0', '9');
                set.setRange('A', 'Z');
                set.setRange('a', 'z');
                set.set('_');
                break :blk b.intern(&set) orelse return .too_complex;
            },
            .slice_start, .slice_end => 0,
            else => unreachable,
        };
        return b.emit(op, cls, 0);
    }

    fn repeat(b: *Builder, body: *const syn.Node, min: u8, max: u8) ?Decline {
        return switch (body.*) {
            .class => |set| b.term(&set, min, max),
            .uclass => .unicode,
            .capture => |g| b.repeat(g.child, min, max),
            // The parser desugars `C{m,n}`'s optional tail NESTED — `(?:C(?:C…)?)?`,
            // RE2's shape, one ε-path per count — so the flat `C?C?…` chain this
            // peephole was written against now arrives as one quest over a concat.
            .concat => if (min == 0 and max == 1) b.optionalRun(body, null) else .group_repeat,
            else => .group_repeat,
        };
    }

    /// Unroll the nested optional tail back into the flat `C?C?…` run the term
    /// fuser folds into `opt(k)`. Sound only while every level repeats the SAME
    /// class: `(?:A(?:B)?)?` refuses the lone `B` that flat `A?B?` admits, so
    /// anything mixed stays a `group_repeat` decline. Each level is
    /// `concat(class, quest(…))` with a bare `class` innermost — exactly and
    /// only the parser's counted-repetition shape.
    fn optionalRun(b: *Builder, n: *const syn.Node, expect: ?*const syn.ByteSet) ?Decline {
        const node = if (n.* == .capture) n.capture.child else n;
        switch (node.*) {
            .class => |set| {
                if (expect) |e| if (!std.meta.eql(e.*, set)) return .group_repeat;
                return b.term(&set, 0, 1);
            },
            .concat => |kids| {
                const head = if (kids[0].* == .capture) kids[0].capture.child else kids[0];
                if (head.* != .class or kids[1].* != .quest) return .group_repeat;
                const set = head.class;
                if (expect) |e| if (!std.meta.eql(e.*, set)) return .group_repeat;
                if (b.term(&set, 0, 1)) |d| return d;
                return b.optionalRun(kids[1].quest.node, &set);
            },
            else => return .group_repeat,
        }
    }

    /// Emit one term, fusing into the previous instruction when it is the same
    /// class doing the same kind of work.
    fn term(b: *Builder, set: *const syn.ByteSet, min: u8, max: u8) ?Decline {
        if (b.model.grain == .lines and set.has('\n')) return .newline_class;
        const cls = b.intern(set) orelse return .too_complex;
        b.mandatory += min;
        if (max == inf) {
            if (min > 0) if (b.emit(.step, cls, min)) |d| return d;
            // `a*a*` is `a*`, and `a+a*` is `a+a*`'s own star — a second closure
            // over the same class adds nothing.
            if (b.tail()) |t| if (t.op == .star and t.cls == cls) return null;
            return b.emit(.star, cls, 1);
        }
        if (min > 0) if (b.emit(.step, cls, min)) |d| return d;
        if (max > min) return b.emit(.opt, cls, max - min);
        return null;
    }

    fn tail(b: *Builder) ?*Instr {
        if (b.last_cls == null or b.prog.ninstrs == 0) return null;
        return &b.prog.instrs[b.prog.ninstrs - 1];
    }

    fn emit(b: *Builder, op: Op, cls: u8, k: u8) ?Decline {
        // A `star` is idempotent and takes one carry; the counted forms fuse by
        // adding their repetitions, which is where `{n,m}` collapses.
        if ((op == .step or op == .opt)) if (b.tail()) |t| {
            if (t.op == op and t.cls == cls and @as(u32, t.k) + k <= 32) {
                if (@as(usize, b.prog.ncarries) + k > max_carries) return .too_complex;
                t.k += k;
                b.prog.ncarries += k;
                return null;
            }
        };
        if (b.prog.ninstrs == max_terms) return .too_complex;
        const need: usize = switch (op) {
            .star => 1,
            .step, .opt => k,
            .line_start, .word_boundary, .not_word_boundary, .word_start, .word_end, .word_start_half, .word_end_half => 1,
            else => 0,
        };
        if (@as(usize, b.prog.ncarries) + need > max_carries) return .too_complex;
        b.prog.instrs[b.prog.ninstrs] = .{ .op = op, .cls = cls, .k = k, .carry = b.prog.ncarries };
        b.prog.ninstrs += 1;
        b.prog.ncarries += @intCast(need);
        b.last_cls = if (op == .step or op == .opt or op == .star) cls else null;
        return null;
    }

    /// Intern a byte set, compiling its circuit on first sight. Distinct terms
    /// over the same class share one stream, which is most of why a pattern
    /// like `\w+@\w+\.\w+` costs three circuits and not five.
    fn intern(b: *Builder, set: *const syn.ByteSet) ?u8 {
        for (b.prog.sets[0..b.prog.nclasses], 0..) |*s, i| {
            if (std.mem.eql(u64, &s.bits, &set.bits)) return @intCast(i);
        }
        if (b.prog.nclasses == stencil.max_classes) return null;
        const c = stencil.compile(set) orelse return null;
        b.prog.sets[b.prog.nclasses] = set.*;
        b.prog.circuits[b.prog.nclasses] = c;
        b.prog.nclasses += 1;
        return b.prog.nclasses - 1;
    }
};
