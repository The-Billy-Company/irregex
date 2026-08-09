//! irregex — the product-free floor: arithmetic and structure with no opinion.
//!
//! The door to this package, and the tier with the least to do with regular
//! expressions. Nothing here knows what a pattern is, what a corpus is, or that
//! a search exists. That is the membership rule: a file belongs here when it
//! would be just as correct inside somebody else's program, and it stops
//! belonging the moment it needs to know why it was called.
//!
//! Which is also why it is worth naming at the root. Half of these are things a
//! reader would otherwise write for themselves — a gitignore-shaped glob
//! matcher, union-find, a did-you-mean, a hash-consed DAG — and the versions
//! here are the ones this package's own hot paths are held to.
//!
//! The succinct sublayer (`sais`, `rrr`, `wavelet`) sits under `succinct/`
//! because those three compose into one structure rather than standing apart,
//! and the FM-index that composes them is a tier of its own (`kernel/codex/`).

/// Two's-complement identities: set-bit walks, word-packed bit sets, the
/// operations the mask tiers ride instead of hand-rolling.
pub const bits = @import("bits.zig");

/// The gitignore/rg-shaped glob matcher — pure pattern-vs-string math, with the
/// `*` / `**` / class / segment rules ripgrep's precedence depends on.
pub const glob = @import("glob.zig");
pub const globMatch = glob.globMatch;

/// Damerau–Levenshtein and the did-you-mean over it: how a misread
/// configuration key finds its nearest intended spelling.
pub const misread = @import("misread.zig");

/// Disjoint-set forest — union-find with path-halving finds and min-index
/// representatives, so a canonical member is deterministic.
pub const forest = @import("forest.zig");

/// Hash mixing — the bit-spreading floor under sketches and hash-table keys.
/// Deliberately not the artifact digest, which is `frame/signet.zig`.
pub const mix = @import("mix.zig");

/// Byte-balanced shard bounds and partial-spawn-safe fan-out: the sharding
/// geometry every parallel lane in the package divides work by. Exposed because
/// a harness that re-derived it would be measuring a different division than
/// the one that ships.
pub const parallel = @import("parallel.zig");

/// Reader/writer leases and the double-checked read-mostly reconcile dance the
/// warm session rides instead of hand-rolling lock/unlock pairs.
pub const lease = @import("lease.zig");

/// The hash-consed DAG a tree-shaped IR folds into, so a repeated subtree is
/// one node and every question about it is asked once. Generic over its payload
/// and arity — the regex AST is one instantiation, not the only possible one.
pub const dag = @import("dag.zig");
pub const Dag = dag.Dag;

/// The crest sieve calculus: the forced-class-run necessary condition that
/// prunes files a literal-free pattern cannot match (`research/crest/PROOF.md`).
pub const crest = @import("crest.zig");

/// The four questions one algorithm can answer when you swap its arithmetic:
/// is there a path, what is the cheapest, which is likeliest, how many.
pub const semiring = @import("semiring.zig");

/// The coarsest partition a transition table cannot tell apart — DFA
/// minimization, an LR table's action-bisimulation, and behaviour classes, which
/// are one algorithm over three readings of what a state's colour means. Moore
/// and Hopcroft both, because each is the other's oracle.
pub const refine = @import("refine.zig");

/// A set of strings as the smallest automaton accepting it — prefixes *and*
/// suffixes shared, and a minimal perfect hash onto `0..count` falling out of the
/// same walk that answers membership, so payloads index an array instead of
/// storing their keys a second time.
pub const dafsa = @import("dafsa.zig");

/// The coarsest partition of a scalar line a family of sets cannot tell apart —
/// character classes, token predicates, guard conditions — so a consumer that
/// asked the family `n` questions per input asks the partition one. One boundary
/// sweep, not the textbook `O(2^n)` of pairwise intersection.
pub const minterm = @import("minterm.zig");

/// SA-IS suffix array construction, RRR bit vectors, the Huffman-shaped wavelet
/// tree — the three structures the FM-index composes — and balanced
/// parentheses, which is the ordinal tree those structures don't cover.
pub const succinct = struct {
    pub const sais = @import("succinct/sais.zig");
    pub const rrr = @import("succinct/rrr.zig");
    pub const wavelet = @import("succinct/wavelet.zig");
    pub const parens = @import("succinct/parens.zig");
};

test {
    @import("std").testing.refAllDecls(@This());
}
