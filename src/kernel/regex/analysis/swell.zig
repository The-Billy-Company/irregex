//! gist — the FORCED-CREST calculus: the query half of the Crest sieve
//! (`../../math/crest.zig`; research/crest/PROOF.md §3).
//!
//! A document carries a *crest* — the longest run of consecutive bytes in each
//! of k byte classes, ρ(d). A pattern forces a *swell*: the crests it will
//! accept nothing below, ĝ(R) ≤ min_{w∈L(R)} ρ(w). `Profile` folds that lower
//! bound out of the AST with a min-of-max prefix/suffix/best algebra, and
//! `forcedSwell` emits ONE per top-level alternative — a disjunction, because a
//! match satisfies one branch, not all of them. The sieve prunes d only when
//! every alternative falls short: k integer compares each, no byte scan,
//! provably no false negatives (Sieve Theorem §2, disjunctive form §3.9).
//!
//! IT READS THE ENGINE'S OWN AST (`../syntax/syntax.zig`) — the same tree
//! `linear/program/lower.zig` compiles to the Thompson program, produced by the
//! same parser under the same options. That is the soundness architecture, not
//! a convenience. A second grammar that accepts one construct with a different
//! meaning is a silent false-negative factory, and this calculus shipped with
//! exactly that hole: its private parser read `\<` as an escaped literal `<`,
//! forcing a punct run that a matching document (`\<foo\>` ⊨ "foo") need not
//! contain, so the sieve elided real hits. One parser, one meaning. The fold is
//! an EXHAUSTIVE switch over `Node`, so a node kind added tomorrow is a compile
//! error here rather than a wrong answer in the field.
//!
//! Two contracts fall out of the AST that the private parser had to hand-hold:
//!   • THE ALPHABET CONTRACT (§3.6) is now structural. A `class` node consumes
//!     exactly one byte from a byte set, so the ⊆-test against `crest.membership`
//!     is exact in either engine mode; a `uclass` consumes one CODEPOINT, which
//!     `encoded` below reduces to the bytes it can spend and the fewest it must,
//!     certifying the scalar-closed half of the family. Either way the node is
//!     priced by the same `atom`, and no `unicode` flag reaches the calculus.
//!   • CASE FOLDING (§3.7) is the matcher's own. `-i` folds the AST *before*
//!     this fold runs (`syn.foldCaseAst`), so the calculus sees the real folded
//!     class — and a Unicode orbit escaping ASCII (`k`→U+212A KELVIN SIGN,
//!     `s`→U+017F LONG S) promotes the node to `uclass`, self-declining by the
//!     rule above instead of by a hand-maintained special case.
//!
//! A THIRD contract (§3.7c, Lemma 2c) prices the codepoint-run lane, which
//! counts codepoint-like units rather than bytes and so needs its own notion
//! of "how much does one atom spend": a `uclass` always spends exactly ONE
//! codepoint, however many bytes its cheapest scalar costs (`min_cp` below,
//! never `min_len`); a `class` byte-set spends one codepoint IFF it holds no
//! UTF-8 continuation byte — a set that does (`[\x80-\xFF]{6}` in byte mode)
//! certifies NOTHING on this lane, because the document scan the certificate
//! must dominate treats a run of bare continuation bytes as codepoint-run
//! ZERO, not six. `encoded`'s `cp_set` is the first-byte view this rule reads:
//! ASCII members verbatim, plus UTF-8 LEAD bytes only (`[0xC0,0xFF]`) — never
//! the continuation range `[0x80,0xBF]` the byte-lane `set` admits wholesale.
//!
//! Everything rounds DOWN: a construct the calculus cannot certify contributes
//! nothing, so under-pruning is the only failure mode.

const std = @import("std");
const syn = @import("../syntax/syntax.zig");
const crest = @import("../../math/crest.zig");

const Node = syn.Node;
const ByteSet = syn.ByteSet;
const K = crest.K;
const Vector = crest.Vector;

