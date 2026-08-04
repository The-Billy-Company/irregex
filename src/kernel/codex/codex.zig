//! codex — the compressed self-index: the book that IS its own index.
//!
//! One structure holding a corpus at entropy-bound size while answering exact
//! substring queries at the information-theoretic time floor:
//!
//!   count(P)   occurrences of any byte string, in |P| backward-search steps —
//!              O(m) rank operations, INDEPENDENT of corpus size. Ω(m) is the
//!              floor (an unread pattern byte can flip the answer), so this is
//!              the lowest time complexity physically possible.
//!   find(P)    every match position, via LF-walks to sampled suffix ranks —
//!              O(m + occ·t) where t is the sampling stride (a space/time knob).
//!   restore()  the ENTIRE original text, byte-exact, from the index alone.
//!              This is the Shannon claim made mechanical: the index is a
//!              decodable lossless code — a compression — not a companion to one.
//!
//! Pipeline: SA-IS suffix array (O(n), `sais.zig` over vendored libsais) →
//! Burrows–Wheeler transform
//! (a permutation: zero information change, Manzini JACM 2001 bounds its
//! zeroth-order-coded size by nH_k) → Huffman-shaped wavelet tree over
//! RRR-compressed bitvectors (`wavelet.zig` + `rrr.zig` — Ferragina–Manzini
//! FOCS 2000; Grossi–Gupta–Vitter SODA 2003; Raman–Raman–Rao SODA 2002).
//! After `build` returns, the suffix array, the BWT, and the text itself are
//! all gone — residency is the wavelet tree, a 257-entry C table, and the
//! optional locate samples.
//!
//! Bytes are lifted to u16 symbols c+1 with a unique sentinel 0, so all 256
//! byte values — including NUL — are ordinary content. The adversarial proof
//! lives in `codex_test.zig`: every operation is differential against naive
//! oracles over random, degenerate, and binary corpora.

const std = @import("std");
const fault = @import("../../fault.zig");
const sais = @import("../math/succinct/sais.zig");
const rrr = @import("../math/succinct/rrr.zig");
const wavelet = @import("../math/succinct/wavelet.zig");

const parallel = @import("../math/parallel.zig");

const Oom = std.mem.Allocator.Error;
const SIGMA: usize = 257; // 256 byte symbols shifted +1, sentinel 0

/// One contiguous row range of the BWT derivation, and the histogram of the
/// symbols it produced. Row j reads `sa[j]` and writes `bwt[j]` and nothing
/// else, so the transform is embarrassingly parallel — only the 257-entry
/// tallies have to meet, once, at the end.
const Weave = struct {
    text: []const u8,
    sa: []const u32,
    bwt: []u16,
    lo: usize,
    hi: usize,
    tally: [SIGMA]u64 = @splat(0),

    fn run(self: *Weave) void {
        const n = self.sa.len;
        const out = self.bwt[self.lo..self.hi];
        for (self.sa[self.lo..self.hi], out) |p, *sym| {
            const prev = if (p == 0) n - 1 else p - 1;
            sym.* = if (prev == n - 1) 0 else @as(u16, self.text[prev]) + 1;
        }
        // The histogram deliberately stays a SECOND sweep, inside the shard.
        // Folding `tally[sym] += 1` into the loop above looks like a free
        // saving — one pass instead of two — and measures 0.87–0.90x, i.e.
        // reliably SLOWER (2026-07-27, 128MB and 200MB, ReleaseFast). That loop
        // is bound by the random gather into `text` and sustains it only by
        // keeping many independent loads in flight; a counter update that
        // depends on the byte just loaded serializes them. This sweep is a pure
        // sequential stream and costs less than the parallelism it buys back.
        // Re-measure `phases.zig` before fusing.
        var tally: [SIGMA]u64 = @splat(0);
        for (out) |c| tally[c] += 1;
        self.tally = tally;
    }
};

