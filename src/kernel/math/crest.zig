//! Crest — the forced-class-run necessary condition (research/crest/PROOF.md).
//!
//! The contiguity bound the trigram index concedes: a literal-free
//! class-repetition pattern (`[0-9a-f]{8}`, `[0-9]{6}`) extracts no required
//! substring, so every substring-presence prefilter degenerates to a full scan
//! (the Certificate's `regex-classcount` hole, cand% = 100%). Crest prunes by a
//! DIFFERENT sound necessary condition:
//!
//!   • per document d, the CREST VECTOR ρ(d) ∈ ℕ^k — the length of the longest
//!     run of consecutive bytes in each member of a fixed k-class family — one
//!     O(|d|) pass, k small ints;
//!   • per query R, the FORCED CREST ĝ(R) ≤ min_{w∈L(R)} ρ(w) — a sound lower
//!     bound folded out of the pattern AST by a min-of-max prefix/suffix/best
//!     run algebra (`../regex/analysis/swell.zig`) — one per top-level
//!     ALTERNATIVE, since `R₁|R₂` obliges a match to satisfy only one of them;
//!   • THE SIEVE: R can match inside d only if some alternative's ĝ is
//!     componentwise met, so a `Swell` all of whose alternatives fall short
//!     prunes d — k integer compares per alternative, no byte scan, provably
//!     no false negatives (Sieve Theorem, PROOF.md §2 and §3.9).
//!
//! This module is the DOCUMENT half and the sieve itself — the pure kernel, no
//! I/O, no allocation, no engine dep. The query half (ĝ, the forced-crest
//! calculus) reads the regex engine's own AST and therefore lives with it, in
//! `../regex/analysis/swell.zig`; deriving it from a second private
//! grammar was a silent false-negative factory (see that file's header). The
//! persisted per-doc table lives in `corpus/index/crest/sidecar.zig`; the
//! read-elision wiring in `exec/cold/engine/{serial.zig,swarm/}`; the
//! production proof harness in `bench/rungs/crest/`.
//!
//! SOUNDNESS POSTURE: everything rounds DOWN — a construct `swell` cannot
//! certify contributes nothing (or zeroes the whole vector), so under-pruning is
//! the only failure mode. All quantities saturate at `maxInt(u16)`; saturation
//! is monotone on both sides of the compare, so it never manufactures a prune.

const std = @import("std");

const signet = @import("../../corpus/index/frame/signet.zig");

/// The eight base classes. Order is load-bearing: a crest vector is indexed in
/// exactly this order and the persisted sidecar stores it verbatim. Chosen for
/// code corpora — narrow classes (digit, hex, upper) are where forced runs are
/// long and chance runs are short (PROOF.md §4).
pub const Class = enum(u8) {
    digit = 0,
    hex,
    upper,
    lower,
    alpha,
    word,
    space,
    punct,
};

/// Each class is measured over two alphabets, and the second one is why `\d`
/// prunes at all under the engine's default `unicode=true`.
///
/// A byte sieve and a codepoint matcher disagree about what a class IS, and
/// PROOF.md §3.6 resolved that disagreement by refusing: a `uclass` certified
/// nothing, so `\d{6}` — the ordinary spelling — sieved by nothing while
/// `[0-9]{6}` pruned 92.8%. The repair is to measure a second family whose
/// members are closed under the non-ASCII bytes: `digit+u` is `[0-9]` ∪
/// [0x80,0xFF]. Every byte of a multi-byte UTF-8 sequence has bit 7 set (Pike
/// & Thompson's design property), so a codepoint class containing U+0660
/// ARABIC-INDIC DIGIT ZERO still spends only bytes inside `digit+u`, and a run
/// of n such codepoints is a run of ≥ n such bytes. The bound is looser than
/// the ASCII one — that is the price of the byte/codepoint gap, and it is
/// still a bound.
pub const Alphabet = enum(u8) {
    ascii = 0,
    scalar,
};

pub const base_k: usize = @typeInfo(Class).@"enum".fields.len;
pub const K: usize = base_k * @typeInfo(Alphabet).@"enum".fields.len;

/// Index of one family member. ASCII lanes stay at their historical indices,
/// so the eight base classes read exactly where they always did.
pub fn lane(c: Class, a: Alphabet) usize {
    return @intFromEnum(a) * base_k + @intFromEnum(c);
}

/// One crest vector: the longest per-member run, saturated at `maxInt(u16)`.
pub const Vector = [K]u16;

/// One bit per family member — the shape `membership` and the ⊆-test share.
pub const Mask = std.meta.Int(.unsigned, K);

pub const zero_vector: Vector = @splat(0);

