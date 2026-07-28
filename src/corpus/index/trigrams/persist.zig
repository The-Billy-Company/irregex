// MONOLITHIC: persisted trigram-index loader/serializer — magic and versioning, the CSR directory, the generation-atomic pair, and mmap load form one on-disk format contract shared by every cold path
//! gist — the persisted-index loader, shared by every cold-query path.
//!
//! `surface/face/gist/verbs/index.zig`'s `run` (the `gist index` verb) serializes the trigram
//! `Index` + the doc→path table to disk; each later fresh process maps them back
//! **zero-copy** and validates only the compact directory up front. Posting
//! groups are checked when queried, avoiding a full body decode on every fresh
//! process. That cold-load path is shared by every shape the unified engine
//! serves — the index-accelerated read-elision walk (`exec/cold/engine/serial.zig`)
//! and the `--rank` ranked view (`exec/cold/view/ranked.zig`) — so it lives
//! here, in the index layer, rather than in a command (a command importing
//! another command's internals is the coupling this split exists to kill).
//!
//! Publish is generation-atomic: both blobs land under `gens/<id>/` first, then
//! a single `pair.gen` rename publishes the pair. Readers bind to that id and
//! re-check it after mapping, so they never observe new `index.gist` with old
//! `paths.list` (or the reverse). Publishing also retires the generations it
//! supersedes — `lapse.zig` owns that policy, and `publishGeneration` is the
//! one place the two halves meet.

const std = @import("std");
const trigram = @import("trigram.zig");
const fault = @import("../../../fault.zig");
const Index = trigram.Index;
const crest = @import("../../../kernel/math/crest.zig");
const crest_sidecar = @import("../crest/sidecar.zig");
const codicil_mod = @import("codicil.zig");
const ngram = @import("ngram.zig");
const sliver = @import("sliver.zig");
const lapse = @import("lapse.zig");
const frame = @import("../frame/frame.zig");
const assay = @import("../../../assay/assay.zig");
const portal = @import("../../../portal.zig");
const home = @import("../frame/home.zig");
const Dir = std.Io.Dir;
// The mapping + atomic-publish primitives are shared wire discipline and live
// in `../frame/`; these are import aliases, not a second implementation.
const Mapping = frame.Mapping;
const mmapFile = frame.mmapFile;
const writeAtomic = frame.writeAtomic;

/// Stable aliases (status / bench size accounting). The query loader prefers the
/// generation published by `pair.gen` when present.
const index_alias = home.ArtifactPath("index.gist");
const paths_alias = home.ArtifactPath("paths.list");
const generation_alias = home.ArtifactPath("pair.gen");
pub fn indexFile() []const u8 {
    return index_alias.get();
}
pub fn pathsFile() []const u8 {
    return paths_alias.get();
}
pub fn generationFile() []const u8 {
    return generation_alias.get();
}

/// Published `pair.gen` contents (gpa-owned; "" when absent). A rebuilt index
/// changes this — both resident sessions probe it to decide `maybeReload`.
pub fn readPublishedGeneration(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const buf = Dir.cwd().readFileAlloc(io, generationFile(), gpa, .limited(128)) catch
        return gpa.alloc(u8, 0);
    const trimmed = std.mem.trimEnd(u8, buf, "\r\n");
    if (trimmed.len == buf.len) return buf;
    defer gpa.free(buf);
    return gpa.dupe(u8, trimmed);
}

pub const gens_subdir = "gens";

