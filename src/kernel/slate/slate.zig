//! irregex — the slate: many patterns in one walk, with exact attribution.
//!
//! The door to this package. A `Regex` answers a question about one pattern; a
//! slate answers it about N of them in a single pass over the bytes, and keeps
//! which pattern found what. That last clause is the whole point — a pipeline
//! of N single-pattern searches produces the same rows, at N times the byte
//! cost, and a naive union of N patterns produces the rows in one pass while
//! throwing the attribution away.
//!
//! Three files, one dispatch, one shaping:
//!
//!  - `PatternSet` compiles the slate and owns the answer. It is what a caller
//!    names.
//!  - The `muster` dragnet and the `trawl` automaton are the two engines under
//!    it, chosen on slate width — a bucketed SIMD sieve while the buckets stay
//!    sparse, an Aho–Corasick automaton once they cannot. Per-byte cost
//!    therefore stops growing with N, which is the property the tier exists
//!    for. Neither is named by callers; `<prefix>MUSTER_TIER` forces one for
//!    measurement.
//!  - `loom` executes a closed filter / group / sort / limit plan over the
//!    attributed rows, engine-side. Every consumer that lacks it re-implements
//!    it downstream over rendered text, which is both slower and a second
//!    opinion about what a row is.
//!
//! The two *ordered* faces of a slate — `Chorus` (which patterns occur
//! anywhere) and `Munch` (which reaches furthest from exactly here) — live in
//! the regex engine, because they are automaton constructions rather than
//! walk strategies. They are hoisted to the package root beside `Regex`.

/// The compiled slate and its attributed answer.
pub const patterns = @import("patterns.zig");
pub const PatternSet = patterns.PatternSet;

/// The closed filter / group / sort / limit plan over attributed rows.
pub const loom = @import("loom.zig");

/// The dragnet: a bucketed SIMD sieve, the narrow-slate engine.
pub const muster = @import("muster.zig");

/// The trawl: one Aho–Corasick automaton, the wide-slate engine.
pub const trawl = @import("trawl.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
