//! gist — positional-trigram candidate index (the proven baseline tier).
//!
//! A document that *contains a literal* must contain every trigram of that
//! literal, so the AND of the per-trigram posting lists is a sound *candidate
//! set*: a superset of the true matches, cheaply computed without scanning
//! (Cox 2012 / google codesearch — required-trigram filter + verify). It is a
//! FILTER, not a matcher — the caller still verifies each candidate with the
//! real regex engine (false positives are expected and harmless; false
//! negatives are not, and the trigram filter has none for literals ≥ 3 bytes).
//!
//! **On-disk/in-memory shape — a CSR directory over delta-varint posting
//! lists** (csearch's own index format: google/codesearch `index/write.go`).
//! A flat `(trigram, doc)` pair table costs 8 bytes/posting (4 tag + 4 doc) and
//! most of that tag is redundant — a distinct trigram has, on average, dozens
//! of postings sharing it. So the index instead stores three parallel arrays
//! over the `n` DISTINCT trigrams present (`dir_tri`/`dir_off`/`dir_count`,
//! csearch's exact per-trigram index-entry triple) plus one `body` byte blob:
//! each group's ascending doc ids are delta-encoded (first id raw, each
//! successor `doc[i]-doc[i-1]`, always ≥ 1 since a doc's own trigram set is
//! deduped) and varint-packed (`varint.zig`), so a locally-clustered doc-id run
//! — the common case for any trigram that appears in a meaningful fraction of
//! files — costs ~1 byte/posting instead of 4. Measured on this repo (18,910
//! files, 343,857 distinct trigrams, 25.56M postings): **195.0 MiB flat → 30.1
//! MiB CSR+varint (6.5x)**, closing most of the README's "COLD one-shot
//! literal vs csearch/zoekt" gap (28 MiB) without giving up the
//! zero-copy mmap load (`persist.zig`) — `dir_*`/`body` still alias the mapped
//! pages directly (`fromTrustedMappedBytes`), so a cold query validates only
//! its touched posting groups instead of eagerly decoding the whole body.
//!
//! Design is deliberately allocation-light and free of std.AutoHashMap so it
//! stays stable across Zig's container-API churn. The n-gram *strategy* (which
//! grams to emit) lives in `ngram.zig`, so the SoTA sparse-n-gram variant
//! (ADR-pending) drops in there without touching build/query.

const std = @import("std");
const portal = @import("../../../portal.zig");
const fault = @import("../../../fault.zig");
const blob = @import("../postings/persisted_blob.zig");
const ngram = @import("ngram.zig");
const varint = @import("../postings/varint.zig");
const parallel = @import("../../../kernel/math/parallel.zig");

/// A trigram packed big-endian into the low 24 bits of a u32 (re-exported from
/// `ngram` so the index's public surface stays self-contained).
pub const Trigram = ngram.Trigram;

/// Longest doc (≥ 1) — the scratch-buffer size both extractors need.
inline fn maxDocLen(docs: []const []const u8) usize {
    var m: usize = 1;
    for (docs) |d| m = @max(m, d.len);
    return m;
}

pub const Posting = struct { tri: Trigram, doc: u32 };

fn postingLess(_: void, a: Posting, b: Posting) bool {
    return if (a.tri != b.tri) a.tri < b.tri else a.doc < b.doc;
}

/// Emit each doc's distinct trigrams into `out` as postings tagged `base_doc + i`,
/// reusing `scratch` (≥ longest doc) and an all-zero presence `bitmap`
/// (`ngram.bitmap_words`, left all-zero again). Returns the posting count.
/// Per-doc trigrams land UNORDERED: both callers order postings globally
/// afterwards (serial: the whole-corpus `postingLess` sort; parallel: the
/// stable 24-bit counting scatter), so the old per-doc sort was dead work —
/// this is the O(bytes) extraction that halves the build's CPU bill.
fn emitPostings(docs: []const []const u8, base_doc: u32, bitmap: []u64, scratch: []Trigram, out: []Posting) usize {
    var w: usize = 0;
    for (docs, 0..) |d, i| {
        const k = ngram.extractUniqueUnordered(d, bitmap, scratch);
        const doc: u32 = base_doc + @as(u32, @intCast(i));
        for (scratch[0..k]) |t| {
            out[w] = .{ .tri = t, .doc = doc };
            w += 1;
        }
    }
    return w;
}

