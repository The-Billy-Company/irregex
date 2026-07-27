//! wavelet — a Huffman-shaped wavelet tree with entropy-compressed levels.
//!
//! The rank oracle of the codex self-index (Grossi, Gupta & Vitter, SODA
//! 2003). The tree routes each symbol down its canonical-Huffman code path,
//! storing one bitvector per internal node; `occ(c, i)` — occurrences of c in
//! the first i symbols — is one root-to-leaf descent of O(1)-time ranks, and
//! `access(i)` walks the stored bits themselves, recovering the symbol AND its
//! occ in the same descent (the LF-mapping fast path).
//!
//! Space is Σ_c freq(c)·len(c) bits — Huffman keeps that within one bit per
//! symbol of the sequence's zeroth-order entropy — and every level is then
//! offered to `rrr.Bits.adopt`, which keeps the RRR encoding wherever it
//! measures smaller. Over a BWT the levels are run-heavy, RRR prices runs at
//! ~0, and the whole tree lands near the k-th order entropy of the ORIGINAL
//! text (implicit compression boosting — Mäkinen & Navarro, SPIRE 2007).
//!
//! The alphabet is `u16` symbols in [0, sigma) — the codex feeds bytes shifted
//! +1 with sentinel 0, so σ = 257; nothing here assumes that beyond σ ≤ 4096.
//!
//! A node knows how its sequence will split before it looks at a symbol — it
//! holds every occurrence of its alphabet, so the frequency histogram already
//! says so. That single fact is what makes construction cheap twice over: a
//! level's bit coding and its partition can share one walk, and a level too big
//! to walk alone can be handed to several threads that already know where their
//! output belongs. Symbols shuttle between two n-symbol halves as the tree
//! descends rather than compacting in place, which is what leaves the shards
//! nothing to collide over. See `weave` and `Tree.buildNode`.

const std = @import("std");
const rrr = @import("rrr.zig");
const parallel = @import("../../../kernel/primitives/parallel.zig");

pub const max_sigma = 4096;

