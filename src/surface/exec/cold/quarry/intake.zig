//! gist — intake: turning walked candidates into readable bytes, reading only
//! what might match.
//!
//! The walk (`walk.zig`) decides WHAT is in the corpus; this decides what is
//! worth OPENING and hands back `InFile` bodies. Two things earn the speed.
//! Reads are sharded across cores — the walk is necessarily single-threaded
//! (ignore rules load as it descends) but nothing about reading is, so the flat
//! candidate list is split by weight and read in parallel, mirroring ripgrep's
//! own walk/read split. And when a persisted trigram index covers the roots,
//! `IndexSkip` elides reads the index proves cannot match.
//!
//! `IndexSkip` is the SERIAL freshness proof over the shared oracle primitives
//! in `elide.zig`: a whole-tree `fresh.candidates` overlay unions trigram hits
//! with everything touched since the build anchor, so a file that GAINED the
//! needle is always re-read. The fused parallel walk proves freshness the other
//! way — per file, from the bulk listing's own timestamps (`elide.Oracle`).
//! Two strategies, one oracle: elision may change speed, never results.

const std = @import("std");
const args = @import("../argv/args.zig");
const corpus_mod = @import("../../../../corpus/tree/corpus.zig");
const crest = @import("../../../../kernel/primitives/crest.zig");
const elide = @import("elide.zig");
const fault = @import("../../../../fault.zig");
const fresh = @import("../../../../corpus/index/trigrams/fresh.zig");
const inode = @import("../read/inode.zig");
const ignore = @import("../../../../corpus/tree/ignore.zig");
const ingest = @import("../read/ingest.zig");
const legible = @import("../read/legible.zig");
const order = @import("order.zig");
const paths_mod = @import("../../../../corpus/scope/paths.zig");
const persist = @import("../../../../corpus/index/trigrams/persist.zig");
const slurp = @import("../read/slurp.zig");
const simd = @import("../../../../kernel/match/scan/simd.zig");
const verify = @import("../../../../kernel/match/scan/verify.zig");
const walk = @import("walk.zig");

const Candidate = walk.Candidate;
const Dir = std.Io.Dir;
const Opts = args.Opts;
const SortCtx = order.SortCtx;
const cmpFiles = order.cmpFiles;
const decodeBom = legible.decodeBom;
const replaceSep = paths_mod.replaceSep;
const die = args.die;
const gather = walk.gather;
const oom = args.oom;
const sortTimeOf = order.sortTimeOf;

/// `assembleIndexSkip`'s private control flow — the serial twin of `elide.Err`
/// (ADR-373 law 2). Both non-OOM members are declinatures the instant they cross
/// into `buildIndexSkip`: "no index on disk" and "the table would not pay for
/// itself" each name the live read as the tier that answers *correctly*, not
/// worse. Inside this file they are only how an early exit reaches `errdefer`.
/// Named and non-`pub` so an inferred error set cannot carry a spelling of
/// "declined" out into the tier's fault vocabulary.
const Err = error{ NoIndex, NotWorthwhile, OutOfMemory };

pub const InFile = struct { path: []const u8, scope: []const u8, bytes: []const u8, explicit: bool = false, sort_time: i96 = 0, root: u32 = 0 };

/// Spawn one shard per core above this candidate count; below it, thread-spawn
/// overhead isn't worth it and the whole batch runs inline on the calling
/// thread. Mirrors `ranked.zig`'s identical `read_par_threshold` tuning
/// for its own parallel candidate-read shards.
const par_threshold = 64;

const ReadShard = struct {
    gpa: std.mem.Allocator,
    // Thread-confined bump allocator for every kept file's byte copy — owned
    // by this shard alone until `readCandidates` has copied `out` into the
    // caller's long-lived arena and tears it down, so parallel shards never
    // contend on `gpa`'s shared allocator machinery for that traffic (the
    // exact reasoning `emit.zig`'s `Shard.arena` documents).
    arena: std.heap.ArenaAllocator,
    candidates: []const Candidate,
    needle: ?simd.Gate,
    cfg: *const ingest.Config,
    out: std.ArrayList(InFile) = .empty,
};

