//! gist — sifting ONE file: read, decode, gate, triage, match, render.
//!
//! The parallel twin of the serial engine's per-file loop body, built from the
//! same `read/` primitives so the two cannot drift. The staging is what earns
//! the speed: decide from the first BUFCAP bytes whatever they already settle
//! (a NUL cutoff, an `-l` match proof) before paying for the tail, since 86% of
//! this corpus's bytes live in the tails of >64 KiB files. Then one whole-file
//! literal gate can drop the body outright, and when that gate is a match
//! EQUIVALENCE rather than mere containment it can ANSWER `-l` with no engine
//! run at all.

const std = @import("std");
const args = @import("../../argv/args.zig");
const beacon = @import("../../../../cli/beacon.zig");
const binary = @import("../../read/binary.zig");
const crew = @import("crew.zig");
const ingest = @import("../../read/ingest.zig");
const json = @import("../../emit/json.zig");
const legible = @import("../../read/legible.zig");
const multiline = @import("../../emit/multiline.zig");
const notice = @import("../../quarry/notice.zig");
const output = @import("../../emit/output.zig");
const simd = @import("../../../../../kernel/match/scan/simd.zig");
const slurp = @import("../../read/slurp.zig");
const stats = @import("../../read/stats.zig");
const verify = @import("../../../../../kernel/match/scan/verify.zig");
const portal = @import("../../../../../portal.zig");

const Emitter = output.Emitter;
const Matcher = @import("../../../../../kernel/match/regex/regex.zig").Matcher;
const Worker = crew.Worker;
const oom = args.oom;

/// A candidate this worker could not OPEN. ripgrep prints the errno line and
/// exits 2 even when other files matched: an unsearched file is a gap in the
/// answer, not an absence of matches. The rendering is the shared
/// `notice.printWalkError` (the line an unreadable DIRECTORY already produced)
/// and the flag is the queue's existing `walk_error` atomic, so the two halves
/// of "could not look" reach the exit code through one path. Discovered by
/// `bench/rgsuite/fuzz.py` differentially against live rg.
fn reportUnopenable(w: *Worker, rel: []const u8, e: slurp.OpenFault) void {
    notice.printWalkError(rel, e);
    w.q.walk_error.store(true, .release);
}

/// Match+render a file whose bytes came from the content-shard mapping rather
/// than a live read. The mmap'd slice is the file's raw bytes (shard membership
/// is `corpus.readMember` — non-binary, so no NUL triage is owed and no UTF-16
/// transcode can fire; a bare UTF-8 BOM still strips via `decodeBom`). Nothing
/// was pre-scanned, so `emitBody` runs the gate + match over the whole body
/// (covered = gate_from = 0) — byte-identical to the staged read path's result.
pub fn searchShardBody(w: *Worker, a: std.mem.Allocator, dpath: []const u8, bytes: []const u8) void {
    const body = legible.decodeBom(a, bytes);
    if (w.cfg.o.mode == .json) return emitJson(w, a, dpath, body);
    if (body.len == 0) return noteEmpty(w, dpath);
    emitBody(w, a, dpath, body, 0, 0);
}

/// Empty-body bookkeeping shared by the live and shard read paths. An empty
/// file has no match, so `--files-without-match` emits its path — and `--stats`
/// counts it as a searched file contributing zero bytes, which is what rg
/// reports (mirrors serial `renderFile`'s empty arm).
fn noteEmpty(w: *Worker, dpath: []const u8) void {
    const o = w.cfg.o;
    if (o.mode.negated()) w.bufferPath(dpath, if (o.null_sep) "\x00" else o.outTerm());
    // rg searched it — zero bytes, but a counted file (serial `renderFile`'s
    // empty arm bumps the same counter).
    if (o.stats) w.stats.bump(.files_searched);
}