/// Canonical Huffman code table over a frequency histogram.
pub const Huff = struct {
    len: []u8, // 0 = absent symbol
    code: []u64, // MSB-first canonical codes

    pub fn bitAt(self: *const Huff, sym: u16, depth: u8) u1 {
        return @intCast((self.code[sym] >> @intCast(self.len[sym] - 1 - depth)) & 1);
    }

    pub fn deinit(self: *Huff, gpa: std.mem.Allocator) void {
        gpa.free(self.len);
        gpa.free(self.code);
    }

    /// Two-queue Huffman over the present symbols (O(σ log σ) in the sort, the
    /// merge itself linear), then canonical (len, sym)-ordered code assignment.
    pub fn build(gpa: std.mem.Allocator, freq: []const u64) !Huff {
        const sigma = freq.len;
        std.debug.assert(sigma <= max_sigma);
        var h = Huff{ .len = try gpa.alloc(u8, sigma), .code = try gpa.alloc(u64, sigma) };
        errdefer h.deinit(gpa);
        @memset(h.len, 0);
        @memset(h.code, 0);

        var order = try gpa.alloc(u16, sigma);
        defer gpa.free(order);
        var np: usize = 0;
        for (freq, 0..) |f, c| if (f > 0) {
            order[np] = @intCast(c);
            np += 1;
        };
        std.debug.assert(np >= 1);
        if (np == 1) {
            h.len[order[0]] = 1; // degenerate σ=1: one-bit code "0"
            return h;
        }
        const FreqKey = struct {
            freq: []const u64,
            fn lt(self: @This(), a: u16, b: u16) bool {
                return if (self.freq[a] != self.freq[b]) self.freq[a] < self.freq[b] else a < b;
            }
        };
        std.mem.sort(u16, order[0..np], FreqKey{ .freq = freq }, FreqKey.lt);

        const Node = struct { w: u64, l: i32, r: i32, sym: i32 };
        var nodes = try gpa.alloc(Node, 2 * np);
        defer gpa.free(nodes);
        for (order[0..np], 0..) |c, i| nodes[i] = .{ .w = freq[c], .l = -1, .r = -1, .sym = c };
        var nn = np;
        var internal = try gpa.alloc(u32, np);
        defer gpa.free(internal);
        var q1h: usize = 0; // leaf FIFO head (nodes[0..np], already sorted)
        var q2h: usize = 0;
        var q2t: usize = 0;
        var remaining = np;
        while (remaining > 1) : (remaining -= 1) {
            var picked: [2]u32 = undefined;
            for (&picked) |*p| {
                const take_leaf = q1h < np and (q2h >= q2t or nodes[q1h].w <= nodes[internal[q2h]].w);
                if (take_leaf) {
                    p.* = @intCast(q1h);
                    q1h += 1;
                } else {
                    p.* = internal[q2h];
                    q2h += 1;
                }
            }
            nodes[nn] = .{ .w = nodes[picked[0]].w + nodes[picked[1]].w, .l = @intCast(picked[0]), .r = @intCast(picked[1]), .sym = -1 };
            internal[q2t] = @intCast(nn);
            q2t += 1;
            nn += 1;
        }
        // code lengths by explicit-stack DFS from the root (= last node built)
        var stack = try gpa.alloc(struct { id: u32, d: u8 }, nn);
        defer gpa.free(stack);
        var sp: usize = 1;
        stack[0] = .{ .id = @intCast(nn - 1), .d = 0 };
        while (sp > 0) {
            sp -= 1;
            const e = stack[sp];
            const nd = nodes[e.id];
            if (nd.sym >= 0) {
                std.debug.assert(e.d >= 1 and e.d <= 63);
                h.len[@intCast(nd.sym)] = e.d;
                continue;
            }
            stack[sp] = .{ .id = @intCast(nd.l), .d = e.d + 1 };
            stack[sp + 1] = .{ .id = @intCast(nd.r), .d = e.d + 1 };
            sp += 2;
        }
        canonicalize(&h, order[0..np]);
        return h;
    }

    /// Rebuild a Huff from persisted code lengths alone: canonical codes are
    /// a pure function of the (len, sym)-ordered length sequence, so the wire
    /// format never stores the codes themselves.
    pub fn fromLengths(gpa: std.mem.Allocator, lens: []const u8) !Huff {
        var h = Huff{ .len = try gpa.dupe(u8, lens), .code = try gpa.alloc(u64, lens.len) };
        errdefer h.deinit(gpa);
        @memset(h.code, 0);
        var order = try gpa.alloc(u16, lens.len);
        defer gpa.free(order);
        var np: usize = 0;
        for (lens, 0..) |l, c| {
            if (l > 63) return error.Corrupt;
            if (l > 0) {
                order[np] = @intCast(c);
                np += 1;
            }
        }
        if (np == 0) return error.Corrupt;
        canonicalize(&h, order[0..np]);
        // Kraft equality guards a mangled length table: Σ 2^(max−len) must
        // land exactly on 2^max for a complete prefix code (σ=1 uses len 1,
        // deliberately half-full, so any sum ≤ capacity is accepted there).
        var kraft: u64 = 0;
        for (order[0..np]) |c| kraft += @as(u64, 1) << @intCast(63 - h.len[c]);
        if (np > 1 and kraft != @as(u64, 1) << 63) return error.Corrupt;
        return h;
    }

    /// Canonical (len, sym)-ordered code assignment over the present symbols.
    fn canonicalize(h: *Huff, present: []u16) void {
        const LenKey = struct {
            len: []const u8,
            fn lt(self: @This(), a: u16, b: u16) bool {
                return if (self.len[a] != self.len[b]) self.len[a] < self.len[b] else a < b;
            }
        };
        std.mem.sort(u16, present, LenKey{ .len = h.len }, LenKey.lt);
        var code: u64 = 0;
        var prev: u8 = h.len[present[0]];
        for (present[1..]) |c| {
            code += 1;
            code <<= @intCast(h.len[c] - prev);
            h.code[c] = code;
            prev = h.len[c];
        }
    }
};

