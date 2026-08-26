//! irregex — the symbolic (predicate-alphabet) determinizer, entered here.
//!
//! The shipped path lowers a Unicode class to a UTF-8 byte trie and then
//! determinizes over bytes, so every epsilon-closure re-walks that trie: `\w+X`
//! costs 8.4 million NFA-state visits to discover a 332-state automaton, and
//! the eager driver's cost budget declines it to the on-demand tier. Nothing
//! about that work is inherent — it is the price of asking a *byte* automaton
//! what a *codepoint* class means, over and over.
//!
//! So this path asks once. `alphabet.zig` partitions the scalar space into the
//! minterms the pattern's own classes induce; `program.zig` lowers the AST with
//! each class as ONE instruction over that alphabet; `determinize.zig` runs the
//! same subset construction there, where a `\w` step is a bitmask test;
//! `transcribe.zig` crosses the result with a UTF-8 → minterm decoder built once
//! for the whole alphabet, and the reachable pairs are the byte `Dfa` the ladder
//! already runs. The scan loop is untouched — same table shape, same
//! premultiplied `trans[s + class[b]]`, same `match`.
//!
//! It is a cost path, never a semantic one. Anything it cannot express exactly
//! — word boundaries, buffer anchors, a raw high-byte class, an alphabet or
//! product past its ceiling — declines, and `../program/lower.zig` falls
//! straight back to `dfa/powerset.zig`. The Pike VM remains the oracle for both.

const std = @import("std");
const syn = @import("../../syntax/syntax.zig");
const Dfa = @import("../dfa/dfa.zig").Dfa;
const alphabet = @import("alphabet.zig");
const program = @import("program.zig");
const determinize = @import("determinize.zig");
const transcribe = @import("transcribe.zig");

pub const Stats = transcribe.Stats;

/// The three phases, named so a price rung can time them apart. `build` below is
/// how production enters and will stay that way; these exist because "the
/// symbolic road costs 40 µs" is not a fact anyone can act on — the minterm
/// lowering, the codepoint subset construction and the decoder crossing have
/// different scaling laws, and a harness that timed only the sum could not tell
/// which one a change moved.
///
/// Three, not four: the alphabet partition is not a phase, it is what
/// `program.lower` does on its way through — predicates intern as instructions
/// emit, and `Builder.finish` solves the partition at the end. There is no seam
/// to time, and a harness that manufactured one would be pricing its own copy.
/// The crossing's own two sub-steps get names too, because "the crossing costs
/// 2.3 ms" turned out to be the whole compile's answer and it needed splitting
/// once more: the decoder is built per alphabet, the horizon per decoder, and the
/// product walk after both.
pub const phase = struct {
    pub const program_mod = program;
    pub const determinize_mod = determinize;
    pub const transcribe_mod = transcribe;
    pub const decoder_mod = @import("decoder.zig");
    pub const horizon_mod = @import("horizon.zig");
};

/// Why the symbolic path produced no automaton. Purely advisory — every value
/// means "the byte path decides this pattern", which is also the status quo.
pub const Decline = enum {
    /// A construct the codepoint alphabet cannot express exactly: `\b`/`\B`/
    /// `\<`/`\>`, `\A`/`\z`, or a `class` carrying a byte ≥ 0x80.
    unsupported,
    /// The alphabet, the codepoint automaton, the decoder or the product
    /// crossed its ceiling.
    too_large,
};

pub const Outcome = union(enum) { built: *Dfa, declined: Decline };

/// Should this pattern even be offered to the symbolic path? Only a `uclass`
/// pays the trie tax; an all-ASCII program's byte determinization is already
/// the cheapest thing in the engine, and routing it here would swap a
/// known-optimal construction for a merely equal one.
pub fn eligible(ast: *const syn.Node) bool {
    return program.hasCodepointClass(ast);
}

/// Determinize `ast` symbolically and transcribe the result into a byte DFA.
/// `anchored` mirrors `analysis.startsAnchored`, exactly as `powerset.build`
/// reads it. Only allocation failure escapes; every other refusal is a
/// `.declined`, because declining is a cost decision with no semantic content.
pub fn build(gpa: std.mem.Allocator, ast: *syn.Node, anchored: bool, stats: *Stats) std.mem.Allocator.Error!Outcome {
    var prog = program.lower(gpa, ast) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Oversized => .{ .declined = .too_large },
        else => .{ .declined = .unsupported },
    };
    defer prog.deinit();

    var aut = determinize.build(gpa, &prog, anchored) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooLarge => .{ .declined = .too_large },
    };
    defer aut.deinit();
    stats.visits = aut.visits;

    const dfa = transcribe.transcribe(gpa, &aut, &prog.alpha, anchored, stats) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        // `Malformed` is a partition invariant the decoder could not confirm —
        // never a claim about the pattern, so it declines like any budget miss.
        error.TooLarge, error.Malformed => .{ .declined = .too_large },
    };
    return .{ .built = dfa };
}
