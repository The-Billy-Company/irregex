//! minterm — the coarsest partition of a scalar line that a family of sets
//! cannot tell apart.
//!
//! Hand it a family of sets over some scalar type — character classes, token
//! predicates, guard conditions — and it cuts the whole line into blocks no
//! member of the family splits, then says which blocks each set holds. Every
//! membership question over the family collapses into one table lookup: "does
//! set `p` hold at scalar `x`" becomes "is `x`'s block in `p`'s row", so a
//! consumer that asked the family `n` questions per input now asks the partition
//! one, and the family's structure is paid for once instead of per scalar.
//!
//! The blocks are the family's **minterms**: the atoms of the Boolean algebra
//! the sets generate. `{\w, {X}}` has three — `{X}`, `\w∖{X}`, and everything
//! else — no matter that `\w` is 748 disjoint Unicode ranges, because a minterm
//! is identified by *which sets cover it*, not by how many intervals it took.
//!
//! **One sweep, not pairwise intersection.** The textbook construction
//! intersects every subset of the family and costs `O(2^n)`. Instead every set's
//! endpoints become open/close events on one line, sorted once; between two
//! consecutive endpoints the covering set is constant, so each gap is an atom
//! whose label is the live set of sets. Atoms sharing a label are the same
//! minterm — that label *is* the minterm's identity — so the partition comes out
//! minimal by construction rather than minimized afterwards, at `O(B log B)` in
//! the number of endpoints.
//!
//! **What a caller must decide, and therefore states as a type.** The scalar
//! type and the top of the space, because a partition of `[0, 0x10FFFF]` and one
//! of `[0, maxInt(u21)]` differ by a block of unencodable scalars that a consumer
//! would then have to lower; and the ceiling on distinct sets, because a set's
//! membership in a minterm's label is one bit of a fixed-width signature, and
//! how wide that word is decides where "pathological, decline it" begins. Both
//! ceilings refuse rather than truncate.
//!
//! Prior art, read rather than name-dropped: [van Noord & Gerdemann, *Finite
//! State Transducers with Predicates and
//! Identities*](https://doi.org/10.1023/A:1011491702637) (Grammars 4(3), 2001) —
//! automata over predicates instead of symbols, where the partition idea comes
//! from; [Veanes, de Halleux & Tillmann, *Rex: Symbolic Regular Expression
//! Explorer*](https://doi.org/10.1109/ICST.2010.15) (ICST 2010) and [D'Antoni &
//! Veanes, *Minimization of Symbolic
//! Automata*](https://doi.org/10.1145/2535838.2535849) (POPL 2014) — `MinTerm`
//! generation for symbolic finite automata, the same partition computed by
//! solver calls over an arbitrary predicate algebra rather than by a sweep,
//! which is what you need when the predicates are not intervals and what you do
//! not need when they are.

const std = @import("std");
const mix = @import("mix.zig");

/// Both ceilings, refused rather than truncated: more distinct sets than the
/// signature word holds, or more minterms than a `Mint` can name.
///
/// One member for both, because that is the fact and the two checks are only
/// where it was noticed — `Oversized` is the taxonomy's declared name for "what
/// this would need exceeds what can hold or address it", and `sais` already
/// returns it from this same floor for the same reason. Naming each bounds check
/// would be three spellings of one fact, which is what the closed vocabulary
/// exists to prevent. A partition this large is a cost decision at the
/// consumer's boundary, not arithmetic that went wrong here.
pub const Error = error{Oversized};

