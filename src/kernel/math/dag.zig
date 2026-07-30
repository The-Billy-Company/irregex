//! The hash-consed DAG a tree-shaped IR is folded into, so every question
//! about it costs one linear sweep instead of one recursion per asker.
//!
//! Three properties, each falling out of the same construction rule ("a node
//! may only be interned after its children are"):
//!
//!   1. **Structural equality is identity.** Two subtrees that are the same
//!      shape get the same `Id`. `a == b` replaces a recursive comparison, and
//!      common subexpressions collapse on the way in rather than being
//!      discovered by a later pass. Filliâtre & Conchon, *Type-Safe Modular
//!      Hash-Consing* (ML '06).
//!   2. **Topological order is free.** A child is interned before its parent,
//!      so `child_id < parent_id` always holds. A bottom-up analysis is
//!      therefore a forward `for` loop over a flat array — no recursion, no
//!      explicit stack, no visited set, no worklist, and no per-node revisit
//!      even when the graph shares heavily.
//!   3. **Sharing is exploitable.** `power` builds an n-fold combination in
//!      `O(log n)` distinct nodes by repeated squaring, so a bounded repetition
//!      that expands to a thousand leaves is a couple of dozen nodes to every
//!      analysis, while still lowering to the thousand-state automaton its
//!      language requires.
//!
//! Pure structure math: no regex opinion, no persistence, no I/O. The payload
//! is the caller's, and every result array is caller-owned — `../regex/ast/` is
//! the regex-shaped layer that supplies one, and is expected not to be the last.
//!
//! Storage is struct-of-arrays on purpose. The whole point of the ordering
//! invariant is that analyses become linear scans, and a linear scan over three
//! dense arrays is what a prefetcher can follow — an array of pointer-linked
//! nodes would hand back the cache misses the invariant was bought to remove.
//!
//! Prior art the shape is borrowed from, beyond hash-consing itself: BDD unique
//! tables (Brace, Rudell & Bryant, DAC '90) for the intern-on-construct
//! discipline, Click's *sea of nodes* (PLDI '95) for the value-numbered graph
//! IR, and `egg` (Willsey et al., POPL '21) for congruence as the basis of
//! rewriting. Deliberately NOT an e-graph: there is no equivalence class per
//! node and no saturation, because the consumers here need one canonical form
//! cheaply, not the space of all equivalent forms.

const std = @import("std");
const mix = @import("mix.zig");

/// A node's handle. Dense and monotone: `@intFromEnum` is the node's index in
/// every SoA array, and a child's value is always strictly less than its
/// parent's — the ordering invariant the whole module rests on.
pub const Id = enum(u32) {
    _,

    /// The absent child, for arities a node does not fill.
    pub const none: Id = @enumFromInt(std.math.maxInt(u32));

    pub inline fn index(self: Id) usize {
        return @intFromEnum(self);
    }
    pub inline fn present(self: Id) bool {
        return self != none;
    }
};

/// How many nodes the caller asked for versus how many the table actually
/// holds — the sharing the hash-cons found, which is exactly the factor by
/// which a sweep beats a recursion.
pub const Stats = struct {
    /// `intern` calls, i.e. the size of the tree that was offered.
    offered: usize = 0,
    /// Distinct nodes retained, i.e. the size of the DAG that resulted.
    distinct: usize = 0,

    /// Offered ÷ distinct. 1.0 is a pure tree; higher is denser sharing.
    pub fn sharing(self: Stats) f64 {
        if (self.distinct == 0) return 1.0;
        return @as(f64, @floatFromInt(self.offered)) / @as(f64, @floatFromInt(self.distinct));
    }
};