/// The cold-loaded index + the doc→path table that maps candidate ids back to
/// files. Both are mmap'd: `idx`'s directory + body slices alias into `imap`
/// (borrowed, no copy) and every `paths` slice aliases into `pmap`, so all
/// lifetimes bind to the two mappings and `deinit` simply unmaps them.
///
/// A generation may additionally carry a CODICIL (`codicil.zig`) — the
/// incremental amendment `gist index` publishes when only a few files changed.
/// The loader folds it in here so every consumer sees ONE layered view:
/// `paths` is extended with the codicil's new docs, `crest` becomes the merged
/// owned table (dirty rows replaced, tombs never-prune), and candidate queries
/// go through `queryLiteral`/`queryAny` below (base ∪ codicil ∪ tombstones)
/// instead of `idx` directly. A missing/rejected codicil costs nothing: the
/// base index answers exactly as before.
pub const Persisted = struct {
    imap: Mapping,
    pmap: Mapping,
    idx: Index,
    /// The crest-sieve sidecar (`corpus/index/crest/sidecar.zig`), mapped zero-copy —
    /// null for a legacy cache or any blob `decode` rejects. Purely additive:
    /// queries without it just lose the sieve, never correctness. When a
    /// codicil is live this is instead an OWNED merged table (`crest_allocation`).
    cmap: ?Mapping = null,
    crest: ?[]const crest.Vector = null,
    /// Mutable owner retained separately when `crest` views a merged allocation.
    crest_allocation: ?[]crest.Vector = null,
    /// Base-index documents this loader could NOT prove are ≥ 3 bytes long, and
    /// which therefore own no trigram and appear in no posting list. The sliver
    /// tier (`sliver.zig`) unions them in unconditionally, which is the whole
    /// reason a sub-trigram needle can be answered from the trigram directory
    /// at all. Derived once at load from the BASE crest table — before any
    /// codicil merge rewrites rows — so it describes exactly the corpus the
    /// base postings were built over. Null when no crest sidecar loaded, which
    /// fail-closes the tier back to a full scan.
    short_docs: ?[]u32 = null,
    /// The codicil mapping + decoded view (slices alias `codmap`); null when
    /// this generation has none (a fresh full build, or a rejected blob).
    codmap: ?Mapping = null,
    cod: ?codicil_mod.Decoded = null,
    paths: std.ArrayList([]const u8),
    /// Heap copy of `roots.list` — null for a legacy pre-roots cache.
    roots_blob: ?[]u8,
    /// The roots this index was BUILT over (NUL-separated in `roots_blob`,
    /// or `.` for a legacy cache — the sound superset). Query paths fold
    /// freshness over these, never a re-derived guess.
    roots: std.ArrayList([]const u8),
    /// The published generation id this pair was loaded from (gpa-owned);
    /// null for a legacy stable-alias cache. The amend path binds to it.
    gen: ?[]u8 = null,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Persisted) void {
        if (self.gen) |g| self.gpa.free(g);
        self.roots.deinit(self.gpa);
        if (self.roots_blob) |b| self.gpa.free(b);
        self.paths.deinit(self.gpa);
        self.idx.deinit(); // borrowed ⇒ frees nothing
        if (self.crest_allocation) |table| self.gpa.free(table);
        if (self.short_docs) |s| self.gpa.free(s);
        if (self.codmap) |m| portal.unmap(m);
        if (self.cmap) |m| portal.unmap(m);
        portal.unmap(self.pmap);
        portal.unmap(self.imap);
    }

    /// Candidate docs that may contain `needle` across BOTH layers: base-index
    /// hits ∪ codicil hits (mapped to global ids) ∪ tombstoned docs (their
    /// base postings are stale, so they are always read, never elided).
    /// Same contract as `Index.queryLiteral`: sorted ascending, caller-owned.
    pub fn queryLiteral(self: *const Persisted, gpa: std.mem.Allocator, needle: []const u8) trigram.QueryError![]u32 {
        if (needle.len <= sliver.max_len) return self.querySliver(gpa, needle);
        const base = try self.idx.queryLiteral(gpa, needle);
        const c = self.cod orelse return base;
        const local = c.idx.queryLiteral(gpa, needle) catch |e| {
            gpa.free(base);
            return e;
        };
        defer gpa.free(local);
        return mergeLayers(gpa, base, local, c.ids, c.tombs);
    }

    /// An alternation whose branches straddle the trigram floor. Each branch is
    /// bounded by whichever tier can bound it — the directory for ≥3 bytes, the
    /// sliver for less — and the union of sound per-branch supersets is a sound
    /// superset of the alternation. One branch nothing can bound leaves the
    /// whole union unbounded, so a decline propagates and the caller full-scans.
    fn queryMixed(self: *const Persisted, gpa: std.mem.Allocator, needles: []const []const u8) trigram.QueryError![]u32 {
        const short = self.short_docs orelse return trigram.QueryError.NeedleTooShort;
        const lists = try gpa.alloc([]u32, needles.len);
        var got: usize = 0;
        defer {
            for (lists[0..got]) |l| gpa.free(l);
            gpa.free(lists);
        }
        var total: usize = 0;
        for (needles, lists) |n, *slot| {
            slot.* = if (n.len <= sliver.max_len)
                try sliver.candidates(&self.idx, gpa, n, short)
            else
                try self.idx.queryLiteral(gpa, n);
            got += 1;
            total += slot.len;
        }
        const buf = try gpa.alloc(u32, total);
        var w: usize = 0;
        for (lists[0..got]) |l| {
            @memcpy(buf[w..][0..l.len], l);
            w += l.len;
        }
        std.mem.sort(u32, buf[0..w], {}, comptime std.sort.asc(u32));
        const n = ngram.dedupSorted(u32, buf, w);
        const base = gpa.realloc(buf, n) catch buf[0..n];

        const c = self.cod orelse return base;
        const all = gpa.alloc(u32, c.ids.len) catch |e| {
            gpa.free(base);
            return e;
        };
        defer gpa.free(all);
        for (all, 0..) |*slot, i| slot.* = @intCast(i);
        return mergeLayers(gpa, base, all, c.ids, c.tombs);
    }

    /// A sub-trigram needle answered from the trigram directory (`sliver.zig`),
    /// with the two admissions that module cannot make for itself: the documents
    /// too short to own a trigram, and every codicil document — amended or
    /// tombstoned — whose base postings no longer speak for its bytes.
    ///
    /// Declines with `NeedleTooShort` when no crest sidecar loaded (nothing
    /// proves which documents are short) or when the union outprices its budget.
    /// Either way the caller keeps the full scan it has always had.
    fn querySliver(self: *const Persisted, gpa: std.mem.Allocator, needle: []const u8) trigram.QueryError![]u32 {
        const short = self.short_docs orelse return trigram.QueryError.NeedleTooShort;
        const base = try sliver.candidates(&self.idx, gpa, needle, short);
        const c = self.cod orelse return base;
        // `mergeLayers` maps a codicil-local list through `c.ids`; admitting the
        // whole layer is that map applied to every local id in order.
        const all = gpa.alloc(u32, c.ids.len) catch |e| {
            gpa.free(base);
            return e;
        };
        defer gpa.free(all);
        for (all, 0..) |*slot, i| slot.* = @intCast(i);
        return mergeLayers(gpa, base, all, c.ids, c.tombs);
    }

    /// `Index.queryAny` across both layers (see `queryLiteral`). An alternation
    /// mixing sub-trigram branches with ordinary ones (`panic|0x`) is unioned
    /// per branch by `queryMixed` rather than declined.
    pub fn queryAny(self: *const Persisted, gpa: std.mem.Allocator, needles: []const []const u8) trigram.QueryError![]u32 {
        if (needles.len == 1) return self.queryLiteral(gpa, needles[0]);
        for (needles) |n| {
            if (n.len <= sliver.max_len) return self.queryMixed(gpa, needles);
        }
        const base = try self.idx.queryAny(gpa, needles);
        const c = self.cod orelse return base;
        const local = c.idx.queryAny(gpa, needles) catch |e| {
            gpa.free(base);
            return e;
        };
        defer gpa.free(local);
        return mergeLayers(gpa, base, local, c.ids, c.tombs);
    }

    /// `Index.queryPlan` across both layers (see `queryLiteral`). The codicil is
    /// its own index, so it re-runs the same plan and picks its own cheapest
    /// clause order over its own cardinalities — both answers are supersets of
    /// their layer's true matches, so the union stays sound.
    pub fn queryPlan(self: *const Persisted, gpa: std.mem.Allocator, plan: []const trigram.Index.Clause) trigram.QueryError![]u32 {
        const base = try self.idx.queryPlan(gpa, plan);
        const c = self.cod orelse return base;
        const local = c.idx.queryPlan(gpa, plan) catch |e| {
            gpa.free(base);
            return e;
        };
        defer gpa.free(local);
        return mergeLayers(gpa, base, local, c.ids, c.tombs);
    }
};

