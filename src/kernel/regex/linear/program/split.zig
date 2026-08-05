const syn = @import("../../syntax/syntax.zig");
const compile = @import("../../compile/compile.zig");

/// A balanced ε-split tree over `entries`, returning its root.
///
/// Balanced buys DEPTH, not work. A union over N branches is N-1 split states in
/// any shape, and `subset.close` pushes both children of every split it pops, so
/// one closure visits all N-1 whichever way they are stacked — a right-leaning
/// chain (rust-`regex`'s `c_alt_iter`) costs the determinizer exactly the same.
/// What balance bounds is this function's own recursion and the closure's stack
/// depth, at `log2 N` rather than `N`.
///
/// It used to be worth more than that: this tree sits directly behind the NFA
/// start, so an unanchored determinization that re-seeds the start on every
/// transition re-walked the whole union once per (state x class).
/// `subset.Subset.seeds` hoists that walk out of the loop — the tree is now
/// closed eight times in total, once per distinguishable gap — which is where
/// the 1.3-2.3x in `bench/rungs/patternid` came from and why the shape of this
/// tree is no longer measurable at all.
pub fn tree(c: *compile.Compiler, entries: []const u32) syn.ParseError!u32 {
    if (entries.len == 1) return entries[0];
    const mid = entries.len / 2;
    return c.push(.{ .split = .{
        .a = try tree(c, entries[0..mid]),
        .b = try tree(c, entries[mid..]),
    } });
}