/// One candidate's read-and-filter: raw POSIX open/read/close into a reused
/// per-shard scratch buffer — the same proven-fast cold-read idiom
/// `emit.zig`'s `grepShard` already uses for its parallel candidate reads
/// (plain syscalls, no `std.Io` handle to share across threads) — then
/// BOM-decoded, then dropped on the spot when the required-literal gate
/// provably isn't in it: one SIMD `contains` call replaces reading a file all
/// the way to "zero hits" through three more serial passes (binary sniff,
/// line split, per-line match) in the caller's loop. A kept file's bytes are
/// copied into `a` (the shard's arena) so they outlive the next reuse of
/// `scratch`.
///
/// `scratch` is sized to `corpus_mod.per_file_cap` — an indexing-corpus
/// budget, NOT a hard ceiling on what `rg`-compat may search (ripgrep itself
/// has no default max file size; only an explicit `--max-filesize` caps it,
/// applied downstream in `collectFiles`). A file that fills `scratch`
/// completely is ambiguous (exactly cap-sized, or bigger) — `readTail` keeps
/// reading past it into a growable buffer instead of silently truncating.
/// Large regular files are memory-MAPPED rather than read-loop + arena-duped:
/// the ~2× serial copy of a big single file is the Amdahl tail under single-file
/// sharding, and a mapping's pages fault in lazily during the (sharded) scan —
/// exactly ripgrep's large-file strategy. Small files stay on the copying path
/// (one read syscall beats mmap+fault setup below this size).
const mmap_min_bytes: usize = 4 << 20;

fn readOneCandidate(a: std.mem.Allocator, scratch: []u8, c: Candidate, needle: ?simd.Gate, cfg: *const ingest.Config) ?InFile {
    // Untransformed large file: map it (no read loop, no dupe). A transforming
    // run (-z/--pre/-E) must read + rewrite the raw bytes, so it can't map.
    if (!cfg.active()) if (slurp.mapFile(c.disk, mmap_min_bytes)) |mapped| {
        const body = decodeBom(a, mapped);
        if (needle) |gate| if (!verify.gateWide(a, body, gate)) return null;
        return .{ .path = c.rel, .scope = c.scope, .bytes = body, .explicit = c.explicit, .root = c.root };
    };
    const raw = slurp.readFileRaw(a, scratch, c.disk) orelse return null;
    // -z/--pre/-E rewrite a file's bytes before matching (decompress, preprocess,
    // transcode); `ingest.apply` owns that whole pipeline (and folds in BOM/
    // encoding). Null means the file is DROPPED — an errored `--pre` whose latch
    // already carries the exit-2 signal. The untransformed fast path stays a plain
    // BOM decode with no per-file branch beyond this one predicate.
    const body = if (cfg.active())
        (ingest.apply(a, cfg, c.disk, c.rel, raw) orelse return null)
    else
        decodeBom(a, raw);
    // `gateWide` ≡ the plain SIMD kernel until the body crosses 16 MiB, then
    // the presence gate fans out across cores (a huge explicit file shouldn't
    // serialize the serial engine's read loop behind one thread's scan).
    if (needle) |gate| if (!verify.gateWide(a, body, gate)) return null;
    // A tail-read (≥ cap) or UTF-16-transcoded body is already `a`-owned; a
    // body still inside `scratch` must be duped to outlive scratch's next reuse.
    const in_scratch = @intFromPtr(body.ptr) >= @intFromPtr(scratch.ptr) and @intFromPtr(body.ptr) < @intFromPtr(scratch.ptr) + scratch.len;
    const owned = if (in_scratch) (a.dupe(u8, body) catch return null) else body;
    return .{ .path = c.rel, .scope = c.scope, .bytes = owned, .explicit = c.explicit, .root = c.root };
}

