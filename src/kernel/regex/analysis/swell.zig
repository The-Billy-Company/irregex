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
const unicode_tables = @import("../unicode/tables.zig");
const crest = @import("../../math/crest.zig");

const Node = syn.Node;
const ByteSet = syn.ByteSet;
const K = crest.K;
const Vector = crest.Vector;

pub const CompileError = std.mem.Allocator.Error || error{
    UnsupportedCrestBudget,
    UnsupportedCrestRank,
};

const Memo = std.AutoHashMap(*const Node, Basis);

/// Compile the production AST into a bounded Pareto disjunction. Overflow
/// merges the least-loss pair through `Profile.alt`, a sound weakening.
pub fn forcedRanked(
    allocator: std.mem.Allocator,
    root: *const Node,
    budget: u8,
    rank: u8,
) CompileError!crest.RankedSwell {
    if (!crest.supportsRank(rank)) return error.UnsupportedCrestRank;
    if (!crest.supportsBudget(budget)) return error.UnsupportedCrestBudget;

    var memo = Memo.init(allocator);
    defer memo.deinit();
    var basis = try visit(root, &memo);
    basis.coarsen(budget);
    return basis.swell(rank, budget);
}

fn visit(node: *const Node, memo: *Memo) std.mem.Allocator.Error!Basis {
    const Frame = struct { node: *const Node, expanded: bool = false };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(memo.allocator);
    try stack.append(memo.allocator, .{ .node = node });

    while (stack.pop()) |frame| {
        if (memo.contains(frame.node)) continue;
        if (frame.expanded) {
            try memo.put(frame.node, foldBasis(frame.node, memo));
            continue;
        }
        try stack.append(memo.allocator, .{ .node = frame.node, .expanded = true });
        switch (frame.node.*) {
            .concat, .alt => |kids| {
                try stack.append(memo.allocator, .{ .node = kids[0] });
                try stack.append(memo.allocator, .{ .node = kids[1] });
            },
            .plus, .star, .quest => |rep| try stack.append(memo.allocator, .{ .node = rep.node }),
            .capture => |group| try stack.append(memo.allocator, .{ .node = group.child }),
            else => {},
        }
    }
    return memo.get(node).?;
}

fn foldBasis(node: *const Node, memo: *const Memo) Basis {
    return switch (node.*) {
        .empty,
        .anchor_start,
        .anchor_end,
        .anchor_buf_start,
        .anchor_buf_end,
        .word,
        => Basis.one(Profile.epsilon()),
        .class => |set| Basis.one(Profile.atomByte(set)),
        .uclass => |ranges| blk: {
            const e = encoded(ranges);
            break :blk Basis.one(Profile.atomUnicode(e.set, e.min_len, e.cp_set, ranges));
        },
        .concat => |kids| Basis.concat(memo.get(kids[0]).?, memo.get(kids[1]).?),
        .alt => |kids| Basis.either(memo.get(kids[0]).?, memo.get(kids[1]).?),
        .plus => |rep| memo.get(rep.node).?,
        .star, .quest => |rep| memo.get(rep.node).?.nullable(),
        .capture => |group| memo.get(group.child).?,
    };
}