/// One row range of the locate scaffolding: which rows carry a sampled suffix
/// rank. Two fan-outs over the same shards — `tally`, then `scatter` — because
/// a shard cannot know where its samples belong in the shared array until the
/// shards before it have counted theirs. The bit marks need no such handshake
/// (each shard owns whole words), so only `samples` waits on the prefix sum.
const Mark = struct {
    sa: []const u32,
    rate: u32,
    plain: *rrr.Plain,
    lo: usize,
    hi: usize,
    found: usize = 0,
    base: usize = 0,
    out: []u32 = &.{},

    fn tally(self: *Mark) void {
        var k: usize = 0;
        for (self.sa[self.lo..self.hi]) |p| k += @intFromBool(p % self.rate == 0);
        self.found = k;
    }

    fn scatter(self: *Mark) void {
        var w = self.base;
        for (self.sa[self.lo..self.hi], self.lo..) |p, row| {
            if (p % self.rate == 0) {
                self.plain.set(row);
                self.out[w] = p;
                w += 1;
            }
        }
    }
};

pub const Options = struct {
    /// Suffix-rank sampling stride for `find`. Smaller = faster locate,
    /// larger = smaller index. 0 disables locate (count/restore only).
    sample_rate: u32 = 32,
    /// Bitvector posture: `.adopt_min` (entropy space — the nH_k rung) or
    /// `.plain_only` (~2× the space, ~5× faster ranks). Same answers either way.
    encoding: wavelet.Encoding = .adopt_min,
};

pub const Stats = struct {
    text_len: usize,
    index_bytes: usize,
    tree_bytes: usize,
    locate_bytes: usize,

    pub fn bitsPerChar(self: Stats) f64 {
        return @as(f64, @floatFromInt(self.index_bytes)) * 8.0 / @as(f64, @floatFromInt(@max(self.text_len, 1)));
    }
};