/// The swell of one already-parsed (and, under `-i`, already-folded) AST: ĝ per
/// TOP-LEVEL ALTERNATIVE, because `R₁|R₂` obliges a match to satisfy only one
/// of them. Folding the branches together instead (`Profile.alt`, the rule for
/// every alternation *inside* a branch) is sound but blunt — two branches with
/// disjoint forced classes min to 0⃗, so `[0-9a-f]{12}|[~]{60}` used to sieve by
/// nothing where its first half alone sieves by hex ≥ 12.
///
/// A WORKLIST, never recursion: `parseAlt` left-folds, so `-f patterns.txt`
/// builds an `alt` spine as deep as the file has lines, and the split budget —
/// not the pattern's shape — must bound this walk. Whatever the budget cannot
/// separate stays one subtree and is profiled whole, which min-folds it exactly
/// as before, so overflow degrades toward the old single-vector sieve.
pub fn forcedSwell(ast: *const Node) crest.Swell {
    var branches: [crest.Swell.capacity]*const Node = undefined;
    branches[0] = bare(ast);
    var n: usize = 1;
    var i: usize = 0;
    while (n < branches.len and i < n) {
        switch (branches[i].*) {
            .alt => |kids| {
                branches[i] = bare(kids[0]);
                branches[n] = bare(kids[1]);
                n += 1;
            },
            else => i += 1,
        }
    }
    var swell: crest.Swell = .{ .len = @intCast(n) };
    for (branches[0..n], swell.crests[0..n]) |branch, *ghat| ghat.* = profile(branch).F;
    return swell;
}

/// A capture group accepts exactly its child's language, so it is transparent
/// to the split as well as to the calculus: `(a|b)` is two alternatives.
fn bare(n: *const Node) *const Node {
    var cur = n;
    while (cur.* == .capture) cur = cur.capture.child;
    return cur;
}

/// The fold. Exhaustive by construction — see the header.
fn profile(n: *const Node) Profile {
    return switch (n.*) {
        .empty => Profile.epsilon(),
        // Zero-width assertions consume no byte, so they are ε for a run
        // algebra — including `\<`/`\>`, whose misreading as literals was the
        // false negative this module exists to make unrepresentable.
        .anchor_start,
        .anchor_end,
        .anchor_buf_start,
        .anchor_buf_end,
        .word,
        => Profile.epsilon(),
        // A `class` node spends the same byte set at 1 codepoint as it does
        // at 1 byte — Lemma 2c's refusal (any continuation byte in `set`
        // kills the codepoint lanes) falls out of `atom`'s shared-membership
        // intersect for free, since `crest.membership` already clears those
        // lanes' bits on a continuation byte.
        .class => |set| Profile.atom(set, 1, set, 1),
        .uclass => |ranges| blk: {
            const e = encoded(ranges);
            break :blk Profile.atom(e.set, e.min_len, e.cp_set, 1);
        },
        .concat => |kids| Profile.concat(profile(kids[0]), profile(kids[1])),
        .alt => |kids| Profile.alt(profile(kids[0]), profile(kids[1])),
        // `{n,m}` never reaches here: the parser already expanded it into a
        // concat chain plus these three, so the concat rule prices it exactly.
        .plus => |r| profile(r.node), // ≥1 copy — the adversary takes exactly one
        .star, .quest => |r| Profile.nullable(profile(r.node)),
        .capture => |c| profile(c.child),
    };
}

fn satAdd(a: u16, b: u16) u16 {
    return @intCast(@min(@as(u32, a) + @as(u32, b), std.math.maxInt(u16)));
}