fn readShard(sh: *ReadShard) void {
    const a = sh.arena.allocator();
    // Both are `oom()`, not a silent return: bailing here would leave this
    // shard's candidates unsearched with nothing set to say so, so the run would
    // report "no match" for files it never read. And the reservation is what
    // makes `appendAssumeCapacity` below sound — swallowing its failure left the
    // loop appending past the buffer on the one path where it can happen.
    const scratch = sh.gpa.alloc(u8, corpus_mod.per_file_cap) catch oom();
    defer sh.gpa.free(scratch);
    sh.out.ensureTotalCapacity(sh.gpa, sh.candidates.len) catch oom();
    for (sh.candidates) |c| if (readOneCandidate(a, scratch, c, sh.needle, sh.cfg)) |f| sh.out.appendAssumeCapacity(f);
}

/// Read every discovered candidate — in parallel across the machine's cores
/// above `par_threshold` candidates, the multi-core walk ripgrep itself runs
/// (`ignore::WalkParallel`) — and append the kept `InFile`s into `out`, BORROWING
/// each body straight from its shard arena. Below the threshold this runs inline:
/// for a handful of files, spawn cost dwarfs the read itself.
///
/// The shard arenas are intentionally kept alive (never deinit'd): the cold
/// engine is one-shot — `run` owns a single query arena and every terminal path
/// `std.process.exit`s right after emit — so the read arenas outlive every
/// match/emit pass that reads their bytes, and the OS reclaims them at exit. This
/// deletes what was a serial ~½-GB `dest.dupe` of the whole kept corpus (the
/// bandwidth floor sitting UNDER the already-parallel read), for zero copies.
fn readCandidates(dest: std.mem.Allocator, gpa: std.mem.Allocator, candidates: []const Candidate, needle: ?simd.Gate, out: *std.ArrayList(InFile), cfg: *const ingest.Config) void {
    const ncpu = std.Thread.getCpuCount() catch 8;
    // A transforming run (-z/--pre/-E) reads in parallel like any other: each
    // shard decompresses/transcodes on its OWN arena + scratch, and `ingest`'s
    // subprocess path (external decompressor / `--pre`) is concurrency-safe —
    // `std.process.run` holds only per-call state (its own child, pipes, buffers)
    // and `posix_spawn` is thread-safe, so parallel forks never race. The one
    // shared datum, the `--pre` failure latch, is an atomic store. Parallelizing
    // the decode is the whole point: it's the bottleneck rg pays per file.
    const nshards = if (candidates.len < par_threshold) 1 else @min(candidates.len, ncpu);
    const shards = gpa.alloc(ReadShard, nshards) catch oom();
    defer gpa.free(shards);
    const per = (candidates.len + nshards - 1) / nshards;
    for (shards, 0..) |*sh, k| sh.* = .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa), .candidates = candidates[@min(k * per, candidates.len)..@min((k + 1) * per, candidates.len)], .needle = needle, .cfg = cfg };
    if (nshards == 1) readShard(&shards[0]) else {
        const threads = gpa.alloc(std.Thread, nshards) catch oom();
        defer gpa.free(threads);
        for (shards, 0..) |*sh, k| threads[k] = std.Thread.spawn(.{}, readShard, .{sh}) catch die("thread spawn failed\n", .{});
        for (threads) |t| t.join();
    }
    out.ensureUnusedCapacity(dest, candidates.len) catch oom();
    // Borrow bodies from the shard arenas (kept alive to process exit — see the
    // doc comment): copy only the small `InFile` structs, never the bytes. The
    // shard's own `out` list (its struct storage) is freed; the arena that backs
    // the bytes is not.
    for (shards) |*sh| {
        out.appendSliceAssumeCapacity(sh.out.items);
        sh.out.deinit(gpa);
    }
}

