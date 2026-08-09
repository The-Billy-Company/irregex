//! dafsa — a set of strings stored as the smallest automaton that accepts it.
//!
//! A trie shares prefixes. A DAFSA shares prefixes *and suffixes*: the hundred
//! keys ending `_test.zig` walk one shared tail rather than a hundred copies of
//! it, because two states accepting the same set of continuations are one state.
//! Built by inserting sorted keys and hash-consing each state at the moment
//! nothing can be added to it again, so the automaton is minimal at every step
//! rather than built large and minimized after.
//!
//! **The reason to reach for this over a sorted array is the ordinal.** Because
//! every state knows how many keys it accepts, the walk that answers membership
//! can count the keys that sort before the one it is walking — so `rank` is a
//! *minimal perfect hash* onto `0..count`, dense and in lexicographic order,
//! obtained from the same bytes that answer `contains`. That is what makes it a
//! table rather than a set: put the payloads in an array, index it with `rank`,
//! and no key needs storing twice. `spell` inverts it, so the structure is a
//! bijection and not a one-way hash.
//!
//! **Sorted input is required and checked.** Ascending order is what lets a
//! state be sealed the moment the next key diverges from it — the guarantee that
//! nothing will ever be added to it again — and it is also why a state's edges
//! come out in label order for free, which the register's structural equality
//! and `rank`'s counting both stand on. Daciuk et al. give a second algorithm
//! for unsorted input that clones states along the way; it is a different and
//! much larger piece of code, and a caller who sorts first does not need it. So
//! unsorted input is `error.NonCanonical`, never a wrong automaton.
//!
//! **Why not `dag.zig`.** That is this package's hash-consing substrate and it
//! looks like the right floor, but its node is `Payload` plus exactly `arity`
//! children, fixed at comptime. A DAFSA state's fan-out is whatever the keys
//! gave it — one edge or forty — so it would have to be encoded either as a
//! wasted `[256]Id` per state or as an edge list inside the payload, at which
//! point `Dag` is contributing a hash table and nothing else. What is shared
//! with it is the discipline, not the type: structural identity, and children
//! always interned before parents, so every id points strictly downward and one
//! ascending sweep can count what each state accepts.
//!
//! Prior art worth reading rather than name-dropping:
//! [Daciuk, Mihov, Watson & Watson, *Incremental Construction of Minimal Acyclic
//! Finite-State Automata*](https://doi.org/10.1162/089120100561601)
//! (Computational Linguistics 26(1), 2000) — the construction below, register
//! and all;
//! [Revuz, *Minimization of acyclic deterministic automata in linear
//! time*](https://doi.org/10.1016/0304-3975(92)90142-3) (TCS 92(1), 1992) — the
//! other road, minimizing a finished trie by height-ordered bucketing, worth
//! knowing because it is what the test oracle does by a third route;
//! [Lucchesi & Kowaltowski, *Applications of finite automata representing large
//! vocabularies*](https://doi.org/10.1002/spe.4380230103) (Softw. Pract. Exper.
//! 23(1), 1993) — where counting keys per state to get a perfect hash out of the
//! automaton comes from.

const std = @import("std");
const mix = @import("mix.zig");

/// Keys were not strictly ascending. `NonCanonical` is the taxonomy's declared
/// name for input that is not in the form a reader requires (`fault.Persist`),
/// and this is that fact about a key list rather than about a file — the
/// vocabulary is closed on purpose, so an `Unsorted` here would be a sixth
/// spelling of it. Equal neighbors land here too: a set has no duplicates, and
/// silently dropping one would make `rank`'s ordinals disagree with the caller's
/// own array.
pub const Error = error{NonCanonical};

