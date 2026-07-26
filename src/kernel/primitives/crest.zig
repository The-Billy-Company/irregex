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
//!     run algebra (`../match/regex/analysis/swell.zig`);
//!   • THE SIEVE: R can match inside d only if ρ(d) ≥ ĝ(R) componentwise, so
//!     `∃C: ρ(d,C) < ĝ(R,C)` prunes d — k integer compares, no byte scan,
//!     provably no false negatives (Sieve Theorem, PROOF.md §2).
//!
//! This module is the DOCUMENT half and the sieve itself — the pure kernel, no
//! I/O, no allocation, no engine dep. The query half (ĝ, the forced-crest
//! calculus) reads the regex engine's own AST and therefore lives with it, in
//! `../match/regex/analysis/swell.zig`; deriving it from a second private
//! grammar was a silent false-negative factory (see that file's header). The
//! persisted per-doc table lives in `corpus/index/crest/sidecar.zig`; the
//! read-elision wiring in `surface/exec/cold/engine/{serial,parallel}.zig`; the
//! production proof harness in `bench/crest/`.
//!
//! SOUNDNESS POSTURE: everything rounds DOWN — a construct `swell` cannot
//! certify contributes nothing (or zeroes the whole vector), so under-pruning is
//! the only failure mode. All quantities saturate at `maxInt(u16)`; saturation
//! is monotone on both sides of the compare, so it never manufactures a prune.

const std = @import("std");

/// The fixed class family. Order is load-bearing: a crest vector is a k-tuple
/// in exactly this order, and the persisted sidecar stores it verbatim. Chosen
/// for code corpora — narrow classes (digit, hex, upper) are where forced runs
/// are long and chance runs are short (PROOF.md §4).
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

pub const K: usize = @typeInfo(Class).@"enum".fields.len;

/// One crest vector: the longest per-class run, saturated at `maxInt(u16)`.
pub const Vector = [K]u16;

pub const zero_vector: Vector = @splat(0);

/// Does the sieve have anything to prune by? (0⃗ prunes nothing.)
pub fn active(v: Vector) bool {
    return !std.mem.eql(u16, &v, &zero_vector);
}

fn isDigit(b: u8) bool {
    return b >= '0' and b <= '9';
}
fn isHex(b: u8) bool {
    return isDigit(b) or (b >= 'a' and b <= 'f') or (b >= 'A' and b <= 'F');
}
fn isUpper(b: u8) bool {
    return b >= 'A' and b <= 'Z';
}
fn isLower(b: u8) bool {
    return b >= 'a' and b <= 'z';
}
fn isAlpha(b: u8) bool {
    return isUpper(b) or isLower(b);
}
fn isWord(b: u8) bool {
    return isAlpha(b) or isDigit(b) or b == '_';
}
fn isSpace(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\n' or b == 0x0B or b == 0x0C or b == '\r';
}
fn isPunct(b: u8) bool {
    return b >= '!' and b <= '~' and !isWord(b);
}
fn classMember(c: Class, b: u8) bool {
    return switch (c) {
        .digit => isDigit(b),
        .hex => isHex(b),
        .upper => isUpper(b),
        .lower => isLower(b),
        .alpha => isAlpha(b),
        .word => isWord(b),
        .space => isSpace(b),
        .punct => isPunct(b),
    };
}

/// `membership[b]` bit `1<<i` is set ⟺ byte b ∈ class i; the document scan and
/// the query calculus share this comptime source of truth.
pub const membership: [256]u8 = blk: {
    @setEvalBranchQuota(20_000);
    var m: [256]u8 = @splat(0);
    for (0..256) |b| {
        var bits: u8 = 0;
        for (0..K) |i| {
            if (classMember(@enumFromInt(i), @intCast(b))) bits |= (@as(u8, 1) << @intCast(i));
        }
        m[b] = bits;
    }
    break :blk m;
};

/// Semantic contract carried by every persisted Crest sidecar. The SHA-256
/// digest of `canonical_bytes` invalidates a cache whenever the class family or
/// meaning of one stored u16 changes, even if its physical width stays fixed.
pub const SidecarSchema = struct {
    pub const format_version: u16 = 2;
    pub const saturation_cap: u16 = std.math.maxInt(u16);
    pub const element_interpretation = "longest consecutive input-byte run belonging to the class, per document, saturated at the numeric cap";
    pub const class_order = "digit\x00hex\x00upper\x00lower\x00alpha\x00word\x00space\x00punct";

    const domain = "irregex/crest-sidecar-semantic-schema\x00";
    const version_le = le16(format_version);
    const cap_le = le16(saturation_cap);
    const membership_len_le = le16(membership.len);

    /// Canonical, architecture-independent schema bytes. Field labels and
    /// fixed little-endian scalars make the preimage self-delimiting; the full
    /// 256-byte table is the final field, not a derived or abbreviated ID.
    pub const canonical_bytes = (domain ++
        "format-version/u16le\x00" ++ version_le ++
        "class-count/u8\x00" ++ [_]u8{@intCast(K)} ++
        "element-width/u8\x00" ++ [_]u8{@sizeOf(u16)} ++
        "class-order/nul-separated\x00" ++ le16(class_order.len) ++ class_order ++
        "saturation-cap/u16le\x00" ++ cap_le ++
        "element-interpretation/utf8\x00" ++ le16(element_interpretation.len) ++ element_interpretation ++
        "membership-table/u8x256\x00" ++ membership_len_le ++ membership).*;

    pub fn hash() [std.crypto.hash.sha2.Sha256.digest_length]u8 {
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&canonical_bytes, &digest, .{});
        return digest;
    }

    fn le16(comptime value: u16) [2]u8 {
        return .{ @truncate(value), @truncate(value >> 8) };
    }
};

/// The crest vector ρ(d): longest per-class run in one O(|d|·k) forward pass,
/// with its k-lane update comptime-unrolled over the bit table.
pub fn crest(doc: []const u8) Vector {
    var best: Vector = @splat(0);
    var cur: [K]u32 = @splat(0);
    for (doc) |b| {
        const bits = membership[b];
        inline for (0..K) |i| {
            if ((bits & (@as(u8, 1) << i)) != 0) {
                cur[i] +|= 1;
                if (cur[i] > best[i] and best[i] < std.math.maxInt(u16)) {
                    best[i] = @intCast(@min(cur[i], std.math.maxInt(u16)));
                }
            } else {
                cur[i] = 0;
            }
        }
    }
    return best;
}

/// Prune ⟺ some class crest falls short of its forced crest: k integer
/// compares, no byte scan. Sound because a match implies ρ(d,C) ≥ g ≥ ĝ.
pub fn pruned(doc_crest: Vector, ghat_vec: Vector) bool {
    inline for (0..K) |i| {
        if (doc_crest[i] < ghat_vec[i]) return true;
    }
    return false;
}

/// Componentwise min of two forced crests — the algebra alternation folds over,
/// so multi-`-e` can never sieve by more than its weakest branch forces.
pub fn weaker(a: Vector, b: Vector) Vector {
    var out: Vector = undefined;
    inline for (0..K) |i| out[i] = @min(a[i], b[i]);
    return out;
}

/// Human label for a class index (reporting only).
pub fn className(i: usize) []const u8 {
    return @tagName(@as(Class, @enumFromInt(i)));
}
