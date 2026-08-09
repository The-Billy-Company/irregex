//! gist — the predicate alphabet: this engine's reading of the minterm
//! partition, plus the one adapter that reads a byte class as a scalar set.
//!
//! A codepoint class (`\w`, `\p{L}`, `.`, `é`) is a predicate over Unicode
//! scalars. The byte engine answers "does this class hold?" by walking a UTF-8
//! trie — hundreds of NFA states per occurrence, re-walked by every closure the
//! determinizer runs. Symbolically the same question needs no automaton at all:
//! partition the scalar space into the coarsest blocks no predicate splits (its
//! **minterms**), and every class becomes a bitmask over a handful of symbols.
//! `\w+X` has three: `{X}`, `\w∖{X}`, and everything else.
//!
//! **The partition itself is not regex knowledge**, so it does not live here. It
//! is one boundary sweep over interval sets, and it sits on the math floor as
//! `math/minterm.zig` where a consumer that is not this engine — a lexer
//! generator, say — can reach it without reaching through `regex.zig` for a
//! grammar it does not want. What is regex-specific is exactly the three lines
//! below: which scalar type, where the space ends, how many predicates before a
//! pattern is pathological — and the `ByteSet` adapter, which is the one place
//! the alphabet has to know what this package's AST calls a character class.

const std = @import("std");
const minterm = @import("../../../math/minterm.zig");
const syn = @import("../../syntax/syntax.zig");

/// Largest Unicode scalar value, and the top of the partitioned space.
/// Surrogates are *inside* it: `utf8seq` drops them when the decoder is lowered,
/// which is exactly how the byte engine treats them (no well-formed encoding ⇒
/// unmatchable). Stopping the space here rather than at `maxInt(u21)` is what
/// keeps the decoder from being handed a block of unencodable scalars to lower.
pub const max_scalar: u21 = 0x10FFFF;

/// Ceiling on distinct predicates. Every consuming AST leaf contributes one
/// (deduplicated by content, so `\w{3,8}`'s eight copies are a single
/// predicate). Past this the signature bitset stops being cheap and the pattern
/// is pathological; the caller falls back to the byte path.
pub const max_predicates: u16 = 512;

const Scalars = minterm.Space(u21, max_scalar, max_predicates);

/// An inclusive scalar range `[lo, hi]` — the same shape `Node.uclass` carries.
pub const Range = Scalars.Range;

/// The finished alphabet: a partition of `[0, max_scalar]` into minterms, plus
/// which minterms each predicate accepts. `contains(pred, mint)` is the whole
/// interface the determinizer needs — a pattern transition is then a bitmask
/// test, never a byte walk.
pub const Alphabet = Scalars.Partition;

/// Accumulates the pattern's distinct predicates and hands out the slot each one
/// occupies in every minterm's label. One instance per compile.
pub const Builder = Scalars.Builder;

/// File-private control flow in the tiers above (the fault-channel taxonomy):
/// converted to `.declined` at the symbolic module boundary — not declared
/// fault-taxonomy members.
pub const Error = minterm.Error;

/// Intern an ASCII `ByteSet` (a `class` node) as a scalar predicate. Callers
/// guarantee no member is ≥ 0x80 — a high byte is not a codepoint and the
/// symbolic path declines such programs up front.
///
/// A free function rather than a method so `Builder` can stay the floor's type
/// unwrapped; the run buffer is a stack array because alternating members of
/// `0..0x7F` is 64 runs and no more.
pub fn internByteSet(
    b: *Builder,
    set: *const syn.ByteSet,
) (Error || std.mem.Allocator.Error)!u16 {
    var runs: [64]Range = undefined;
    var n: usize = 0;
    var i: u16 = 0;
    while (i <= 0x7F) {
        if (!set.has(@intCast(i))) {
            i += 1;
            continue;
        }
        const lo = i;
        while (i <= 0x7F and set.has(@intCast(i))) i += 1;
        runs[n] = .{ @intCast(lo), @intCast(i - 1) };
        n += 1;
    }
    return b.intern(runs[0..n]);
}
