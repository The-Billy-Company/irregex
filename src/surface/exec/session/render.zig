//! gist resident session — the warm `lines` renderer (ADR-352 rung 2.5).
//!
//! Renders the default `gist <pattern>` presentation (`path:text`, `-n` for
//! `path:line:text`) for a pre-gated, path-sorted document list — through the
//! cold engine's OWN `Emitter` and `grepfile.handleBinary`, not a re-derived
//! formatter. Byte-parity is therefore by construction: the same line split
//! (`collectLines`), the same binary policy (emit up to the buffer that
//! revealed the first NUL, then the implicit-file WARNING), the same
//! `--max-columns`/trim/terminator behavior (all at their defaults here — the
//! classifier admits no flag that changes them), the same rendering code.
//!
//! The eligible warm surface never reaches the presentation states that need
//! run-wide resolution in `run.zig`: the client declines a TTY stdout (color +
//! the interactive long-line cap), context/heading/replace flags are
//! classifier-ineligible, and the rootless walk is always recursive so the
//! filename prefix is always on. What remains is exactly the default piped
//! frame, which this module reproduces verbatim.
//!
//! Fail-closed like the rest of the session: a pattern the chosen engine
//! declines (the linear default, or the PCRE2 backend under `-P`) is
//! `error.Unsupported` (→ decline → certified cold answer), never
//! a `die()`. (The Emitter's own internal OOM `die` remains the documented
//! catastrophic-OOM fail-open: the daemon exits, the client's dropped
//! connection falls back cold.)

const std = @import("std");
const args = @import("../cold/argv/args.zig");
const output = @import("../cold/emit/output.zig");
const grepfile = @import("../cold/read/grepfile.zig");
const parallel = @import("../../../kernel/primitives/parallel.zig");
const query_mod = @import("../../../kernel/match/query.zig");
const request = @import("request.zig");
const shm = @import("shm.zig");
const Regex = @import("../../../kernel/match/regex/linear/core.zig").Regex;
const matcher_mod = @import("../../../kernel/match/regex/linear/matcher.zig");
const Matcher = matcher_mod.Matcher;
const Pcre = matcher_mod.Pcre;

pub const RenderError = error{ Unsupported, OutOfMemory };

/// One renderable document: display path, decoded resident bytes, and the
/// byte offset of the first NUL (null ⇒ text). Mirrors `mirror.Doc` + path.
pub const Doc = struct { path: []const u8, bytes: []const u8, nul: ?usize };

/// The shared parallel floor + shard cap (`parallel.min_bytes`/`max_shards`),
/// re-exported so every warm face (this render emit, the resident `-l`/`-c`
/// fold, the FFI record stream) and the cold match/emit cross into parallelism
/// at the SAME corpus size — one definition, no drift.
pub const par_min_bytes = parallel.min_bytes;
pub const par_max_shards = parallel.max_shards;

