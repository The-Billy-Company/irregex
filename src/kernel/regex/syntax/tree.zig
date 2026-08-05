//! gist — what a parsed pattern *is*: the byte class, the AST node, and the
//! compiled NFA instruction, plus the one error set the whole pipeline returns.
//!
//! These four are one file because they are one vocabulary: a `class` node
//! carries a `ByteSet`, a `consume` instruction carries the same `ByteSet`, and
//! `State` is the shape `Node` lowers into. Every stage downstream — analysis,
//! compile, the DFA, the Pike VM — is written against exactly these types and
//! nothing else here. Parse-time machinery (the cursor, escapes, class bodies,
//! scalar accumulation) lives in the sibling files and depends on this one.

const bitsmod = @import("../../math/bits.zig");
const assertion = @import("assertion.zig");

const B64 = bitsmod.Field(u64);
const Word = assertion.Word;

/// The one error set of the whole compile pipeline: a pattern the grammar
/// rejects, or allocation failure. Re-exported by every engine module.
pub const ParseError = error{ BadPattern, OutOfMemory };

/// 256-bit byte class (which bytes a consuming state accepts).
pub const ByteSet = struct {
    bits: [4]u64 = @splat(0),

    pub fn set(self: *ByteSet, b: u8) void {
        B64.set(&self.bits, b);
    }
    /// Inclusive [lo, hi]; a reversed range adds nothing (parser contract).
    pub fn setRange(self: *ByteSet, lo: u8, hi: u8) void {
        if (lo > hi) return;
        B64.setRange(&self.bits, lo, hi); // word-masked: O(words), not O(hi−lo)
    }
    pub fn has(self: *const ByteSet, b: u8) bool {
        return B64.get(&self.bits, b);
    }
    pub fn remove(self: *ByteSet, b: u8) void {
        B64.clear(&self.bits, b);
    }
    pub fn negate(self: *ByteSet) void {
        for (&self.bits) |*w| w.* = ~w.*;
    }
    pub fn unionWith(self: *ByteSet, o: ByteSet) void {
        for (&self.bits, o.bits) |*w, ow| w.* |= ow;
    }
    /// The three class-set operators a bracket body can spell between two
    /// operands - `&&`, `--`, `~~`. Bitwise here for the same reason the union
    /// is: a byte class is already the whole universe in 256 bits.
    pub fn intersectWith(self: *ByteSet, o: ByteSet) void {
        for (&self.bits, o.bits) |*w, ow| w.* &= ow;
    }
    pub fn subtract(self: *ByteSet, o: ByteSet) void {
        for (&self.bits, o.bits) |*w, ow| w.* &= ~ow;
    }
    pub fn symmetricWith(self: *ByteSet, o: ByteSet) void {
        for (&self.bits, o.bits) |*w, ow| w.* ^= ow;
    }
    pub fn count(self: *const ByteSet) usize {
        return B64.count(&self.bits);
    }
    /// The sole member when the set is a singleton (drives the SIMD `memchr`
    /// skip in the regex scanner); null for empty or multi-byte sets.
    pub fn only(self: *const ByteSet) ?u8 {
        if (self.count() != 1) return null;
        return @intCast(B64.first(&self.bits).?);
    }
    /// ASCII case-fold: for every letter present, also admit its opposite-case
    /// twin (`a`⇄`A`). Drives the `-i` flag — applied to every consuming class so
    /// a folded literal byte becomes a 2-member set, which `only` then reports as
    /// non-singleton, so `required`-literal extraction yields "" and the query
    /// soundly falls back to a full scan (trigrams are case-sensitive). Idempotent
    /// — safe to re-apply to a shared (DAG) node.
    pub fn foldCase(self: *ByteSet) void {
        var c: u8 = 'a';
        while (c <= 'z') : (c += 1) {
            const up = c - ('a' - 'A');
            if (self.has(c)) self.set(up);
            if (self.has(up)) self.set(c);
        }
    }
};

/// The regex AST — what recursive descent (`Parser`) produces and every
/// downstream compiler/analysis consumes (`compile.zig`, `captures.zig`,
/// `analysis.zig`). Arena-allocated; nodes are never freed piecewise.
pub const Node = union(enum) {
    empty,
    class: ByteSet, // a single consuming step (literal byte, ., \d, [..])
    // A Unicode codepoint class: a sorted, coalesced list of inclusive scalar
    // ranges (`é`, `\w`, `\p{L}`, `[^a]` in Unicode mode, a fold orbit). Lowers to
    // a compact UTF-8 byte sub-automaton in `compile.zig`/`captures.zig`. An
    // all-ASCII set never becomes a `uclass` — it stays the fast single-byte
    // `class` — so a `uclass` always carries ≥1 non-ASCII (multi-byte) codepoint.
    uclass: []const [2]u21,
    anchor_start, // `^` — zero-width, asserts start of line
    anchor_end, // `$` — zero-width, asserts end of line
    anchor_buf_start, // `\A` under multiline — zero-width, asserts start of BUFFER
    anchor_buf_end, // `\z` under multiline — zero-width, asserts end of BUFFER
    word: Word, // `\b \B \< \>` and the `\b{…}` spellings — zero-width, see `Word`
    concat: [2]*Node,
    alt: [2]*Node,
    // Quantifiers carry a `lazy` flag: greedy (`a*`) prefers to consume, lazy
    // (`a*?`) prefers to stop — this flips only the Thompson `split` PRIORITY, so
    // it changes which leftmost match is chosen (the span), never whether a match
    // exists (boolean/DFA semantics and the reachable-end oracle are laziness-
    // independent). RE2/rust-regex (ripgrep) non-greedy semantics.
    star: Rep,
    plus: Rep,
    quest: Rep,
    // A capturing group `(child)` tagged with its 1-based group index. STRUCTURALLY
    // TRANSPARENT to the match engine (the main compiler + every analysis lower it
    // exactly like its child, so the DFA/Pike boolean semantics are unchanged); the
    // idx is consumed only by the separate capture VM in `captures.zig`, which needs
    // group boundaries for `-r`/`--json`.
    capture: struct { idx: u32, child: *Node },

    /// A quantified sub-expression: the repeated `node` plus greedy/lazy priority.
    pub const Rep = struct { node: *Node, lazy: bool = false };
};

/// A `(?P<name>…)` / `(?<name>…)` group's name paired with its 1-based index —
/// recorded only when the parser is given a `names` sink (the capture VM), so the
/// hot main-engine parse allocates nothing extra.
pub const NamedCap = struct { name: []const u8, idx: u32 };

/// A compiled Thompson-NFA instruction (the flat program `../linear/program/lower.zig`
/// emits and both the Pike VM and the lazy DFA execute). Lives here, beside the
/// AST it lowers from, so `../linear/dfa/` can determinize over it without an
/// import cycle through the engine.
pub const State = union(enum) {
    consume: struct { set: ByteSet, out: u32 },
    split: struct { a: u32, b: u32 },
    assert_start: u32, // zero-width `^`: pass to `out` only at line start
    assert_end: u32, // zero-width `$`: pass to `out` only at line end
    // Every word assertion, as one state: `mask` says which (word_before,
    // word_after) pairs pass to `out`. One case for an engine to evaluate
    // instead of one per spelling — see `Word`.
    assert_word: struct { mask: Word, out: u32 },
    assert_buf_start: u32, // zero-width `\A` (multiline): pass only at buffer start
    assert_buf_end: u32, // zero-width `\z` (multiline): pass only at buffer end
    match,
};