/// The `--json` per-file render on the parallel walk: emit ripgrep's
/// `begin`/`match`/`end` records for ONE file through the shared `json.emitOne`
/// (the identical encoder the serial/shard `--json` path uses), tallying this
/// worker's running `jstats`, then stream the self-framed record block through
/// the sink. `run` sums every worker's `jstats` into the single trailing
/// `summary`. Byte-identical to the serial collect-then-shard path by
/// construction: the SAME `file_needle` whole-file gate decides which admitted
/// files are searched (mirroring `readOneCandidate` — a body missing the required
/// literal provably can't match, so it is neither searched nor counted, keeping
/// the `searches` tally in lockstep), and `line_needle` accelerates the per-line
/// span scan inside `emitOne`. `file_alts` is deliberately NOT applied — the
/// serial collect path gates `--json` on the single `file_needle` only.
fn emitJson(w: *Worker, a: std.mem.Allocator, dpath: []const u8, decoded: []const u8) void {
    const cfg = w.cfg;
    const body = ingest.visibleBody(cfg.o.encoding, decoded);
    if (cfg.file_needle) |gate| if (!verify.gateWide(a, body, gate)) return;
    const ss = w.spanSim() orelse return;
    var buf: std.ArrayList(u8) = .empty;
    json.emitOne(a, &buf, cfg.re.?, ss, null, cfg.o, .{ .path = dpath, .body = body }, &w.jstats, cfg.line_needle);
    if (buf.items.len > 0) cfg.sink.emit(.json, buf.items, 0);
}

/// Read + match + render ONE file straight into the sink — the parallel
/// twin of the serial engine's per-file loop body (`serial.zig`), built from the
/// same `read/` primitives so the two cannot drift. `disk` is resolved
/// relative to `dirfd` (the walk passes the still-open parent directory so the
/// kernel resolves one component; deferred/elision reads pass `portal.cwd()` with
/// the full path).
pub fn searchFile(w: *Worker, a: std.mem.Allocator, scratch: []u8, dirfd: std.posix.fd_t, disk: []const u8, dpath: []const u8, openable: []const u8) void {
    const cfg = w.cfg;
    const o = cfg.o;
    const re = cfg.re.?;

    // `--json` reads the WHOLE body (rg emits every match line's record) and
    // renders it through `emitJson`, bypassing the text prefix-triage/`-l`
    // fast paths below — `--json` declines `-z`/`-E` (see `eligible`), so no
    // transform is owed here. Every admitted file reaches `emitJson` exactly
    // once, so its `searches` tally stays byte-identical to the serial path.
    if (o.mode == .json) {
        const sf = slurp.StagedFile.open(scratch, dirfd, disk) catch |e| return reportUnopenable(w, dpath, e);
        defer sf.close();
        const raw = if (sf.more) (sf.readRest(a, scratch) orelse return) else sf.prefix;
        return emitJson(w, a, dpath, legible.decodeBom(a, raw));
    }

    // Transform run (`-z`/`-E`): the on-disk bytes are compressed/encoded, so the
    // staged prefix triage below (a NUL sniff, an `-l` prefix proof) would read
    // garbage — read the WHOLE file, rewrite it via `ingest`, then match the
    // decoded body from offset 0 (covered/gate_from = 0). `openable` is the
    // CWD-relative path the external-codec subprocess (bz2/lz4/br) re-opens;
    // native decoders (gz/zst/xz) and `-E` reuse the bytes we just read. A null
    // return is a dropped file (never reached here: `--pre`, the only dropping
    // transform, stays on the serial engine).
    if (cfg.ingest) |icfg| {
        const sf = slurp.StagedFile.open(scratch, dirfd, disk) catch |e| return reportUnopenable(w, dpath, e);
        defer sf.close();
        const raw = sf.readRest(a, scratch) orelse return;
        const body = ingest.apply(a, icfg, openable, dpath, raw) orelse return;
        if (body.len == 0) return noteEmpty(w, dpath);
        return emitBody(w, a, dpath, body, 0, 0);
    }

    const sf = slurp.StagedFile.open(scratch, dirfd, disk) catch |e| return reportUnopenable(w, dpath, e);
    defer sf.close();

    // Stage 1 — decide what the first BUFCAP bytes (rg's buffer 0) already
    // settle, before paying for the tail (86% of this corpus's bytes live in
    // the tails of >64 KiB files). A UTF-16 BOM opts out: the transcode needs
    // the whole file and dissolves its NULs, so no prefix triage is sound.
    const utf16 = std.mem.startsWith(u8, sf.prefix, "\xFF\xFE") or std.mem.startsWith(u8, sf.prefix, "\xFE\xFF");
    // A NUL inside buffer 0 that only `--stats` kept us reading for: the binary
    // arm below hunts the first NUL from `covered` on the premise that stage 1
    // proved the prefix clean, which this fall-through breaks. Remembering it
    // re-arms that arm (via `covered = 0`), where forgetting it published the
    // file as ordinary text — the `--stats`-only binary leak the fuzzer found.
    var prefix_nul = false;
    if (!utf16) {
        // NUL in buffer 0: rg's emission cutoff is the start of the buffer that
        // holds the first NUL — the very first — so an implicit walked file
        // contributes NOTHING in content modes (`-l`, default, `-c`, context,
        // `-o`, `--files-without-match`). `--stats` still needs the committed-
        // prefix tally (serial `renderFile`'s binary arm), so it falls through
        // to the full read + `emitBody` binary path. `--binary`-style explicit
        // files never reach this engine.
        if (cfg.binary_detect and std.mem.indexOfScalar(u8, sf.prefix, 0) != null) {
            if (!o.stats) return;
            prefix_nul = true;
        }
        // `-l` / `--files-without-match` + a >64 KiB file: a match PROVEN
        // inside the NUL-free prefix settles the file — `-l` emits and skips
        // the tail; `--files-without-match` skips WITHOUT emitting (the file
        // HAS a match). Absence proves nothing; fall through to the full read.
        if (cfg.fast_l and sf.more and prefixProvesMatch(w, re, ingest.visibleBody(o.encoding, sf.prefix))) {
            if (!o.mode.negated()) w.bufferPath(dpath, if (o.null_sep) "\x00" else o.outTerm());
            return;
        }
    }
    const raw = if (sf.more) (sf.readRest(a, scratch) orelse return) else sf.prefix;
    const body = legible.decodeBom(a, raw);
    if (body.len == 0) return noteEmpty(w, dpath);
    // Bytes of `body` already covered by the stage-1 prefix scans, in body
    // space: `body` aliases `raw` at offset 0 or 3 (UTF-8 BOM strip), so the
    // scanned raw prefix maps to `body[0..covered]`. A UTF-16 transcode built a
    // fresh buffer with different bytes — nothing carries over (covered = 0).
    const covered: usize = if (utf16 or prefix_nul) 0 else sf.prefix.len -| (@intFromPtr(body.ptr) - @intFromPtr(raw.ptr));
    // Literal gate. When stage 1 already proved the equivalence gate absent
    // from the prefix (fast_l + tail present + no early emit above), rescan
    // only the unseen tail plus a `gate_len-1` straddle window for a literal
    // crossing the seam — not the whole body again.
    const gate_from: usize = if (cfg.fast_l and cfg.lits_equiv and !utf16 and sf.more) covered -| (cfg.gate_len - 1) else 0;
    emitBody(w, a, dpath, body, covered, gate_from);
}