/// What a CODEPOINT class spends in the document's alphabet: the bytes its
/// members can be encoded from, the fewest of them any member costs, and the
/// narrower first-byte view the codepoint-run lane must read instead (§3.7c).
///
/// `set`/`min_len` are the whole of the alphabet repair (§3.6). A `uclass`
/// cannot certify an ASCII class — `\d` under `unicode=true` admits U+0660,
/// which is no ASCII digit — but every non-ASCII scalar encodes to bytes that
/// ALL have bit 7 set, so it can certify the scalar-closed twin, and one
/// codepoint of it spends `min_len` ≥ 1 bytes rather than one. Both halves
/// round down: `set` is a superset of what the class can actually spend
/// (surrogates encode to nothing, and 0x80..0xFF is taken whole), which can
/// only shrink the shared mask, and `min_len` reads the lowest scalar of each
/// range, which cannot exceed the true minimum because UTF-8 length is
/// monotone in the codepoint.
///
/// `cp_set` differs from `set` in exactly one place: it admits UTF-8 LEAD
/// bytes (`[0xC0,0xFF]`) where `set` admits the whole non-ASCII byte
/// (`[0x80,0xFF]`) — because on the codepoint-run lane a lead byte is a valid
/// "first byte" of this class's member and a bare continuation byte never is
/// (Lemma 2c). Every `uclass` atom still spends exactly ONE codepoint of it,
/// however many bytes `min_len` costs — the caller passes that length
/// literally, not derived from this set.
fn encoded(ranges: []const [2]u21) struct { set: ByteSet, min_len: u16, cp_set: ByteSet } {
    var set = ByteSet{};
    var cp_set = ByteSet{};
    var min_len: u16 = 4; // no encoding is longer
    for (ranges) |r| {
        min_len = @min(min_len, utf8Len(r[0]));
        if (r[0] <= 0x7F) {
            const hi: u8 = @intCast(@min(r[1], 0x7F));
            set.setRange(@intCast(r[0]), hi);
            cp_set.setRange(@intCast(r[0]), hi);
        }
        if (r[1] > 0x7F) {
            set.setRange(0x80, 0xFF);
            cp_set.setRange(0xC0, 0xFF); // leads only — a continuation is never a "first byte"
        }
    }
    return .{ .set = set, .min_len = min_len, .cp_set = cp_set };
}

/// UTF-8 byte length, monotone and total — `std.unicode`'s errors on the
/// surrogate gap, which a range may legally span (the lowering drops it).
fn utf8Len(cp: u21) u16 {
    return if (cp < 0x80) 1 else if (cp < 0x800) 2 else if (cp < 0x10000) 3 else 4;
}