/// Per-level bitvector policy — the index's space/time posture.
pub const Encoding = enum {
    /// Offer every level to RRR, keep whichever is smaller (entropy space,
    /// combinadic block decode on the rank path).
    adopt_min,
    /// Plain bitvectors everywhere (zeroth-order space, ~10ns ranks).
    plain_only,
};

/// Build-time scratch threaded down the recursion, so descending a level costs
/// no allocation of its own. `route` is rebuilt by each node and read only
/// inside that node's own pass — including by every shard of that pass, which
/// is safe because the pass never writes it — so one copy serves the whole
/// tree even when the levels are woven in parallel.
const Loom = struct {
    huff: *const Huff,
    freq: []const u64,
    encoding: Encoding,
    /// symbol → its code bit at the current node's depth. Only the node's live
    /// alphabet is written, and only those symbols are ever looked up.
    route: [max_sigma]u8 = undefined,
};

/// One 64-aligned slice of a level. It codes only whole words, so no two wefts
/// ever carry a read-modify-write on the same one, and it places its symbols
/// only once the prefix sum has told it where its two runs begin.
const Weft = struct {
    route: *const [max_sigma]u8,
    src: []const u16,
    dst: []u16,
    words: []u64,
    lo: usize,
    hi: usize,
    ones: usize = 0,
    lbase: usize = 0,
    rbase: usize = 0,

    fn code(self: *Weft) void {
        var ones: usize = 0;
        var base = self.lo;
        while (base < self.hi) : (base += 64) {
            var word: u64 = 0;
            for (self.src[base..@min(base + 64, self.hi)], 0..) |c, k| {
                if (self.route[c] == 1) word |= @as(u64, 1) << @intCast(k);
            }
            self.words[base >> 6] = word;
            ones += @popCount(word);
        }
        self.ones = ones;
    }

    fn place(self: *Weft) void {
        var li = self.lbase;
        var ri = self.rbase;
        for (self.src[self.lo..self.hi]) |c| {
            if (self.route[c] == 1) {
                self.dst[ri] = c;
                ri += 1;
            } else {
                self.dst[li] = c;
                li += 1;
            }
        }
    }
};

/// Code one level's bitvector and route its symbols into `dst`, in the fewest
/// sweeps the available parallelism allows.
///
/// The two shapes below differ for a real reason, not an incidental one. A lone
/// worker knows where a symbol lands the moment it reads it, so it codes and
/// routes in ONE sweep. Shards cannot: a shard's destination offsets depend on
/// how many symbols the shards before it sent left, and nobody knows that until
/// they have looked. So they read the range twice — once to code and count,
/// once to place — and still win, because there are a dozen of them. Below
/// `parallel.build_min_bytes` that second read would be pure loss, which is
/// exactly where the fork sits.
fn weave(gpa: std.mem.Allocator, route: *const [max_sigma]u8, src: []const u16, dst: []u16, words: []u64, nzero: usize) !void {
    const bounds = try parallel.evenBounds(src.len, @sizeOf(u16), 64, parallel.build_min_bytes, parallel.max_shards, gpa);
    defer gpa.free(bounds);
    if (bounds.len == 2) {
        var li: usize = 0;
        var ri: usize = nzero;
        var base: usize = 0;
        while (base < src.len) : (base += 64) {
            var word: u64 = 0;
            for (src[base..@min(base + 64, src.len)], 0..) |c, k| {
                if (route[c] == 1) {
                    word |= @as(u64, 1) << @intCast(k);
                    dst[ri] = c;
                    ri += 1;
                } else {
                    dst[li] = c;
                    li += 1;
                }
            }
            words[base >> 6] = word;
        }
        std.debug.assert(li == nzero and ri == src.len);
        return;
    }

    const shards = try gpa.alloc(Weft, bounds.len - 1);
    defer gpa.free(shards);
    const threads = try gpa.alloc(std.Thread, shards.len);
    defer gpa.free(threads);
    for (shards, bounds[0 .. bounds.len - 1], bounds[1..]) |*sh, lo, hi|
        sh.* = .{ .route = route, .src = src, .dst = dst, .words = words, .lo = lo, .hi = hi };
    parallel.fanOut(Weft, shards, threads, Weft.code);
    var l: usize = 0;
    var r: usize = nzero;
    for (shards) |*sh| {
        sh.lbase = l;
        sh.rbase = r;
        l += (sh.hi - sh.lo) - sh.ones;
        r += sh.ones;
    }
    // The two runs met exactly where the histogram said they would — i.e.
    // `freq` really was this node's own, and every weft counted its share.
    std.debug.assert(l == nzero and r == src.len);
    parallel.fanOut(Weft, shards, threads, Weft.place);
}