pub const Codex = struct {
    tree: wavelet.Tree,
    c_table: [SIGMA]usize,
    marks: ?rrr.Bits, // rows whose suffix rank is sampled
    samples: []u32, // sampled suffix positions, in row order
    sample_rate: u32,
    n: usize, // symbol count = text len + 1
    stats: Stats,

    /// Build from `text` (any bytes, up to `sais.max_text_len` — the suffix
    /// sort's 2 GiB addressing ceiling, past which this returns `Oversized`
    /// rather than a truncated index). The text is not retained.
    pub fn build(gpa: std.mem.Allocator, text: []const u8, opts: Options) !Codex {
        const n = text.len + 1;
        const bwt = try gpa.alloc(u16, n);
        defer gpa.free(bwt);
        var freq: [SIGMA]u64 = @splat(0);
        // locate scaffolding: mark rows whose suffix position is ≡ 0 (mod rate)
        var marks: ?rrr.Bits = null;
        var samples: []u32 = &.{};
        errdefer if (marks) |*m| m.deinit(gpa);
        errdefer gpa.free(samples);

        // Both readers of the suffix array live in this scope, so the scope is
        // its lifetime — and that is a memory decision, not a tidiness one. The
        // SA is the largest thing this function ever holds (4n bytes against the
        // tree's 2n), so the phases that need it run FIRST and it is gone before
        // the most memory-hungry phase starts. Ordering the build this way is
        // what pays for the wavelet tree's second half.
        {
            const sa = try sais.build(gpa, text);
            defer gpa.free(sa);

            // BWT (Burrows–Wheeler): permute so each symbol sits by its right
            // context. Zeroth-order coding of the BWT ≤ nH_k of the original
            // (Manzini JACM 2001) — why the wavelet+RRR below reaches k-th order.
            {
                const bounds = try parallel.evenBounds(n, @sizeOf(u16), 1, parallel.build_min_bytes, parallel.max_shards, gpa);
                defer gpa.free(bounds);
                const shards = try gpa.alloc(Weave, bounds.len - 1);
                defer gpa.free(shards);
                const threads = try gpa.alloc(std.Thread, shards.len);
                defer gpa.free(threads);
                for (shards, bounds[0 .. bounds.len - 1], bounds[1..]) |*sh, lo, hi|
                    sh.* = .{ .text = text, .sa = sa, .bwt = bwt, .lo = lo, .hi = hi };
                parallel.fanOut(Weave, shards, threads, Weave.run);
                for (shards) |*sh| for (&freq, sh.tally) |*f, t| {
                    f.* += t;
                };
            }

            if (opts.sample_rate > 0) {
                var plain = try rrr.Plain.initEmpty(gpa, n);
                errdefer plain.deinit(gpa);
                // 64-grain: the shards set marks in one shared word array, so a
                // boundary inside a word would be a lost read-modify-write.
                const bounds = try parallel.evenBounds(n, @sizeOf(u32), 64, parallel.build_min_bytes, parallel.max_shards, gpa);
                defer gpa.free(bounds);
                const shards = try gpa.alloc(Mark, bounds.len - 1);
                defer gpa.free(shards);
                const threads = try gpa.alloc(std.Thread, shards.len);
                defer gpa.free(threads);
                for (shards, bounds[0 .. bounds.len - 1], bounds[1..]) |*sh, lo, hi|
                    sh.* = .{ .sa = sa, .rate = opts.sample_rate, .plain = &plain, .lo = lo, .hi = hi };
                parallel.fanOut(Mark, shards, threads, Mark.tally);
                // Prefix sum: each shard's write cursor is where its predecessors
                // stopped, so the scatter below needs no lock and no merge.
                var total: usize = 0;
                for (shards) |*sh| {
                    sh.base = total;
                    total += sh.found;
                }
                samples = try gpa.alloc(u32, total);
                for (shards) |*sh| sh.out = samples;
                parallel.fanOut(Mark, shards, threads, Mark.scatter);
                try plain.finalize(gpa);
                marks = try rrr.Bits.adopt(gpa, plain);
            }
        }

        var c_table: [SIGMA]usize = undefined;
        var acc: usize = 0;
        for (0..SIGMA) |c| {
            c_table[c] = acc;
            // The tallies are u64 by the shard's counter width, but they partition
            // `text` — every one is ≤ `text.len`, itself a usize — so narrowing to
            // the cumulative index type is exact on any address width.
            acc += @intCast(freq[c]);
        }

        var tree = try wavelet.Tree.build(gpa, bwt, &freq, opts.encoding);
        errdefer tree.deinit(gpa);

        var self = Codex{ .tree = tree, .c_table = c_table, .marks = marks, .samples = samples, .sample_rate = opts.sample_rate, .n = n, .stats = undefined };
        self.setStats();
        return self;
    }

    /// Derive `stats` from the resident structures (shared by build and load).
    fn setStats(self: *Codex) void {
        const tree_bytes = self.tree.sizeBytes();
        const locate_bytes = (if (self.marks) |*m| m.sizeBytes() else 0) + self.samples.len * 4;
        self.stats = .{ .text_len = self.n - 1, .index_bytes = tree_bytes + locate_bytes + @sizeOf(Codex), .tree_bytes = tree_bytes, .locate_bytes = locate_bytes };
    }

    pub fn deinit(self: *Codex, gpa: std.mem.Allocator) void {
        self.tree.deinit(gpa);
        if (self.marks) |*m| m.deinit(gpa);
        gpa.free(self.samples);
    }

    /// Original text length in bytes.
    pub fn len(self: *const Codex) usize {
        return self.n - 1;
    }

    /// A suffix-array row interval — the state of an incremental backward
    /// search. `width() == 0` means the pattern so far does not occur.
    ///
    /// Not a `Span`: that word is the package's byte range over a haystack
    /// (`../../mark.zig`), and these are row numbers in the BWT. Two things
    /// under one name is how a caller ends up slicing text with them.
    pub const Rows = struct {
        lo: usize,
        hi: usize,

        pub fn width(self: Rows) usize {
            return self.hi - self.lo;
        }
    };

    /// The interval of the empty pattern: every row.
    pub fn whole(self: *const Codex) Rows {
        return .{ .lo = 0, .hi = self.n };
    }

    /// One FM-index backward-search step (Ferragina–Manzini FOCS 2000):
    /// interval of `byte ++ P` from the interval of `P`. Two occ ranks —
    /// O(code length), independent of corpus size. Empty stays empty.
    pub fn extend(self: *const Codex, rows: Rows, byte: u8) Rows {
        if (rows.lo >= rows.hi) return .{ .lo = 0, .hi = 0 };
        const sym: u16 = @as(u16, byte) + 1;
        // LF / C[c] + occ(c, ·): map the BWT rows of `P` to those of `cP`.
        const lo = self.c_table[sym] + self.tree.occ(sym, rows.lo);
        const hi = self.c_table[sym] + self.tree.occ(sym, rows.hi);
        return if (lo >= hi) .{ .lo = 0, .hi = 0 } else .{ .lo = lo, .hi = hi };
    }

    /// Full FM backward search: SA row range [lo, hi) of `pattern` (right→left).
    fn range(self: *const Codex, pattern: []const u8) Rows {
        var rows = self.whole();
        var j = pattern.len;
        while (j > 0) {
            j -= 1;
            rows = self.extend(rows, pattern[j]);
            if (rows.lo >= rows.hi) break;
        }
        return rows;
    }

    /// Occurrences of `pattern` (overlapping counted). Empty pattern ⇒ 0 by
    /// definition (a search answer, not the vacuous n+1 of the mathematics).
    pub fn count(self: *const Codex, pattern: []const u8) usize {
        return if (pattern.len == 0) 0 else self.range(pattern).width();
    }

    /// LF-mapping (Ferragina–Manzini): SA-row of the text position one left.
    /// Same C[c]+occ identity as `extend`; walks BWT without the text.
    fn lf(self: *const Codex, row: usize) usize {
        const a = self.tree.access(row);
        return self.c_table[a.sym] + a.occ;
    }

    /// Suffix position of `row`, by LF-walking to the nearest sampled row.
    fn suffixAt(self: *const Codex, marks: *const rrr.Bits, row: usize) u32 {
        var r = row;
        var steps: u32 = 0;
        while (marks.get(r) == 0) : (steps += 1) r = self.lf(r);
        return self.samples[marks.rank1(r)] + steps;
    }

    /// Text position of one exemplar row of a suffix interval — the cheapest
    /// possible locate (a single sampled-mark walk, O(sample_rate) LF steps).
    ///
    /// **Declines** when the index was built without locate samples
    /// (`sample_rate == 0`): counting is exact either way, so a mark-less codex
    /// is a smaller index that answers *where* nowhere rather than a broken one
    /// . The declinature rides the success position because every
    /// caller has somewhere to go — "(not in corpus)" — and a `try` here would
    /// turn a legitimately cheaper artifact into an abort.
    pub fn posOf(self: *const Codex, row: usize) fault.Answer(u32) {
        const marks = if (self.marks) |*m| m else return .{ .declined = .capability_missing };
        std.debug.assert(row < self.n);
        return .{ .got = self.suffixAt(marks, row) };
    }

    /// Every match position of `pattern`, ascending. Declines without locate
    /// support, exactly as `posOf` does. Caller frees.
    pub fn find(self: *const Codex, gpa: std.mem.Allocator, pattern: []const u8) Oom!fault.Answer([]u32) {
        const marks = if (self.marks) |*m| m else return .{ .declined = .capability_missing };
        if (pattern.len == 0) return .{ .got = try gpa.alloc(u32, 0) };
        const r = self.range(pattern);
        const out = try gpa.alloc(u32, r.hi - r.lo);
        for (out, r.lo..) |*pos, row| pos.* = self.suffixAt(marks, row);
        std.mem.sort(u32, out, {}, std.sort.asc(u32));
        return .{ .got = out };
    }

    /// Reconstruct the full original text from the index alone — the proof the
    /// index is a decodable code. Caller frees.
    pub fn restore(self: *const Codex, gpa: std.mem.Allocator) ![]u8 {
        const out = try gpa.alloc(u8, self.n - 1);
        var row: usize = 0; // row 0 is the sentinel suffix; LF walks the text right-to-left
        for (0..self.n - 1) |step| {
            const a = self.tree.access(row);
            std.debug.assert(a.sym != 0); // the sentinel can only close the walk
            out[self.n - 2 - step] = @intCast(a.sym - 1);
            row = self.c_table[a.sym] + a.occ;
        }
        return out;
    }

    // ── persistence ──
    // The wire format stores only PRIMARY data — bitvector payloads, Huffman
    // code lengths, tree topology, samples. Everything derived (rank samples,
    // canonical codes, superblock cursors, the C table's validity) is rebuilt
    // through the layers' validating constructors at load, so a mangled blob
    // fails closed with `error.Corrupt` instead of answering wrong.

    const MAGIC = "CDX1";
    // v2 replaced the XxHash64 trailer with the shared BLAKE3 signet; an older
    // blob reads as corrupt and the shelf is rebuilt.
    const VERSION: u32 = 2;

    /// Serialize to an owned byte buffer (I/O stays with the caller). The
    /// payload is framed magic + version up front, sealed at the tail. Caller
    /// frees.
    pub fn save(self: *const Codex, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.appendSlice(gpa, MAGIC);
        try putInt(gpa, &out, u32, VERSION);
        try putInt(gpa, &out, u64, self.n);
        try putInt(gpa, &out, u32, self.sample_rate);
        for (self.c_table) |v| try putInt(gpa, &out, u64, v);
        try out.appendSlice(gpa, self.tree.huff.len);
        try putInt(gpa, &out, u32, @intCast(self.tree.nodes.len));
        for (self.tree.nodes) |*nd| {
            try putInt(gpa, &out, i32, nd.child[0]);
            try putInt(gpa, &out, i32, nd.child[1]);
            try putBits(gpa, &out, &nd.bits);
        }
        try out.append(gpa, @intFromBool(self.marks != null));
        if (self.marks) |*m| try putBits(gpa, &out, m);
        try putInt(gpa, &out, u64, @intCast(self.samples.len));
        for (self.samples) |s| try putInt(gpa, &out, u32, s);
        try signet.sealInto(gpa, &out);
        return out.toOwnedSlice(gpa);
    }

    /// Deserialize a `save` buffer. Fails closed (`error.Corrupt`) on any
    /// framing, checksum, or structural violation.
    pub fn load(gpa: std.mem.Allocator, bytes: []const u8) !Codex {
        if (bytes.len < MAGIC.len + 4 + signet.len or !std.mem.eql(u8, bytes[0..4], MAGIC)) return error.Corrupt;
        const body = try signet.unseal(bytes);
        var c = Cursor{ .buf = body, .pos = MAGIC.len };
        if (try c.int(u32) != VERSION) return error.Corrupt;
        // The format records the BWT length as u64 (width-neutral on disk), but the
        // wavelet tree indexes it as `usize`. A value past this address space is
        // therefore not a truncation to paper over — it is an artifact this build
        // cannot load, which is exactly what `Corrupt` means to every caller.
        const n = std.math.cast(usize, try c.int(u64)) orelse return error.Corrupt;
        if (n == 0) return error.Corrupt;
        const sample_rate = try c.int(u32);
        var c_table: [SIGMA]usize = undefined;
        var prev: u64 = 0;
        for (&c_table, 0..) |*v, i| {
            const raw = try c.int(u64);
            if (raw > n or (i > 0 and raw < prev)) return error.Corrupt; // must be monotone within [0, n]
            v.* = @intCast(raw);
            prev = raw;
        }
        if (c_table[0] != 0) return error.Corrupt;

        var huff = try wavelet.Huff.fromLengths(gpa, try c.bytes(SIGMA));
        errdefer huff.deinit(gpa);
        const node_count = try c.int(u32);
        if (node_count == 0 or node_count > SIGMA) return error.Corrupt;
        var nodes: std.ArrayList(wavelet.Tree.Node) = .empty;
        errdefer {
            for (nodes.items) |*nd| nd.bits.deinit(gpa);
            nodes.deinit(gpa);
        }
        for (0..node_count) |_| {
            const l = try c.int(i32);
            const r = try c.int(i32);
            for ([2]i32{ l, r }) |ch| { // child: node id in range, or leaf −(sym+1)
                if (ch >= 0 and ch >= node_count) return error.Corrupt;
                if (ch < 0 and ch != std.math.minInt(i32) and -(ch + 1) >= SIGMA) return error.Corrupt;
            }
            try nodes.append(gpa, .{ .bits = try takeBits(gpa, &c), .child = .{ l, r } });
        }
        var tree = wavelet.Tree{ .nodes = try nodes.toOwnedSlice(gpa), .huff = huff, .n = n };
        errdefer tree.deinit(gpa);
        if (tree.nodes[0].bits.nbits() != n) return error.Corrupt;

        var marks: ?rrr.Bits = null;
        errdefer if (marks) |*m| m.deinit(gpa);
        if (try c.int(u8) == 1) {
            marks = try takeBits(gpa, &c);
            if (marks.?.nbits() != n) return error.Corrupt;
        }
        const nsamples = try c.int(u64);
        if (nsamples > n) return error.Corrupt;
        const samples = try gpa.alloc(u32, @intCast(nsamples));
        errdefer gpa.free(samples);
        for (samples) |*s| s.* = try c.int(u32);
        if (c.pos != body.len) return error.Corrupt;

        var self = Codex{ .tree = tree, .c_table = c_table, .marks = marks, .samples = samples, .sample_rate = sample_rate, .n = @intCast(n), .stats = undefined };
        self.setStats();
        return self;
    }
};