/// Render every doc's matching lines into `out`, in the docs' given order
/// (the caller path-sorts with `run.pathLess`, the warm canonical order). Returns
/// whether any file matched — cold's exit-code boolean (a binary doc whose only
/// matches sit past its NUL buffer produces no output and no match, exactly
/// like the cold loop). `a` should be a per-query arena: the compiled emission
/// engine, line lists, and every transient are freed with it as a unit.
pub fn renderLines(a: std.mem.Allocator, req: request.Request, docs: []const Doc, out: *std.ArrayList(u8)) RenderError!bool {
    // Compile the SAME effective pattern the cold path feeds `buildMatcher`:
    // `-F` escapes the literal (`combinePatterns`), the RESOLVED case state
    // (`effectiveIgnoreCase` — `-i`, or `-S` folded through the single
    // session-side smart-case resolution) sets the engine's case fold,
    // Unicode stays at the rg-parity default. A pattern outside the chosen
    // engine's syntax is the caller's cue to answer cold.
    const caseless = req.effectiveIgnoreCase();
    const eff = if (req.fixed) try query_mod.escapeLiteral(a, req.pattern) else req.pattern;
    // The SAME engine seam the shared core compiles through (`query.zig`): `-P`
    // (never under `-F`, where fixed wins) realizes the PCRE2 backend —
    // lookaround/backreferences the linear engine declines — else the linear
    // arm. A pattern the CHOSEN engine rejects is `Unsupported`, the caller's
    // cue to answer cold. Multiline/dotall stay off (classifier-ineligible).
    var re: Matcher = if (req.pcre and !req.fixed)
        .{ .pcre = Pcre.compileOpts(a, eff, .{ .caseless = caseless, .unicode = true }) catch |e| switch (e) {
            error.OutOfMemory => return RenderError.OutOfMemory,
            else => return RenderError.Unsupported,
        } }
    else
        .{ .linear = Regex.compileOpts(a, eff, .{ .caseless = caseless, .unicode = true }) catch |e| switch (e) {
            error.OutOfMemory => return RenderError.OutOfMemory,
            else => return RenderError.Unsupported,
        } };
    // The linear arm lives in `a` (arena-freed as a unit); the PCRE2 arm holds
    // libc-owned program memory, so `re` must self-free regardless of the arena.
    defer re.deinit();
    // `requiredLiteralGate` (run.zig): the SIMD line gate is sound only when
    // the engine isn't folding case (RESOLVED, so a folding `-S` declines it
    // exactly like `-i`). It stays sound under `-w` too: the gate only SKIPS
    // engine work on needle-FREE lines, and no needle ⇒ no match ⇒ no
    // word-valid match (a needle-bearing line with zero word-valid spans is
    // still classified by the Emitter's own word scan). It also stays sound
    // under `-v`: the gate never changes the per-line match VERDICT (a
    // needle-free line has zero matches whether or not we invert), only which
    // verdict the Emitter selects, so the complement it prints is identical.
    const req_lit = re.required();
    const needle: ?[]const u8 = if (!caseless and req_lit.len > 0) req_lit else null;

    // Defaults everywhere except `-n`, `-w`, and `-m N`: exactly the option
    // state a piped rootless `gist <pattern> [-n] [-w] [-m N]` reaches the cold
    // emit loop with. The cold Emitter owns the whole `-w` presentation (its
    // wordOk / nextSpan span filter) AND the per-file `-m` cap (it breaks each
    // file at `max_per_file` emitted lines — 0 = unlimited), so wiring the
    // options here IS the parity. `-m0` (match nothing) never reaches this
    // renderer — the session short-circuits it (`Request.matchNothing`).
    const o = args.Opts{
        .line_num = req.line_num,
        .word = req.word,
        // `-v`: the cold Emitter's own line loop selects the complement
        // (`if (hit == o.invert) continue`), so wiring the flag here IS the
        // parity — a non-matching line is framed as a match row (`:`) with its
        // own line number, exactly as a piped `rg -v` produces.
        .invert = req.invert,
        // `-A`/`-B`/`-C`: the cold Emitter's `file` path draws the whole context
        // window and the intra-file `--` group separator off these two fields, so
        // wiring them here IS the parity (the classifier admits only the default
        // separator/terminator, which `Opts`'s defaults already carry). The
        // inter-file `--` is drawn below, exactly as cold's serial `renderFile`.
        .before = req.before,
        .after = req.after,
        .max_per_file = if (req.max_count) |m| std.math.cast(usize, m) orelse std.math.maxInt(usize) else 0,
        .max_per_file_set = req.max_count != null,
    };
    var em = output.Emitter{ .a = a, .re = &re, .o = o, .show_name = true, .out = out, .needle = if (needle) |n| .{ .bytes = n } else null };

    var matched = false;
    // rg's cross-file context separator: a `--` line precedes every EMITTING file
    // after the first whenever a window is active — the serial-only state cold
    // gates onto `renderFile` (`serial.zig`), so a context answer renders serial
    // (see `renderLinesParallel`/`renderLinesShm`) and this loop owns the join.
    const join_groups = o.wantsContext();
    var first = true;
    for (docs) |d| {
        if (d.bytes.len == 0) continue; // cold skips empty bodies in every mode
        em.base = @intFromPtr(d.bytes.ptr);
        if (d.nul) |nul| {
            // Walked (implicit) binary file: cold's exact policy — matches from
            // complete buffers before the NUL, then the WARNING note. Cold's
            // `renderFile` returns on this path before the join-groups insert, so
            // a binary answer neither draws nor consumes the `--` separator.
            if (grepfile.handleBinary(a, &re, o, out, &em, d.path, false, d.bytes, nul, true)) matched = true;
            continue;
        }
        var lines: std.ArrayList([]const u8) = .empty;
        grepfile.collectLines(a, d.bytes, o.term(), &lines);
        const before = out.items.len;
        if (em.file(d.path, lines.items) > 0) {
            if (join_groups and !first and out.items.len > before)
                out.insertSlice(a, before, "--\n") catch return RenderError.OutOfMemory;
            first = false;
            matched = true;
        }
    }
    return matched;
}