/// The finished automaton: CSR edges, and per state the number of keys it
/// accepts.
///
/// Holds no allocator. It is a frozen artifact whose lifetime is the caller's,
/// and threading the allocator through the one call that frees it costs a word
/// per instance less than storing it — the same trade `Table` and the frozen DFA
/// tiers make.
pub const Dafsa = struct {
    /// `accepts[s]` — whether the walk may stop at `s`.
    accepts: []const bool,
    /// CSR bounds into `labels`/`targets`; `states + 1` long.
    start: []const u32,
    /// Edge labels, ascending within each state — which the construction gets for
    /// free from sorted input, and which `rank` and the register both need.
    labels: []const u8,
    targets: []const u32,
    /// `reach[s]` — how many keys are accepted from `s`. What turns the
    /// membership walk into an ordinal.
    reach: []const u32,
    /// The start state. The last one sealed, so the highest id: every edge points
    /// strictly downward.
    root: u32,
    /// The longest key, so `spell` can state its buffer requirement rather than
    /// discovering it.
    longest: u32,

    pub fn deinit(d: *const Dafsa, gpa: std.mem.Allocator) void {
        gpa.free(d.accepts);
        gpa.free(d.start);
        gpa.free(d.labels);
        gpa.free(d.targets);
        gpa.free(d.reach);
    }

    pub fn states(d: *const Dafsa) u32 {
        return @intCast(d.accepts.len);
    }

    pub fn edges(d: *const Dafsa) u32 {
        return @intCast(d.labels.len);
    }

    /// How many keys the set holds.
    pub fn count(d: *const Dafsa) u32 {
        return d.reach[d.root];
    }

    /// Follow `key`, or report where it left the automaton. Separate from `rank`
    /// because it is the cheaper walk — no counting arithmetic — and membership is
    /// the question most callers have.
    pub fn contains(d: *const Dafsa, key: []const u8) bool {
        var s = d.root;
        for (key) |c| s = d.step(s, c) orelse return false;
        return d.accepts[s];
    }

    /// The key's position in ascending order, or null if it is not a member: a
    /// minimal perfect hash onto `0..count()`.
    ///
    /// At each state the keys accepted from it are, in order, the prefix itself
    /// (when the state accepts) and then whole subtrees in label order. So every
    /// step adds what it has just stepped past, and the total is the number of
    /// keys that sort before this one.
    pub fn rank(d: *const Dafsa, key: []const u8) ?u32 {
        var s = d.root;
        var before: u32 = 0;
        for (key) |c| {
            if (d.accepts[s]) before += 1;
            var next: ?u32 = null;
            for (d.start[s]..d.start[s + 1]) |e| {
                if (d.labels[e] < c) {
                    before += d.reach[d.targets[e]];
                } else {
                    if (d.labels[e] == c) next = d.targets[e];
                    break; // labels ascend, so nothing later can match either
                }
            }
            s = next orelse return null;
        }
        return if (d.accepts[s]) before else null;
    }

    /// The `i`th key in ascending order, written into `buf`, or null when `i` is
    /// past the end. `buf` must hold `longest` bytes — the inverse of `rank`, and
    /// the reason a `rank` this structure hands out can be trusted as a bijection
    /// rather than assumed to be one.
    pub fn spell(d: *const Dafsa, i: u32, buf: []u8) ?[]const u8 {
        std.debug.assert(buf.len >= d.longest);
        if (i >= d.count()) return null;
        var s = d.root;
        var skip = i;
        var n: usize = 0;
        while (true) {
            if (d.accepts[s]) {
                if (skip == 0) return buf[0..n];
                skip -= 1;
            }
            const edge = for (d.start[s]..d.start[s + 1]) |e| {
                const held = d.reach[d.targets[e]];
                if (skip < held) break e;
                skip -= held;
            } else unreachable; // `reach[s]` counted these; the index was in range
            buf[n] = d.labels[edge];
            n += 1;
            s = d.targets[edge];
        }
    }

    fn step(d: *const Dafsa, s: u32, c: u8) ?u32 {
        for (d.start[s]..d.start[s + 1]) |e| {
            if (d.labels[e] == c) return d.targets[e];
            if (d.labels[e] > c) return null; // labels ascend
        }
        return null;
    }
};

/// One edge of a state still being built.
const Edge = struct { label: u8, target: u32 };

/// A state on the path of the key most recently added — the only states that can
/// still grow, and therefore the only ones not yet sealed.
const Open = struct {
    /// The label on the edge from its parent. Unread for the root.
    label: u8,
    accepts: bool,
    edges: std.ArrayList(Edge),
};

const KeyCtx = mix.SliceCtx(u64);
const Register = std.HashMap([]const u64, u32, KeyCtx, std.hash_map.default_max_load_percentage);

/// Build the minimal automaton over `keys`, which must be strictly ascending.
///
/// The construction holds one open path — the states along the key just added —
/// and seals a state the moment the next key proves nothing more will be added
/// to it. Sealing is a lookup in the register: an equivalent state already
/// exists, or this one becomes canonical. Since sealing runs deepest-first, every
/// state is sealed only after its children, and the minimality argument is
/// Daciuk's: a state is registered only when it is complete, and never twice.
pub fn build(
    gpa: std.mem.Allocator,
    keys: []const []const u8,
) (Error || std.mem.Allocator.Error)!Dafsa {
    var b = try Build.init(gpa);
    defer b.deinit();

    var longest: u32 = 0;
    for (keys, 0..) |key, i| {
        if (i > 0 and !std.mem.lessThan(u8, keys[i - 1], key)) return error.NonCanonical;
        longest = @max(longest, @as(u32, @intCast(key.len)));

        const shared = if (i == 0) 0 else common(keys[i - 1], key);
        // Everything below the shared prefix can no longer grow: the keys ascend,
        // so no later key will pass back through it.
        try b.sealBelow(shared);
        for (key[shared..]) |c| try b.open(c);
        b.path.items[b.path.items.len - 1].accepts = true;
    }
    return try b.finish(longest);
}

fn common(a: []const u8, b: []const u8) usize {
    const n = @min(a.len, b.len);
    for (0..n) |i| if (a[i] != b[i]) return i;
    return n;
}