/// The shared match+render tail: literal gate, binary handling, the `-l` fused
/// fast path, and the per-line emit — streamed into the sink. Both callers reach
/// it with a fully-decoded `body`: the staged read path (raw on-disk bytes,
/// `covered`/`gate_from` reflecting its stage-1 prefix scan) and the transform
/// path (`ingest`-rewritten bytes, both 0 — nothing was pre-scanned).
fn emitBody(w: *Worker, a: std.mem.Allocator, dpath: []const u8, body: []const u8, covered: usize, gate_from: usize) void {
    const cfg = w.cfg;
    const o = cfg.o;
    const re = cfg.re.?;
    // The `Wide` gates are the plain SIMD kernels until a body crosses
    // `verify.wide_threshold` (16 MiB) — then the presence test itself fans
    // out across cores. One worker owning an mmap'd multi-GiB blob (which the
    // rg-parity walk legitimately admits via explicit-root scoping) stops
    // serializing the whole walk behind a single-thread scan.
    // Whole-file gate miss: the body can't match. `-l` drops it; `--files-
    // without-match` emits the path (the invert); `--stats` tallies a searched
    // zero-hit file (rg counts non-matching bytes as searched) and drops the
    // content stream. Content modes return silently.
    if (cfg.file_needle) |n| if (!verify.gateWide(a, body[gate_from..], n)) {
        gateMiss(w, dpath, body);
        return;
    };
    if (cfg.file_alts.len > 0 and !verify.containsAnyWide(a, body[gate_from..], cfg.file_alts)) {
        gateMiss(w, dpath, body);
        return;
    }

    var buf: std.ArrayList(u8) = .empty;
    var em: Emitter = .{
        .a = a,
        .re = re,
        .o = o,
        // The serial engine keys this off the RAW --heading flag (not the
        // count/files-only-adjusted `cfg.heading`) — match it exactly.
        .show_name = if (o.groups()) false else cfg.show_name,
        .out = &buf,
        .base = @intFromPtr(body.ptr),
        .body_end = @intFromPtr(body.ptr) + body.len,
        .use_color = cfg.use_color,
        .needle = cfg.line_needle,
        // The worker's reusable scratch (null only on OOM ⇒ Emitter builds a
        // local) — one Sim per worker instead of three allocs per file.
        .sim = w.matchSim(),
    };
    // Whole-buffer or per-line — the same question serial `renderFile` asks,
    // and `-U` alone does not answer it (`multiline.sliceModel`).
    const slice_model = multiline.sliceModel(re, o);

    // Stage 1 already proved `body[0..covered]` NUL-free (or we'd have
    // returned there), so the first NUL — the binary cutoff — can only sit in
    // the unseen tail. Sub-cap files are fully covered: zero bytes rescanned.
    if (cfg.binary_detect) if (std.mem.indexOfScalarPos(u8, body, covered, 0)) |nul| {
        // rg's -U slice model runs only when the pattern can actually match
        // `\n`; slice model + NUL beyond the 64K sniff means the searcher never
        // notices it — ordinary text, fall through to the normal path.
        if (!(slice_model and !binary.multilineBinary(body.len, nul))) {
            // `--files-without-match` skips binary files entirely (serial
            // `fileWithoutMatch` returns before any emit) — no path, no tally.
            if (o.mode.negated()) return;
            if (o.stats) {
                // Walked (implicit) file: only the committed prefix was
                // searched — mirror serial `renderFile`'s binary stats arm.
                const searched = body[0..binary.committedPrefix(body, nul)];
                var blines: std.ArrayList([]const u8) = .empty;
                if (!o.multiline) legible.collectLines(a, searched, o.term(), &blines);
                const fs = stats.fileMatchStats(re, a, o, searched, blines.items, cfg.line_needle);
                w.stats.bump(.files_searched);
                w.stats.add(.matches, fs.matches);
                w.stats.add(.matched_lines, fs.lines);
                w.stats.add(.bytes_searched, fs.bytes);
            }
            const matched = binary.handleBinary(a, re, o, &buf, &em, dpath, false, body, nul, cfg.show_name);
            if (matched or buf.items.len > 0)
                w.deliver(if (matched) .bin_hit else .text_plain, dpath, buf.items, em.chrome);
            return;
        }
    };

    // `-l` / `--files-without-match` fused fast path: one early-exit whole-
    // buffer pass answers the file — no line split, no per-line engine
    // dispatch. When the pattern is a pure literal (alternation), the whole-
    // file gate above already PROVED the match (equivalence, not containment),
    // so not even `docMatch` runs. A containment-only gate still drives the
    // scan: jump gate hit to gate hit at SIMD speed and run the engine on just
    // each hit's line (`gatedDocMatch`). `--files-without-match` emits on a
    // MISS (the invert of `-l`).
    if (cfg.fast_l) {
        const hit = cfg.lits_equiv or blk: {
            const sim = w.matchSim() orelse break :blk false;
            // `-U`: the whole-buffer boolean — `run` admits `fast_l` here only
            // when `bufBoolExact` proved it equals the emit model's verdict.
            if (o.multiline) break :blk re.bufMatch(sim, body);
            // Caseless only: the case-sensitive whole-body `docMatch` is
            // already DFA-fast, while the caseless engine pays per byte —
            // that is the run the hit-jump rescues.
            if (cfg.file_needle) |n| if (n.ci) break :blk gatedDocMatch(re, sim, n, body);
            break :blk re.docMatch(sim, body);
        };
        if (hit != o.mode.negated()) w.bufferPath(dpath, if (o.null_sep) "\x00" else o.outTerm());
        return;
    }

    // `-U` renders through the whole-buffer emitter (no line split — a match
    // may cross `\n`); the per-line model splits into rg lines. The line-free
    // literal fast path (`Emitter.fileLit`) — rg's candidate-jump searcher —
    // reads `body` directly, so skip `collectLines` when it is eligible. This is
    // exactly the count/`-o`/`-n`/plain literal regime `fast_l` above does not
    // cover; without it every worker paid a full line split + per-line engine
    // dispatch on a ubiquitous literal the index can't prune. Mirrors the serial
    // engine's per-file dispatch exactly. `--stats` disables the fused class-run
    // shortcut (it needs the line array for `fileMatchStats`, like serial).
    const fast = !slice_model and em.litFastEligible();
    const fused = !slice_model and !fast and !o.stats and em.fusedFileEligible();
    var lines: std.ArrayList([]const u8) = .empty;
    if (!slice_model and !fast and !fused) legible.collectLines(a, body, o.term(), &lines);
    if (o.stats) {
        const fs = stats.fileMatchStats(re, a, o, body, lines.items, cfg.line_needle);
        w.stats.bump(.files_searched);
        w.stats.add(.matches, fs.matches);
        w.stats.add(.matched_lines, fs.lines);
        w.stats.add(.bytes_searched, fs.bytes);
    }
    // Under `--heading` the filename is printed once, here, and the rows below
    // carry only line numbers — so this heading is the only thing a human can
    // click to open the file. `em.out` IS this buffer, so the shared emitter
    // writes the title exactly as the serial engine does and keeps its own
    // chrome tally, which is what the output budget discounts. Hand-rolling the
    // line here instead is how the two engines came to paint it differently.
    if (cfg.heading and cfg.show_name) em.heading(dpath);
    const before_body = buf.items.len;
    const hits = if (slice_model) em.buffer(dpath, body) else if (fast) em.fileLit(dpath, body, 0, body.len, 0, true) else em.file(dpath, lines.items);
    if (hits > 0) return w.deliver(.text_hit, dpath, buf.items, em.chrome);
    // No heading header to keep, and (except --passthru) no body either.
    if (!cfg.heading and buf.items.len > before_body) w.deliver(.text_plain, dpath, buf.items, em.chrome);
}

