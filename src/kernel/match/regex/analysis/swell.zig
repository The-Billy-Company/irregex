//! gist — the FORCED-CREST calculus: the query half of the Crest sieve
//! (`../../../primitives/crest.zig`; research/crest/PROOF.md §3).
//!
//! A document carries a *crest* — the longest run of consecutive bytes in each
//! of k byte classes, ρ(d). A pattern forces a *swell*: the smallest crest any
//! string it accepts can have, ĝ(R) ≤ min_{w∈L(R)} ρ(w). `forcedCrest` folds
//! that lower bound out of the AST with a min-of-max prefix/suffix/best algebra
//! (`Profile`), and the sieve prunes d whenever ρ(d) ≱ ĝ(R) — k integer
//! compares, no byte scan, provably no false negatives (Sieve Theorem §2).
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
//!     is exact in either engine mode; a `uclass` always carries a non-ASCII
//!     scalar (syntax.zig's invariant), so it occupies ≥1 byte and certifies
//!     nothing. No `unicode` flag reaches the calculus at all.
//!   • CASE FOLDING (§3.7) is the matcher's own. `-i` folds the AST *before*
//!     this fold runs (`syn.foldCaseAst`), so the calculus sees the real folded
//!     class — and a Unicode orbit escaping ASCII (`k`→U+212A KELVIN SIGN,
//!     `s`→U+017F LONG S) promotes the node to `uclass`, self-declining by the
//!     rule above instead of by a hand-maintained special case.
//!
//! Everything rounds DOWN: a construct the calculus cannot certify contributes
//! nothing, so under-pruning is the only failure mode.

const std = @import("std");
const syn = @import("../syntax/syntax.zig");
const crest = @import("../../../primitives/crest.zig");

const Node = syn.Node;
const ByteSet = syn.ByteSet;
const K = crest.K;
const Vector = crest.Vector;

/// ĝ(R) for one already-parsed (and, under `-i`, already-folded) AST.
pub fn forcedCrest(ast: *const Node) Vector {
    return profile(ast).F;
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
        .word_boundary,
        .not_word_boundary,
        .word_start,
        .word_end,
        => Profile.epsilon(),
        .class => |set| Profile.atom(set),
        .uclass => Profile.unit(),
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

/// A sub-expression's forced run summary (PROOF.md §3). Every numeric field is
/// a sound LOWER bound over the sub-language; `only_c_cert` is one-sided — true
/// obliges every accepted string to be class-C bytes end to end, false claims
/// nothing. Max-subarray prefix/suffix/best, inverted for adversarial minima,
/// entirely in the document's saturated u16 domain.
pub const Profile = struct {
    F: Vector, // forced longest run:  F ≤ min_{w∈L} ρ(w,C)
    P: Vector, // forced leading run
    S: Vector, // forced trailing run
    min_len: u16, // forced minimum BYTE length (saturating)
    only_c_cert: [K]bool, // ⇒ every w∈L is composed solely of class-C bytes

    /// Language {ε}: the concatenation identity, certified for every class.
    pub fn epsilon() Profile {
        return .{ .F = @splat(0), .P = @splat(0), .S = @splat(0), .min_len = 0, .only_c_cert = @splat(true) };
    }

    /// No usable semantics: numerically harmless and never licenses a seam.
    pub fn unknown() Profile {
        return .{ .F = @splat(0), .P = @splat(0), .S = @splat(0), .min_len = 0, .only_c_cert = @splat(false) };
    }

    /// One mandatory byte of unknown class — a `uclass`, which spends ≥1 byte
    /// on a codepoint that is in no ASCII class by construction.
    pub fn unit() Profile {
        var p = unknown();
        p.min_len = 1;
        return p;
    }

    /// One mandatory byte drawn from `set`. It certifies class C iff every byte
    /// the node can consume is in C — exact, since a `class` node spends exactly
    /// one byte. Intersecting the membership masks answers all k classes in one
    /// pass. An empty set (`[^\x00-\xff]`) matches nothing, so it claims nothing
    /// rather than everything vacuously.
    pub fn atom(set: ByteSet) Profile {
        var p = unit();
        var shared: u8 = 0;
        if (set.count() != 0) {
            shared = 0xFF;
            for (0..256) |b| {
                if (set.has(@intCast(b))) shared &= crest.membership[b];
            }
        }
        inline for (0..K) |i| {
            if ((shared & (@as(u8, 1) << @intCast(i))) != 0) {
                p.F[i] = 1;
                p.P[i] = 1;
                p.S[i] = 1;
                p.only_c_cert[i] = true;
            }
        }
        return p;
    }

    /// E₁·E₂: S₁+P₂ is the only seam term; certificates alone license extension.
    pub fn concat(a: Profile, b: Profile) Profile {
        var r: Profile = .{ .F = undefined, .P = undefined, .S = undefined, .min_len = satAdd(a.min_len, b.min_len), .only_c_cert = undefined };
        inline for (0..K) |i| {
            r.F[i] = @max(@max(a.F[i], b.F[i]), satAdd(a.S[i], b.P[i]));
            r.P[i] = if (a.only_c_cert[i]) satAdd(a.min_len, b.P[i]) else a.P[i];
            r.S[i] = if (b.only_c_cert[i]) satAdd(b.min_len, a.S[i]) else b.S[i];
            r.only_c_cert[i] = a.only_c_cert[i] and b.only_c_cert[i];
        }
        return r;
    }

    /// E₁|E₂ — the adversary picks the branch minimizing each field.
    pub fn alt(a: Profile, b: Profile) Profile {
        var r: Profile = .{ .F = undefined, .P = undefined, .S = undefined, .min_len = @min(a.min_len, b.min_len), .only_c_cert = undefined };
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