/// The compiled analyzer's longest literal present in every match, as a SIMD
/// `Gate`. This works for literals and regexes alike (including 1–2 byte
/// literals that cannot use the trigram index), and stays null for
/// alternations without a common literal. Engine-neutral: `Matcher.required()`
/// is the sound per-match literal from either backend (`Regex.required` / the
/// PCRE2 `literal.zig` extractor). A caseless run (`-i`/resolved `-S`) no
/// longer stands the gate down: the raw (pre-fold) required literal is still
/// required in SOME case, so an ASCII-fold-closed literal gates through the
/// caseless SIMD kernel instead (`caselessGate`).
// ─────────────────── index-backed read elision (acceleration) ───────────────────
//
// The persisted trigram index is used ONLY to skip *reading* files the walk
// already discovered but that provably can't match — it never changes the file
// set, the ignore semantics, the ordering, or the output. The live walk above
// stays the sole authority on WHAT to search (so every rgsuite parity guarantee
// holds unchanged); the index just answers, for a walked path it already knows,
// "does this file contain the pattern's required literal?" and, if not (and the
// file is unchanged since the index was built — the freshness overlay forces a
// re-read of anything touched since), lets the read be elided. A skipped file
// couldn't have produced a single line of output, so eliding its read is
// byte-invisible — the win is turning "open+read ~16k files" into "open+read
// only the trigram candidates" for a selective query, gist's whole thesis.
//
// Soundness rests on two sets drawn from the index:
//   • `indexed`  — every path the index covers (only THESE may be elided; a path
//     the index doesn't know — a new file, or one outside the indexed roots — is
//     always read, so nothing is ever wrongly skipped);
//   • `candidates` — `fresh.candidates`: trigram hits for the prefilter UNIONed
//     with every file touched since the build (the freshness overlay closes the
//     stale-index gap — a file that GAINED the needle since the build is in this
//     set and gets read).
// Elide reading path P iff P is exactly indexed AND its doc id is not a candidate.
//
// The CREST SIEVE (research/crest/) adds a second, independent necessary
// condition for the patterns the trigram filter concedes entirely (literal-free
// class repetitions — `[0-9a-f]{8}`): elide P also when its persisted crest
// vector falls short of the pattern's forced crest ĝ — but only for docs the
// freshness overlay did NOT flag (a fresh doc's persisted vector describes
// stale bytes, so it is always read).
const IndexSkip = struct {
    p: persist.Persisted,
    cand: fresh.Candidates,
    indexed_count: usize,
    indexed: elide.IndexedPaths,
    candidates: std.DynamicBitSet,
    /// Docs the freshness walk flagged (never crest-elided).
    fresh_set: std.DynamicBitSet,
    /// The persisted crest table — null disables the sieve (legacy cache,
    /// rejected blob, inactive ĝ, or no trustworthy anchor).
    table: ?[]const crest.Vector,
    sieve: crest.Vector,

    fn skip(self: *const IndexSkip, rel: []const u8) bool {
        const doc = self.indexed.get(self.p.paths.items[0..self.indexed_count], rel) orelse return false;
        if (!self.candidates.isSet(doc)) return true;
        if (self.table) |t| {
            if (doc < t.len and !self.fresh_set.isSet(doc) and crest.pruned(t[doc], self.sieve)) return true;
        }
        return false;
    }
    fn deinit(self: *IndexSkip) void {
        self.fresh_set.deinit();
        self.candidates.deinit();
        self.indexed.deinit();
        self.cand.deinit();
        self.p.deinit();
    }
};