/// The construction's mutable half: the frozen arrays as they fill, the register
/// of sealed states, and the open path.
const Build = struct {
    gpa: std.mem.Allocator,
    accepts: std.ArrayList(bool) = .empty,
    start: std.ArrayList(u32) = .empty,
    labels: std.ArrayList(u8) = .empty,
    targets: std.ArrayList(u32) = .empty,
    register: Register,
    /// `path[0]` is the root and `path[i]` the state reached by the previous
    /// key's `i`th byte, so its length is that key's length plus one.
    path: std.ArrayList(Open) = .empty,
    /// Scratch for the structural key, so sealing a state does not allocate one.
    key: std.ArrayList(u64) = .empty,

    fn init(gpa: std.mem.Allocator) std.mem.Allocator.Error!Build {
        var b: Build = .{ .gpa = gpa, .register = Register.init(gpa) };
        errdefer b.deinit();
        try b.path.append(gpa, .{ .label = 0, .accepts = false, .edges = .empty });
        return b;
    }

    fn deinit(b: *Build) void {
        b.accepts.deinit(b.gpa);
        b.start.deinit(b.gpa);
        b.labels.deinit(b.gpa);
        b.targets.deinit(b.gpa);
        var it = b.register.keyIterator();
        while (it.next()) |k| b.gpa.free(k.*);
        b.register.deinit();
        for (b.path.items) |*node| node.edges.deinit(b.gpa);
        b.path.deinit(b.gpa);
        b.key.deinit(b.gpa);
    }

    /// Extend the open path by one byte.
    fn open(b: *Build, c: u8) std.mem.Allocator.Error!void {
        try b.path.append(b.gpa, .{ .label = c, .accepts = false, .edges = .empty });
    }

    /// Seal every open state deeper than `depth`, wiring each into its parent.
    fn sealBelow(b: *Build, depth: usize) std.mem.Allocator.Error!void {
        while (b.path.items.len > depth + 1) {
            var node = b.path.pop().?;
            defer node.edges.deinit(b.gpa);
            const id = try b.seal(&node);
            const parent = &b.path.items[b.path.items.len - 1];
            // Ascending keys mean ascending labels here, which is the order
            // `rank` counts in and the register compares on.
            std.debug.assert(parent.edges.items.len == 0 or
                parent.edges.items[parent.edges.items.len - 1].label < node.label);
            try parent.edges.append(b.gpa, .{ .label = node.label, .target = id });
        }
    }

    /// The canonical id of a completed state: an equivalent one if the register
    /// holds it, otherwise this one, appended and registered.
    fn seal(b: *Build, node: *const Open) std.mem.Allocator.Error!u32 {
        b.key.clearRetainingCapacity();
        try b.key.append(b.gpa, @intFromBool(node.accepts));
        for (node.edges.items) |e|
            try b.key.append(b.gpa, (@as(u64, e.label) << 32) | e.target);
        if (b.register.get(b.key.items)) |id| return id;

        const id: u32 = @intCast(b.accepts.items.len);
        try b.start.append(b.gpa, @intCast(b.labels.items.len));
        try b.accepts.append(b.gpa, node.accepts);
        for (node.edges.items) |e| {
            std.debug.assert(e.target < id); // children sealed first; ids point down
            try b.labels.append(b.gpa, e.label);
            try b.targets.append(b.gpa, e.target);
        }
        const owned = try b.gpa.dupe(u64, b.key.items);
        errdefer b.gpa.free(owned);
        try b.register.put(owned, id);
        return id;
    }

    /// Seal the whole remaining path, close the CSR, and count what each state
    /// accepts.
    fn finish(b: *Build, longest: u32) std.mem.Allocator.Error!Dafsa {
        try b.sealBelow(0);
        var root_node = b.path.pop().?;
        defer root_node.edges.deinit(b.gpa);
        const root = try b.seal(&root_node);
        try b.start.append(b.gpa, @intCast(b.labels.items.len));

        // One ascending sweep: every edge points at a lower id, so a state's
        // children are counted before it is.
        const reach = try b.gpa.alloc(u32, b.accepts.items.len);
        errdefer b.gpa.free(reach);
        for (0..reach.len) |s| {
            var held: u32 = @intFromBool(b.accepts.items[s]);
            for (b.start.items[s]..b.start.items[s + 1]) |e|
                held += reach[b.targets.items[e]];
            reach[s] = held;
        }

        // Handed over one at a time with their own unwinds: a struct literal of
        // five fallible calls leaks the ones that already succeeded.
        const accepts = try b.accepts.toOwnedSlice(b.gpa);
        errdefer b.gpa.free(accepts);
        const start = try b.start.toOwnedSlice(b.gpa);
        errdefer b.gpa.free(start);
        const labels = try b.labels.toOwnedSlice(b.gpa);
        errdefer b.gpa.free(labels);
        const targets = try b.targets.toOwnedSlice(b.gpa);
        errdefer b.gpa.free(targets);

        return .{
            .accepts = accepts,
            .start = start,
            .labels = labels,
            .targets = targets,
            .reach = reach,
            .root = root,
            .longest = longest,
        };
    }
};
