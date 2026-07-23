// MONOLITHIC: Crest's document signature, query calculus, and parser co-maintain one soundness proof.
//! Crest — the forced-class-run necessary condition (research/crest/PROOF.md).
//!
//! The contiguity bound the trigram index concedes: a literal-free
//! class-repetition pattern (`[0-9a-f]{8}`, `[0-9]{6}`) extracts no required
//! substring, so every substring-presence prefilter degenerates to a full scan
//! (the Certificate's `regex-classcount` hole, cand% = 100%). Crest prunes by a
//! DIFFERENT sound necessary condition:
//!
//!   • per document d, the CREST VECTOR ρ(d) ∈ ℕ^k — the length of the longest
//!     run of consecutive bytes in each class of a fixed k-class lattice — one
//!     O(|d|) pass, k small ints;
//!   • per query R, the FORCED CREST ĝ(R) ≤ min_{w∈L(R)} ρ(w) — a sound lower
//!     bound extracted from the pattern AST by a min-of-max prefix/suffix/best
//!     run algebra (`Profile`);
//!   • THE SIEVE: R can match inside d only if ρ(d) ≥ ĝ(R) componentwise, so
//!     `∃C: ρ(d,C) < ĝ(R,C)` prunes d — k integer compares, no byte scan,
//!     provably no false negatives (Sieve Theorem, PROOF.md §2).
//!
//! This module is the pure kernel — no I/O, no allocation, no engine dep. The
//! persisted per-doc table lives in `corpus/index/crest/sidecar.zig`; the read-elision
//! wiring in `surface/exec/cold/engine/{serial,parallel}.zig`; the production proof
//! harness in `bench/crest/`.
//!
//! SOUNDNESS POSTURE (everything rounds DOWN):
//!   • any construct `ghat` cannot certify contributes nothing (or zeroes the
//!     whole vector) — under-pruning is the only failure mode;
//!   • caseless queries return 0⃗ (the fold changes byte membership);
//!   • Unicode mode (rg default) keeps only certifications that are exact over
//!     UTF-8 bytes: an explicit class certifies iff all its members are ASCII
//!     (codepoint ≡ byte), while `\d`/`\w`/`\s` — codepoint classes with
//!     non-ASCII members — force nothing (the Alphabet Contract, PROOF.md §3.6);
//!   • all quantities saturate at `maxInt(u16)`; saturation is monotone on both
//!     sides of the compare, so it never manufactures a prune.

const std = @import("std");

/// The fixed class lattice. Order is load-bearing: a crest vector is a k-tuple
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

/// `membership[b]` bit `1<<i` is set ⟺ byte b ∈ class i; Crest and atom
/// certification share this comptime source of truth.
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

/// Pattern semantics that alter byte membership; callers pass the engine's
/// already-resolved flags (post smart-case).
pub const Opts = struct {
    /// Unicode `\d`/`\w`/`\s` force nothing; explicit ASCII remains byte-exact.
    unicode: bool = true,
    /// `-i` (or resolved `-S`): the fold changes byte membership ⇒ decline all.
    caseless: bool = false,
};

/// Return ĝ(R); caseless, unsupported, or trailing garbage yields 0⃗.
pub fn ghat(pattern: []const u8, opts: Opts) Vector {
    if (opts.caseless) return zero_vector;
    var p = Parser{ .s = pattern, .unicode = opts.unicode };
    const prof = p.parseAll() catch Profile.unknown();
    return prof.F;
}

/// Multi-`-e` means alternation: componentwise min, or 0⃗ for no patterns.
pub fn ghatMany(patterns: []const []const u8, opts: Opts) Vector {
    if (patterns.len == 0) return zero_vector;
    var out = ghat(patterns[0], opts);
    for (patterns[1..]) |p| {
        const v = ghat(p, opts);
        inline for (0..K) |i| out[i] = @min(out[i], v[i]);
    }
    return out;
}

/// Human label for a class index (reporting only).
pub fn className(i: usize) []const u8 {
    return @tagName(@as(Class, @enumFromInt(i)));
}

// ─────────────────────────────────────────────────────────────────────────────
// Forced-crest calculus (PROOF.md §3): numeric fields are sound lower bounds;
// `only_c_cert` is one-sided. This is max-subarray prefix/suffix/best inverted
// for adversarial minima, entirely in the document's saturated u16 domain.
// ─────────────────────────────────────────────────────────────────────────────

