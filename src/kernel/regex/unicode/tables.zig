//! gist — the Unicode data API over the generated `tables.gen.zig`. Everything
//! the parser, class compiler, and word-boundary engine need to be Unicode-aware
//! lives behind this small surface: the Perl class ranges (`word`/`digit`/
//! `space`), `\p{...}` property lookup by name, simple case-fold orbit expansion,
//! and the codepoint word-ness test. The generated module is an implementation
//! detail — callers depend only on these functions.

const std = @import("std");
const gen = @import("tables.gen.zig");

pub const Range = gen.Range;
pub const version = gen.unicode_version;

pub const word = gen.word;
pub const digit = gen.digit;
pub const space = gen.space;

/// Whole valid scalar space minus the surrogate gap — the universe a negated
/// class (`\P{…}`, `[^…]` in Unicode mode) complements against.
pub const all: []const Range = &.{ .{ 0x0, 0xD7FF }, .{ 0xE000, 0x10FFFF } };

/// Membership test over a sorted, coalesced range table (binary search).
pub fn inRanges(ranges: []const Range, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < ranges[mid][0]) {
            hi = mid;
        } else if (cp > ranges[mid][1]) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

/// Is `cp` a Unicode word codepoint? ASCII fast path, then the `word` table.
/// The single predicate behind Unicode `\b`/`\B`/`\<`/`\>`, `-w`, and `\w`.
pub fn isWord(cp: u21) bool {
    if (cp < 0x80) return (cp >= '0' and cp <= '9') or (cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z') or cp == '_';
    return inRanges(word, cp);
}

/// Is `cp` an uppercase or titlecase letter (general category Lu/Lt)? The
/// codepoint-aware predicate behind smart-case (`-S`): any uppercase in the
/// pattern disables the automatic case fold, exactly rg's Unicode default.
pub fn isUpper(cp: u21) bool {
    if (cp < 0x80) return cp >= 'A' and cp <= 'Z';
    if (property("Lu")) |lu| if (inRanges(lu, cp)) return true;
    if (property("Lt")) |lt| if (inRanges(lt, cp)) return true;
    return false;
}

/// The simple case-fold orbit of `cp` — the OTHER codepoints case-equivalent to
/// it (empty when `cp` folds only to itself). Binary search over `fold_entries`.
pub fn foldOrbit(cp: u21) []const u21 {
    var lo: usize = 0;
    var hi: usize = gen.fold_entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const e = gen.fold_entries[mid];
        if (cp < e.cp) {
            hi = mid;
        } else if (cp > e.cp) {
            lo = mid + 1;
        } else return gen.fold_members[e.off .. e.off + e.len];
    }
    return &.{};
}

/// Append the simple case-fold orbit members of every codepoint contained in
/// `ranges` to `out` (the fold expansion for `-i`/smart-case). Cheap: one pass
/// over the ~3k fold entries, binary-searching each against the (small) class.
pub fn foldMembers(ranges: []const Range, gpa: std.mem.Allocator, out: *std.ArrayList(u21)) !void {
    for (gen.fold_entries) |e| {
        if (inRanges(ranges, e.cp)) {
            try out.appendSlice(gpa, gen.fold_members[e.off .. e.off + e.len]);
        }
    }
}

/// Case-insensitive, separator-insensitive comparison (Unicode property names
/// are matched loosely: `\p{Canadian_Aboriginal}` ≡ `canadianaboriginal`).
fn looseEql(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and isSep(a[i])) i += 1;
        while (j < b.len and isSep(b[j])) j += 1;
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[j])) return false;
        i += 1;
        j += 1;
    }
}
fn isSep(c: u8) bool {
    return c == '_' or c == '-' or c == ' ';
}

/// Resolve a `\p{NAME}` body to its scalar ranges, or null if unknown. Accepts a
/// bare property/script name and the `gc=`/`sc=`/`script=`/`general_category=`
/// key forms, plus `Any`. Case- and separator-insensitive.
pub fn property(name_in: []const u8) ?[]const Range {
    var name = std.mem.trim(u8, name_in, " \t");
    if (std.mem.indexOfScalar(u8, name, '=')) |eq| {
        const key = std.mem.trim(u8, name[0..eq], " \t");
        // A key we recognize is stripped; an unknown key means an unsupported
        // property form (fail closed → null).
        if (!(looseEql(key, "gc") or looseEql(key, "generalcategory") or looseEql(key, "sc") or looseEql(key, "script"))) return null;
        name = std.mem.trim(u8, name[eq + 1 ..], " \t");
    }
    if (looseEql(name, "any")) return all;
    for (gen.properties) |p| if (looseEql(p.name, name)) return p.ranges;
    return null;
}

// ─────────────────────────────── tests ───────────────────────────────

const testing = std.testing;

test "word/digit/space membership matches expectations" {
    try testing.expect(isWord('a'));
    try testing.expect(isWord('_'));
    try testing.expect(isWord(0x00E9)); // é
    try testing.expect(isWord(0x4E2D)); // 中
    try testing.expect(!isWord(' '));
    try testing.expect(!isWord('!'));
    try testing.expect(inRanges(digit, '7'));
    try testing.expect(inRanges(digit, 0x0660)); // ARABIC-INDIC DIGIT ZERO
    try testing.expect(!inRanges(digit, 'a'));
    try testing.expect(inRanges(space, ' '));
    try testing.expect(inRanges(space, 0x00A0)); // NBSP
    try testing.expect(!inRanges(space, 'x'));
}