/// The sound trigram prefilter for this invocation, or empty (⇒ no read is ever
/// elided) whenever anything makes "contains the required literal" an unsafe
/// proxy for "can match": `--no-index`,
/// inversion (`-v` emits zero-hit files too), or the whole-file scans
/// (`--stats`, `--json` — whose summary message carries the same stats —
/// `--passthru`) that must read every byte regardless. Otherwise the
/// engine's own required literal (`re.required`, present in EVERY match) or, for
/// an alternation, its per-branch cover set (`re.alts` — `foo|bar` ⇒ {foo,bar}),
/// both of which `fresh.candidates` treats as sound supersets. Case-folding
/// (`-i`/resolved `-S`) no longer stands the index down wholesale: the raw
/// (pre-fold) required literal is still required in SOME case, so one window
/// of it expands into the ≤16-variant OR-set the index can query
/// (`caselessFilter`) — declining only when no admissible window exists.
/// Build the read-elision oracle from the persisted index — the indexed→live
/// seam (ADR-373 law 1). It declines when there's nothing to gain (no sound
/// prefilter, `--no-index`, or no index on disk — the last probed SILENTLY via
/// `loadQuiet`, since a bare `gist <pattern>` outside an indexed corpus is the
/// normal case, not a miss to nag about). `fresh_roots` scopes the freshness
/// stat-walk to the query's own roots (else the indexed corpus) so a scoped
/// query doesn't pay a whole-corpus stat pass.
fn buildIndexSkip(gpa: std.mem.Allocator, io: std.Io, parsed: args.Parsed, filters: []const []const u8, sieve: crest.Vector) fault.Answer(IndexSkip) {
    if (!elide.indexElisionWanted(io, parsed, filters, sieve)) return .{ .declined = .not_worthwhile };
    if (assembleIndexSkip(gpa, io, parsed, filters, sieve)) |s| return .{ .got = s } else |e| return switch (e) {
        error.NoIndex => .{ .declined = .index_absent },
        error.NotWorthwhile => .{ .declined = .not_worthwhile },
        // A genuine fault in BUILDING the oracle. Every persisted artifact fails
        // CLOSED to the live path (`fault.Persist`), so from this query's side
        // the index is simply not there: it loses the elision and nothing else.
        error.OutOfMemory => .{ .declined = .index_absent },
    };
}

/// `collectFiles`'s overlap thread body: run the seam into the caller's box.
fn computeIndexSkip(out: *fault.Answer(IndexSkip), gpa: std.mem.Allocator, io: std.Io, parsed: args.Parsed, filters: []const []const u8, sieve: crest.Vector) void {
    out.* = buildIndexSkip(gpa, io, parsed, filters, sieve);
}

/// Fallible half of `buildIndexSkip` (the `assembleElide` idiom): every early
/// exit — no index on disk, an unworthwhile saving, an OOM — is an error, so
/// `errdefer` sheds the half-built state instead of hand-threading `deinit`
/// down each return path. Those errors are this file's private control flow,
/// like the shadow rewriter's `Bail`; `buildIndexSkip` is where they become the
/// seam's typed declinature.
fn assembleIndexSkip(gpa: std.mem.Allocator, io: std.Io, parsed: args.Parsed, filters: []const []const u8, sieve: crest.Vector) Err!IndexSkip {
    var p = (persist.loadQuiet(gpa, io) catch return error.NoIndex) orelse return error.NoIndex;
    errdefer p.deinit();
    // Snapshot the indexed path set BEFORE freshness widens `p.paths` with new
    // files (only originally-indexed paths are elision-eligible; the new files
    // freshness appends are, by definition, things to read).
    const n_indexed = p.paths.items.len;
    // Freshness folds over the roots the index was BUILT with (persisted
    // beside it), unless the query's own explicit roots narrow the walk.
    const fresh_roots = if (parsed.roots.len > 0) parsed.roots else p.roots.items;
    // `fresh.candidates` fails only on OOM: every unreadable sidecar and
    // untakeable stat it meets already folds CLOSED into "assume changed",
    // which is why the fold has no declinature of its own to convert here.
    var cand = try fresh.candidates(gpa, io, &p, &p.paths, filters, fresh_roots);
    errdefer cand.deinit();
    var candidates = try std.DynamicBitSet.initEmpty(gpa, p.paths.items.len);
    errdefer candidates.deinit();
    var fresh_set = try std.DynamicBitSet.initEmpty(gpa, p.paths.items.len);
    errdefer fresh_set.deinit();
    for (cand.fresh_ids) |d| fresh_set.set(d);
    // The sieve engages only when there is a ĝ to enforce, a persisted table
    // bound to this doc space, AND a trustworthy anchor (without one, no doc's
    // persisted vector provably describes its live bytes).
    const table: ?[]const crest.Vector = if (crest.active(sieve) and cand.anchored) p.crest else null;
    var indexed_candidates: usize = 0;
    for (cand.ids) |d| {
        candidates.set(d);
        if (d >= n_indexed) continue;
        // Count only docs that will actually be read — the crest sieve's
        // provable prunes are savings, so they inform the worth heuristic too.
        if (table) |t| if (d < t.len and !fresh_set.isSet(d) and crest.pruned(t[d], sieve)) continue;
        indexed_candidates += 1;
    }
    if (!elide.indexSavingsWorthTable(n_indexed, indexed_candidates)) return error.NotWorthwhile;
    const indexed = try elide.IndexedPaths.init(gpa, p.paths.items[0..n_indexed]);
    return .{ .p = p, .cand = cand, .indexed_count = n_indexed, .indexed = indexed, .candidates = candidates, .fresh_set = fresh_set, .table = table, .sieve = sieve };
}

