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
//! Fail-closed like the rest of the session: a pattern the linear engine
//! declines is `error.Unsupported` (→ decline → certified cold answer), never
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
const Regex = @import("../../../kernel/match/regex/linear/core.zig").Regex;
const Matcher = @import("../../../kernel/match/regex/linear/matcher.zig").Matcher;

pub const RenderError = error{ Unsupported, OutOfMemory };

/// One renderable document: display path, decoded resident bytes, and the
/// byte offset of the first NUL (null ⇒ text). Mirrors `mirror.Doc` + path.
pub const Doc = struct { path: []const u8, bytes: []const u8, nul: ?usize };

/// Below this many total corpus bytes a warm face emits/folds serially: thread
/// spawn + arena setup + the per-shard `Regex` recompile / scratch only pay off
/// once the scan itself dominates. Cold's own parallel engine has the same floor
/// (a tiny tree is faster single-threaded), so matching it keeps the small-corpus
/// warm answer from regressing while the big-corpus one wins. `pub` so every warm
/// face (this render emit, the resident `-l`/`-c` fold, the FFI record stream)
/// crosses into parallelism at the SAME corpus size through `parallel.shardBounds`.
pub const par_min_bytes: usize = 256 << 10;

/// Hard cap on emit/fold shards — the realistic core count, so a giant corpus
/// doesn't spawn hundreds of threads that thrash the scheduler.
pub const par_max_shards: usize = 16;

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
    // Unicode stays at the rg-parity default. A pattern outside the
    // linear-time syntax is the caller's cue to answer cold.
    const caseless = req.effectiveIgnoreCase();
    const eff = if (req.fixed) try query_mod.escapeLiteral(a, req.pattern) else req.pattern;
    const linear = Regex.compileOpts(a, eff, .{ .caseless = caseless, .unicode = true }) catch |e| switch (e) {
        error.OutOfMemory => return RenderError.OutOfMemory,
        else => return RenderError.Unsupported,
    };
    var re = Matcher{ .linear = linear };
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
        .max_per_file = if (req.max_count) |m| std.math.cast(usize, m) orelse std.math.maxInt(usize) else 0,
        .max_per_file_set = req.max_count != null,
    };
    var em = output.Emitter{ .a = a, .re = &re, .o = o, .show_name = true, .out = out, .needle = needle };

    var matched = false;
    for (docs) |d| {
        if (d.bytes.len == 0) continue; // cold skips empty bodies in every mode
        em.base = @intFromPtr(d.bytes.ptr);
        if (d.nul) |nul| {
            // Walked (implicit) binary file: cold's exact policy — matches from
            // complete buffers before the NUL, then the WARNING note.
            if (grepfile.handleBinary(a, &re, o, out, &em, d.path, false, d.bytes, nul, true)) matched = true;
            continue;
        }
        var lines: std.ArrayList([]const u8) = .empty;
        grepfile.collectLines(a, d.bytes, o.term(), &lines);
        if (em.file(d.path, lines.items) > 0) matched = true;
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

fn renderToString(a: std.mem.Allocator, req: request.Request, docs: []const Doc) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    _ = try renderLines(a, req, docs, &out);
    return out.items;
}

test "renderLines: default and -n frames match the cold presentation" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const docs = [_]Doc{
        .{ .path = "a.txt", .bytes = "alpha\nneedle one\n", .nul = null },
        .{ .path = "b.txt", .bytes = "needle two\nno\nneedle three", .nul = null }, // no trailing \n
    };
    // Expected bytes pinned from ripgrep's default piped frame (path:text,
    // recursive walk ⇒ filename prefix on; final line still terminated).
    try t.expectEqualStrings(
        "a.txt:needle one\nb.txt:needle two\nb.txt:needle three\n",
        try renderToString(a, .{ .pattern = "needle", .mode = .lines, .fixed = true }, &docs),
    );
    try t.expectEqualStrings(
        "a.txt:2:needle one\nb.txt:1:needle two\nb.txt:3:needle three\n",
        try renderToString(a, .{ .pattern = "needle", .mode = .lines, .fixed = true, .line_num = true }, &docs),
    );
}

test "renderLines: regex, caseless, and CR-keeping line semantics" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // rg keeps a trailing \r without --crlf; `n.edle` is a live regex; `-i`
    // folds case through the engine (escaped-literal path for -F -i).
    const docs = [_]Doc{.{ .path = "f.txt", .bytes = "Needle\r\nplain needle\n", .nul = null }};
    try t.expectEqualStrings(
        "f.txt:plain needle\n",
        try renderToString(a, .{ .pattern = "n.edle", .mode = .lines }, &docs),
    );
    try t.expectEqualStrings(
        "f.txt:Needle\r\nf.txt:plain needle\n",
        try renderToString(a, .{ .pattern = "needle", .mode = .lines, .fixed = true, .ignore_case = true }, &docs),
    );
    // -S resolves HERE (the renderer reads `effectiveIgnoreCase`, never the
    // raw bit): a lowercase pattern folds — identical bytes to the -i row —
    // and an uppercase pattern stays case-sensitive.
    try t.expectEqualStrings(
        "f.txt:Needle\r\nf.txt:plain needle\n",
        try renderToString(a, .{ .pattern = "needle", .mode = .lines, .fixed = true, .smart_case = true }, &docs),
    );
    try t.expectEqualStrings(
        "f.txt:Needle\r\n",
        try renderToString(a, .{ .pattern = "Needle", .mode = .lines, .fixed = true, .smart_case = true }, &docs),
    );
}

