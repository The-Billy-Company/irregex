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
const beacon = @import("../../../../surface/cli/beacon.zig");
const binary = @import("../../read/binary.zig");
const crew = @import("crew.zig");
const ingest = @import("../../read/ingest.zig");
const json = @import("../../emit/json.zig");
const legible = @import("../../../../corpus/read/legible.zig");
const multiline = @import("../../emit/multiline.zig");
const notice = @import("../../quarry/notice.zig");
const output = @import("../../emit/output.zig");
const simd = @import("../../../../kernel/scan/simd.zig");
const slurp = @import("../../../../corpus/read/slurp.zig");
const stats = @import("../../read/stats.zig");
const verify = @import("../../../../kernel/scan/verify.zig");
const portal = @import("../../../../portal.zig");

const Emitter = output.Emitter;
const Opts = @import("../../argv/args.zig").Opts;
const Matcher = @import("../../../../kernel/regex/regex.zig").Matcher;
const Worker = crew.Worker;
const oom = @import("../../../../surface/cli/outcome.zig").oom;

/// A candidate this worker could not OPEN. ripgrep prints the errno line and
/// exits 2 even when other files matched: an unsearched file is a gap in the
/// answer, not an absence of matches. The rendering is the shared
/// `notice.printWalkError` (the line an unreadable DIRECTORY already produced)
/// and the flag is the queue's existing `walk_error` atomic, so the two halves
/// of "could not look" reach the exit code through one path. Discovered by
/// `gist/bench/conformance/rgsuite/fuzz.py` differentially against live rg.
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
        const staged: slurp.Body = if (sf.more) (sf.readWhole(a, scratch) orelse return) else .{ .bytes = sf.prefix };
        defer if (staged.map) |m| slurp.release(m);
        return emitJson(w, a, dpath, legible.decodeBom(a, staged.bytes));
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
        const staged = sf.readWhole(a, scratch) orelse return;
        defer if (staged.map) |m| slurp.release(m);
        const body = ingest.apply(a, icfg, openable, dpath, staged.bytes) orelse return;
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
    // How many RAW prefix bytes stage 1's proof actually read — 0 when no proof
    // ran at all. The whole-file gate below skips past them; see `proven`.
    var read: usize = 0;
    if (!utf16) {
        // NUL in buffer 0: rg's emission cutoff is the start of the buffer that
        // holds the first NUL — the very first — so an implicit walked file
        // contributes NOTHING in content modes (`-l`, default, `-c`, context,
        // `-o`, `--files-without-match`). `--stats` still needs the committed-
        // prefix tally (serial `renderFile`'s binary arm), so it falls through
        // to the full read + `emitBody` binary path. `--binary`-style explicit
        // files never reach this engine.
        if (cfg.binary_detect and std.mem.indexOfScalar(u8, sf.prefix, 0) != null) {
            if (!o.stats) {
                // Unlistable, but its abandoned search found no match — which is
                // what `--files-without-match` succeeds on (`sink.unlisted`).
                if (o.mode.negated()) cfg.sink.noteUnlisted();
                return;
            }
            prefix_nul = true;
        }
        // `-l` / `--files-without-match` + a >64 KiB file: a match PROVEN
        // inside the NUL-free prefix settles the file — `-l` emits and skips
        // the tail; `--files-without-match` skips WITHOUT emitting (the file
        // HAS a match). Absence proves nothing; fall through to the full read.
        if (cfg.fast_l and sf.more) {
            const proof = provePrefix(w, re, sf.prefix);
            if (proof.matched) {
                if (!o.mode.negated()) w.bufferPath(dpath, if (o.null_sep) "\x00" else o.outTerm());
                return;
            }
            read = proof.read;
        }
    }
    // A file past the scratch cap is read by MAPPING it (`slurp.readTail`), and
    // this frame is where the last reference to those pages dies: `emitBody`
    // renders into the worker arena and `deliver` holds only that rendering. So
    // drop the view on the way out — a walk over a tree of large files then
    // holds one map per worker at a time instead of every file it ever touched
    // (274 MiB → ~40 MiB of resident set on an 11 GiB tree).
    //
    // A NUL already in buffer 0 makes the tail MOOT, so `--stats` reads the
    // prefix and stops. Everything downstream of a buffer-0 NUL is bounded by
    // it: `committedPrefix` returns at the fill that reads the NUL, so both the
    // tally's searched region and `handleBinary`'s emitted region lie inside the
    // prefix, and `multilineBinary` (`nul < min(len, BUFCAP)`) answers the same
    // for the prefix as for the whole file — so even the `-U` arm's verdict is
    // unchanged. Reading the rest bought nothing and charged the walk the whole
    // file: `--stats` over `.git` was 100x its own no-stats time (2.26 s vs
    // 0.02 s) because every pack file was faulted in to re-find a NUL that
    // stage 1 had already found in its first 64 KiB.
    const raw: slurp.Body = if (sf.more and !prefix_nul) (sf.readWhole(a, scratch) orelse return) else .{ .bytes = sf.prefix };
    defer if (raw.map) |m| slurp.release(m);
    const body = legible.decodeBom(a, raw.bytes);
    if (body.len == 0) return noteEmpty(w, dpath);
    // Bytes of `body` already covered by the stage-1 prefix scans, in body
    // space: `body` aliases `raw` at offset 0 or 3 (UTF-8 BOM strip), so the
    // scanned raw prefix maps to `body[0..covered]`. A UTF-16 transcode built a
    // fresh buffer with different bytes — nothing carries over (covered = 0).
    const bom: usize = if (utf16) 0 else @intFromPtr(body.ptr) - @intFromPtr(raw.bytes.ptr);
    const covered: usize = if (utf16 or prefix_nul) 0 else sf.prefix.len -| bom;
    // Bytes stage 1's PROOF read, in body space — a different question with a
    // different answer. `covered` is how far the NUL sniff got (the whole
    // prefix); the proof reads only `provableRegion`, the prefix cut at its
    // LAST terminator. A prefix holding no `\n` at all proves nothing and reads
    // nothing, so deriving the gate's start from `covered` told it to skip
    // 64 KiB the gate had never looked at — `-l` then dropped a match sitting
    // at the head of a long line, and `--files-without-match` asserted the file
    // had none. Ask stage 1 what it read instead of re-deriving it here: two
    // derivations of one fact is exactly how these drifted apart.
    const proven: usize = if (prefix_nul) 0 else read -| bom;
    // Literal gate. When stage 1 already proved the equivalence gate absent
    // from what it read (fast_l + tail present + no early emit above), rescan
    // only the unproven remainder plus a `gate_len-1` straddle window for a
    // literal crossing the seam — not the whole body again. Only the
    // equivalence arm proves the LITERAL absent; a regex proof that came back
    // undecided says nothing about the gate.
    const gate_from: usize = if (cfg.lits_equiv) proven -| (cfg.gate_len - 1) else 0;
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
    // Re-price the gate + sweep anchors on this body, as serial `renderFile` does.
    // A worker's gate came from the pattern alone and is shared by every file it
    // walks, so a large body whose local alphabet the shipped rarity table
    // mis-ranks would otherwise filter on two locally-dense bytes.
    em.openOn(body);
    // Whole-buffer or per-line — the same question serial `renderFile` asks,
    // and `-U` alone does not answer it (`multiline.sliceModel`).
    const slice_model = multiline.sliceModel(re, o);

    // Stage 1 already proved `body[0..covered]` NUL-free (or we'd have
    // returned there), so the first NUL — the binary cutoff — can only sit in
    // the unseen tail. Sub-cap files are fully covered: zero bytes rescanned.
    if (binaryCut(w, re, body, covered)) |nul| {
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
        // `--files-without-match` lists no binary file (serial
        // `fileWithoutMatch` returns before any emit) — but the search it
        // abandoned found nothing, which is exactly what this mode succeeds
        // on, so the file still carries the exit code. After the tally
        // above: rg counts it as a searched file either way.
        if (o.mode.negated()) {
            cfg.sink.noteUnlisted();
            return;
        }
        const matched = binary.handleBinary(a, re, o, &buf, &em, dpath, false, body, nul, cfg.show_name);
        if (matched or buf.items.len > 0)
            w.deliver(if (matched) .bin_hit else .text_plain, dpath, buf.items, em.chrome);
        return;
    }

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