pub const QueryError = error{ NeedleTooShort, OutOfMemory } || fault.Persist;
pub const LoadError = error{OutOfMemory} || fault.Persist;

pub const format_version = blob.format_version;
pub const header_len = blob.header_len;

/// Below this many corpus bytes the single-threaded comparison-sort build wins
/// — thread spawn + a 64 MiB counting histogram aren't worth it.
const parallel_build_threshold: usize = 4 << 20; // 4 MiB

/// Immutable CSR directory (`dir_tri`/`dir_off`/`dir_count`) over a
/// delta-varint-packed posting `body` (see the file header).
pub const Index = struct {
    dir_tri: []const u32,
    dir_off: []const u32,
    dir_count: []const u32,
    body: []const u8,
    doc_count: u32,
    posting_count: u32,
    allocator: std.mem.Allocator,
    /// The slices alias caller-owned bytes; `deinit` then frees nothing.
    /// This is the zero-copy mmap cold-load path.
    borrowed: bool = false,

    /// Build over `docs` (doc ids are indices). Large corpora extract private
    /// shards and stable-count-sort the 24-bit key; small corpora avoid the
    /// 64 MiB histogram. `compact` then emits the CSR+varint shape.
    pub fn build(allocator: std.mem.Allocator, docs: []const []const u8) QueryError!Index {
        var upper: usize = 0;
        for (docs) |d| upper += d.len; // ≥ distinct trigrams across all docs

        const flat = if (upper < parallel_build_threshold or docs.len < 2)
            try buildFlatSerial(allocator, docs, upper)
        else
            buildFlatParallel(allocator, docs, upper) catch |e| switch (e) {
                // Any threading/alloc hiccup degrades gracefully to the proven path.
                error.OutOfMemory => try buildFlatSerial(allocator, docs, upper),
            };
        defer allocator.free(flat);
        return compact(allocator, @intCast(docs.len), flat);
    }

    fn buildFlatSerial(allocator: std.mem.Allocator, docs: []const []const u8, upper: usize) std.mem.Allocator.Error![]Posting {
        const postings = try allocator.alloc(Posting, upper);
        errdefer allocator.free(postings);
        const scratch = try allocator.alloc(Trigram, maxDocLen(docs));
        defer allocator.free(scratch);
        const bitmap = try allocator.alloc(u64, ngram.bitmap_words);
        defer allocator.free(bitmap);
        @memset(bitmap, 0);

        const final = postings[0..emitPostings(docs, 0, bitmap, scratch, postings)];
        std.mem.sort(Posting, final, {}, postingLess);
        return allocator.realloc(postings, final.len) catch final;
    }

    const radix_bits = 24; // a trigram is 24 bits → one histogram bucket each
    const radix = 1 << radix_bits;

    fn buildFlatParallel(allocator: std.mem.Allocator, docs: []const []const u8, upper: usize) std.mem.Allocator.Error![]Posting {
        const ncpu = portal.cpuCount() catch 1;
        const nthr = @min(@max(ncpu, 1), docs.len);

        // Byte-balanced contiguous [lo, hi) shards keep concat doc-major.
        const bounds = try allocator.alloc(usize, nthr + 1);
        defer allocator.free(bounds);
        parallel.greedyBounds([]const u8, docs, {}, parallel.sliceLen, upper, bounds);

        const shards = try allocator.alloc(ExtractShard, nthr);
        defer allocator.free(shards);
        const threads = try allocator.alloc(std.Thread, nthr);
        defer allocator.free(threads);
        // Private posting buffers use each shard's byte budget as their bound.
        var allocated: usize = 0;
        errdefer for (shards[0..allocated]) |*sh| allocator.free(sh.buf);
        for (0..nthr) |t| {
            const slice = docs[bounds[t]..bounds[t + 1]];
            var bytes: usize = 0;
            for (slice) |d| bytes += d.len;
            shards[t] = .{ .docs = slice, .base_doc = @intCast(bounds[t]), .buf = try allocator.alloc(Posting, @max(bytes, 1)) };
            allocated += 1;
        }
        defer for (shards) |*sh| allocator.free(sh.buf);

        for (0..nthr) |t| threads[t] = std.Thread.spawn(.{}, extractShard, .{&shards[t]}) catch {
            // Couldn't spawn — run remaining shards inline, join what we have.
            for (t..nthr) |u| extractShard(&shards[u]);
            for (0..t) |u| threads[u].join();
            return countingAssemble(allocator, shards, t);
        };
        for (0..nthr) |t| threads[t].join();
        for (shards) |*sh| if (sh.err) return error.OutOfMemory;
        return countingAssemble(allocator, shards, nthr);
    }

    const ExtractShard = struct {
        docs: []const []const u8,
        base_doc: u32,
        buf: []Posting,
        n: usize = 0,
        err: bool = false,
    };

    fn extractShard(sh: *ExtractShard) void {
        // Thread-safe scratch; the caller's allocator may be an arena/non-Sync.
        const scratch = std.heap.page_allocator.alloc(Trigram, maxDocLen(sh.docs)) catch {
            sh.err = true;
            return;
        };
        defer std.heap.page_allocator.free(scratch);
        // One private 2 MiB presence bitmap per shard, zeroed once — each doc
        // clears only its own bits on the way out (O(distinct), no re-memset).
        const bitmap = std.heap.page_allocator.alloc(u64, ngram.bitmap_words) catch {
            sh.err = true;
            return;
        };
        defer std.heap.page_allocator.free(bitmap);
        @memset(bitmap, 0);
        sh.n = emitPostings(sh.docs, sh.base_doc, bitmap, scratch, sh.buf);
    }

    /// Counting-sort doc-major shards into one `(trigram, doc)` slice. O(n+radix).
    fn countingAssemble(allocator: std.mem.Allocator, shards: []ExtractShard, used: usize) std.mem.Allocator.Error![]Posting {
        // Give back each shard's unused tail BEFORE claiming the output buffer.
        //
        // A shard's buffer is sized by its BYTE budget, because that is the only
        // bound available before extraction; per-document dedup then fills a
        // fraction of it. Since this sort is out-of-place, the slack would
        // otherwise be held across the one moment the build needs its most
        // memory — every shard at byte size PLUS an output buffer — which is the
        // peak a resident daemon's whole memory ration has to accommodate
        // (`exec/session/warden/ration.zig`). Capacity only: the postings each
        // shard actually produced, and their order, are untouched.
        for (shards[0..used]) |*sh| {
            if (allocator.remap(sh.buf, @max(sh.n, 1))) |snug| sh.buf = snug;
        }

        var total: usize = 0;
        for (shards[0..used]) |sh| total += sh.n;

        const hist = try allocator.alloc(u32, radix);
        defer allocator.free(hist);
        @memset(hist, 0);
        for (shards[0..used]) |sh| for (sh.buf[0..sh.n]) |p| {
            hist[p.tri] += 1;
        };
        // Prefix-sum counts → bucket start offsets.
        var sum: u32 = 0;
        for (hist) |*h| {
            const c = h.*;
            h.* = sum;
            sum += c;
        }
        const out = try allocator.alloc(Posting, total);
        errdefer allocator.free(out);
        // Scatter in doc-major order ⇒ each bucket lands doc-ascending (stable).
        for (shards[0..used]) |sh| for (sh.buf[0..sh.n]) |p| {
            out[hist[p.tri]] = p;
            hist[p.tri] += 1;
        };
        return out;
    }

    /// Compact sorted postings into one directory triple per trigram plus a
    /// worst-case-sized delta-varint body; both allocations shrink to fit.
    fn compact(allocator: std.mem.Allocator, doc_count: u32, sorted: []const Posting) std.mem.Allocator.Error!Index {
        const dir_tri = try allocator.alloc(u32, @max(sorted.len, 1));
        errdefer allocator.free(dir_tri);
        const dir_off = try allocator.alloc(u32, @max(sorted.len, 1));
        errdefer allocator.free(dir_off);
        const dir_count = try allocator.alloc(u32, @max(sorted.len, 1));
        errdefer allocator.free(dir_count);
        var body = try allocator.alloc(u8, @max(sorted.len * varint.max_len, 1));
        errdefer allocator.free(body);

        var gi: usize = 0; // dir index (distinct-trigram count so far)
        var bp: usize = 0; // body write cursor
        var i: usize = 0;
        while (i < sorted.len) {
            const t = sorted[i].tri;
            const group_off = bp;
            var prev: u32 = 0;
            var cnt: u32 = 0;
            while (i < sorted.len and sorted[i].tri == t) : (i += 1) {
                const doc = sorted[i].doc;
                const delta: u64 = if (cnt == 0) doc else doc - prev;
                bp += varint.encode(body[bp..], delta);
                prev = doc;
                cnt += 1;
            }
            dir_tri[gi] = t;
            dir_off[gi] = @intCast(group_off);
            dir_count[gi] = cnt;
            gi += 1;
        }

        return .{
            .dir_tri = allocator.realloc(dir_tri, gi) catch dir_tri[0..gi],
            .dir_off = allocator.realloc(dir_off, gi) catch dir_off[0..gi],
            .dir_count = allocator.realloc(dir_count, gi) catch dir_count[0..gi],
            // Exact bp lets an empty index free the one-byte placeholder.
            .body = allocator.realloc(body, bp) catch body[0..bp],
            .doc_count = doc_count,
            .posting_count = @intCast(sorted.len),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Index) void {
        if (!self.borrowed) {
            self.allocator.free(self.dir_tri);
            self.allocator.free(self.dir_off);
            self.allocator.free(self.dir_count);
            self.allocator.free(self.body);
        }
        self.* = undefined;
    }

    fn blobView(self: *const Index) blob.Structure {
        return .{ .dir_tri = self.dir_tri, .dir_off = self.dir_off, .dir_count = self.dir_count, .body = self.body, .doc_count = self.doc_count, .posting_count = self.posting_count };
    }

    /// Bytes needed to serialize this index (header + directory + body).
    pub fn serializedSize(self: *const Index) usize {
        return blob.serializedSize(self.blobView());
    }

    /// Serialize IO-free into `buf` (`>= serializedSize()`); returns bytes written.
    pub fn writeInto(self: *const Index, buf: []u8) usize {
        return blob.writeInto(self.blobView(), buf);
    }

    /// Copy a blob into naturally aligned owned directory/body allocations;
    /// unlike `fromMappedBytes`, this never reinterprets raw bytes as `u32`.
    pub fn fromBytes(allocator: std.mem.Allocator, bytes: []const u8) LoadError!Index {
        // The untrusted tier copies and fully validates every byte, so the seal
        // costs it nothing extra and buys the one class of damage the posting
        // decoder cannot see: a flipped bit that still decodes canonically.
        try blob.verify(bytes);
        const h = try blob.parseHeader(bytes);
        var off: usize = header_len;
        var dirs: [3][]u32 = undefined;
        var made: usize = 0;
        errdefer for (dirs[0..made]) |d| allocator.free(d);
        for (&dirs) |*d| {
            d.* = try allocator.alloc(u32, h.n_tri);
            made += 1;
            @memcpy(std.mem.sliceAsBytes(d.*), bytes[off..][0 .. h.n_tri * 4]);
            off += h.n_tri * 4;
        }
        // Exact length (including zero) keeps `deinit`'s free shape identical.
        // The seal is a trailer, not the last posting group.
        const sealed = bytes[0 .. bytes.len - blob.seal_len];
        const body = try allocator.alloc(u8, sealed.len - off);
        errdefer allocator.free(body);
        @memcpy(body, sealed[off..]);
        // Reject corrupt copied bodies; errdefers release every region.
        try blob.validateStructure(.{ .dir_tri = dirs[0], .dir_off = dirs[1], .dir_count = dirs[2], .body = body, .doc_count = h.doc_count, .posting_count = h.posting_count });
        return .{ .dir_tri = dirs[0], .dir_off = dirs[1], .dir_count = dirs[2], .body = body, .doc_count = h.doc_count, .posting_count = h.posting_count, .allocator = allocator };
    }

    fn borrowMapped(m: blob.MappedRegions) Index {
        // `allocator` is undefined — unused: `borrowed` ⇒ `deinit` frees nothing
        return .{ .dir_tri = m.dir_tri, .dir_off = m.dir_off, .dir_count = m.dir_count, .body = m.body, .doc_count = m.header.doc_count, .posting_count = m.header.posting_count, .allocator = undefined, .borrowed = true };
    }

    /// Borrow after FULL eager posting validation: the untrusted/test contract.
    /// The seal is checked here for the same reason `fromBytes` checks it — an
    /// eager loader has already committed to reading every byte, and the two
    /// eager loaders must never disagree about whether a blob is acceptable.
    pub fn fromMappedBytes(bytes: []const u8) LoadError!Index {
        try blob.verify(bytes);
        const m = try blob.parseMapped(bytes);
        try blob.validateStructure(m.structure());
        return borrowMapped(m);
    }

    /// Borrow Gist's atomically-written LOCAL cache after directory validation.
    /// Touched groups validate lazily and return `Corrupt` for full-walk.
    pub fn fromTrustedMappedBytes(bytes: []const u8) LoadError!Index {
        const m = try blob.parseMapped(bytes);
        try blob.validateDirectory(m.structure());
        return borrowMapped(m);
    }

    /// Binary-search `tri`, or null when its candidate set is soundly empty.
    fn dirIndexOf(self: *const Index, tri: Trigram) ?usize {
        var lo: usize = 0;
        var hi: usize = self.dir_tri.len;
        while (lo < hi) {
            const m = lo + (hi - lo) / 2;
            if (self.dir_tri[m] < tri) lo = m + 1 else if (self.dir_tri[m] > tri) hi = m else return m;
        }
        return null;
    }

    fn decodeGroup(self: *const Index, gi: usize, out: []u32) QueryError!usize {
        return blob.decodeGroup(self.blobView(), gi, out) catch QueryError.Corrupt;
    }

    fn dirCountLess(self: *const Index, a: usize, b: usize) bool {
        return self.dir_count[a] < self.dir_count[b];
    }

    /// Intersect ascending lists into `a`; the write cursor cannot outrun reads.
    fn intersectAscending(a: []u32, b: []const u32) usize {
        var i: usize = 0;
        var j: usize = 0;
        var w: usize = 0;
        while (i < a.len and j < b.len) {
            if (a[i] < b[j]) {
                i += 1;
            } else if (a[i] > b[j]) {
                j += 1;
            } else {
                a[w] = a[i];
                w += 1;
                i += 1;
                j += 1;
            }
        }
        return w;
    }

    /// Candidate docs that *may* contain `needle` (AND of its trigrams' posting
    /// lists). Returned slice is caller-owned (same allocator), sorted ascending.
    /// `needle.len < 3` ⇒ NeedleTooShort (caller full-scans; can't filter < 3 B).
    ///
    /// T1 — rarest-first: resolve each trigram's directory group, order by
    /// posting COUNT (exact, from `dir_count` — no decode needed to compare),
    /// decode the rarest fully as the seed, then decode+merge-intersect each
    /// remaining group outward. AND is commutative so order is irrelevant, but
    /// the rarest seed (not lexicographically-first) stays small and shrinks
    /// fastest — e.g. "context.Context" no longer seeds on "con".
    pub fn queryLiteral(self: *const Index, allocator: std.mem.Allocator, needle: []const u8) QueryError![]u32 {
        var lazy: ?[]u32 = null;
        defer if (lazy) |s| allocator.free(s);
        return self.queryLiteralWith(allocator, needle, &lazy);
    }

    /// `queryLiteral` over a caller-owned lazy scratch cell: the `doc_count`-
    /// sized decode buffer is allocated at most ONCE into `lazy` (only when a
    /// needle actually has >1 trigram group) and reused across calls, so a
    /// k-branch `queryAny` pays one scratch instead of k. Caller frees `lazy`.
    fn queryLiteralWith(self: *const Index, allocator: std.mem.Allocator, needle: []const u8, lazy: *?[]u32) QueryError![]u32 {
        if (needle.len < 3) return QueryError.NeedleTooShort;
        const local_cap = 128;
        var local_trigrams: [local_cap]Trigram = undefined;
        const qbuf = if (needle.len <= local_cap)
            local_trigrams[0..needle.len]
        else
            try allocator.alloc(Trigram, needle.len);
        defer if (needle.len > local_cap) allocator.free(qbuf);
        const m = ngram.extractSortedUnique(needle, qbuf);
        if (m == 0) return QueryError.NeedleTooShort;

        var local_groups: [local_cap]usize = undefined;
        const groups = if (m <= local_cap)
            local_groups[0..m]
        else
            try allocator.alloc(usize, m);
        defer if (m > local_cap) allocator.free(groups);
        for (qbuf[0..m], 0..) |t, i| groups[i] = self.dirIndexOf(t) orelse return allocator.alloc(u32, 0);
        std.mem.sort(usize, groups, self, dirCountLess);

        const seed = groups[0];
        var cand = try allocator.alloc(u32, self.dir_count[seed]);
        errdefer allocator.free(cand);
        var n = try self.decodeGroup(seed, cand);

        if (groups.len > 1) {
            if (lazy.* == null) lazy.* = try allocator.alloc(u32, self.doc_count);
            const scratch = lazy.*.?;
            for (groups[1..]) |gi| {
                const cnt = try self.decodeGroup(gi, scratch);
                n = intersectAscending(cand[0..n], scratch[0..cnt]);
                if (n == 0) break;
            }
        }
        return allocator.realloc(cand, n) catch cand[0..n];
    }

    /// One conjunct of a prefilter plan: the AND of the trigrams of EVERY
    /// literal in it. `{"func"}` spells the conjunct as the literal it came
    /// from; `{"etu","ret","tur","urn"}` spells the same conjunct as bare
    /// trigrams. Both forms mean "a candidate holds all of these trigrams".
    pub const Atom = []const []const u8;

    /// A disjunction of atoms — a document survives the clause when ANY atom's
    /// trigrams are all present. One clause is exactly what `queryAny` answers.
    pub const Clause = []const Atom;

    /// Estimated posting work for one clause: Σ over its atoms of Σ over their
    /// trigrams of the group cardinality. An absent trigram makes its atom
    /// vacuous (cost 0) — the atom, and possibly the whole clause, is empty.
    fn clauseWork(self: *const Index, clause: Clause) u64 {
        var work: u64 = 0;
        for (clause) |atom| for (atom) |lit| {
            if (lit.len < 3) continue;
            for (0..lit.len - 2) |i| {
                if (self.dirIndexOf(ngram.pack(lit[i..][0..3].*))) |gi| work += self.dir_count[gi];
            }
        };
        return work;
    }

    /// How far past the cheapest clause's posting work a further clause may
    /// cost before it is dropped. Dropping a conjunct only WIDENS the candidate
    /// set (see `queryPlan`), so this ceiling can never cost a match — it is a
    /// pure work/pruning trade, and 64x is where a clause stops paying for its
    /// own decode on the measured slate (`bench/sieve/indexq.zig`).
    const plan_work_ratio: u64 = 64;
    /// Directory groups one atom may resolve; past this the atom is declined
    /// (sound — it only widens). 4096 covers every literal a plan can carry.
    const plan_group_cap: usize = 4096;
    /// Posting entries whose decode costs about what *scanning one average
    /// candidate document* costs — the exchange rate between the two things a
    /// prefilter trades. A source file averages ~10 KB and the scan kernel runs
    /// at ~2 GB/s (Layer A), so a document is ~5 µs of scanning; a posting entry
    /// is ~1 ns to decode and intersect. 4096 is that ratio, rounded toward
    /// evaluating.
    ///
    /// This is the denominator `plan_work_ratio` cannot supply. Once a clause
    /// has already cut the candidate set to `n` documents, the *marginal*
    /// question is no longer "how does this clause compare to the cheapest one"
    /// but "does decoding it cost less than just reading the n documents it
    /// could filter". Without it, `pgxpool\.\w+` spent 6.1 ms of posting decode
    /// to remove 86 KB of scanning — measured, and the reason this exists.
    const plan_scan_equivalent: u64 = 4096;

    /// Candidate docs for a CNF prefilter plan: **AND over clauses, OR over the
    /// atoms of a clause, AND over the trigrams of an atom.** This is the
    /// general shape a regex→trigram planner produces (Cox 2012 builds the same
    /// boolean formula), and it strictly generalizes the two narrower entry
    /// points beside it: `queryLiteral` is a one-clause one-atom plan, and
    /// `queryAny` is a one-clause plan whose atoms are single literals.
    ///
    /// **Dropping a clause only widens the answer**, because the plan is a
    /// conjunction — so this evaluates clauses CHEAPEST-FIRST by measured
    /// posting cardinality and declines any clause costing more than
    /// `plan_work_ratio`x the cheapest, with no soundness argument needed per
    /// rule. That measured choice is the thing a purely syntactic planner
    /// cannot make: posting counts exist only here, in the built index.
    ///
    /// Sorted ascending, caller-owned, same allocator. An empty plan (or a
    /// clause no atom can filter) yields `NeedleTooShort` so the caller keeps
    /// its full-scan fallback rather than silently dropping matches.
    pub fn queryPlan(self: *const Index, allocator: std.mem.Allocator, plan: []const Clause) QueryError![]u32 {
        if (plan.len == 0) return QueryError.NeedleTooShort;
        if (plan.len == 1 and plan[0].len == 1 and plan[0][0].len == 1) return self.queryLiteral(allocator, plan[0][0][0]);

        // Cost-order the clauses without decoding anything: `dir_count` is the
        // exact cardinality, already in the directory.
        const order = try allocator.alloc(usize, plan.len);
        defer allocator.free(order);
        const work = try allocator.alloc(u64, plan.len);
        defer allocator.free(work);
        for (plan, order, work, 0..) |clause, *o, *w, i| {
            o.* = i;
            w.* = self.clauseWork(clause);
        }
        std.mem.sort(usize, order, work, struct {
            fn less(w: []const u64, a: usize, b: usize) bool {
                return w[a] < w[b];
            }
        }.less);

        var scratch: ?[]u32 = null;
        defer if (scratch) |s| allocator.free(s);
        var cand: ?[]u32 = null;
        errdefer if (cand) |c| allocator.free(c);
        var n: usize = 0;
        const budget = work[order[0]] *| plan_work_ratio;
        for (order) |ci| {
            // Two independent ceilings, both pure work/pruning trades (dropping
            // a conjunct only widens, so neither can cost a match): the clause
            // must be affordable against the cheapest clause, AND against the
            // candidate set it would actually be filtering.
            if (cand != null and (n == 0 or work[ci] > budget or work[ci] > @as(u64, n) *| plan_scan_equivalent)) break;
            const next = self.queryClause(allocator, plan[ci], &scratch) catch |e| switch (e) {
                // A clause that cannot filter is simply not a constraint.
                QueryError.NeedleTooShort => if (cand == null) return e else continue,
                else => return e,
            };
            if (cand) |c| {
                defer allocator.free(next);
                n = intersectAscending(c[0..n], next);
            } else {
                cand = next;
                n = next.len;
            }
        }
        const c = cand orelse return QueryError.NeedleTooShort;
        return allocator.realloc(c, n) catch c[0..n];
    }

    /// The candidate set of ONE clause: the union over its atoms of the AND of
    /// each atom's trigrams. `queryAny`'s answer when every atom is a single
    /// literal, generalized to atoms spelled as several literals.
    fn queryClause(self: *const Index, allocator: std.mem.Allocator, clause: Clause, scratch: *?[]u32) QueryError![]u32 {
        if (clause.len == 0) return QueryError.NeedleTooShort;
        var total: usize = 0;
        const lists = try allocator.alloc([]u32, clause.len);
        var got: usize = 0;
        defer {
            for (lists[0..got]) |l| allocator.free(l);
            allocator.free(lists);
        }
        for (clause, lists) |atom, *slot| {
            slot.* = try self.queryAtom(allocator, atom, scratch);
            got += 1;
            total += slot.len;
        }
        if (got == 1) {
            got = 0; // ownership of the one list moves to the caller; `lists` still frees
            return lists[0];
        }
        const buf = try allocator.alloc(u32, total);
        errdefer allocator.free(buf);
        var n: usize = 0;
        for (lists[0..got]) |l| {
            @memcpy(buf[n..][0..l.len], l);
            n += l.len;
        }
        std.mem.sort(u32, buf[0..n], {}, comptime std.sort.asc(u32));
        const w = ngram.dedupSorted(u32, buf, n);
        return allocator.realloc(buf, w) catch buf[0..w];
    }

    /// The candidate set of ONE atom: the AND of the trigrams of every literal
    /// it names, rarest group first (`queryLiteral`'s T1 order, over a multi-
    /// literal trigram set). Every literal must be ≥3 bytes or the atom cannot
    /// be filtered at all.
    fn queryAtom(self: *const Index, allocator: std.mem.Allocator, atom: Atom, lazy: *?[]u32) QueryError![]u32 {
        if (atom.len == 0) return QueryError.NeedleTooShort;
        if (atom.len == 1) return self.queryLiteralWith(allocator, atom[0], lazy);
        var span: usize = 0;
        for (atom) |lit| {
            if (lit.len < 3) return QueryError.NeedleTooShort;
            span += lit.len - 2;
        }
        if (span > plan_group_cap) return QueryError.NeedleTooShort;
        const groups = try allocator.alloc(usize, span);
        defer allocator.free(groups);
        var m: usize = 0;
        for (atom) |lit| for (0..lit.len - 2) |i| {
            const gi = self.dirIndexOf(ngram.pack(lit[i..][0..3].*)) orelse return allocator.alloc(u32, 0);
            groups[m] = gi;
            m += 1;
        };
        std.mem.sort(usize, groups[0..m], self, dirCountLess);
        const seed = groups[0];
        var cand = try allocator.alloc(u32, self.dir_count[seed]);
        errdefer allocator.free(cand);
        var n = try self.decodeGroup(seed, cand);
        if (m > 1) {
            if (lazy.* == null) lazy.* = try allocator.alloc(u32, self.doc_count);
            const buf = lazy.*.?;
            for (groups[1..m]) |gi| {
                if (gi == seed) continue; // a repeated trigram adds nothing
                const cnt = try self.decodeGroup(gi, buf);
                n = intersectAscending(cand[0..n], buf[0..cnt]);
                if (n == 0) break;
            }
        }
        return allocator.realloc(cand, n) catch cand[0..n];
    }

    /// TEST/DEBUG ONLY: fully decode the index back into a sorted `(tri, doc)`
    /// list — O(postings), never on the query hot path. Lets round-trip/parity
    /// tests assert byte-for-byte equivalence without exposing the compact
    /// on-disk representation to the public query API.
    pub fn debugAllPostings(self: *const Index, allocator: std.mem.Allocator) QueryError![]Posting {
        const out = try allocator.alloc(Posting, self.posting_count);
        errdefer allocator.free(out);
        const scratch = try allocator.alloc(u32, self.doc_count);
        defer allocator.free(scratch);
        var w: usize = 0;
        for (self.dir_tri, 0..) |t, gi| {
            const cnt = try self.decodeGroup(gi, scratch);
            if (w > out.len or cnt > out.len - w) return QueryError.Corrupt;
            for (scratch[0..cnt]) |d| {
                out[w] = .{ .tri = t, .doc = d };
                w += 1;
            }
        }
        if (w != out.len) return QueryError.Corrupt;
        return out;
    }

    /// Union of the candidate sets of `needles` (each ≥3 B) — the sound superset
    /// for an alternation where every match contains one of them. Sorted ascending
    /// and deduplicated, caller-owned. A sub-query error (e.g. a needle < 3 B)
    /// propagates so the caller full-scans rather than drop a branch's matches.
    pub fn queryAny(self: *const Index, allocator: std.mem.Allocator, needles: []const []const u8) QueryError![]u32 {
        if (needles.len == 1) return self.queryLiteral(allocator, needles[0]);
        // Resolve every branch first so the union buffer is allocated ONCE at
        // its exact size — the old shape realloc'd (and re-copied) the growing
        // buffer per needle, O(total·k) moves for a k-branch alternation.
        // One lazy `doc_count`-sized decode scratch is shared by every branch
        // (each branch used to allocate + free its own).
        var scratch: ?[]u32 = null;
        defer if (scratch) |s| allocator.free(s);
        const lists = try allocator.alloc([]u32, needles.len);
        var got: usize = 0;
        defer {
            for (lists[0..got]) |l| allocator.free(l);
            allocator.free(lists);
        }
        var total: usize = 0;
        for (needles, lists) |needle, *slot| {
            slot.* = try self.queryLiteralWith(allocator, needle, &scratch);
            got += 1;
            total += slot.len;
        }
        const buf = try allocator.alloc(u32, total);
        errdefer allocator.free(buf);
        var n: usize = 0;
        for (lists) |l| {
            @memcpy(buf[n..][0..l.len], l);
            n += l.len;
        }
        // Each branch is already sorted, so the concatenation is k sorted runs
        // — a shape the stable block sort handles near-linearly.
        std.mem.sort(u32, buf[0..n], {}, comptime std.sort.asc(u32));
        const w = ngram.dedupSorted(u32, buf, n); // dedup the now-sorted union
        return allocator.realloc(buf, w) catch buf[0..w];
    }
};