/// Gather (walk, single-threaded) → read (parallel, see `readCandidates`) →
/// type/glob filter → path-sort → apply --path-separator. Shared by the
/// search path and `--files`. `gpa` (not the arena `a`) backs the parallel
/// read shards — `std.heap.ArenaAllocator` isn't safe to allocate through
/// concurrently, so each shard gets its OWN arena wrapping the shared,
/// thread-safe `gpa` (see `ReadShard`/`readCandidates`). `filters` is the sound
/// trigram prefilter (`trigramFilter`); empty ⇒ read every walked file (today's
/// behavior), non-empty ⇒ let the persisted index elide provable-non-candidate
/// reads (`buildIndexSkip`) — the output is identical either way.
/// `walked` counts every candidate the walk ADMITTED (post ignore/type/glob/
/// hidden filters, pre body-read) — including index-elided files, which rg
/// would still have opened. It feeds the implicit-path "No files were
/// searched" heuristic (`notice.printNothingSearched`), which must fire on
/// "the filters excluded everything", never on "the index proved everything
/// out" or "the pattern missed".
pub const Collected = struct { files: []InFile, recursive: bool, path_error: bool, walked: usize };
pub fn collectFiles(a: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, parsed: args.Parsed, filters: []const []const u8, sieve: crest.Vector, file_needle: ?simd.Gate, cfg: *const ingest.Config) Collected {
    const o = parsed.opts;
    var candidates: std.ArrayList(Candidate) = .empty;
    // The command plane's terminal decision: the shared walk returns OOM, gist
    // exits 2 with the canonical notice, exactly as it always has.
    var ig = ignore.Ignore.init(a, io, ignore.Options.from(o), parsed.roots) catch oom();

    // The elision oracle's freshness stat-walk and the gather walk are
    // INDEPENDENT tree passes (gather reads no bodies; `buildIndexSkip`
    // touches only the persisted index + file metadata, allocating through
    // the thread-safe `gpa`), so overlap them: the serial engine's second
    // metadata pass now costs ~zero wall time instead of doubling the
    // walk phase. Spawn failure (or elision not wanted) degrades to the
    // old sequential compute — never a lost oracle.
    var box: fault.Answer(IndexSkip) = .{ .declined = .not_worthwhile };
    const skip_thread: ?std.Thread = if (elide.indexElisionWanted(io, parsed, filters, sieve))
        std.Thread.spawn(.{}, computeIndexSkip, .{ &box, gpa, io, parsed, filters, sieve }) catch null
    else
        null;

    const g = gather(a, io, parsed.roots, o, &ig, &candidates, null) catch oom();

    var all: std.ArrayList(InFile) = .empty;
    const admitted: fault.Answer(IndexSkip) = if (skip_thread) |t| blk: {
        t.join();
        break :blk box;
    } else buildIndexSkip(gpa, io, parsed, filters, sieve);
    // Every declinature this seam can carry names the live read, so past this
    // line the run only needs to know whether it holds an oracle.
    var skip: ?IndexSkip = switch (admitted) {
        .got => |s| s,
        .declined => null,
    };
    defer if (skip) |*s| s.deinit();
    const read_list = if (skip) |*s| blk: {
        // Partition the walked set: read only what the index can't prove out.
        // An elided file contributes nothing to any mode EXCEPT --files-without-
        // match, which lists every non-matching file — so there it's kept as an
        // unread (empty-body) entry, which the run loop treats as "no match".
        var to_read: std.ArrayList(Candidate) = .empty;
        to_read.ensureTotalCapacity(a, candidates.items.len) catch oom();
        for (candidates.items) |c| {
            if (s.skip(c.rel)) {
                if (o.files_without) all.append(a, .{ .path = c.rel, .scope = c.scope, .bytes = "", .explicit = c.explicit, .root = c.root }) catch oom();
            } else to_read.appendAssumeCapacity(c);
        }
        break :blk to_read.items;
    } else candidates.items;
    // A lone explicitly-named file is searched regardless of the whole-file
    // presence gate: it can't be skipped (it was named), so the gate proves
    // nothing the mode's own scan doesn't. Worse, that scan already runs — the
    // sharded count/match pass, or the `-l`/`-q` early-exit — so gating here
    // means faulting the body TWICE, and `gateWide`'s parallel fan-out faults
    // every core's contiguous region before an early-exit can short-circuit,
    // exactly defeating rg's fault-to-first-hit locality. Drop it for the single
    // explicit file (output-neutral: absence yields no match either way); the
    // recursive/multi-file walk keeps it, where it skips whole non-matching files.
    if (o.files_list) {
        // --files lists paths, not contents: never fault a body. rg's --files
        // and the parallel --files path both walk-only, so a `--sort`/`-L`-forced
        // serial run must be too — else a listing pays a full-corpus read. The
        // sole metadata need is a size cap: one stat, never an open+read.
        all.ensureTotalCapacity(a, candidates.items.len) catch oom();
        for (candidates.items) |c| {
            if (o.max_filesize != 0) {
                const st = inode.statPath(c.disk) orelse continue;
                if (st.size > o.max_filesize) continue;
            }
            all.appendAssumeCapacity(.{ .path = c.rel, .scope = c.scope, .bytes = "", .explicit = c.explicit, .root = c.root });
        }
    } else {
        const read_needle = if (read_list.len == 1 and read_list[0].explicit) null else file_needle;
        readCandidates(a, gpa, read_list, read_needle, &all, cfg);
    }

    var files: std.ArrayList(InFile) = .empty;
    files.ensureTotalCapacity(a, all.items.len) catch oom();
    for (all.items) |f| {
        if (o.filter.active() and !o.filter.admits(a, f.scope)) continue;
        if (o.max_filesize != 0 and f.bytes.len > o.max_filesize) continue;
        files.appendAssumeCapacity(f);
    }
    // A time-keyed sort needs each file's timestamp; stat only then, and only
    // the kept set. `.path`/`.none` need no metadata (path is already in hand).
    if (o.sort_key == .modified or o.sort_key == .accessed or o.sort_key == .created) for (files.items) |*f| {
        f.sort_time = sortTimeOf(io, o.sort_key, f.path);
    };
    std.mem.sort(InFile, files.items, SortCtx{ .key = o.sort_key, .reverse = o.sort_reverse }, cmpFiles);
    if (o.path_sep) |sepstr| for (files.items) |*f| {
        f.path = replaceSep(a, f.path, sepstr);
    };
    // Path-only filters decide `walked` (rg's `searched` flips as the walk
    // yields a haystack, before any body read); size caps apply post-read.
    var walked: usize = 0;
    for (candidates.items) |c| walked += @intFromBool(!o.filter.active() or o.filter.admits(a, c.scope));
    return .{ .files = files.items, .recursive = g.recursive, .path_error = g.path_error, .walked = walked };
}