/// Whole-file gate / alts miss: settle `--files-without-match` (emit) and
/// `--stats` (tally a zero-hit searched file); every other mode is a silent drop.
/// `--stats` bytes follow the binary cutoff: a walked file with a NUL only
/// contributes its committed prefix (serial `renderFile`'s binary arm).
fn gateMiss(w: *Worker, dpath: []const u8, body: []const u8) void {
    const o = w.cfg.o;
    if (o.mode.negated()) {
        w.bufferPath(dpath, if (o.null_sep) "\x00" else o.outTerm());
    } else if (o.stats) {
        var bytes = body.len;
        if (w.cfg.binary_detect) if (std.mem.indexOfScalar(u8, body, 0)) |nul| {
            bytes = binary.committedPrefix(body, nul);
        };
        w.stats.bump(.files_searched);
        w.stats.add(.bytes_searched, bytes);
    }
}

/// The gate-driven `-l` boolean: every matching line must contain the gate
/// literal (the gate is a per-match necessary condition), so instead of
/// running the engine over every admitted byte, jump from gate hit to gate
/// hit with the SIMD kernel and run the engine only on each hit's enclosing
/// line. Exact: a matching line holds a gate hit inside it, so it is visited;
/// a rejected line's remaining hits are skipped by resuming past its end.
/// This is what keeps a caseless run at SIMD throughput — the fold-heavy
/// engine (whose caseless DFA pays per byte) touches only gate-hit lines.
fn gatedDocMatch(re: *const Matcher, sim: *Matcher.Sim, gate: simd.Gate, body: []const u8) bool {
    var from: usize = 0;
    while (gate.find(body, from)) |pos| {
        const ls = if (std.mem.lastIndexOfScalar(u8, body[0..pos], '\n')) |k| k + 1 else 0;
        const le = std.mem.indexOfScalarPos(u8, body, pos, '\n') orelse body.len;
        if (re.lineMatch(sim, body[ls..le])) return true;
        if (le >= body.len) break;
        from = le + 1;
    }
    return false;
}