/// The minterm calculus over `[0, top]` in `Scalar`, for at most `capacity`
/// distinct sets.
pub fn Space(comptime Scalar: type, comptime top: Scalar, comptime capacity: u16) type {
    comptime {
        const info = @typeInfo(Scalar);
        if (info != .int or info.int.signedness != .unsigned) @compileError(
            "a scalar line is indexed by an unsigned integer; got " ++ @typeName(Scalar),
        );
        if (capacity == 0) @compileError("a family of at most zero sets has one minterm and no questions");
    }
    return struct {
        /// An inclusive range `[lo, hi]`. Inclusive because the top of the space
        /// is a legal member, and a half-open upper bound at `maxInt` is not
        /// representable.
        pub const Range = [2]Scalar;

        /// A set's index in the family, handed out by `intern`.
        pub const Slot = u16;

        /// A minterm's index in the partition.
        pub const Mint = u16;

        /// The declared ceilings, readable by a consumer deciding whether to
        /// route a problem here at all.
        pub const sets_max: u16 = capacity;
        pub const ceiling: Scalar = top;

        /// One wider than `Scalar`, so a range's exclusive end (`hi + 1`, which
        /// is `top + 1` for a range touching the ceiling) cannot wrap. The sweep
        /// runs in this type and narrows only when it emits an atom.
        const Pos = std.meta.Int(.unsigned, @bitSizeOf(Scalar) + 1);
        const beyond: Pos = @as(Pos, top) + 1;
        const words: usize = (@as(usize, capacity) + 63) / 64;

        /// A set's endpoint on the line. `open` distinguishes the two, and ties
        /// at a shared position open before they close so a set that starts
        /// exactly where another ends does not produce an empty atom.
        const Event = struct { pos: Pos, set: Slot, open: bool };

        fn earlier(_: void, a: Event, b: Event) bool {
            if (a.pos != b.pos) return a.pos < b.pos;
            return @intFromBool(a.open) > @intFromBool(b.open);
        }

        /// A range set, and a minterm's label, both keyed as `u64` words: a
        /// `Range` is two integers with padding bits nobody wrote, and hashing
        /// those would hand back two ids for one value.
        const Keyed = std.HashMap([]const u64, u16, mix.SliceCtx(u64), std.hash_map.default_max_load_percentage);

        /// The finished partition: a sorted, gapless, disjoint cover of
        /// `[0, top]`, plus which minterms each set holds.
        ///
        /// Holds no allocator, like every other frozen artifact on this floor —
        /// it is the caller's lifetime, and threading the allocator through the
        /// one call that frees it costs a word per instance less than storing it.
        pub const Partition = struct {
            /// The cover, ascending. Several atoms may share a minterm: `\w` is
            /// 748 disjoint ranges and one minterm when it is the only set.
            atoms: []const Range,
            /// `owner[i]` — which minterm atom `i` belongs to.
            owner: []const Mint,
            /// How many minterms the partition has.
            count: Mint,
            /// How many sets were interned.
            sets: Slot,
            /// `membership[set * count + mint]`. Read it through `contains`.
            membership: []const bool,

            pub fn deinit(p: *const Partition, gpa: std.mem.Allocator) void {
                gpa.free(p.atoms);
                gpa.free(p.owner);
                gpa.free(p.membership);
            }

            /// Does `set` hold on `mint`? The whole interface a consumer needs:
            /// a transition becomes a bitmask test, never a walk.
            pub fn contains(p: *const Partition, set: Slot, mint: Mint) bool {
                return p.membership[@as(usize, set) * p.count + mint];
            }

            /// The scalar ranges belonging to minterm `m`, ascending and
            /// coalesced. Caller owns the returned slice. For a consumer that has
            /// to lower a minterm back into the scalar encoding — anything else
            /// should be reading `contains`.
            pub fn rangesOf(
                p: *const Partition,
                gpa: std.mem.Allocator,
                m: Mint,
            ) std.mem.Allocator.Error![]Range {
                var out: std.ArrayList(Range) = .empty;
                errdefer out.deinit(gpa);
                for (p.atoms, p.owner) |r, o| {
                    if (o != m) continue;
                    // Atoms ascend, so a run of this minterm's atoms that happens
                    // to be contiguous fuses instead of paying a second
                    // decomposition downstream.
                    if (out.items.len > 0 and @as(Pos, out.items[out.items.len - 1][1]) + 1 == r[0]) {
                        out.items[out.items.len - 1][1] = r[1];
                    } else try out.append(gpa, r);
                }
                return out.toOwnedSlice(gpa);
            }
        };

        /// Accumulates the family, deduplicating by content, and hands out the
        /// slot each set occupies in every minterm's label. One instance per
        /// partition; `finish` turns it into the `Partition`.
        pub const Builder = struct {
            gpa: std.mem.Allocator,
            /// Owned; `ranges[s]` is set `s`.
            ranges: std.ArrayList([]Range) = .empty,
            /// Content key → slot. Owns its keys.
            index: Keyed,
            key: std.ArrayList(u64) = .empty,

            pub fn init(gpa: std.mem.Allocator) Builder {
                return .{ .gpa = gpa, .index = Keyed.init(gpa) };
            }

            pub fn deinit(b: *Builder) void {
                for (b.ranges.items) |r| b.gpa.free(r);
                b.ranges.deinit(b.gpa);
                b.key.deinit(b.gpa);
                var it = b.index.keyIterator();
                while (it.next()) |k| b.gpa.free(k.*);
                b.index.deinit();
            }

            /// Intern a set given as sorted, disjoint ranges; return its slot.
            /// Identical sets collapse — the whole reason a class repeated eight
            /// times by a bounded repetition costs one set rather than eight.
            pub fn intern(
                b: *Builder,
                ranges: []const Range,
            ) (Error || std.mem.Allocator.Error)!Slot {
                b.key.clearRetainingCapacity();
                for (ranges) |r| try b.key.append(b.gpa, pack(r));
                if (b.index.get(b.key.items)) |s| return @intCast(s);
                if (b.ranges.items.len >= capacity) return error.Oversized;

                const key = try b.gpa.dupe(u64, b.key.items);
                errdefer b.gpa.free(key);
                const owned = try b.gpa.dupe(Range, ranges);
                errdefer b.gpa.free(owned);
                const slot: Slot = @intCast(b.ranges.items.len);
                try b.ranges.append(b.gpa, owned);
                try b.index.put(key, slot);
                return slot;
            }

            /// Sweep every interned set's endpoints once, cut the line at each,
            /// and label every resulting atom by the sets covering it.
            pub fn finish(b: *Builder) (Error || std.mem.Allocator.Error)!Partition {
                const gpa = b.gpa;
                const sets: Slot = @intCast(b.ranges.items.len);

                var events: std.ArrayList(Event) = .empty;
                defer events.deinit(gpa);
                for (b.ranges.items, 0..) |set, s| for (set) |r| {
                    try events.append(gpa, .{ .pos = r[0], .set = @intCast(s), .open = true });
                    try events.append(gpa, .{ .pos = @as(Pos, r[1]) + 1, .set = @intCast(s), .open = false });
                };
                std.mem.sort(Event, events.items, {}, earlier);

                var atoms: std.ArrayList(Range) = .empty;
                errdefer atoms.deinit(gpa);
                var owner: std.ArrayList(Mint) = .empty;
                errdefer owner.deinit(gpa);

                var seen = Keyed.init(gpa);
                defer {
                    var it = seen.keyIterator();
                    while (it.next()) |k| gpa.free(k.*);
                    seen.deinit();
                }
                var labels: std.ArrayList([]const u64) = .empty; // borrowed from `seen`'s keys
                defer labels.deinit(gpa);

                var active = [_]u64{0} ** words;
                var cursor: Pos = 0;
                var i: usize = 0;
                while (cursor <= top) {
                    // Everything strictly before the next endpoint shares a label.
                    const next: Pos = if (i < events.items.len) events.items[i].pos else beyond;
                    if (next > cursor) {
                        const hi: Pos = @min(next - 1, @as(Pos, top));
                        const id = try label(gpa, &seen, &labels, &active);
                        try atoms.append(gpa, .{ @intCast(cursor), @intCast(hi) });
                        try owner.append(gpa, id);
                        cursor = hi + 1;
                        if (cursor > top) break;
                    }
                    while (i < events.items.len and events.items[i].pos == next) : (i += 1) {
                        const e = events.items[i];
                        const bit = @as(u64, 1) << @intCast(e.set % 64);
                        if (e.open) active[e.set / 64] |= bit else active[e.set / 64] &= ~bit;
                    }
                }

                const count: Mint = @intCast(labels.items.len);
                const membership = try gpa.alloc(bool, @as(usize, sets) * count);
                errdefer gpa.free(membership);
                @memset(membership, false);
                for (labels.items, 0..) |sig, m| {
                    var s: Slot = 0;
                    while (s < sets) : (s += 1) {
                        if (sig[s / 64] & (@as(u64, 1) << @intCast(s % 64)) != 0)
                            membership[@as(usize, s) * count + m] = true;
                    }
                }
                return .{
                    .atoms = try atoms.toOwnedSlice(gpa),
                    .owner = try owner.toOwnedSlice(gpa),
                    .count = count,
                    .sets = sets,
                    .membership = membership,
                };
            }
        };

        /// A range as one word every bit of which was written. Both endpoints fit
        /// in 32 bits because `Scalar` is at most that wide wherever this is
        /// reached; a wider scalar keys on two words instead.
        fn pack(r: Range) u64 {
            if (@bitSizeOf(Scalar) <= 32) return (@as(u64, r[0]) << 32) | @as(u64, r[1]);
            @compileError("a scalar wider than 32 bits needs two key words per range");
        }

        /// Intern one atom's label, returning its minterm id.
        fn label(
            gpa: std.mem.Allocator,
            seen: *Keyed,
            labels: *std.ArrayList([]const u64),
            active: *const [words]u64,
        ) (Error || std.mem.Allocator.Error)!Mint {
            if (seen.get(active)) |id| return @intCast(id);
            if (labels.items.len > std.math.maxInt(Mint)) return error.Oversized;
            const key = try gpa.dupe(u64, active);
            errdefer gpa.free(key);
            const id: Mint = @intCast(labels.items.len);
            try seen.put(key, id);
            try labels.append(gpa, key);
            return id;
        }
    };
}