/// A sub-expression's forced run summary (PROOF.md §3). Every numeric field is
/// a sound LOWER bound over the sub-language; `only_c_cert` is one-sided — true
/// obliges every accepted string to be class-C bytes end to end, false claims
/// nothing. Max-subarray prefix/suffix/best, inverted for adversarial minima,
/// entirely in the document's saturated u16 domain.
pub const Profile = struct {
    F: Vector, // forced longest run:  F ≤ min_{w∈L} ρ(w,C)
    P: Vector, // forced leading run
    S: Vector, // forced trailing run
    min_len: u16, // forced minimum BYTE length (saturating) — byte + scalar-closed lanes
    min_cp: u16, // forced minimum CODEPOINT length (saturating) — codepoint-run lanes only
    only_c_cert: [K]bool, // ⇒ every w∈L is composed solely of class-C bytes

    /// True for a codepoint-run lane — the boundary `concat` reads to pick
    /// `min_len` (bytes) or `min_cp` (codepoints) as the unit a seam extends
    /// by. Lane layout is `crest.Alphabet`'s declared order (ascii, scalar,
    /// codepoint), so this is a single threshold, not a lookup.
    fn isCodepointLane(i: usize) bool {
        return i >= 2 * crest.base_k;
    }

    /// Language {ε}: the concatenation identity, certified for every class.
    pub fn epsilon() Profile {
        return .{ .F = @splat(0), .P = @splat(0), .S = @splat(0), .min_len = 0, .min_cp = 0, .only_c_cert = @splat(true) };
    }

    /// No usable semantics: numerically harmless and never licenses a seam.
    pub fn unknown() Profile {
        return .{ .F = @splat(0), .P = @splat(0), .S = @splat(0), .min_len = 0, .min_cp = 0, .only_c_cert = @splat(false) };
    }

    /// One mandatory atom, priced twice: `byte_len` bytes drawn from
    /// `byte_set` (the byte + scalar-closed lanes) and `cp_len` codepoints
    /// drawn from `cp_set` (the codepoint-run lane, §3.7c). For a `class` node
    /// the two sets and lengths coincide (it spends one byte that is also one
    /// codepoint-worth, or — if the set holds a continuation byte — neither
    /// certifies, Lemma 2c's refusal falling out of the shared-membership
    /// intersect with no extra code); for a `uclass`, `byte_set`/`byte_len`
    /// are `encoded`'s scalar-closed view and `cp_set`/`cp_len` are its
    /// first-byte view at exactly 1 codepoint. Each set independently
    /// intersects `crest.membership` over its own lane range, so the two
    /// prices can certify different members without cross-contaminating one
    /// another. An empty set matches nothing, so it claims nothing rather
    /// than everything vacuously.
    ///
    /// A certified run is `byte_len`/`cp_len` long, not 1: `\d` forces four
    /// bytes of `digit+u` if its cheapest member is a 4-byte codepoint, and
    /// pricing it at 1 would throw away the very contiguity the sieve trades
    /// on — while it forces exactly ONE `digit+cp`, since one codepoint is one
    /// codepoint regardless of its encoded width.
    pub fn atom(byte_set: ByteSet, byte_len: u16, cp_set: ByteSet, cp_len: u16) Profile {
        var p = unknown();
        p.min_len = byte_len;
        p.min_cp = cp_len;
        fillShared(&p, byte_set, byte_len, 0, 2 * crest.base_k);
        fillShared(&p, cp_set, cp_len, 2 * crest.base_k, K);
        return p;
    }

    /// Certify every lane in `[lo, hi)` whose membership bit is shared across
    /// every byte of `set`, at the given run length — `atom`'s shared work,
    /// scoped to one lane range so the byte-priced and codepoint-priced halves
    /// never read each other's set.
    fn fillShared(p: *Profile, set: ByteSet, len: u16, lo: usize, hi: usize) void {
        if (set.count() == 0) return;
        var shared: crest.Mask = std.math.maxInt(crest.Mask);
        for (0..256) |b| {
            if (shared == 0) break; // a wide set shares nothing; stop reading
            if (set.has(@intCast(b))) shared &= crest.membership[b];
        }
        for (lo..hi) |i| {
            if ((shared & (@as(crest.Mask, 1) << @intCast(i))) != 0) {
                p.F[i] = len;
                p.P[i] = len;
                p.S[i] = len;
                p.only_c_cert[i] = true;
            }
        }
    }

    /// E₁·E₂: S₁+P₂ is the only seam term; certificates alone license
    /// extension, and each lane extends by ITS OWN unit — bytes for a byte or
    /// scalar-closed lane, codepoints for a codepoint-run one (§3.7c) — so a
    /// 3-byte CJK atom seams a byte lane by 3 and a codepoint lane by 1.
    pub fn concat(a: Profile, b: Profile) Profile {
        var r: Profile = .{ .F = undefined, .P = undefined, .S = undefined, .min_len = satAdd(a.min_len, b.min_len), .min_cp = satAdd(a.min_cp, b.min_cp), .only_c_cert = undefined };
        inline for (0..K) |i| {
            const a_unit = if (isCodepointLane(i)) a.min_cp else a.min_len;
            const b_unit = if (isCodepointLane(i)) b.min_cp else b.min_len;
            r.F[i] = @max(@max(a.F[i], b.F[i]), satAdd(a.S[i], b.P[i]));
            r.P[i] = if (a.only_c_cert[i]) satAdd(a_unit, b.P[i]) else a.P[i];
            r.S[i] = if (b.only_c_cert[i]) satAdd(b_unit, a.S[i]) else b.S[i];
            r.only_c_cert[i] = a.only_c_cert[i] and b.only_c_cert[i];
        }
        return r;
    }

    /// E₁|E₂ — the adversary picks the branch minimizing each field.
    pub fn alt(a: Profile, b: Profile) Profile {
        var r: Profile = .{ .F = undefined, .P = undefined, .S = undefined, .min_len = @min(a.min_len, b.min_len), .min_cp = @min(a.min_cp, b.min_cp), .only_c_cert = undefined };
        inline for (0..K) |i| {
            r.F[i] = @min(a.F[i], b.F[i]);
            r.P[i] = @min(a.P[i], b.P[i]);
            r.S[i] = @min(a.S[i], b.S[i]);
            r.only_c_cert[i] = a.only_c_cert[i] and b.only_c_cert[i];
        }
        return r;
    }

    /// `E*` / `E?` — the adversary takes zero copies, collapsing every numeric
    /// bound to ε. The certificate survives: a copy that DOES appear is still
    /// all-C, so a run straddling this node never breaks (`[0-9][0-9]*[0-9]`
    /// still forces two digits, not three).
    pub fn nullable(p: Profile) Profile {
        var out = epsilon();
        out.only_c_cert = p.only_c_cert;
        return out;
    }
};