fn satAdd(a: u16, b: u16) u16 {
    const sum: u32 = @as(u32, a) + @as(u32, b);
    return @intCast(@min(sum, std.math.maxInt(u16)));
}

pub const Profile = struct {
    F: Vector, // forced longest run:  F ≤ min_{w∈L} ρ(w,C)
    P: Vector, // forced leading run
    S: Vector, // forced trailing run
    min_len: u16, // forced minimum word length (saturating)
    only_c_cert: [K]bool, // true ⇒ every w∈L is composed solely of class-C bytes

    /// Language {ε}: the concatenation identity, certified for every class.
    pub fn epsilon() Profile {
        return .{ .F = @splat(0), .P = @splat(0), .S = @splat(0), .min_len = 0, .only_c_cert = @splat(true) };
    }

    /// No usable semantics: numerically harmless and never licenses a seam.
    pub fn unknown() Profile {
        return .{ .F = @splat(0), .P = @splat(0), .S = @splat(0), .min_len = 0, .only_c_cert = @splat(false) };
    }

    /// One mandatory unit from `members`. It certifies C iff every allowed byte
    /// is in C; an uncertifiable Unicode codepoint atom forces length only.
    fn atom(members: *const [256]bool, certifiable: bool) Profile {
        var p: Profile = .{ .F = @splat(0), .P = @splat(0), .S = @splat(0), .min_len = 1, .only_c_cert = @splat(false) };
        if (!certifiable) return p;
        inline for (0..K) |i| {
            var all = true;
            for (0..256) |b| {
                if (members[b] and (membership[b] & (@as(u8, 1) << i)) == 0) {
                    all = false;
                    break;
                }
            }
            if (all) {
                p.F[i] = 1;
                p.P[i] = 1;
                p.S[i] = 1;
                p.only_c_cert[i] = true;
            }
        }
        return p;
    }

    /// E₁·E₂: S₁+P₂ is the only seam term; certificates alone license extension.
    fn concat(a: Profile, b: Profile) Profile {
        var r: Profile = .{ .F = undefined, .P = undefined, .S = undefined, .min_len = satAdd(a.min_len, b.min_len), .only_c_cert = undefined };
        inline for (0..K) |i| {
            const straddle = satAdd(a.S[i], b.P[i]);
            r.F[i] = @max(@max(a.F[i], b.F[i]), straddle);
            r.P[i] = if (a.only_c_cert[i]) satAdd(a.min_len, b.P[i]) else a.P[i];
            r.S[i] = if (b.only_c_cert[i]) satAdd(b.min_len, a.S[i]) else b.S[i];
            r.only_c_cert[i] = a.only_c_cert[i] and b.only_c_cert[i];
        }
        return r;
    }

    /// Alternation E₁|E₂ — the adversary picks the branch minimizing each field.
    fn alt(a: Profile, b: Profile) Profile {
        var r: Profile = .{ .F = undefined, .P = undefined, .S = undefined, .min_len = @min(a.min_len, b.min_len), .only_c_cert = undefined };
        inline for (0..K) |i| {
            r.F[i] = @min(a.F[i], b.F[i]);
            r.P[i] = @min(a.P[i], b.P[i]);
            r.S[i] = @min(a.S[i], b.S[i]);
            r.only_c_cert[i] = a.only_c_cert[i] and b.only_c_cert[i];
        }
        return r;
    }

    fn concatPower(p: Profile, count: u32) Profile {
        var n = count;
        var out = Profile.epsilon();
        var base = p;
        while (n != 0) : (n >>= 1) {
            if ((n & 1) != 0) out = concat(out, base);
            if (n > 1) base = concat(base, base);
        }
        return out;
    }

    /// Numeric bounds use mandatory copies; the certificate covers all copies.
    fn repeat(p: Profile, lower: u32, upper: ?u32) Profile {
        std.debug.assert(upper == null or upper.? >= lower);
        var out = concatPower(p, lower);
        const can_emit_copy = upper == null or upper.? > 0;
        inline for (0..K) |i| out.only_c_cert[i] = !can_emit_copy or p.only_c_cert[i];
        return out;
    }
};

const ParseError = error{Unsupported};