/// Three-way sorted union: `base` (consumed/freed) ∪ `local` mapped through
/// `map` (codicil local→global, both ascending ⇒ mapped stays ascending) ∪
/// `tombs`. Deduplicated, ascending, caller-owned.
fn mergeLayers(gpa: std.mem.Allocator, base: []u32, local: []const u32, map: []const u32, tombs: []const u32) trigram.QueryError![]u32 {
    const out = gpa.alloc(u32, base.len + local.len + tombs.len) catch |e| {
        gpa.free(base);
        return e;
    };
    var i: usize = 0; // base cursor
    var j: usize = 0; // local (codicil) cursor
    var k: usize = 0; // tombs cursor
    var w: usize = 0;
    while (true) {
        var next: u32 = std.math.maxInt(u32);
        var any = false;
        if (i < base.len) {
            next = base[i];
            any = true;
        }
        if (j < local.len and map[local[j]] <= next) {
            next = map[local[j]];
            any = true;
        }
        if (k < tombs.len and tombs[k] <= next) {
            next = tombs[k];
            any = true;
        }
        if (!any) break;
        while (i < base.len and base[i] == next) i += 1;
        while (j < local.len and map[local[j]] == next) j += 1;
        while (k < tombs.len and tombs[k] == next) k += 1;
        out[w] = next;
        w += 1;
    }
    gpa.free(base);
    return gpa.realloc(out, w) catch out[0..w];
}