/// The warm `lines` emit, data-parallel over documents (both faces).
///
/// The emit walk can be the whole corpus, not a pruned candidate set: bare
/// `gist -v` selects (nearly) EVERY line of EVERY text doc, and a common
/// positive token (`fn`, `pub`, `import`) prunes to a candidate set so LARGE
/// that the serial render is exactly the 1-core-vs-16-core loss to cold's fused
/// scan. This shards the docs by byte weight (`parallel.shardBounds` →
/// `greedyBounds`, so one huge file can't stall a thread), renders each shard
/// through the SAME serial `renderLines` core into its own arena buffer, then
/// concatenates the buffers in ORIGINAL doc order. Output is therefore
/// byte-identical to the serial render — the shards are contiguous doc ranges and
/// every transient (compiled engine, line lists) lives in that shard's arena,
/// freed here as a unit. Invert and positive share this ONE primitive: the
/// caller path-sorts `docs`, `req.invert` flows straight into each shard's
/// `renderLines`. Returns cold's exit-code boolean (any file matched). Below
/// `par_min_bytes` or with one usable core it falls straight through to the
/// serial core — no thread, no extra arena.
pub fn renderLinesParallel(
    gpa: std.mem.Allocator,
    a: std.mem.Allocator,
    req: request.Request,
    docs: []const Doc,
    out: *std.ArrayList(u8),
) RenderError!bool {
    // A context window carries cross-file `--` separator state that an order-free
    // shard split can't reproduce — cold gates it onto its serial loop, so we do
    // too (context queries are narrow; the walk-elimination win still stands).
    if (req.before != 0 or req.after != 0) return renderLines(a, req, docs, out);
    const bounds = parallel.shardBounds(Doc, docs, {}, docWeight, par_min_bytes, par_max_shards, a) orelse
        return renderLines(a, req, docs, out);
    const nthr = bounds.len - 1;

    const Shard = struct {
        gpa: std.mem.Allocator,
        req: request.Request,
        docs: []const Doc,
        buf: std.ArrayList(u8) = .empty,
        arena: std.heap.ArenaAllocator = undefined,
        matched: bool = false,
        err: ?RenderError = null,

        fn run(sh: *@This()) void {
            const sa = sh.arena.allocator();
            sh.matched = renderLines(sa, sh.req, sh.docs, &sh.buf) catch |e| {
                sh.err = e;
                return;
            };
        }
    };

    const shards = try a.alloc(Shard, nthr);
    for (shards, 0..) |*sh, i| sh.* = .{
        .gpa = gpa,
        .req = req,
        .docs = docs[bounds[i]..bounds[i + 1]],
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
    defer for (shards) |*sh| sh.arena.deinit();

    const threads = try a.alloc(std.Thread, nthr);
    parallel.fanOut(Shard, shards, threads, Shard.run);

    var matched = false;
    for (shards) |*sh| {
        if (sh.err) |e| return e;
        try out.appendSlice(a, sh.buf.items);
        matched = matched or sh.matched;
    }
    return matched;
}

fn docWeight(_: void, d: Doc) usize {
    return d.bytes.len;
}

/// A `lines` answer assembled in shared memory (the fd-transport daemon path):
/// filled but NOT yet frozen. The caller freezes it, hands off `buffer.fd`, then
/// closes its own handle — the object lives until the client's fd closes.
pub const ShmLines = struct { buffer: shm.Buffer, len: usize, matched: bool };

/// How a rendered `lines` answer leaves `renderLinesShm`: either a shared-memory
/// buffer to pass as an fd (answer ≥ `floor`, shm available — the zero-socket-copy
/// win), or the rendered bytes to stream as ordinary `chunk` frames (answer below
/// the floor, or shm unavailable — the fail-open path). Byte-identical either way;
/// `chunk` is never a new failure mode.
pub const LinesEmit = union(enum) {
    fd: ShmLines,
    chunk: struct { bytes: []const u8, matched: bool },
};

/// Render the warm `lines` answer and choose its transport by ANSWER SIZE, not
/// shard count: at/above `floor` the bytes are gathered into a shared-memory
/// buffer the daemon hands off as an fd (`sendChunkFd`) so the multi-MB answer
/// never traverses the socket; below it — or if shm setup fails — the same bytes
/// come back to stream as `chunk` frames. A large SINGLE-doc answer is fd-eligible
/// too: the win is the eliminated socket copy, independent of how many docs (or
/// shards) produced it.
///
/// The bytes are byte-identical to `renderLinesParallel`: the same shards, the
/// same per-shard `renderLines` core, the same doc-order concatenation. For the
/// fd case the shard buffers are copied STRAIGHT into shm (one copy, no arena
/// concatenation first); for the chunk case a single shard's bytes are returned
/// as-is and multiple shards are concatenated into the arena.
pub fn renderLinesShm(
    gpa: std.mem.Allocator,
    a: std.mem.Allocator,
    req: request.Request,
    docs: []const Doc,
    floor: usize,
) RenderError!LinesEmit {
    // Serial render (corpus below `par_min_bytes`, one core, a single doc a shard
    // split can't divide, OR a context window whose cross-file `--` state resists
    // an order-free split — same serial gate cold applies): one arena buffer holds
    // the whole answer, then the same floor decision — a huge single doc still
    // earns the fd path.
    const ctx = req.before != 0 or req.after != 0;
    const bounds = if (ctx) null else parallel.shardBounds(Doc, docs, {}, docWeight, par_min_bytes, par_max_shards, a);
    const bnds = bounds orelse {
        var out: std.ArrayList(u8) = .empty;
        const matched = try renderLines(a, req, docs, &out);
        return emit(a, &.{out.items}, matched, floor);
    };
    const nthr = bnds.len - 1;

    const Shard = struct {
        req: request.Request,
        docs: []const Doc,
        buf: std.ArrayList(u8) = .empty,
        arena: std.heap.ArenaAllocator = undefined,
        matched: bool = false,
        err: ?RenderError = null,

        fn run(sh: *@This()) void {
            const sa = sh.arena.allocator();
            sh.matched = renderLines(sa, sh.req, sh.docs, &sh.buf) catch |e| {
                sh.err = e;
                return;
            };
        }
    };

    const shards = try a.alloc(Shard, nthr);
    for (shards, 0..) |*sh, i| sh.* = .{
        .req = req,
        .docs = docs[bnds[i]..bnds[i + 1]],
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
    defer for (shards) |*sh| sh.arena.deinit();

    const threads = try a.alloc(std.Thread, nthr);
    parallel.fanOut(Shard, shards, threads, Shard.run);

    const pieces = try a.alloc([]const u8, nthr);
    var matched = false;
    for (shards, pieces) |*sh, *p| {
        if (sh.err) |e| return e;
        p.* = sh.buf.items;
        matched = matched or sh.matched;
    }
    return emit(a, pieces, matched, floor);
}

/// Hand the rendered `pieces` (in doc order, ≥1) to the caller as an fd or a
/// chunk stream. At/above `floor` they're copied contiguously into a fresh shm
/// buffer (one copy); on an shm failure or below the floor they fall to `chunk` —
/// a single piece as-is, several concatenated into `a`. The shard/serial arenas
/// backing `pieces` stay alive until the caller returns, so both reads are safe.
fn emit(a: std.mem.Allocator, pieces: []const []const u8, matched: bool, floor: usize) RenderError!LinesEmit {
    var total: usize = 0;
    for (pieces) |p| total += p.len;
    if (total >= floor) {
        if (shm.Buffer.create(total)) |created| {
            var buffer = created;
            var off: usize = 0;
            for (pieces) |p| {
                @memcpy(buffer.map[off..][0..p.len], p);
                off += p.len;
            }
            return .{ .fd = .{ .buffer = buffer, .len = total, .matched = matched } };
        } else |_| {} // shm unavailable → fall open to chunk frames
    }
    if (pieces.len == 1) return .{ .chunk = .{ .bytes = pieces[0], .matched = matched } };
    var out: std.ArrayList(u8) = .empty;
    for (pieces) |p| try out.appendSlice(a, p);
    return .{ .chunk = .{ .bytes = out.items, .matched = matched } };
}

test {
    // The warm `lines` renderer's correctness suite lives in the sibling
    // `render_test.zig` per this tier's `*_test.zig` shape-cap convention
    // (see `root.zig`). root.zig imports THIS file, so referencing the sibling
    // here wires the suite into `zig build test` without a root.zig edit.
    _ = @import("render_test.zig");
}