const Basis = struct {
    cells: [crest.RankedSwell.capacity]Profile = undefined,
    len: u8 = 0,

    fn one(cell: Profile) Basis {
        var out: Basis = .{};
        out.insert(cell);
        return out;
    }

    fn either(left: Basis, right: Basis) Basis {
        var out: Basis = .{};
        for (left.slice()) |cell| out.insert(cell);
        for (right.slice()) |cell| out.insert(cell);
        return out;
    }

    fn concat(left: Basis, right: Basis) Basis {
        var out: Basis = .{};
        for (left.slice()) |a| for (right.slice()) |b| out.insert(Profile.concat(a, b));
        return out;
    }

    fn nullable(self: Basis) Basis {
        var out: Basis = .{};
        for (self.slice()) |cell| out.insert(Profile.nullable(cell));
        return out;
    }

    fn slice(self: *const Basis) []const Profile {
        return self.cells[0..self.len];
    }

    fn insert(self: *Basis, candidate: Profile) void {
        var i: usize = 0;
        while (i < self.len) {
            if (self.cells[i].absorbs(candidate)) return;
            if (candidate.absorbs(self.cells[i])) {
                self.remove(i);
                continue;
            }
            i += 1;
        }
        if (self.len < self.cells.len) {
            self.cells[self.len] = candidate;
            self.len += 1;
            return;
        }

        var expanded: [crest.RankedSwell.capacity + 1]Profile = undefined;
        @memcpy(expanded[0..self.len], self.slice());
        expanded[self.len] = candidate;
        var n: usize = self.len + 1;
        mergeOne(&expanded, &n);
        self.len = 0;
        for (expanded[0..n]) |cell| self.insert(cell);
    }

    fn coarsen(self: *Basis, budget: u8) void {
        while (self.len > budget) {
            var n: usize = self.len;
            mergeOne(&self.cells, &n);
            var merged: [crest.RankedSwell.capacity]Profile = undefined;
            @memcpy(merged[0..n], self.cells[0..n]);
            self.len = 0;
            for (merged[0..n]) |cell| self.insert(cell);
        }
    }

    fn remove(self: *Basis, index: usize) void {
        self.len -= 1;
        if (index < self.len) self.cells[index] = self.cells[self.len];
    }

    fn swell(self: *const Basis, rank: u8, budget: u8) crest.RankedSwell {
        var out: crest.RankedSwell = .{ .rank = rank, .budget = budget };
        for (self.slice()) |cell| {
            const candidate = cell.requirement(rank);
            var i: usize = 0;
            while (i < out.len) {
                if (requirementAbsorbs(out.requirements[i], candidate, rank)) break;
                if (requirementAbsorbs(candidate, out.requirements[i], rank)) {
                    out.len -= 1;
                    if (i < out.len) out.requirements[i] = out.requirements[out.len];
                    continue;
                }
                i += 1;
            } else {
                out.requirements[out.len] = candidate;
                out.len += 1;
            }
        }
        return out;
    }
};

fn mergeOne(cells: []Profile, len: *usize) void {
    std.debug.assert(len.* >= 2);
    var best_i: usize = 0;
    var best_j: usize = 1;
    var best_loss = mergeLoss(cells[0], cells[1]);
    for (0..len.*) |i| for (i + 1..len.*) |j| {
        const loss = mergeLoss(cells[i], cells[j]);
        if (loss < best_loss) {
            best_i = i;
            best_j = j;
            best_loss = loss;
        }
    };
    cells[best_i] = Profile.alt(cells[best_i], cells[best_j]);
    len.* -= 1;
    if (best_j < len.*) cells[best_j] = cells[len.*];
}

fn mergeLoss(a: Profile, b: Profile) u64 {
    const envelope = Profile.alt(a, b);
    var loss = delta(a.min_len, envelope.min_len) +
        delta(b.min_len, envelope.min_len) +
        delta(a.min_cp, envelope.min_cp) +
        delta(b.min_cp, envelope.min_cp);
    inline for (0..K) |i| {
        loss += delta(a.F[i], envelope.F[i]) +
            delta(b.F[i], envelope.F[i]) +
            delta(a.P[i], envelope.P[i]) +
            delta(b.P[i], envelope.P[i]) +
            delta(a.S[i], envelope.S[i]) +
            delta(b.S[i], envelope.S[i]);
        inline for (0..crest.max_rank) |rank| {
            const column = crest.spectrumLane(i, rank);
            loss += delta(a.I[column], envelope.I[column]) + delta(b.I[column], envelope.I[column]);
        }
        loss += @intFromBool(a.only_c_cert[i] != envelope.only_c_cert[i]);
        loss += @intFromBool(b.only_c_cert[i] != envelope.only_c_cert[i]);
        loss += @intFromBool(a.break_c_cert[i] != envelope.break_c_cert[i]);
        loss += @intFromBool(b.break_c_cert[i] != envelope.break_c_cert[i]);
    }
    return loss;
}