/// This run's binary cutoff in `body` at or after `from` — the offset of the
/// first NUL that makes the file binary — or null when the file is text as far
/// as gist is concerned.
///
/// One definition, because the gate-miss path and the post-gate path must reach
/// the SAME verdict about the same bytes: whether a file is listable does not
/// depend on which of the two got there first. The `-U` clause is rg's: the
/// slice model runs only when the pattern can match `\n`, and a NUL past the
/// 64K sniff window is one the searcher never notices, so the file stays
/// ordinary text.
fn binaryCut(w: *Worker, re: *const Matcher, body: []const u8, from: usize) ?usize {
    const o = w.cfg.o;
    if (!w.cfg.binary_detect) return null;
    const nul = std.mem.indexOfScalarPos(u8, body, from, 0) orelse return null;
    if (multiline.sliceModel(re, o) and !binary.multilineBinary(body.len, nul)) return null;
    return nul;
}

/// Whole-file gate / alts miss: settle `--files-without-match` (emit) and
/// `--stats` (tally a zero-hit searched file); every other mode is a silent drop.
/// `--stats` bytes follow the binary cutoff: a walked file with a NUL only
/// contributes its committed prefix (serial `renderFile`'s binary arm).
fn gateMiss(w: *Worker, dpath: []const u8, body: []const u8) void {
    const o = w.cfg.o;
    if (o.mode.negated()) {
        // A walked binary is unlistable in this mode, and the gate proving the
        // pattern absent does not make it listable — the same verdict the
        // post-gate arm above reaches, just from the other side of the gate.
        // Stage 1's prefix sniff catches most of these before the gate ever
        // runs, but not all: a NUL in the TAIL of a >64 KiB file is past the
        // sniffed prefix, and a transform run (`-E`/`-z`) skips stage 1
        // entirely. Both arrived here and got listed, where rg lists neither.
        // The abandoned search still found no match, which is what this mode
        // succeeds on, so the file carries the exit code without a row.
        if (binaryCut(w, w.cfg.re.?, body, 0) != null) return w.cfg.sink.noteUnlisted();
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

/// The prefix region a stage-1 proof may draw on — null ⇒ nothing is provable.
///
/// A NUL-free prefix is NOT the same thing as a SEARCHED prefix, which is what
/// an early emit needs. rg's line-mode reader commits only up to the LAST `\n`
/// it has read, and the fill that reads the first NUL is discarded whole
/// (`committedPrefix`), so a match sitting past the prefix's final terminator
/// may never be searched at all: a 155 KB blob whose first `\n` lands AFTER its
/// first NUL commits zero bytes and matches nothing, however clean its first
/// 64 KiB looked. Bounding every proof to that terminator makes the emit sound
/// whatever the unseen tail turns out to hold.
///
/// The `-U` slice model has no such roll — it sniffs `min(len, 64K)` once, and a
/// NUL inside the sniff already dropped the file before stage 1 — so its raw
/// prefix serves.
fn provableRegion(re: *const Matcher, o: Opts, prefix: []const u8) ?[]const u8 {
    if (multiline.sliceModel(re, o)) return prefix;
    const nl = std.mem.lastIndexOfScalar(u8, prefix, '\n') orelse return null;
    return prefix[0 .. nl + 1];
}

/// What stage 1 settled from the first BUFCAP bytes, and at what cost.
///
/// `matched` is positive-only: true ⇒ the file matches (emit and skip its
/// tail); false ⇒ undecided (the caller reads the rest). `read` is how many RAW
/// prefix bytes the proof looked at, and it is reported rather than re-derived
/// because it is NOT `prefix.len`: `provableRegion` can cut the region short or
/// refuse it outright, and a caller that assumes otherwise skips its own scan
/// past bytes nobody read.
const Proof = struct { matched: bool, read: usize };

/// Positive-only match proof over a buffer prefix. The pure-literal
/// equivalence answers from SIMD `contains` alone — no engine run at all. The
/// regex path sees only COMPLETE lines: a truncated line's cut IS an
/// end-of-line to `docMatch`, so `$`/`^$` could fire where the real line
/// continues — a false positive `provableRegion`'s terminator bound removes.
fn provePrefix(w: *Worker, re: *const Matcher, prefix: []const u8) Proof {
    const cfg = w.cfg;
    const visible = ingest.visibleBody(cfg.o.encoding, prefix);
    const region = provableRegion(re, cfg.o, visible) orelse return .{ .matched = false, .read = 0 };
    // Back into RAW prefix space: `visibleBody` may have dropped a BOM off the
    // front, and the caller measures this against the raw staged read.
    const read = (prefix.len - visible.len) + region.len;
    const matched = blk: {
        if (cfg.lits_equiv) {
            if (cfg.file_needle) |n| break :blk n.in(region);
            break :blk simd.containsAny(region, cfg.file_alts);
        }
        if (cfg.o.multiline) {
            // `-U`: sound only for an assertion-free pattern (substring-closed
            // — nothing zero-width can assert against the cut).
            if (!re.bufPrefixClosed()) break :blk false;
            const sim = w.matchSim() orelse break :blk false;
            break :blk re.bufMatch(sim, region);
        }
        const sim = w.matchSim() orelse break :blk false;
        break :blk re.docMatch(sim, region);
    };
    return .{ .matched = matched, .read = read };
}

const Regex = @import("../../../../kernel/regex/regex.zig").Regex;

test "a stage-1 proof never reaches past the last terminator rg committed" {
    const t = std.testing;
    // The parity bug: `dog` sits at offset 14223 of a 155 KB ruff-cache blob
    // whose first NUL is at 94015 and whose first `\n` is at 94788 — AFTER the
    // NUL. rg's reader finds no terminator to commit, the NUL-bearing fill is
    // discarded, `--stats` says `0 bytes searched`, and `rg -uu -l dog` exits 1.
    // gist's `lits_equiv` arm scanned the raw 64 KiB prefix, proved the literal,
    // and published the file — two files `--rank` (which honors the cut) omitted.
    var m = Matcher{ .linear = try Regex.compile(t.allocator, "dog") };
    defer m.deinit();
    const o = Opts{ .mode = .files_with_matches };

    // The second bug this pins, on the consuming side: because the region can
    // be null or short, a caller may only skip its own scan past what the proof
    // READ (`Proof.read`), never past the prefix. Deriving the whole-file
    // literal gate's start from the NUL sniff's extent instead had `-l` skip
    // 64 KiB nobody had looked at, and `--files-without-match` swear a matching
    // file held nothing.
    var blob: [1024]u8 = undefined;
    @memset(&blob, 'x');
    @memcpy(blob[100..103], "dog");
    // No terminator anywhere ⇒ nothing is provable, whatever the prefix holds.
    try t.expect(provableRegion(&m, o, &blob) == null);

    // A terminator AFTER the match commits its line: the proof may run, and the
    // region stops at that terminator rather than running to the prefix's end.
    blob[200] = '\n';
    const region = provableRegion(&m, o, &blob) orelse return t.expect(false);
    try t.expectEqual(@as(usize, 201), region.len);
    try t.expect(std.mem.indexOf(u8, region, "dog") != null);

    // A terminator BEFORE the match leaves the match outside the committed
    // region — the file falls through to the full read instead of early-emitting.
    @memset(blob[100..103], 'x');
    @memcpy(blob[300..303], "dog");
    const short = provableRegion(&m, o, &blob) orelse return t.expect(false);
    try t.expectEqual(@as(usize, 201), short.len);
    try t.expect(std.mem.indexOf(u8, short, "dog") == null);
}