/// Cold-load the persisted index + doc→path table by mmap (zero-copy). Returns
/// null (after printing guidance) when no index has been built yet — the one
/// expected miss. Paths are NUL-separated in doc-id order; the list is pre-sized
/// from the NUL count so the split is one allocation.
pub fn load(gpa: std.mem.Allocator, io: std.Io) !?Persisted {
    return loadAt(gpa, io, home.outDir(), true);
}

/// `load`, but SILENT on a miss (no "run `gist index`" guidance). The bare
/// `gist <pattern>` front door probes for an index on every invocation to
/// accelerate its live walk (skip reading provable-non-candidate files —
/// `exec/cold/engine/serial.zig`), and outside an indexed corpus that probe MUST
/// stay quiet: a missing index there is the normal case, not something to nag
/// about, and the walk falls back to reading every file exactly as before.
pub fn loadQuiet(gpa: std.mem.Allocator, io: std.Io) !?Persisted {
    return loadAt(gpa, io, home.outDir(), false);
}

/// Doc→path table integrity: the index guarantees every candidate id < doc_count,
/// but that only prevents an out-of-bounds path lookup if the table holds EXACTLY
/// doc_count entries. Called by the loader; exposed for tests.
///
/// Both members come from the declared `persist` domain (ADR-373 law 2). A path
/// table of the wrong length IS corruption — the two blobs were written by
/// different builds — and saying so in the shared vocabulary is what lets the
/// loader handle every untrustworthy-bytes fact with one prong.
pub const PairError = error{ Corrupt, GenerationMismatch };
pub fn validatePersistedPair(doc_count: u32, paths: []const []const u8) PairError!void {
    if (paths.len != doc_count) return PairError.Corrupt;
}

pub fn validateGeneration(observed: []const u8, published: []const u8) PairError!void {
    if (!std.mem.eql(u8, observed, published)) return PairError.GenerationMismatch;
}

fn joinPath(buf: []u8, parts: anytype) ![]u8 {
    comptime var fmt: []const u8 = "{s}";
    inline for (1..parts.len) |_| fmt = fmt ++ "/{s}";
    return std.fmt.bufPrint(buf, fmt, parts);
}

/// The per-pair blob paths (index / paths / roots / crest sidecar / codicil /
/// base anchor) under one directory, formatted into caller-lifetime buffers.
const PairFiles = struct {
    bufs: [6][512]u8 = undefined,
    index: []const u8 = undefined,
    paths: []const u8 = undefined,
    roots: []const u8 = undefined,
    crest: []const u8 = undefined,
    codicil: []const u8 = undefined,
    basens: []const u8 = undefined,

    fn init(self: *PairFiles, dir: []const u8) !void {
        self.index = try joinPath(&self.bufs[0], .{ dir, "index.gist" });
        self.paths = try joinPath(&self.bufs[1], .{ dir, "paths.list" });
        self.roots = try joinPath(&self.bufs[2], .{ dir, "roots.list" });
        self.crest = try joinPath(&self.bufs[3], .{ dir, crest_sidecar.file_name });
        self.codicil = try joinPath(&self.bufs[4], .{ dir, codicil_mod.file_name });
        self.basens = try joinPath(&self.bufs[5], .{ dir, codicil_mod.base_ns_name });
    }
};

fn readGenerationFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    const buf = Dir.cwd().readFileAlloc(io, path, gpa, .limited(128)) catch return null;
    const trimmed = std.mem.trimEnd(u8, buf, "\r\n");
    if (trimmed.len == buf.len and buf.len > 0) return buf;
    defer gpa.free(buf);
    return if (trimmed.len == 0) null else try gpa.dupe(u8, trimmed);
}