test "renderLines: -w flows through the cold Emitter's own word filter" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Substring hits (`runner`), Unicode-neighbor hits (`érun`), and a
    // word-rejected-then-valid line (`rerun run`) — the Emitter's wordOk /
    // nextSpan pass decides, the renderer only sets the flag.
    const docs = [_]Doc{.{ .path = "w.txt", .bytes = "run runner\nrerun run\nrunner only\n\xc3\xa9run there\n", .nul = null }};
    try t.expectEqualStrings(
        "w.txt:run runner\nw.txt:rerun run\n",
        try renderToString(a, .{ .pattern = "run", .mode = .lines, .fixed = true, .word = true }, &docs),
    );
    // -w composes with the resolved case fold; the word check runs on the
    // original bytes (`RUN` bounded by space/edge is word-valid once folded).
    const cased = [_]Doc{.{ .path = "c.txt", .bytes = "RUN loud\nrerunning\n", .nul = null }};
    try t.expectEqualStrings(
        "c.txt:RUN loud\n",
        try renderToString(a, .{ .pattern = "run", .mode = .lines, .fixed = true, .ignore_case = true, .word = true }, &cased),
    );
}

test "renderLines: implicit binary emits pre-NUL-buffer matches + WARNING, or nothing" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // NUL in the first 64 KiB buffer ⇒ nothing visible before the cut ⇒ rg
    // quits silently: no output, no match.
    const early = [_]Doc{.{ .path = "bin.dat", .bytes = "needle\x00tail", .nul = 6 }};
    var out1: std.ArrayList(u8) = .empty;
    try t.expect(!try renderLines(a, .{ .pattern = "needle", .mode = .lines, .fixed = true }, &early, &out1));
    try t.expectEqualStrings("", out1.items);

    // A match in a complete buffer BEFORE the one holding the first NUL emits,
    // then the implicit-file WARNING (cold `handleBinary` verbatim).
    const pad = try a.alloc(u8, grepfile.BUFCAP);
    @memset(pad, 'x');
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(a, "needle early\n");
    try body.appendSlice(a, pad); // push the NUL past the first BUFCAP buffer
    try body.appendSlice(a, "\x00");
    const late = [_]Doc{.{ .path = "big.dat", .bytes = body.items, .nul = std.mem.indexOfScalar(u8, body.items, 0) }};
    var out2: std.ArrayList(u8) = .empty;
    try t.expect(try renderLines(a, .{ .pattern = "needle", .mode = .lines, .fixed = true }, &late, &out2));
    try t.expect(std.mem.startsWith(u8, out2.items, "big.dat:needle early\n"));
    try t.expect(std.mem.indexOf(u8, out2.items, "WARNING: stopped searching binary file") != null);
}

test "renderLinesParallel: byte-identical to the serial invert core" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Enough docs and bytes to cross `par_min_bytes` and fan across shards; a
    // per-doc line pattern guarantees each doc has both matching and
    // non-matching lines so the complement is non-trivial in every shard.
    var docs: std.ArrayList(Doc) = .empty;
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        var body: std.ArrayList(u8) = .empty;
        var l: usize = 0;
        while (l < 40) : (l += 1)
            try body.appendSlice(a, if (l % 3 == 0) "needle here\n" else "plain filler line\n");
        try docs.append(a, .{
            .path = try std.fmt.allocPrint(a, "d{d:0>4}.txt", .{i}),
            .bytes = body.items,
            .nul = null,
        });
    }
    const req = request.Request{ .pattern = "needle", .mode = .lines, .fixed = true, .invert = true, .line_num = true };

    var serial: std.ArrayList(u8) = .empty;
    const sm = try renderLines(a, req, docs.items, &serial);
    var par: std.ArrayList(u8) = .empty;
    const pm = try renderLinesParallel(t.allocator, a, req, docs.items, &par);

    try t.expectEqual(sm, pm);
    try t.expectEqualStrings(serial.items, par.items);

    // The POSITIVE emit (a large candidate set) is byte-identical too: same
    // pattern without `-v`, over the same doc slice, shards and concatenates to
    // exactly the serial render.
    const preq = request.Request{ .pattern = "needle", .mode = .lines, .fixed = true, .line_num = true };
    var pos_serial: std.ArrayList(u8) = .empty;
    const psm = try renderLines(a, preq, docs.items, &pos_serial);
    var pos_par: std.ArrayList(u8) = .empty;
    const ppm = try renderLinesParallel(t.allocator, a, preq, docs.items, &pos_par);
    try t.expectEqual(psm, ppm);
    try t.expectEqualStrings(pos_serial.items, pos_par.items);
}

test "renderLines: a pattern outside the linear engine declines (never dies)" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var out: std.ArrayList(u8) = .empty;
    try t.expectError(RenderError.Unsupported, renderLines(arena.allocator(), .{ .pattern = "(?<=look)behind", .mode = .lines }, &.{}, &out));
}