fn delta(strong: u16, weak: u16) u64 {
    return @as(u64, strong) - weak;
}

fn requirementAbsorbs(a: crest.Requirement, b: crest.Requirement, rank: u8) bool {
    for (0..@as(usize, rank) * K) |i| if (a[i] > b[i]) return false;
    return true;
}

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
        .class => |set| Profile.atomByte(set),
        .uclass => |ranges| blk: {
            const e = encoded(ranges);
            break :blk Profile.atomUnicode(e.set, e.min_len, e.cp_set, ranges);
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

fn insertRun(runs: *[crest.max_rank]u16, run: u16) void {
    var candidate = run;
    inline for (0..crest.max_rank) |rank| {
        const displaced = @min(runs[rank], candidate);
        runs[rank] = @max(runs[rank], candidate);
        candidate = displaced;
    }
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

fn rangesSubsetOfProperty(ranges: []const [2]u21, property: crest.ExactProperty) bool {
    const allowed = unicode_tables.property(exactPropertyName(property)) orelse return false;
    for (ranges) |range| {
        var cursor: u32 = range[0];
        const hi: u32 = range[1];
        for (allowed) |candidate| {
            if (candidate[1] < cursor) continue;
            if (candidate[0] > cursor) return false;
            if (candidate[1] >= hi) {
                cursor = hi + 1;
                break;
            }
            cursor = @as(u32, candidate[1]) + 1;
        }
        if (cursor <= hi) return false;
    }
    return true;
}

fn rangesDisjointFromProperty(ranges: []const [2]u21, property: crest.ExactProperty) bool {
    const allowed = unicode_tables.property(exactPropertyName(property)) orelse return false;
    var i: usize = 0;
    var j: usize = 0;
    while (i < ranges.len and j < allowed.len) {
        if (ranges[i][1] < allowed[j][0]) {
            i += 1;
        } else if (allowed[j][1] < ranges[i][0]) {
            j += 1;
        } else return false;
    }
    return true;
}

fn exactPropertyName(property: crest.ExactProperty) []const u8 {
    return switch (property) {
        .nd => "Nd",
        .letter => "L",
        .white_space => "White_Space",
    };
}

/// A sub-expression's forced run summary (PROOF.md §3). Every numeric field is
/// a sound LOWER bound over the sub-language; `only_c_cert` is one-sided — true
/// obliges every accepted string to be class-C bytes end to end, false claims
/// nothing. Max-subarray prefix/suffix/best, inverted for adversarial minima,
/// entirely in the document's saturated u16 domain.
pub const Profile = struct {
    F: Vector, // forced longest run:  F ≤ min_{w∈L} ρ(w,C)
    I: crest.Requirement, // forced internal disjoint runs, rank-major
    P: Vector, // forced leading run
    S: Vector, // forced trailing run
    min_len: u16, // forced minimum BYTE length (saturating) — byte + scalar-closed lanes
    min_cp: u16, // forced minimum CODEPOINT length (saturating) — codepoint-run lanes only
    only_c_cert: [K]bool, // ⇒ every w∈L is composed solely of class-C bytes
    break_c_cert: [K]bool, // ⇒ every w∈L contains a proven C-breaking gap

    /// True for a codepoint-run lane — the boundary `concat` reads to pick
    /// `min_len` (bytes) or `min_cp` (codepoints) as the unit a seam extends
    /// by. Lane layout is `crest.Alphabet`'s declared order (ascii, scalar,
    /// codepoint), so this is a single threshold, not a lookup.
    fn isCodepointLane(i: usize) bool {
        return i >= 2 * crest.base_k;
    }

    /// Language {ε}: the concatenation identity, certified for every class.
    pub fn epsilon() Profile {
        return .{ .F = @splat(0), .I = @splat(0), .P = @splat(0), .S = @splat(0), .min_len = 0, .min_cp = 0, .only_c_cert = @splat(true), .break_c_cert = @splat(false) };
    }

    /// No usable semantics: numerically harmless and never licenses a seam.
    pub fn unknown() Profile {
        return .{ .F = @splat(0), .I = @splat(0), .P = @splat(0), .S = @splat(0), .min_len = 0, .min_cp = 0, .only_c_cert = @splat(false), .break_c_cert = @splat(false) };
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
        fillShared(&p, cp_set, cp_len, 2 * crest.base_k, crest.approximate_k);
        return p;
    }

    pub fn atomByte(set: ByteSet) Profile {
        var p = atom(set, 1, set, 1);
        // Exact lanes decode UCD scalars; a raw high byte is not the
        // same-valued scalar, so byte sets certify them only inside ASCII.
        if (set.count() == 0 or set.bits[2] != 0 or set.bits[3] != 0) return p;
        inline for (std.enums.values(crest.ExactProperty)) |property| {
            var subset = true;
            var disjoint = true;
            for (0..256) |byte| {
                if (set.has(@intCast(byte))) {
                    const member = crest.exactMember(property, @intCast(byte));
                    subset = subset and member;
                    disjoint = disjoint and !member;
                }
            }
            const i = crest.exactLane(property);
            if (subset) certify(&p, i, 1) else if (disjoint) p.break_c_cert[i] = true;
        }
        return p;
    }

    pub fn atomUnicode(byte_set: ByteSet, byte_len: u16, cp_set: ByteSet, ranges: []const [2]u21) Profile {
        var p = atom(byte_set, byte_len, cp_set, 1);
        inline for (std.enums.values(crest.ExactProperty)) |property| {
            const i = crest.exactLane(property);
            if (rangesSubsetOfProperty(ranges, property)) {
                certify(&p, i, 1);
            } else if (rangesDisjointFromProperty(ranges, property)) p.break_c_cert[i] = true;
        }
        return p;
    }

    fn certify(p: *Profile, i: usize, len: u16) void {
        p.F[i] = len;
        p.P[i] = len;
        p.S[i] = len;
        p.only_c_cert[i] = true;
    }

    /// Certify every lane in `[lo, hi)` whose membership bit is shared across
    /// every byte of `set`, at the given run length — `atom`'s shared work,
    /// scoped to one lane range so the byte-priced and codepoint-priced halves
    /// never read each other's set.
    fn fillShared(p: *Profile, set: ByteSet, len: u16, lo: usize, hi: usize) void {
        if (set.count() == 0) return;
        var shared: crest.Mask = std.math.maxInt(crest.Mask);
        var may_keep: crest.Mask = 0;
        for (0..256) |b| {
            if (set.has(@intCast(b))) {
                shared &= crest.membership[b];
                may_keep |= crest.membership[b];
                if (crest.isContinuation(@intCast(b))) {
                    for (2 * crest.base_k..crest.approximate_k) |i|
                        may_keep |= @as(crest.Mask, 1) << @intCast(i);
                }
            }
        }
        for (lo..hi) |i| {
            const bit = @as(crest.Mask, 1) << @intCast(i);
            if ((shared & bit) != 0) {
                p.F[i] = len;
                p.P[i] = len;
                p.S[i] = len;
                p.only_c_cert[i] = true;
            } else if (may_keep & bit == 0) p.break_c_cert[i] = true;
        }
    }

    fn absorbs(self: Profile, other: Profile) bool {
        if (self.min_len > other.min_len or self.min_cp > other.min_cp) return false;
        inline for (0..K) |i| {
            if (self.F[i] > other.F[i] or self.P[i] > other.P[i] or self.S[i] > other.S[i]) return false;
            inline for (0..crest.max_rank) |rank| {
                const column = crest.spectrumLane(i, rank);
                if (self.I[column] > other.I[column]) return false;
            }
            if (self.only_c_cert[i] and !other.only_c_cert[i]) return false;
            if (self.break_c_cert[i] and !other.break_c_cert[i]) return false;
        }
        return true;
    }

    fn requirement(self: Profile, rank: u8) crest.Requirement {
        var out = crest.zero_spectrum;
        inline for (0..K) |i| {
            out[crest.spectrumLane(i, 0)] = self.F[i];
            var runs: [crest.max_rank]u16 = undefined;
            inline for (0..crest.max_rank) |r|
                runs[r] = self.I[crest.spectrumLane(i, r)];
            if (self.break_c_cert[i]) {
                insertRun(&runs, self.P[i]);
                insertRun(&runs, self.S[i]);
            } else {
                insertRun(&runs, @max(self.P[i], self.S[i]));
            }
            for (1..@as(usize, rank)) |r|
                out[crest.spectrumLane(i, r)] = runs[r];
        }
        return out;
    }

    /// E₁·E₂: S₁+P₂ is the only seam term; certificates alone license
    /// extension, and each lane extends by ITS OWN unit — bytes for a byte or
    /// scalar-closed lane, codepoints for a codepoint-run one (§3.7c) — so a
    /// 3-byte CJK atom seams a byte lane by 3 and a codepoint lane by 1.
    pub fn concat(a: Profile, b: Profile) Profile {
        var r: Profile = .{ .F = undefined, .I = @splat(0), .P = undefined, .S = undefined, .min_len = satAdd(a.min_len, b.min_len), .min_cp = satAdd(a.min_cp, b.min_cp), .only_c_cert = undefined, .break_c_cert = undefined };
        inline for (0..K) |i| {
            const a_unit = if (isCodepointLane(i)) a.min_cp else a.min_len;
            const b_unit = if (isCodepointLane(i)) b.min_cp else b.min_len;
            r.F[i] = @max(@max(a.F[i], b.F[i]), satAdd(a.S[i], b.P[i]));
            r.P[i] = if (a.only_c_cert[i]) satAdd(a_unit, b.P[i]) else a.P[i];
            r.S[i] = if (b.only_c_cert[i]) satAdd(b_unit, a.S[i]) else b.S[i];
            r.only_c_cert[i] = a.only_c_cert[i] and b.only_c_cert[i];
            r.break_c_cert[i] = a.break_c_cert[i] or b.break_c_cert[i];

            var runs: [crest.max_rank]u16 = @splat(0);
            inline for (0..crest.max_rank) |rank| {
                insertRun(&runs, a.I[crest.spectrumLane(i, rank)]);
                insertRun(&runs, b.I[crest.spectrumLane(i, rank)]);
            }
            if (a.break_c_cert[i] and b.break_c_cert[i])
                insertRun(&runs, satAdd(a.S[i], b.P[i]));
            inline for (0..crest.max_rank) |rank|
                r.I[crest.spectrumLane(i, rank)] = runs[rank];
        }
        return r;
    }

    /// E₁|E₂ — the adversary picks the branch minimizing each field.
    pub fn alt(a: Profile, b: Profile) Profile {
        var r: Profile = .{ .F = undefined, .I = undefined, .P = undefined, .S = undefined, .min_len = @min(a.min_len, b.min_len), .min_cp = @min(a.min_cp, b.min_cp), .only_c_cert = undefined, .break_c_cert = undefined };
        inline for (0..K) |i| {
            r.F[i] = @min(a.F[i], b.F[i]);
            r.P[i] = @min(a.P[i], b.P[i]);
            r.S[i] = @min(a.S[i], b.S[i]);
            r.only_c_cert[i] = a.only_c_cert[i] and b.only_c_cert[i];
            r.break_c_cert[i] = a.break_c_cert[i] and b.break_c_cert[i];
            inline for (0..crest.max_rank) |rank| {
                const column = crest.spectrumLane(i, rank);
                r.I[column] = @min(a.I[column], b.I[column]);
            }
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