// ── wire helpers (little-endian ints, u64-slice payloads) ──
// `putInt`/`Cursor` moved to the shared framing module (`../frame/frame.zig`):
// `shelf.zig`, the atlas, and the trigram pair loader frame their catalogs
// with the same primitives so the formats can't drift on conventions.

const frame = @import("../../corpus/index/frame/frame.zig");
const putInt = frame.putInt;
const putWords = frame.putWords;
const Cursor = frame.Cursor;
const signet = @import("../../corpus/index/frame/signet.zig");

fn putBits(gpa: std.mem.Allocator, out: *std.ArrayList(u8), bits: *const rrr.Bits) !void {
    try out.append(gpa, @intFromEnum(std.meta.activeTag(bits.*)));
    try putInt(gpa, out, u64, @intCast(bits.nbits()));
    switch (bits.*) {
        .plain => |*p| try putWords(gpa, out, p.words),
        .rrr => |*r| {
            try putWords(gpa, out, r.classes);
            try putWords(gpa, out, r.offsets);
        },
    }
}

fn takeBits(gpa: std.mem.Allocator, c: *Cursor) !rrr.Bits {
    const tag = try c.int(u8);
    const nbits: usize = @intCast(try c.int(u64));
    switch (tag) {
        @intFromEnum(@as(std.meta.Tag(rrr.Bits), .plain)) => {
            const w = try c.words(gpa);
            errdefer gpa.free(w);
            return .{ .plain = try rrr.Plain.fromWords(gpa, w, nbits) };
        },
        @intFromEnum(@as(std.meta.Tag(rrr.Bits), .rrr)) => {
            const classes = try c.words(gpa);
            errdefer gpa.free(classes);
            const offsets = try c.words(gpa);
            errdefer gpa.free(offsets);
            return .{ .rrr = try rrr.Rrr.fromParts(gpa, classes, offsets, nbits) };
        },
        else => return error.Corrupt,
    }
}