test "case-fold orbits are symmetric and complete" {
    // K, k, KELVIN SIGN all fold together.
    const k = foldOrbit('K');
    try testing.expect(std.mem.indexOfScalar(u21, k, 'k') != null);
    try testing.expect(std.mem.indexOfScalar(u21, k, 0x212A) != null);
    // é ⇄ É
    try testing.expect(std.mem.indexOfScalar(u21, foldOrbit(0x00E9), 0x00C9) != null);
    try testing.expect(std.mem.indexOfScalar(u21, foldOrbit(0x00C9), 0x00E9) != null);
    // A digit folds to nothing.
    try testing.expectEqual(@as(usize, 0), foldOrbit('7').len);
}

test "property lookup: gc coarse/fine, scripts, keys, Any" {
    try testing.expect(property("L") != null);
    try testing.expect(property("Lu") != null);
    try testing.expect(property("Letter") == null or property("L") != null); // long gc names optional
    try testing.expect(inRanges(property("L").?, 'a'));
    try testing.expect(inRanges(property("Lu").?, 'A'));
    try testing.expect(!inRanges(property("Lu").?, 'a'));
    try testing.expect(inRanges(property("Greek").?, 0x03B1)); // α
    try testing.expect(inRanges(property("gc=Nd").?, '5'));
    try testing.expect(inRanges(property("Script=Cyrillic").?, 0x0410)); // А (Cyrillic)
    try testing.expect(inRanges(property("any").?, 0x1F600));
    try testing.expect(property("NotARealProperty") == null);
}

test "property lookup: the identifier properties every language grammar spells" {
    // `[_\p{XID_Start}][_\p{XID_Continue}]*` is verbatim how tree-sitter-go
    // writes `identifier`, and Java, C, Rust, and JavaScript differ only in
    // which sigils they add. Without these, the most common terminal in every
    // language is the one a lexer cannot compile.
    for ([_][]const u8{ "XID_Start", "XID_Continue", "ID_Start", "ID_Continue" }) |name| {
        const p = property(name) orelse return error.MissingProperty;
        try testing.expect(inRanges(p, 'a'));
        try testing.expect(inRanges(p, 0x00E9)); // é
        try testing.expect(!inRanges(p, ' '));
        try testing.expect(!inRanges(p, '-'));
    }
    // Start excludes what only Continue admits: a digit, and the combining
    // marks that may follow a letter but never open an identifier.
    try testing.expect(!inRanges(property("XID_Start").?, '7'));
    try testing.expect(inRanges(property("XID_Continue").?, '7'));
    try testing.expect(inRanges(property("XID_Continue").?, 0x0300)); // COMBINING GRAVE
    try testing.expect(!inRanges(property("XID_Start").?, 0x0300));
    // Loose matching (UAX#44-LM3) is the runtime's rule, so the spellings a
    // grammar author might reach for all land on the same table.
    try testing.expectEqual(property("XID_Start").?.ptr, property("xid start").?.ptr);
    try testing.expectEqual(property("XID_Start").?.ptr, property("xidstart").?.ptr);

    // The rest of the binary properties came along generically, not from a
    // list — so this holds without anyone having named them.
    try testing.expect(inRanges(property("Alphabetic").?, 'a'));
    try testing.expect(inRanges(property("White_Space").?, ' '));
    try testing.expect(inRanges(property("Uppercase").?, 'A'));
    try testing.expect(!inRanges(property("Uppercase").?, 'a'));
    try testing.expect(inRanges(property("Dash").?, '-'));
    // A multi-valued property is a property VALUE, not a binary class, and must
    // not have been folded into one under its own name.
    try testing.expect(property("InCB") == null);
}

/// Every consumer (`inRanges`, `foldOrbit`, `property`) binary-searches these
/// tables, so sortedness + non-overlap is a correctness PRECONDITION, not a nicety.
/// This test is the drift tripwire: a regenerated `tables.gen.zig` that emits an
/// unsorted, overlapping, or empty range — or an asymmetric fold orbit — silently
/// breaks lookups, and this fails closed before it can ship. (Complements the
/// regenerate-and-diff `gen-gist-unicode-verify` byte gate: that proves the file
/// matches the generator; this proves the shape the searches rely on.)
fn assertSortedRanges(ranges: []const Range) !void {
    for (ranges, 0..) |r, i| {
        try testing.expect(r[0] <= r[1]); // well-formed
        try testing.expect(r[1] <= 0x10FFFF); // in scalar space
        // Sorted AND strictly gapped: an adjacent/overlapping pair (lo ≤ prev_hi+1)
        // should have been coalesced by the generator — its presence is drift.
        if (i > 0) try testing.expect(ranges[i - 1][1] + 1 < r[0]);
    }
}

test "unicode tables: sorted, coalesced, and fold orbits symmetric (drift tripwire)" {
    try testing.expect(version.len > 0);
    try assertSortedRanges(word);
    try assertSortedRanges(digit);
    try assertSortedRanges(space);
    for (gen.properties) |p| {
        try testing.expect(p.name.len > 0);
        try assertSortedRanges(p.ranges);
    }
    // fold_entries sorted by cp (binary search); every orbit member is symmetric —
    // if `m` is in `foldOrbit(cp)`, then `cp` is in `foldOrbit(m)` (never self).
    var prev: u21 = 0;
    for (gen.fold_entries, 0..) |e, i| {
        if (i > 0) try testing.expect(e.cp > prev);
        prev = e.cp;
        const orbit = gen.fold_members[e.off .. e.off + e.len];
        try testing.expect(orbit.len > 0);
        for (orbit) |m| {
            try testing.expect(m != e.cp);
            try testing.expect(std.mem.indexOfScalar(u21, foldOrbit(m), e.cp) != null);
        }
    }
}
