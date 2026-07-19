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
//! text (implicit compression boosting — Mäkinen & Navarro, CPM 2007).
//!
//! The alphabet is `u16` symbols in [0, sigma) — the codex feeds bytes shifted
//! +1 with sentinel 0, so σ = 257; nothing here assumes that beyond σ ≤ 4096.

const std = @import("std");
const rrr = @import("rrr.zig");

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
        for (freq, 0..) |f, c| {
            if (f > 0) {
                order[np] = @intCast(c);
                np += 1;
            }
        }
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

/// The tree. Internal nodes only; `child < 0` encodes leaf symbol −(child+1).
pub const Tree = struct {
    const unreachable_child: i32 = std.math.minInt(i32);

    nodes: []Node,
    huff: Huff,
    n: usize,

    pub const Node = struct { bits: rrr.Bits, child: [2]i32 };

    pub fn build(gpa: std.mem.Allocator, seq: []const u16, freq: []const u64, encoding: Encoding) !Tree {
        var self = Tree{ .nodes = &.{}, .huff = try Huff.build(gpa, freq), .n = seq.len };
        errdefer self.huff.deinit(gpa);
        var list: std.ArrayList(Node) = .empty;
        errdefer {
            for (list.items) |*nd| nd.bits.deinit(gpa);
            list.deinit(gpa);
        }
        const scratch = try gpa.alloc(u16, seq.len);
        defer gpa.free(scratch);
        @memcpy(scratch, seq);
        _ = try buildNode(gpa, &list, &self.huff, scratch, 0, encoding);
        self.nodes = try list.toOwnedSlice(gpa);
        return self;
    }

    /// Builds node `id` from `seq` (all symbols sharing a code prefix of
    /// length `depth`), partitioning IN PLACE: after the bitvector is coded,
    /// `seq` is stably rearranged to [left | right] and the halves recursed.
    /// Peak transient memory is the single n-symbol scratch, not one buffer
    /// per level.
    fn buildNode(gpa: std.mem.Allocator, list: *std.ArrayList(Node), huff: *const Huff, seq: []u16, depth: u8, encoding: Encoding) !i32 {
        const id: i32 = @intCast(list.items.len);
        try list.append(gpa, .{ .bits = .{ .plain = try rrr.Plain.initEmpty(gpa, seq.len) }, .child = .{ unreachable_child, unreachable_child } });
        var nzero: usize = 0;
        {
            var plain = &list.items[@intCast(id)].bits.plain;
            for (seq, 0..) |c, i| {
                if (huff.bitAt(c, depth) == 1) plain.set(i) else nzero += 1;
            }
            try plain.finalize(gpa);
        }
        if (encoding == .adopt_min)
            list.items[@intCast(id)].bits = try rrr.Bits.adopt(gpa, list.items[@intCast(id)].bits.plain);
        // stable in-place partition via cycle-free two-pointer copy through a stack slice
        {
            var buf: [512]u16 = undefined;
            var right_tmp: []u16 = undefined;
            var heap_tmp: ?[]u16 = null;
            defer if (heap_tmp) |t| gpa.free(t);
            const nright = seq.len - nzero;
            if (nright <= buf.len) {
                right_tmp = buf[0..nright];
            } else {
                heap_tmp = try gpa.alloc(u16, nright);
                right_tmp = heap_tmp.?;
            }
            var li: usize = 0;
            var ri: usize = 0;
            for (seq) |c| {
                if (huff.bitAt(c, depth) == 1) {
                    right_tmp[ri] = c;
                    ri += 1;
                } else {
                    seq[li] = c;
                    li += 1;
                }
            }
            @memcpy(seq[nzero..], right_tmp);
        }
        for (0..2) |b| {
            const part = if (b == 0) seq[0..nzero] else seq[nzero..];
            if (part.len == 0) continue; // σ=1 degenerate branch: no code routes here
            const sym = part[0];
            // materialize the child BEFORE indexing items: the recursion appends
            // and may reallocate, so the destination pointer must be computed last
            const child: i32 = if (huff.len[sym] == depth + 1)
                -(@as(i32, sym) + 1)
            else
                try buildNode(gpa, list, huff, part, depth + 1, encoding);
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