const Parser = struct {
    s: []const u8,
    unicode: bool,
    i: usize = 0,

    fn peek(self: *const Parser) u8 {
        return if (self.i < self.s.len) self.s[self.i] else 0;
    }

    fn parseAll(self: *Parser) ParseError!Profile {
        const p = try self.alternation();
        if (self.i != self.s.len) return error.Unsupported;
        return p;
    }

    fn alternation(self: *Parser) ParseError!Profile {
        var left = try self.concatenation();
        while (self.peek() == '|') {
            self.i += 1;
            left = Profile.alt(left, try self.concatenation());
        }
        return left;
    }

    fn concatenation(self: *Parser) ParseError!Profile {
        var out = Profile.epsilon();
        while (self.i < self.s.len and self.peek() != '|' and self.peek() != ')') {
            out = Profile.concat(out, try self.quantified());
        }
        return out;
    }

    fn quantified(self: *Parser) ParseError!Profile {
        const base = try self.atom();
        switch (self.peek()) {
            '*' => {
                self.i += 1;
                return Profile.repeat(base, 0, null);
            },
            '?' => {
                self.i += 1;
                return Profile.repeat(base, 0, 1);
            },
            '+' => {
                self.i += 1;
                return Profile.repeat(base, 1, null);
            },
            '{' => return self.counted(base),
            else => return base,
        }
    }

    /// `{n}` / `{n,}` / `{n,m}`. Exponentiation by squaring makes the full u32
    /// range cheap; malformed bounds decline the whole Crest analysis.
    fn counted(self: *Parser, base: Profile) ParseError!Profile {
        const close = std.mem.indexOfScalarPos(u8, self.s, self.i, '}') orelse return error.Unsupported;
        const body = self.s[self.i + 1 .. close];
        self.i = close + 1;
        const comma = std.mem.indexOfScalar(u8, body, ',');
        if (comma) |c| {
            if (std.mem.indexOfScalarPos(u8, body, c + 1, ',') != null) return error.Unsupported;
            const lo = try parseCount(body[0..c]);
            const hi = if (body[c + 1 ..].len == 0) null else try parseCount(body[c + 1 ..]);
            if (hi) |n| if (n < lo) return error.Unsupported;
            return Profile.repeat(base, lo, hi);
        }
        const count = try parseCount(body);
        return Profile.repeat(base, count, count);
    }

    fn parseCount(s: []const u8) ParseError!u32 {
        if (s.len == 0) return error.Unsupported;
        for (s) |c| if (!isDigit(c)) return error.Unsupported;
        return std.fmt.parseInt(u32, s, 10) catch error.Unsupported;
    }

    fn atom(self: *Parser) ParseError!Profile {
        const c = self.peek();
        switch (c) {
            '(' => {
                self.i += 1;
                if (self.i + 1 < self.s.len and self.s[self.i] == '?' and self.s[self.i + 1] == ':') {
                    self.i += 2; // non-capturing
                } else if (self.peek() == '?') {
                    return error.Unsupported; // lookaround / named / inline flags
                }
                const inner = try self.alternation();
                if (self.peek() != ')') return error.Unsupported;
                self.i += 1;
                return inner;
            },
            '[' => return self.charClass(),
            '^', '$' => {
                self.i += 1;
                return Profile.epsilon();
            },
            '\\' => {
                self.i += 1;
                var m: [256]bool = @splat(false);
                switch (try self.escapeMembers(&m)) {
                    .zero_width => return Profile.epsilon(),
                    .certifiable => return Profile.atom(&m, true),
                    .opaque_unit => return Profile.atom(&m, false),
                }
            },
            '.' => {
                self.i += 1;
                // any byte/codepoint except \n — never all-in an ASCII class.
                return Profile.atom(&dot_members, false);
            },
            ')', '|', '*', '+', '?', '{', 0 => return error.Unsupported,
            else => {
                self.i += 1;
                if (c >= 0x80) return error.Unsupported; // raw non-ASCII: codepoint semantics
                var m: [256]bool = @splat(false);
                m[c] = true;
                return Profile.atom(&m, true);
            },
        }
    }

    const EscapeKind = enum { certifiable, opaque_unit, zero_width };

    /// Resolve the escape at `self.i` (the byte after '\') into a byte-set.
    /// Fail-closed: any escape whose byte semantics we cannot pin exactly
    /// (`\p{…}`, `\x`, unknown letters) is Unsupported ⇒ ĝ = 0⃗. In Unicode
    /// mode the perl classes are CODEPOINT classes — they still occupy ≥1 byte
    /// (`opaque_unit`) but certify no ASCII class (Alphabet Contract).
    fn escapeMembers(self: *Parser, m: *[256]bool) ParseError!EscapeKind {
        if (self.i >= self.s.len) return error.Unsupported;
        const c = self.s[self.i];
        self.i += 1;
        switch (c) {
            'd', 'D', 'w', 'W', 's', 'S' => {
                if (self.unicode) {
                    // codepoint class: forces one unit of length, no membership.
                    return .opaque_unit;
                }
                fillPerl(c, m);
                return .certifiable;
            },
            'b', 'B' => return .zero_width,
            'n' => m['\n'] = true,
            't' => m['\t'] = true,
            'r' => m['\r'] = true,
            'f' => m[0x0C] = true,
            'v' => m[0x0B] = true,
            'a' => m[0x07] = true,
            else => {
                // Escaped metacharacter / punctuation is itself; any other
                // letter/digit escape (\x, \p, \u, \0 octal, backreference …)
                // is out — engines disagree on their exact byte semantics.
                if (isWord(c)) return error.Unsupported;
                m[c] = true;
            },
        }
        return .certifiable;
    }

    fn charClass(self: *Parser) ParseError!Profile {
        self.i += 1; // past '['
        var neg = false;
        if (self.peek() == '^') {
            neg = true;
            self.i += 1;
        }
        var m: [256]bool = @splat(false);
        var certifiable = true;
        var prev: ?u8 = null;
        var first = true;
        while (true) {
            const c = self.peek();
            if (c == 0) return error.Unsupported; // unterminated
            if (c == ']' and !first) {
                self.i += 1;
                break;
            }
            first = false;
            if (c >= 0x80) return error.Unsupported; // non-ASCII class member: codepoint semantics
            if (c == '[' and self.i + 1 < self.s.len and self.s[self.i + 1] == ':') {
                // POSIX class ([[:alpha:]]) — a misparse here would certify the
                // wrong byte set, so the whole pattern declines (ĝ = 0⃗).
                return error.Unsupported;
            }
            if (c == '\\') {
                self.i += 1;
                var em: [256]bool = @splat(false);
                switch (try self.escapeMembers(&em)) {
                    .zero_width => return error.Unsupported, // \b inside a class is backspace — decline
                    .opaque_unit => certifiable = false, // unicode perl class inside [...]
                    .certifiable => {},
                }
                for (0..256) |b| {
                    if (em[b]) m[b] = true;
                }
                // `[\(-\{]`-style ranges anchored on an escape: treating the
                // endpoints as members would certify a SUBSET of the real range
                // (a false-negative factory). Decline the pattern instead.
                if (self.peek() == '-' and self.i + 1 < self.s.len and self.s[self.i + 1] != ']')
                    return error.Unsupported;
                prev = null;
                continue;
            }
            const next = if (self.i + 1 < self.s.len) self.s[self.i + 1] else 0;
            if (c == '-' and prev != null and next != ']' and next != 0) {
                self.i += 1;
                const hi = self.peek();
                if (hi >= 0x80 or hi == '\\') return error.Unsupported; // escape as range hi: decline
                self.i += 1;
                var b: usize = prev.?;
                while (b <= hi) : (b += 1) m[b] = true;
                prev = null;
                continue;
            }
            m[c] = true;
            prev = c;
            self.i += 1;
        }
        if (neg) {
            // A negated class accepts non-ASCII codepoints (multi-byte in
            // UTF-8); the byte superset is everything outside the listed set —
            // continuation bytes included — so membership stays a superset and
            // the certification below stays exact-or-declined.
            for (0..256) |b| m[b] = !m[b];
        }
        return Profile.atom(&m, certifiable);
    }
};

/// `.` — any unit except newline. Byte superset (never certifies anyway).
const dot_members: [256]bool = blk: {
    var m: [256]bool = @splat(true);
    m['\n'] = false;
    break :blk m;
};

/// ASCII membership for `\d \w \s \D \W \S` (byte/ASCII engine mode only).
fn fillPerl(c: u8, m: *[256]bool) void {
    for (0..256) |b| {
        const byte: u8 = @intCast(b);
        m[b] = switch (c) {
            'd' => isDigit(byte),
            'w' => isWord(byte),
            's' => isSpace(byte),
            'D' => !isDigit(byte),
            'W' => !isWord(byte),
            'S' => !isSpace(byte),
            else => unreachable,
        };
    }
}