/// The tree. Internal nodes only; `child < 0` encodes leaf symbol −(child+1).
pub const Tree = struct {
    const unreachable_child: i32 = std.math.minInt(i32);

    nodes: []Node,
    huff: Huff,
    n: usize,

    pub const Node = struct { bits: rrr.Bits, child: [2]i32 };

    /// `freq` must be the histogram OF `seq` — it shapes the Huffman code, and
    /// each node also reads it to size its own two halves before touching a
    /// single symbol (see `buildNode`). A histogram that disagrees with `seq`
    /// trips an assert rather than yielding a quietly wrong tree.
    pub fn build(gpa: std.mem.Allocator, seq: []const u16, freq: []const u64, encoding: Encoding) !Tree {
        var self = Tree{ .nodes = &.{}, .huff = try Huff.build(gpa, freq), .n = seq.len };
        errdefer self.huff.deinit(gpa);
        var list: std.ArrayList(Node) = .empty;
        errdefer {
            for (list.items) |*nd| nd.bits.deinit(gpa);
            list.deinit(gpa);
        }
        // Two n-symbol halves, ping-ponged by depth: a node reads one over its
        // row range and writes the other over the SAME range. Ranges therefore
        // never move as the tree descends, so siblings can never reach each
        // other's symbols and no node needs a private temp for the half it is
        // displacing. It is also what lets a level be woven by several threads
        // at once — an in-place compaction cannot be sharded, because a shard
        // would overwrite symbols its neighbors have not read yet.
        const front = try gpa.alloc(u16, seq.len);
        defer gpa.free(front);
        const back = try gpa.alloc(u16, seq.len);
        defer gpa.free(back);
        @memcpy(front, seq);

        // The root's alphabet, partitioned in place on the way down so every
        // node's live symbol set is a sub-slice of its parent's.
        const alphabet = try gpa.alloc(u16, freq.len);
        defer gpa.free(alphabet);
        var live: usize = 0;
        for (freq, 0..) |f, c| if (f > 0) {
            alphabet[live] = @intCast(c);
            live += 1;
        };

        var loom = Loom{ .huff = &self.huff, .freq = freq, .encoding = encoding };
        _ = try buildNode(gpa, &list, &loom, front, back, alphabet[0..live], 0);
        self.nodes = try list.toOwnedSlice(gpa);
        return self;
    }

    /// Builds node `id` over `src` — every occurrence of every symbol in
    /// `alphabet`, the symbols sharing a code prefix of length `depth` — and
    /// leaves the level's symbols in `dst` as [left | right]. `src` and `dst`
    /// are the same row range of the two ping-pong halves, so the children
    /// simply read what this node wrote and write back over what it read.
    ///
    /// The level's split point is known BEFORE a single symbol is read: a node
    /// holds every occurrence of its alphabet, so `freq` summed over the
    /// left-routed symbols already gives it. That is what lets `weave` code the
    /// bitvector and route the symbols in one sweep when it is alone, and what
    /// lets it hand shards their destinations after one counting sweep when it
    /// is not. It also pays for the `route` table: an O(σ) sweep the node was
    /// doing anyway turns the hot loop's Huffman bit extraction into a byte
    /// load.
    fn buildNode(gpa: std.mem.Allocator, list: *std.ArrayList(Node), loom: *Loom, src: []u16, dst: []u16, alphabet: []u16, depth: u8) !i32 {
        var nzero: usize = 0;
        for (alphabet) |c| {
            const bit = loom.huff.bitAt(c, depth);
            loom.route[c] = bit;
            if (bit == 0) nzero += @intCast(loom.freq[c]);
        }
        std.debug.assert(nzero <= src.len);

        const id: i32 = @intCast(list.items.len);
        try list.append(gpa, .{ .bits = .{ .plain = try rrr.Plain.initEmpty(gpa, src.len) }, .child = .{ unreachable_child, unreachable_child } });
        try weave(gpa, &loom.route, src, dst, list.items[@intCast(id)].bits.plain.words, nzero);
        try list.items[@intCast(id)].bits.plain.finalize(gpa);
        if (loom.encoding == .adopt_min)
            list.items[@intCast(id)].bits = try rrr.Bits.adopt(gpa, list.items[@intCast(id)].bits.plain);

        // The alphabet splits the same way, but unordered: a node reads its
        // alphabet only as a set, and a one-symbol child IS the leaf.
        var lo: usize = 0;
        var hi: usize = alphabet.len;
        while (lo < hi) {
            if (loom.route[alphabet[lo]] == 0) lo += 1 else {
                hi -= 1;
                std.mem.swap(u16, &alphabet[lo], &alphabet[hi]);
            }
        }
        for (0..2) |b| {
            const part = if (b == 0) alphabet[0..lo] else alphabet[lo..];
            if (part.len == 0) continue; // σ=1 degenerate branch: no code routes here
            const from = if (b == 0) @as(usize, 0) else nzero;
            const upto = if (b == 0) nzero else src.len;
            // materialize the child BEFORE indexing items: the recursion appends
            // and may reallocate, so the destination pointer must be computed last
            const child: i32 = if (part.len == 1) blk: {
                std.debug.assert(loom.huff.len[part[0]] == depth + 1);
                break :blk -(@as(i32, part[0]) + 1);
            } else try buildNode(gpa, list, loom, dst[from..upto], src[from..upto], part, depth + 1);
            list.items[@intCast(id)].child[b] = child;
        }
        return id;
    }

    pub fn deinit(self: *Tree, gpa: std.mem.Allocator) void {
        for (self.nodes) |*nd| nd.bits.deinit(gpa);
        gpa.free(self.nodes);
        self.huff.deinit(gpa);
    }

    /// occ(sym, pos): occurrences of `sym` in seq[0..pos). O(code length).
    pub fn occ(self: *const Tree, sym: u16, pos: usize) usize {
        const L = self.huff.len[sym];
        if (L == 0) return 0;
        var p = pos;
        var node: i32 = 0;
        var d: u8 = 0;
        while (true) {
            const nd = &self.nodes[@intCast(node)];
            const r1 = nd.bits.rank1(p);
            p = if (self.huff.bitAt(sym, d) == 1) r1 else p - r1;
            d += 1;
            if (d == L) return p;
            node = nd.child[self.huff.bitAt(sym, d - 1)];
        }
    }

    /// Read seq[pos] and its occ-before in one descent (the LF fast path).
    pub fn access(self: *const Tree, pos: usize) struct { sym: u16, occ: usize } {
        var p = pos;
        var node: i32 = 0;
        while (true) {
            const nd = &self.nodes[@intCast(node)];
            const bit = nd.bits.get(p);
            const r1 = nd.bits.rank1(p);
            p = if (bit == 1) r1 else p - r1;
            const ch = nd.child[bit];
            if (ch < 0) return .{ .sym = @intCast(-(ch + 1)), .occ = p };
            node = ch;
        }
    }

    pub fn sizeBytes(self: *const Tree) usize {
        var total: usize = @sizeOf(Tree) + self.huff.len.len * (1 + 8);
        for (self.nodes) |*nd| total += nd.bits.sizeBytes() + @sizeOf(Node);
        return total;
    }
};