fn loadMappedPair(gpa: std.mem.Allocator, io: std.Io, pf: *const PairFiles, gen: ?[]const u8, comptime verbose: bool) !?Persisted {
    const imap = mmapFile(io, pf.index) catch {
        if (verbose) assay.diag("no index at {s} — run `gist index` first\n", .{pf.index});
        return null;
    };
    errdefer portal.unmap(imap);
    var idx = try Index.fromTrustedMappedBytes(imap);
    errdefer idx.deinit();

    const pmap = mmapFile(io, pf.paths) catch {
        if (verbose) assay.diag("incomplete index — {s} missing; run `gist index` to rebuild\n", .{pf.paths});
        portal.unmap(imap);
        return null;
    };
    errdefer portal.unmap(pmap);
    var paths = try frame.parsePathTable(gpa, pmap);
    errdefer paths.deinit(gpa);
    validatePersistedPair(idx.doc_count, paths.items) catch {
        if (verbose) assay.diag("index/paths mismatch ({d} paths != {d} docs) — run `gist index` to rebuild\n", .{ paths.items.len, idx.doc_count });
        paths.deinit(gpa);
        portal.unmap(pmap);
        portal.unmap(imap);
        return null;
    };

    // Build roots (NUL-separated, tiny). A legacy cache predates roots.list
    // (and an empty file is corruption); either way fall back to `.` — the
    // whole tree is a sound superset of whatever the index was built over
    // (elision keys on the persisted path set, never on roots; a wider
    // freshness walk only re-reads more, it never wrongly skips).
    var roots_blob: ?[]u8 = Dir.cwd().readFileAlloc(io, pf.roots, gpa, .limited(1 << 16)) catch null;
    errdefer if (roots_blob) |b| gpa.free(b);
    var roots = if (roots_blob) |b| try frame.parsePathTable(gpa, b) else std.ArrayList([]const u8).empty;
    errdefer roots.deinit(gpa);
    if (roots.items.len == 0) {
        if (roots_blob) |b| gpa.free(b);
        roots_blob = null;
        roots.clearRetainingCapacity();
        try roots.append(gpa, ".");
    }

    // Crest sidecar: optional, fail-closed. A miss or a rejected blob costs
    // only the sieve (the query still answers exactly), so both read as null.
    var cmap: ?Mapping = mmapFile(io, pf.crest) catch null;
    var crest_view: ?[]const crest.Vector = if (cmap) |m| crest_sidecar.decode(m, idx.doc_count) else null;
    if (cmap != null and crest_view == null) {
        portal.unmap(cmap.?);
        cmap = null;
    }

    // The sliver tier's soundness premise, resolved once against the BASE table
    // (a codicil merge below rewrites rows, so this must read it first).
    const short_docs: ?[]u32 = if (crest_view) |base_table| try shortDocs(gpa, base_table) else null;
    errdefer if (short_docs) |s| gpa.free(s);

    // Codicil: optional, fail-closed, and bound to the EXACT generation id (a
    // legacy stable-alias load has no gen, so it never sees one). On admit the
    // layered view is materialized here once: paths extended with the new
    // docs, crest replaced by an owned merged table whose codicil rows are the
    // recomputed vectors (tombstones never-prune) — so every consumer's
    // per-doc lookup stays a plain slice index.
    const gen_owned: ?[]u8 = if (gen) |g| try gpa.dupe(u8, g) else null;
    errdefer if (gen_owned) |g| gpa.free(g);
    var codmap: ?Mapping = null;
    var cod: ?codicil_mod.Decoded = null;
    var crest_allocation: ?[]crest.Vector = null;
    errdefer if (codmap) |m| portal.unmap(m);
    if (gen) |g| blk: {
        const m = mmapFile(io, pf.codicil) catch break :blk;
        const d = codicil_mod.decode(m, idx.doc_count, g) orelse {
            portal.unmap(m);
            break :blk;
        };
        const new_paths = frame.splitNulExact(gpa, d.new_paths_blob, d.n_new, true) catch {
            portal.unmap(m);
            break :blk;
        };
        defer gpa.free(new_paths);
        try paths.appendSlice(gpa, new_paths); // slices alias the codicil map
        codmap = m;
        cod = d;
        if (crest_view) |base_table| {
            const merged = try gpa.alloc(crest.Vector, paths.items.len);
            @memcpy(merged[0..base_table.len], base_table);
            for (merged[base_table.len..]) |*v| v.* = codicil_mod.never_prune;
            for (d.ids, d.rows) |gid, row| merged[gid] = row;
            for (d.tombs) |gid| merged[gid] = codicil_mod.never_prune;
            portal.unmap(cmap.?);
            cmap = null;
            crest_view = merged;
            crest_allocation = merged;
        }
    }

    return .{ .imap = imap, .pmap = pmap, .idx = idx, .cmap = cmap, .crest = crest_view, .crest_allocation = crest_allocation, .short_docs = short_docs, .codmap = codmap, .cod = cod, .paths = paths, .roots_blob = roots_blob, .roots = roots, .gen = gen_owned, .gpa = gpa };
}

/// Documents a crest table cannot prove are ≥ 3 bytes long, ascending.
///
/// `max ρ(d) ≥ 3` means some character class runs three consecutive bytes in
/// `d`, which witnesses `len(d) ≥ 3` and therefore that `d` owns a trigram and
/// appears in the postings. The converse does not hold — `"a1 "` is three bytes
/// with no 3-run — so a document that fails the test is merely *unproven*, not
/// known short, and is admitted. That asymmetry is the sound direction: this
/// list may be a superset of the truly-short documents, never a subset.
fn shortDocs(gpa: std.mem.Allocator, table: []const crest.Vector) ![]u32 {
    var n: usize = 0;
    for (table) |v| {
        if (@reduce(.Max, @as(@Vector(crest.K, u16), v)) < 3) n += 1;
    }
    const out = try gpa.alloc(u32, n);
    var w: usize = 0;
    for (table, 0..) |v, d| {
        if (@reduce(.Max, @as(@Vector(crest.K, u16), v)) < 3) {
            out[w] = @intCast(d);
            w += 1;
        }
    }
    return out;
}

