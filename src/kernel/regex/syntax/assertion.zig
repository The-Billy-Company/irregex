//! irregex — the word-assertion family, as the truth table it actually is.
//!
//! Three declarations, no dependencies: `Word` names the six spellings a pattern
//! can write, `mask` is the algebra over the raw 4-bit masks an engine reaches by
//! intersecting them, and `Sides` is what a gap position looks like when one is
//! evaluated. Nothing here knows about a byte class, the AST, or the parser — it
//! is pure predicate, which is why every engine arm can share it.

/// Which word assertion — as the truth table it actually is.
///
/// Every spelling in this family (`\b \B \< \>` and rust-regex's `\b{start}`,
/// `\b{end}`, `\b{start-half}`, `\b{end-half}`) asks one question about two
/// booleans: is the byte behind this position a word byte, and is the byte ahead
/// one? Four inputs, so an assertion IS a 4-bit mask — bit `(before << 1) | after`
/// set means that pair satisfies it. Nothing else distinguishes them.
///
/// Naming the family this way is what keeps a new spelling cheap. rust-regex
/// carries twelve `Look` variants for these (six × ASCII/Unicode) and every
/// engine that walks a program switches on all twelve; here a program carries one
/// state, each engine evaluates one predicate, and adding a spelling is a line in
/// the parser. `admits` is the whole contract.
pub const Word = enum(u4) {
    boundary = 0b0110, // `\b` — the two sides differ
    not_boundary = 0b1001, // `\B` — the two sides agree
    start = 0b0010, // `\<`, `\b{start}` — a word begins here
    end = 0b0100, // `\>`, `\b{end}` — a word ends here
    start_half = 0b0011, // `\b{start-half}` — nothing wordy behind, ahead unconstrained
    end_half = 0b0101, // `\b{end-half}` — nothing wordy ahead, behind unconstrained

    /// Does this assertion hold at a position whose neighbors are as given?
    /// A haystack edge counts as a non-word side, which is what makes
    /// `\b{start-half}` true at offset 0 and `\b{end-half}` true at the end —
    /// callers pass `false` there, as they already do for `\b`.
    pub fn admits(self: Word, before: bool, after: bool) bool {
        return mask.admits(@intFromEnum(self), before, after);
    }

    /// Does this assertion hold at a position that looks like `s`? The engine
    /// entry point — `admits` is only the truth table. See `mask.holds`.
    pub fn holds(self: Word, s: Sides) bool {
        return mask.holds(@intFromEnum(self), s);
    }
};

/// What a gap position looks like to a word assertion: how wordy each side is,
/// and whether each side is a whole character at all.
///
/// The second pair exists because the first cannot carry it. "Is the character
/// before me a word character?" answers *false* both for a comma and for a gap
/// standing between the two bytes of `é` — one is silence, the other is the
/// middle of a word. Under `(?-u)` every byte is its own character and the
/// question cannot arise, so both flags stay true.
pub const Sides = struct {
    before: bool,
    after: bool,
    left_ok: bool = true,
    right_ok: bool = true,
};

/// The word-assertion algebra, over a raw mask.
///
/// `Word` names the six masks a pattern can write; an engine that *intersects*
/// two of them lands elsewhere. The one-pass builder flattens a whole ε-path
/// into a single guard, so `\b\<` becomes `0b0010` and `\B\<` becomes the empty
/// mask — a contradiction it can see at build time, where a bit per spelling
/// could only rediscover it once per byte. Those masks name no spelling, so the
/// rules live here and `Word` delegates.
pub const mask = struct {
    /// The mask of a path with no word assertion on it: every pair still admitted.
    pub const free: u4 = 0b1111;

    /// The truth table. Bit `(before << 1) | after` is set when that pair passes.
    pub fn admits(m: u4, before: bool, after: bool) bool {
        const pair = (@as(u2, @intFromBool(before)) << 1) | @intFromBool(after);
        return (m >> pair) & 1 != 0;
    }

    /// The truth table, plus the one thing two booleans cannot say.
    ///
    /// An assertion that can fire on silence must also insist the silence is
    /// real, or it fires in the middle of a character and reports a match
    /// boundary that splits it — `\B` matching between the two bytes of `é`.
    /// Those are exactly the masks admitting the all-quiet pair, which is
    /// exactly the masks with bit 0 set: `\B` and the two halves. The others
    /// need no guard and pay for none, because firing requires a word character
    /// on some side and a word character is a whole one. The guard applies only
    /// to the sides the mask reads, so `\b{start-half}` looks left and does not
    /// care that a character to its right is unfinished.
    pub fn holds(m: u4, s: Sides) bool {
        if (!admits(m, s.before, s.after)) return false;
        if (m & 1 == 0) return true;
        return (s.left_ok or !readsBefore(m)) and (s.right_ok or !readsAfter(m));
    }

    /// Does the answer depend on the side at all? Read off the mask rather than
    /// listed per spelling: `before` matters exactly when the table's two halves
    /// disagree, and `after` exactly when its two interleaved halves do.
    pub fn readsBefore(m: u4) bool {
        return (m & 0b0011) != (m >> 2);
    }
    pub fn readsAfter(m: u4) bool {
        return (m & 0b0101) != ((m & 0b1010) >> 1);
    }
};