/// The query's forced crest, as the DISJUNCTION the grammar actually hands us:
/// one ĝ per top-level alternative of the pattern. `R₁|R₂` obliges a match to
/// satisfy exactly one branch, so the sieve may prune only a document that
/// clears NONE of them.
///
/// Collapsing the branches into a single componentwise min — the old shape —
/// keeps soundness but throws that structure away, and two branches with
/// disjoint forced classes min to 0⃗: a sieve that prunes nothing at all. Since
/// multi-`-e` reaches the engine as `(?:a)|(?:b)`, every multi-pattern search
/// used to run with the sieve silently stood down.
///
/// Bounded and inline, so the query half stays allocation-free and the whole
/// object copies into a loader thread's frame. Beyond `capacity` alternatives
/// the surplus stays folded by `Profile.alt` into one slot, degrading toward
/// the single-vector sieve rather than failing.
pub const Swell = struct {
    pub const capacity = 8;

    crests: [capacity]Vector = @splat(zero_vector),
    len: u8 = 0,

    /// Prune ⟺ the document falls short of EVERY alternative. A match takes
    /// some branch, and that branch's ĝ would have admitted d — which is the
    /// whole proof. An empty swell analyzed nothing, so it proves nothing and
    /// prunes nothing.
    pub fn prunes(s: *const Swell, doc: Vector) bool {
        if (s.len == 0) return false;
        for (s.crests[0..s.len]) |ghat| if (!pruned(doc, ghat)) return false;
        return true;
    }

    /// Is there anything to prune by? A single alternative demanding 0⃗ makes
    /// the whole disjunction inert however strong its siblings are — it admits
    /// every document on its own.
    pub fn active(s: *const Swell) bool {
        if (s.len == 0) return false;
        for (s.crests[0..s.len]) |ghat| if (@reduce(.Max, @as(@Vector(K, u16), ghat)) == 0) return false;
        return true;
    }
};

/// The one spelling of "this run proves nothing about any document": a pattern
/// the engine declined, a PCRE2 arm, or an output mode that must read every
/// byte. Every stand-down names it rather than open-coding an empty swell.
pub const no_sieve: Swell = .{};

/// The seven INDEPENDENT byte predicates. Every class in the family is a
/// boolean combination of these, and `classes` below is that combination —
/// written once, so the four derived classes cannot drift from the three they
/// are derived from.
const Prims = struct {
    digit: u1,
    upper: u1,
    lower: u1,
    hexalpha: u1,
    under: u1,
    space: u1,
    graph: u1,

    /// The eight base classes, in `Class` order. THE definition of the family.
    fn classes(p: Prims) [base_k]u1 {
        const alpha = p.upper | p.lower;
        const word = alpha | p.digit | p.under;
        return .{ p.digit, p.digit | p.hexalpha, p.upper, p.lower, alpha, word, p.space, p.graph & ~word };
    }
};

fn classify(b: u8) Prims {
    const in = struct {
        fn f(v: u8, comptime lo: u8, comptime hi: u8) u1 {
            return @intFromBool(v >= lo and v <= hi);
        }
    }.f;
    return .{
        .digit = in(b, '0', '9'),
        .upper = in(b, 'A', 'Z'),
        .lower = in(b, 'a', 'z'),
        // `|0x20` folds the case before one range test; no byte ≥ 0x80 can
        // fold into 'a'..'f', so the high half stays out on its own.
        .hexalpha = in(b | 0x20, 'a', 'f'),
        .under = @intFromBool(b == '_'),
        .space = @intFromBool(b == ' ') | in(b, '\t', '\r'),
        .graph = in(b, '!', '~'),
    };
}

/// `membership[b]` bit `1 << lane(c, a)` is set ⟺ byte b belongs to family
/// member (c, a). This table is the ONLY classifier: the document scan reads
/// it rather than re-deriving the predicates, so there is no second definition
/// to drift. A non-ASCII byte is in no base class and in every scalar twin —
/// the closure rule, in its per-byte spelling.
pub const membership: [256]Mask = blk: {
    @setEvalBranchQuota(100_000);
    var m: [256]Mask = @splat(0);
    for (&m, 0..) |*slot, b| {
        const cls = classify(@intCast(b)).classes();
        const high = b >= 0x80;
        var set: Mask = 0;
        for (cls, 0..) |hit, c| {
            if (hit != 0) set |= one(c) | one(base_k + c);
            if (high) set |= one(base_k + c);
        }
        slot.* = set;
    }
    break :blk m;
};

inline fn one(i: usize) Mask {
    return @as(Mask, 1) << @intCast(i);
}