/// Load from an arbitrary cache root (production uses `home.outDir()`; tests
/// inject a tempdir). When `pair.gen` is present, both blobs must come from
/// `gens/<id>/` and the generation must still match after the maps succeed.
pub fn loadAt(gpa: std.mem.Allocator, io: std.Io, out_dir: []const u8, comptime verbose: bool) !?Persisted {
    var gen_path_buf: [512]u8 = undefined;
    const gen_path = try joinPath(&gen_path_buf, .{ out_dir, "pair.gen" });
    if (try readGenerationFile(gpa, io, gen_path)) |gen| {
        defer gpa.free(gen);
        var gen_dir_buf: [512]u8 = undefined;
        var pf: PairFiles = .{};
        try pf.init(try joinPath(&gen_dir_buf, .{ out_dir, gens_subdir, gen }));
        const loaded = try loadMappedPair(gpa, io, &pf, gen, verbose) orelse return null;
        // Seqlock-style recheck: a concurrent publisher may have advanced
        // pair.gen after we started mapping. Reject rather than mix gens.
        const gen_after = try readGenerationFile(gpa, io, gen_path);
        defer if (gen_after) |g| gpa.free(g);
        if (gen_after == null or !std.mem.eql(u8, gen, gen_after.?)) {
            var tmp = loaded;
            tmp.deinit();
            const what: []const u8 = if (gen_after == null) "retracted" else "changed";
            if (verbose) assay.diag("index generation {s} mid-load — run `gist index` to rebuild\n", .{what});
            return null;
        }
        return loaded;
    }

    // Legacy caches (pre-generation publish): stable paths only.
    var pf: PairFiles = .{};
    try pf.init(out_dir);
    return loadMappedPair(gpa, io, &pf, null, verbose);
}

/// Serialize + generation-publish the index/path/roots triple (plus the crest
/// sidecar when the builder computed one) under `out_dir`, and record
/// `built_ns` as the generation's BASE instant (`base.ns` — what a later
/// `gist index` amend measures "changed since" against). Returns the
/// posting-blob byte length.
pub fn persistIndexAndPathsAt(
    gpa: std.mem.Allocator,
    io: std.Io,
    out_dir: []const u8,
    idx: *const Index,
    paths: []const []const u8,
    roots: []const []const u8,
    crest_vectors: ?[]const crest.Vector,
    built_ns: i128,
) !usize {
    try Dir.cwd().createDirPath(io, out_dir);

    var gen_buf: [32]u8 = undefined;
    const gen = try newGenId(io, &gen_buf);

    var gen_dir_buf: [512]u8 = undefined;
    const gen_dir = try joinPath(&gen_dir_buf, .{ out_dir, gens_subdir, gen });
    try Dir.cwd().createDirPath(io, gen_dir);

    const blob = try gpa.alloc(u8, idx.serializedSize());
    defer gpa.free(blob);
    _ = idx.writeInto(blob);

    var pl: std.ArrayList(u8) = .empty;
    defer pl.deinit(gpa);
    try frame.joinNul(gpa, &pl, paths);

    var rl: std.ArrayList(u8) = .empty;
    defer rl.deinit(gpa);
    try frame.joinNul(gpa, &rl, roots);

    // Crest sidecar bytes (empty when the builder skipped the pass).
    const cblob: []u8 = if (crest_vectors) |cv| blk: {
        const b = try gpa.alloc(u8, try crest_sidecar.encodedSize(cv.len));
        errdefer gpa.free(b);
        _ = try crest_sidecar.writeInto(cv, b);
        break :blk b;
    } else &.{};
    defer if (cblob.len > 0) gpa.free(cblob);

    // Stage all blobs under the unpublished generation directory first.
    try writePairBlobs(io, gen_dir, blob, pl.items, rl.items, cblob);
    var ns_buf: [8]u8 = undefined;
    std.mem.writeInt(i64, &ns_buf, @intCast(built_ns), .little);
    var pf_gen: PairFiles = .{};
    try pf_gen.init(gen_dir);
    try writeAtomic(io, pf_gen.basens, &ns_buf);

    // Single atomic publish of the pair.
    try publishGeneration(io, out_dir, gen);

    // Stable aliases for status / bench tooling (after publish; load prefers
    // gens/). Hardlinked from the staged generation — the blobs are already on
    // disk, so re-WRITING ~80 MiB here was pure duplicate I/O; a link + rename
    // is atomic per file and byte-identical. Any failure falls back to the
    // proven full write (cross-FS out_dir, restrictive mounts).
    linkPairBlobs(io, gen_dir, out_dir, gen, cblob.len > 0) catch
        try writePairBlobs(io, out_dir, blob, pl.items, rl.items, cblob);

    return blob.len;
}