/// A hash-consed DAG over `Payload`-tagged nodes of at most `arity` children.
///
/// `Payload` may supply `pub fn hash(self) u64` and
/// `pub fn eql(a: @This(), b: @This()) bool`; without them the payload is
/// hashed and compared bitwise, which is correct for POD payloads and WRONG
/// for any payload holding a slice or pointer whose contents define identity —
/// such a payload must declare the pair.
pub fn Dag(comptime Payload: type, comptime arity: usize) type {
    comptime std.debug.assert(arity >= 1);

    return struct {
        const Self = @This();

        /// One node's children, `Id.none` in every slot it does not use.
        pub const Kids = [arity]Id;

        payloads: std.ArrayList(Payload) = .empty,
        kids: std.ArrayList(Kids) = .empty,
        /// Merkle digest per node: a fold of the payload's hash over the
        /// children's digests, so it names the whole subtree's shape rather
        /// than one node's. The low 64 bits index the intern table; the full
        /// 128 are what a caller compares to claim two DAGs are the same.
        digests: std.ArrayList(u128) = .empty,

        /// Open-addressed intern table. Slots hold `id + 1`; 0 is empty.
        slots: []u32 = &.{},
        stats: Stats = .{},

        pub const empty: Self = .{};

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.payloads.deinit(gpa);
            self.kids.deinit(gpa);
            self.digests.deinit(gpa);
            gpa.free(self.slots);
            self.* = .empty;
        }

        pub inline fn len(self: *const Self) usize {
            return self.payloads.items.len;
        }
        pub inline fn payload(self: *const Self, id: Id) Payload {
            return self.payloads.items[id.index()];
        }
        pub inline fn kidsOf(self: *const Self, id: Id) Kids {
            return self.kids.items[id.index()];
        }
        /// The subtree's structural name. Equal digests mean equal shape, to
        /// within a 128-bit collision — the intern table itself never relies
        /// on this, since it settles ties by full comparison.
        pub inline fn digest(self: *const Self, id: Id) u128 {
            return self.digests.items[id.index()];
        }

        fn payloadHash(p: Payload) u64 {
            if (comptime declares("hash")) return p.hash();
            // Field-wise, not byte-wise: a bitwise hash of a padded struct or
            // union reads the padding, which is undefined. `autoHash` also
            // refuses at comptime to hash through a pointer — so a payload
            // whose identity lives behind a slice cannot silently be interned
            // by address; it has to declare the pair.
            var h = std.hash.Wyhash.init(0);
            std.hash.autoHash(&h, p);
            return h.final();
        }
        fn payloadEql(a: Payload, b: Payload) bool {
            if (comptime declares("eql")) return a.eql(b);
            return std.meta.eql(a, b);
        }
        inline fn declares(comptime name: []const u8) bool {
            return switch (@typeInfo(Payload)) {
                .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(Payload, name),
                else => false,
            };
        }

        fn merkle(self: *const Self, p: Payload, kids: Kids) u128 {
            var acc: u64 = mix.fnv_offset ^ payloadHash(p);
            for (kids) |k| {
                const d: u128 = if (k.present()) self.digest(k) else 0;
                acc = (acc ^ @as(u64, @truncate(d))) *% mix.fnv_prime;
                acc = (acc ^ @as(u64, @truncate(d >> 64))) *% mix.fnv_prime;
            }
            const lo = mix.finalize(acc);
            const hi = mix.finalize(acc ^ 0x9e3779b97f4a7c15);
            return (@as(u128, hi) << 64) | lo;
        }

        /// Intern a node, returning the existing `Id` when this exact
        /// payload-and-children combination is already present.
        ///
        /// Every child must already be interned in this DAG. That is what
        /// buys the ordering invariant, so it is asserted rather than assumed.
        pub fn intern(self: *Self, gpa: std.mem.Allocator, p: Payload, kids: Kids) !Id {
            self.stats.offered += 1;
            const next: u32 = @intCast(self.len());
            for (kids) |k| std.debug.assert(!k.present() or k.index() < next);

            const dig = self.merkle(p, kids);
            if (self.slots.len * 10 < (self.len() + 1) * 14) try self.grow(gpa);

            const mask = self.slots.len - 1;
            var probe: usize = @as(usize, @truncate(dig)) & mask;
            while (self.slots[probe] != 0) : (probe = (probe + 1) & mask) {
                const cand: Id = @enumFromInt(self.slots[probe] - 1);
                const cand_kids = self.kidsOf(cand);
                if (self.digest(cand) == dig and
                    payloadEql(self.payload(cand), p) and
                    std.mem.eql(Id, &cand_kids, &kids)) return cand;
            }

            try self.payloads.append(gpa, p);
            errdefer _ = self.payloads.pop();
            try self.kids.append(gpa, kids);
            errdefer _ = self.kids.pop();
            try self.digests.append(gpa, dig);
            self.slots[probe] = next + 1;
            self.stats.distinct = self.len();
            return @enumFromInt(next);
        }

        fn grow(self: *Self, gpa: std.mem.Allocator) !void {
            const want = @max(64, self.slots.len * 2);
            const fresh = try gpa.alloc(u32, want);
            @memset(fresh, 0);
            const mask = want - 1;
            for (self.digests.items, 0..) |d, i| {
                var probe: usize = @as(usize, @truncate(d)) & mask;
                while (fresh[probe] != 0) probe = (probe + 1) & mask;
                fresh[probe] = @intCast(i + 1);
            }
            gpa.free(self.slots);
            self.slots = fresh;
        }

        // ── The calculus. Every analysis over the DAG is one of these three. ──

        /// Synthesized attributes: one value per node, computed bottom-up in a
        /// single forward sweep. `f(ctx, id, payload, kids, done)` sees only
        /// `done` — the results of strictly-lower ids — which is every child's
        /// result and nothing else, so the "children first" contract is
        /// enforced by the slice's length rather than by discipline.
        ///
        /// Each distinct node is visited exactly once no matter how many
        /// parents it has. Computing several attributes at once is not a
        /// separate operation: make `T` a struct of them, and the fourteen
        /// walks a consumer used to make become this one.
        pub fn fold(self: *const Self, gpa: std.mem.Allocator, comptime T: type, ctx: anytype, comptime f: anytype) ![]T {
            const out = try gpa.alloc(T, self.len());
            errdefer gpa.free(out);
            for (0..self.len()) |i| {
                out[i] = f(ctx, @as(Id, @enumFromInt(i)), self.payloads.items[i], self.kids.items[i], out[0..i]);
            }
            return out;
        }

        /// `fold` for an analysis that can fail — one that allocates, or that
        /// gives up on a pattern it cannot express.
        pub fn foldTry(self: *const Self, gpa: std.mem.Allocator, comptime T: type, ctx: anytype, comptime f: anytype) ![]T {
            const out = try gpa.alloc(T, self.len());
            errdefer gpa.free(out);
            for (0..self.len()) |i| {
                out[i] = try f(ctx, @as(Id, @enumFromInt(i)), self.payloads.items[i], self.kids.items[i], out[0..i]);
            }
            return out;
        }

        /// Inherited attributes: context handed down from the roots in a single
        /// reverse sweep. Where a shared node has several parents its incoming
        /// contexts are combined with `meet`, which must be commutative,
        /// associative and idempotent — a node reached two ways gets the
        /// weakest claim both parents support, never whichever arrived last.
        ///
        /// `down(ctx, id, payload, slot, here)` is the context a parent hands
        /// to the child in `slot`.
        pub fn descend(
            self: *const Self,
            gpa: std.mem.Allocator,
            comptime T: type,
            roots: []const Id,
            seed: T,
            bottom: T,
            ctx: anytype,
            comptime down: anytype,
            comptime meet: anytype,
        ) ![]T {
            const out = try gpa.alloc(T, self.len());
            errdefer gpa.free(out);
            @memset(out, bottom);
            for (roots) |r| out[r.index()] = meet(out[r.index()], seed);
            var i = self.len();
            while (i > 0) {
                i -= 1;
                const here = out[i];
                for (self.kids.items[i], 0..) |k, slot| {
                    if (!k.present()) continue;
                    const gift = down(ctx, @as(Id, @enumFromInt(i)), self.payloads.items[i], slot, here);
                    out[k.index()] = meet(out[k.index()], gift);
                }
            }
            return out;
        }

        /// How many parents each node has. One is a tree edge; more is shared
        /// structure, which is what makes a memoized sweep pay and what tells a
        /// lowering pass which fragments are worth caching.
        pub fn census(self: *const Self, gpa: std.mem.Allocator) ![]u32 {
            const out = try gpa.alloc(u32, self.len());
            @memset(out, 0);
            for (self.kids.items) |ks| {
                for (ks) |k| if (k.present()) {
                    out[k.index()] += 1;
                };
            }
            return out;
        }

        /// Which nodes a set of roots can still reach. Interning never removes
        /// anything, so a rewrite leaves its superseded nodes in place; this is
        /// how a later pass tells the live DAG from the rubble.
        pub fn live(self: *const Self, gpa: std.mem.Allocator, roots: []const Id) ![]bool {
            const out = try gpa.alloc(bool, self.len());
            @memset(out, false);
            for (roots) |r| out[r.index()] = true;
            var i = self.len();
            while (i > 0) {
                i -= 1;
                if (!out[i]) continue;
                for (self.kids.items[i]) |k| if (k.present()) {
                    out[k.index()] = true;
                };
            }
            return out;
        }

        /// `base` combined with itself `n` times, in `O(log n)` distinct nodes
        /// by repeated squaring — the identity that makes a bounded repetition
        /// cheap to analyse. `combine` must be associative for this to preserve
        /// meaning; concatenation is, so `a{1000}` becomes ~19 nodes instead of
        /// 1000 while still denoting the same language.
        ///
        /// Returns `null` for `n == 0`: the identity element is the caller's to
        /// name, since this module knows nothing about the payload's algebra.
        pub fn power(self: *Self, gpa: std.mem.Allocator, base: Id, n: usize, ctx: anytype, comptime combine: anytype) !?Id {
            if (n == 0) return null;
            var acc: ?Id = null;
            var sq = base;
            var rem = n;
            while (true) {
                if (rem & 1 == 1) acc = if (acc) |a| try combine(ctx, self, gpa, a, sq) else sq;
                rem >>= 1;
                if (rem == 0) break;
                sq = try combine(ctx, self, gpa, sq, sq);
            }
            return acc;
        }
    };
}