/// `keep[b]` is `membership[b]` already in the shape the scan consumes: lane C
/// holds all-ones iff b belongs to C, so resetting the run counters is one AND
/// against a loaded constant.
///
/// Derived from `membership`, never beside it — one classifier, two shapes. The
/// bitset is what the query half intersects (`swell.atom`) and what the schema
/// hashes; this is what the document half reads, 8 KiB of it, L1-resident for
/// the whole scan.
const keep: [256]@Vector(K, u16) = blk: {
    @setEvalBranchQuota(100_000);
    var t: [256]@Vector(K, u16) = undefined;
    for (&t, membership) |*slot, m| {
        var lanes: [K]u16 = undefined;
        for (&lanes, 0..) |*l, c| l.* = if ((m & one(c)) != 0) 0xFFFF else 0;
        slot.* = lanes;
    }
    break :blk t;
};

/// Human label for a family member (reporting only).
pub fn className(i: usize) []const u8 {
    return lane_names[i];
}

const lane_names: [K][]const u8 = blk: {
    var out: [K][]const u8 = undefined;
    for (std.enums.values(Class)) |c| {
        out[lane(c, .ascii)] = @tagName(c);
        out[lane(c, .scalar)] = @tagName(c) ++ "+u";
    }
    break :blk out;
};

/// Semantic contract carried by every persisted Crest sidecar. The schema
/// signet over `canonical_bytes` invalidates a cache whenever the class family
/// or meaning of one stored u16 changes, even if its physical width stays fixed.
pub const SidecarSchema = struct {
    pub const format_version: u16 = 3;
    pub const saturation_cap: u16 = std.math.maxInt(u16);
    pub const element_interpretation = "longest consecutive input-byte run belonging to the class, per document, saturated at the numeric cap";

    /// Every member's label, in lane order — derived, so a family that grows
    /// or reorders cannot leave a stale name in the preimage.
    pub const class_order = blk: {
        var s: []const u8 = className(0);
        for (1..K) |i| s = s ++ "\x00" ++ className(i);
        break :blk s;
    };

    const domain = "irregex/crest-sidecar-semantic-schema\x00";

    /// The membership table as canonical little-endian bytes: it is a u16 per
    /// byte now that the family spans both alphabets, and the preimage must be
    /// architecture-independent.
    pub const membership_le = blk: {
        var out: [membership.len * 2]u8 = undefined;
        for (membership, 0..) |m, i| out[2 * i ..][0..2].* = le16(m);
        break :blk out;
    };

    /// Canonical, architecture-independent schema bytes. Field labels and
    /// fixed little-endian scalars make the preimage self-delimiting; the full
    /// table is the final field, not a derived or abbreviated ID.
    pub const canonical_bytes = (domain ++
        "format-version/u16le\x00" ++ le16(format_version) ++
        "class-count/u8\x00" ++ [_]u8{@intCast(K)} ++
        "element-width/u8\x00" ++ [_]u8{@sizeOf(u16)} ++
        "class-order/nul-separated\x00" ++ le16(class_order.len) ++ class_order ++
        "saturation-cap/u16le\x00" ++ le16(saturation_cap) ++
        "element-interpretation/utf8\x00" ++ le16(element_interpretation.len) ++ element_interpretation ++
        "membership-table/u16le-x256\x00" ++ le16(membership_le.len) ++ membership_le).*;

    /// The schema's identity. `domain` above names WHICH schema; signet's
    /// `.schema` label names what KIND of statement this is, so the sidecar's
    /// mark can never be confused with the artifact seal on a sibling blob.
    pub fn hash() signet.Signet {
        return signet.of(.schema, &canonical_bytes);
    }

    fn le16(comptime value: u16) [2]u8 {
        return .{ @truncate(value), @truncate(value >> 8) };
    }
};

const V = @Vector(K, u16);
const zeros: V = @splat(0);
const ones: V = @splat(0xFFFF);
const step: V = @splat(1);

/// How many pieces the document is cut into and scanned interleaved.
///
/// THE STATE IS TWO VECTORS and it never leaves them: the counters saturate at
/// the same cap the vector stores, so `cur` and `best` are u16 like the answer
/// and the whole family is 32 bytes each. But the per-byte update is a
/// saturating add feeding an AND — a loop-carried chain about three cycles
/// deep, which one scan cannot fill. Measured, a single scan spent 4.4
/// cycles/byte with the machine mostly idle, and cutting the op count (a
/// preshaped `keep` table for a splat-and-compare) moved it by nothing at all,
/// which is the signature of a latency bound. Four pieces put four chains in
/// flight, and `cur` + `best` for four pieces is 16 of the 32 NEON registers.
///
/// Written instead as an `inline for` over the classes updating plain arrays —
/// which reads better — it is the same arithmetic and the register allocator
/// spills it. Single-threaded that barely shows, because the spills hit L1; in
/// `crest/sidecar.zig`'s sharded build, where every core is spilling at once, it
/// is 3.7x slower over the live corpus and that is the path that ships. The
/// retired shape also branched per class per byte, on a boundary no predictor
/// can learn.
///
/// A bitmap pass — classify 64 bytes SIMD, fold to u64 masks, extract runs from
/// the words — was measured and rejected: the classification is genuinely
/// cheaper, but extracting a longest run costs a step per RUN, and a dense mask
/// has a run every few bits. It measured 3.8x slower than this.
const ways = 4;