/// Flip `pair.gen` to `gen` — the single atomic act that publishes a staged
/// generation — then retire the ones it superseded (`lapse.zig`). Both build
/// paths end here, so a generation becoming live and the history that becoming
/// live obsoletes have ONE definition and cannot drift apart. Retention is
/// best-effort by contract: it reports rather than fails, so a directory it
/// could not remove costs disk, never the publish.
fn publishGeneration(io: std.Io, out_dir: []const u8, gen: []const u8) !void {
    var gen_path_buf: [512]u8 = undefined;
    try writeAtomic(io, try joinPath(&gen_path_buf, .{ out_dir, "pair.gen" }), gen);
    reclaimSuperseded(io, out_dir, gen);
}

/// Retire what the generation `gen` superseded, publishing nothing. Every
/// publish ends in this (via `publishGeneration`), but the no-change amend
/// path never publishes at all — it advances the freshness anchor and stops —
/// so without a second call site `gist index` would tidy the artifact
/// directory only on the runs that happened to find work, leaving a backlog to
/// drain behind future edits. Calling it here too makes the lifecycle verb
/// idempotent in the way its name implies, for the cost of one directory
/// listing.
pub fn reclaimSuperseded(io: std.Io, out_dir: []const u8, gen: []const u8) void {
    var gens_buf: [512]u8 = undefined;
    const gens_dir = joinPath(&gens_buf, .{ out_dir, gens_subdir }) catch return;
    _ = lapse.reclaim(io, gens_dir, gen);
}

/// A fresh generation id: hex wall-clock ns, unique per publish on one box.
/// Public so the amend path can mint the id BEFORE encoding its codicil —
/// the blob embeds the generation it publishes as (`codicil.decode` binds it
/// to the directory it is loaded from).
pub fn newGenId(io: std.Io, buf: *[32]u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{x}", .{@as(u64, @truncate(@as(u128, @intCast(std.Io.Clock.now(.real, io).nanoseconds))))});
}

/// Atomically write the index/paths/roots blobs (plus the crest sidecar when
/// non-empty) under `dir`.
fn writePairBlobs(io: std.Io, dir: []const u8, blob: []const u8, pl: []const u8, rl: []const u8, cblob: []const u8) !void {
    var pf: PairFiles = .{};
    try pf.init(dir);
    try writeAtomic(io, pf.index, blob);
    try writeAtomic(io, pf.paths, pl);
    try writeAtomic(io, pf.roots, rl);
    if (cblob.len > 0) try writeAtomic(io, pf.crest, cblob);
}

/// Replace `dest` with a hardlink to `src` atomically: link to a unique temp
/// name, then rename over the destination (POSIX rename atomicity — the same
/// guarantee `writeAtomic` provides, without rewriting the bytes).
fn linkAtomic(io: std.Io, src: []const u8, dest: []const u8, tag: []const u8) !void {
    var tmp_buf: [512]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.{s}.lnk", .{ dest, tag });
    fault.spare("clear a stale link temp", Dir.cwd().deleteFile(io, tmp));
    try Dir.cwd().hardLink(src, Dir.cwd(), tmp, io, .{});
    errdefer fault.spare("unlink the link temp", Dir.cwd().deleteFile(io, tmp));
    try Dir.cwd().rename(tmp, Dir.cwd(), dest, io);
}

/// Hardlink the stable aliases at the staged generation's blobs.
fn linkPairBlobs(io: std.Io, gen_dir: []const u8, out_dir: []const u8, tag: []const u8, with_crest: bool) !void {
    var src: PairFiles = .{};
    try src.init(gen_dir);
    var dst: PairFiles = .{};
    try dst.init(out_dir);
    try linkAtomic(io, src.index, dst.index, tag);
    try linkAtomic(io, src.paths, dst.paths, tag);
    try linkAtomic(io, src.roots, dst.roots, tag);
    if (with_crest) try linkAtomic(io, src.crest, dst.crest, tag);
}

