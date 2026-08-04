//! irregex — the byte tier: finding candidates without an automaton.
//!
//! The door to this package, and the reason it needs one. Everything here
//! answers the same question at a different literal count — *does this buffer
//! plausibly contain one of these, and where* — and the whole tier's value is
//! that a caller does not have to know which kernel answers it. One needle goes
//! to the rare-byte-pair `memmem`; a handful to Teddy at two loads a block; a
//! large set to sparse Aho–Corasick; a dense character class to the class-run
//! scan. `literals.LiteralSet` is the dispatcher over that whole range, and the
//! reason it is the name most callers want.
//!
//! Its results carry an `Authority`, which is the tier's real contract: an
//! `.exact` answer decides presence and position outright, a `.candidate`
//! answer only nominates and must be verified. That two-valued return is what
//! lets a prefilter be as aggressive as it likes without ever being wrong.
//!
//! Four of these were reachable from the package root and six were not, which
//! is a strange way to ship an Aho–Corasick and a Teddy. This file is the
//! grouping the root re-exports as one name, so the tier is entered the way it
//! is described in the README rather than as a partial list of its files.
//!
//! **These are prefilters, not matchers.** A literal hit is not a regex match:
//! the pattern that motivated the literal still has to run. The one exception is
//! an `.exact` set, which by construction has nothing left to prove.

/// The rare-byte-pair SIMD substring kernel — one needle, block-filtered on the
/// conjunction of two probes, and the primitive the whole tier bottoms out in.
pub const simd = @import("simd.zig");

/// Teddy: up to 64 needles at two vector loads per block (Hyperscan's
/// algorithm, as in ripgrep's `aho-corasick`).
pub const teddy = @import("teddy.zig");

/// Sparse Aho–Corasick, for literal sets past what Teddy will hold.
pub const aho = @import("aho.zig");

/// The dispatcher across that whole range, and the type that carries
/// `Authority` — start here unless you know which kernel you want.
pub const literals = @import("literal_set.zig");
pub const LiteralSet = literals.LiteralSet;
pub const Authority = literals.Authority;

/// The dense character-class boolean scan — a class run is not a literal, but
/// it is the same question asked of a set of bytes instead of a sequence.
pub const classrun = @import("classrun.zig");
pub const ClassRun = classrun.ClassRun;

/// Which two needle offsets the block filter should compare: the shipped
/// decision, from corpus-derived byte density.
pub const anchor = @import("anchor.zig");

/// The same decision re-priced on the buffer actually in hand — an improvement
/// test over `anchor`, never an override (adopting the sample's favorite
/// unconditionally measured as a CPU tax).
pub const calibrate = @import("calibrate.zig");

/// The corpus-derived byte density table both decisions read.
pub const rarity = @import("rarity.zig");

/// The lane algebra the shuffle rung and this tier share: a transformation as a
/// vector, composition as one shuffle.
pub const lanes = @import("lanes.zig");

/// Data-parallel candidate verification — what runs after a `.candidate`.
pub const verify = @import("verify.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