/// Under this, the joins and the per-piece lead scan cost more than the
/// interleave returns, so a short document takes the plain loop.
const interleave_floor = 4 * 1024;

/// What one contiguous piece of a document proves, per lane: the run it opens
/// with, the longest run inside it, the run it ends with, and whether it is one
/// unbroken run — the last because a piece that never breaks carries a run
/// through from its left neighbour to its right one.
///
/// This is the document-side twin of `swell.Profile`, down to the field names:
/// same P/F/S, same concatenation law. There it folds over the pattern AST,
/// here over the pieces of a document. Not a coincidence — both are asking
/// what a concatenation forces, and it is what makes cutting the document up
/// exact rather than approximate.
const Piece = struct {
    lead: V,
    best: V,
    trail: V,
    whole: V, // all-ones on lanes the piece never broke

    fn join(a: Piece, a_len: V, b: Piece, b_len: V) Piece {
        return .{
            .lead = @select(u16, a.whole != zeros, a_len +| b.lead, a.lead),
            .best = @max(@max(a.best, b.best), a.trail +| b.lead),
            .trail = @select(u16, b.whole != zeros, b_len +| a.trail, b.trail),
            .whole = a.whole & b.whole,
        };
    }
};

/// The crest vector ρ(d): the longest run of each family member, in one pass.
pub fn crest(doc: []const u8) Vector {
    if (doc.len < interleave_floor) return solo(doc).best;

    const span = doc.len / ways; // the last piece also takes the remainder
    var cur: [ways]V = @splat(zeros);
    var best: [ways]V = @splat(zeros);
    for (0..span) |j| {
        inline for (&cur, &best, 0..) |*c, *bst, w| {
            c.* = (c.* +| step) & keep[doc[w * span + j]];
            bst.* = @max(bst.*, c.*);
        }
    }
    const last = ways - 1;
    for (doc[ways * span ..]) |b| { // contiguous with the last piece
        cur[last] = (cur[last] +| step) & keep[b];
        best[last] = @max(best[last], cur[last]);
    }

    var acc: Piece = undefined;
    var acc_len: usize = 0;
    inline for (0..ways) |w| {
        const len = if (w == last) doc.len - w * span else span;
        const l = lead(doc[w * span ..][0..len]);
        const p: Piece = .{ .lead = l.run, .best = best[w], .trail = cur[w], .whole = l.alive };
        acc = if (w == 0) p else acc.join(saturate(acc_len), p, saturate(len));
        acc_len += len;
    }
    return acc.best;
}

/// One piece, scanned whole — the shape `crest` degenerates to for a short
/// document, and the definition the interleaved path is differential-tested
/// against.
fn solo(d: []const u8) Piece {
    var cur = zeros;
    var best = zeros;
    for (d) |b| {
        cur = (cur +| step) & keep[b];
        best = @max(best, cur);
    }
    const l = lead(d);
    return .{ .lead = l.run, .best = best, .trail = cur, .whole = l.alive };
}

/// A piece's opening run per lane, and which lanes it never broke.
///
/// Kept out of the main loop deliberately. Carried there it is two more ops on
/// every byte of the document; here it stops as soon as every lane has broken,
/// which ordinary text does within a few dozen bytes — a letter breaks `digit`,
/// a space breaks `word`, a printable breaks `space`. A piece that genuinely
/// never breaks is scanned twice, and that is the file whose run saturates
/// anyway.
fn lead(d: []const u8) struct { run: V, alive: V } {
    var alive = ones;
    var run = zeros;
    var i: usize = 0;
    while (i < d.len) {
        // A dead lane adds zero, so overshooting the exit costs time and never
        // an answer — which is why the horizontal reduce, expensive on NEON,
        // is amortized over a stride instead of paid per byte.
        const stop = @min(i + 64, d.len);
        while (i < stop) : (i += 1) {
            alive &= keep[d[i]];
            run +|= alive & step;
        }
        if (@reduce(.Or, alive) == 0) break;
    }
    return .{ .run = run, .alive = alive };
}

fn saturate(n: usize) V {
    return @splat(@intCast(@min(n, std.math.maxInt(u16))));
}

/// One alternative's dominance test: it falls short ⟺ some member's crest is
/// below the run that alternative forces — k integer compares, no byte scan.
/// Sound because a match of that alternative implies ρ(d,C) ≥ g ≥ ĝ. `Swell`
/// is what a query sieves by; this is the inequality it is built from.
pub fn pruned(doc_crest: Vector, ghat_vec: Vector) bool {
    return @reduce(.Or, @as(@Vector(K, u16), doc_crest) < @as(@Vector(K, u16), ghat_vec));
}