pub fn persistIndexAndPaths(
    gpa: std.mem.Allocator,
    io: std.Io,
    idx: *const Index,
    paths: []const []const u8,
    roots: []const []const u8,
    crest_vectors: ?[]const crest.Vector,
    built_ns: i128,
) !usize {
    return persistIndexAndPathsAt(gpa, io, home.outDir(), idx, paths, roots, crest_vectors, built_ns);
}

/// The base build instant of generation `gen` (`gens/<gen>/base.ns`), or null
/// when missing/torn/future — the amend path then falls back to a full build.
pub fn readBaseNs(gpa: std.mem.Allocator, io: std.Io, out_dir: []const u8, gen: []const u8) ?i128 {
    var buf: [512]u8 = undefined;
    var pf: PairFiles = .{};
    const dir = joinPath(&buf, .{ out_dir, gens_subdir, gen }) catch return null;
    pf.init(dir) catch return null;
    const b = Dir.cwd().readFileAlloc(io, pf.basens, gpa, .limited(64)) catch return null;
    defer gpa.free(b);
    if (b.len < 8) return null;
    const ns: i128 = std.mem.readInt(i64, b[0..8], .little);
    if (ns <= 0 or ns > std.Io.Clock.now(.real, io).nanoseconds) return null;
    return ns;
}

/// The build roots of generation `gen` (`gens/<gen>/roots.list`), read cheaply
/// — no index mmap, no doc path-table parse. This is what lets a no-change
/// `gist index` amend answer without ever loading the pair. Null when the
/// list is missing/empty/torn (legacy layout or a torn publish; the amend
/// caller falls back to the full build).
pub const RootsList = struct {
    blob: []u8,
    roots: std.ArrayList([]const u8), // slices alias `blob`
    gpa: std.mem.Allocator,
    pub fn deinit(self: *RootsList) void {
        self.roots.deinit(self.gpa);
        self.gpa.free(self.blob);
    }
};

pub fn readRootsAt(gpa: std.mem.Allocator, io: std.Io, out_dir: []const u8, gen: []const u8) ?RootsList {
    var buf: [512]u8 = undefined;
    var pf: PairFiles = .{};
    const dir = joinPath(&buf, .{ out_dir, gens_subdir, gen }) catch return null;
    pf.init(dir) catch return null;
    const blob = Dir.cwd().readFileAlloc(io, pf.roots, gpa, .limited(1 << 16)) catch return null;
    var roots = frame.parsePathTable(gpa, blob) catch {
        gpa.free(blob);
        return null;
    };
    if (roots.items.len == 0) {
        roots.deinit(gpa);
        gpa.free(blob);
        return null;
    }
    return .{ .blob = blob, .roots = roots, .gpa = gpa };
}

/// Publish a codicil as the NEW generation `gen` (pre-minted via `newGenId`
/// and embedded in `blob`, so `codicil.decode` binds the blob to the exact
/// directory it is loaded from): hardlink (or copy) the base generation's
/// blobs forward unchanged, stage `blob` as `codicil.bin`, then flip
/// `pair.gen` — the same single-file atomic publish full builds use, so
/// concurrent readers (and both resident daemons, which key reloads on the
/// generation id) observe either the old pair or the complete amended one.
/// The stable aliases still point at the base blobs, which ARE this
/// generation's base — status/bench size accounting stays truthful.
pub fn publishCodicil(io: std.Io, out_dir: []const u8, base_gen: []const u8, gen: []const u8, blob: []const u8) !void {
    var base_dir_buf: [512]u8 = undefined;
    const base_dir = try joinPath(&base_dir_buf, .{ out_dir, gens_subdir, base_gen });
    var new_dir_buf: [512]u8 = undefined;
    const new_dir = try joinPath(&new_dir_buf, .{ out_dir, gens_subdir, gen });
    try Dir.cwd().createDirPath(io, new_dir);

    var src: PairFiles = .{};
    try src.init(base_dir);
    var dst: PairFiles = .{};
    try dst.init(new_dir);
    try linkOrCopy(io, src.index, dst.index);
    try linkOrCopy(io, src.paths, dst.paths);
    try linkOrCopy(io, src.roots, dst.roots);
    try linkOrCopy(io, src.basens, dst.basens);
    fault.spare("link the crest sidecar (optional)", linkOrCopy(io, src.crest, dst.crest));

    try writeAtomic(io, dst.codicil, blob);

    try publishGeneration(io, out_dir, gen);
}

fn linkOrCopy(io: std.Io, src: []const u8, dest: []const u8) !void {
    Dir.cwd().hardLink(src, Dir.cwd(), dest, io, .{}) catch
        try Dir.cwd().copyFile(src, Dir.cwd(), dest, io, .{});
}