/// Positive-only match proof over a buffer prefix: true ⇒ the file matches
/// (emit and skip its tail); false ⇒ undecided (the caller reads the rest).
/// The pure-literal equivalence answers from SIMD `contains` alone — sound even
/// inside the truncated final line, since a literal carries no `\n` and so sits
/// inside the real (longer) line too. The regex path instead sees only COMPLETE
/// lines: a truncated line's cut IS an end-of-line to `docMatch`, so `$`/`^$`
/// could fire where the real line continues — a false positive the trim removes.
fn prefixProvesMatch(w: *Worker, re: *const Matcher, prefix: []const u8) bool {
    const cfg = w.cfg;
    if (cfg.lits_equiv) {
        if (cfg.file_needle) |n| return n.in(prefix);
        return simd.containsAny(prefix, cfg.file_alts);
    }
    if (cfg.o.multiline) {
        // `-U`: sound only for an assertion-free pattern (substring-closed —
        // nothing zero-width can assert against the cut), and then the RAW
        // prefix serves: any match inside it is a match of the file.
        if (!re.bufPrefixClosed()) return false;
        const sim = w.matchSim() orelse return false;
        return re.bufMatch(sim, prefix);
    }
    const nl = std.mem.lastIndexOfScalar(u8, prefix, '\n') orelse return false;
    const sim = w.matchSim() orelse return false;
    return re.docMatch(sim, prefix[0 .. nl + 1]);
}
