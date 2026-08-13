//! The `rg` face — a ripgrep-DEFAULT drop-in over an arbitrary directory tree,
//! and (since the two engines merged) the SOLE search engine we ship: the same
//! walk-and-emit pipeline backs the bare `<pattern> [PATH...]` shorthand
//! (no verb, no index required — the everyday zero-setup front door) and the
//! explicit `rg` alias. A persisted trigram index, when it covers the
//! searched roots, is used purely to ELIDE reads of files it proves can't match
//! (`../quarry/elide.zig`) — never to change the file set, ignore semantics,
//! ordering, or output; `--no-index`/`--index` force the pure walk / the
//! accelerated path, and `--rank[=N]` ranks the same compiled-regex hits (and
//! PATH scope) via the definition-first RRF view (`../view/`). This needs to
//! *prove* the face is a genuine ripgrep drop-in against ripgrep's own
//! integration suite — which creates a throwaway directory, drops in fixtures,
//! and runs `rg` in that CWD — so this module searches an arbitrary tree with
//! ripgrep's DEFAULT presentation:
//!   • filename shown only when recursive or >1 file (a single explicit file
//!     prints no `path:` prefix), `-H` forces it, `--no-filename`/`-I` suppress;
//!   • line numbers OFF by default, `-n` turns them on;
//!   • `:` frames a match line, `-` a context line, `--` separates groups;
//!   • `-t/-T/-g/--glob/--iglob` scope by type/glob (reusing `../scope/`);
//!   • `.gitignore`/`.ignore`/`.rgignore` precedence honored (`ignore.zig`),
//!     byte-identical to `rg`'s own default corpus scope;
//!   • exit 0 = matched, 1 = no match, 2 = error/unsupported (ripgrep's codes).
//! It reuses our linear-time RE2-style matcher for the default per-line and
//! the `-U`/`--multiline` whole-buffer paths, and routes `-P`/`--pcre2` to the
//! opt-in PCRE2 JIT backend (`kernel/regex/pcre2/backend.zig`) — both behind the
//! engine-neutral `Matcher` seam, so `multiline.zig` + `Emitter.buffer` own
//! cross-line emission regardless of which engine produced a span. This module
//! is the walk + presentation shell that makes both engines addressable the way
//! `rg` is: `--json`/`--column`/`--vimgrep` ARE honored (`json.zig`,
//! `output.zig`). A PCRE2 run that trips a resource limit on pathological input
//! (catastrophic backtracking) mirrors ripgrep's exit 2 rather than reporting a
//! silent no-match. `--rank` is the one native view that stays linear-only
//! (it declines loud under `-P`).

const std = @import("std");
const corpus_mod = @import("../../../corpus/tree/corpus.zig");
const args = @import("../argv/args.zig");
const assay = @import("../../../assay/assay.zig");
const Outcome = @import("../../../surface/cli/outcome.zig").Outcome;
const output = @import("../emit/output.zig");
const json = @import("../emit/json.zig");
const beacon = @import("../../../surface/cli/beacon.zig");
const color = @import("../emit/color.zig");
const legible = @import("../../../corpus/read/legible.zig");
const multiline = @import("../emit/multiline.zig");
const stats = @import("../read/stats.zig");
const notice = @import("../quarry/notice.zig");
const ingest = @import("../read/ingest.zig");
const walk = @import("../quarry/walk.zig");
const intake = @import("../quarry/intake.zig");
const order = @import("../quarry/order.zig");
const stream = @import("../quarry/stream.zig");
const directive = @import("../writ/directive.zig");
const arm = @import("../writ/arm.zig");
const writ = @import("../writ/writ.zig");
const render = @import("../emit/render.zig");
const swarm = @import("swarm/swarm.zig");
const par = @import("../../../kernel/math/parallel.zig");
const types = @import("../../../corpus/scope/types.zig");
const genus = @import("../../../corpus/scope/genus.zig");
const crest = @import("../../../kernel/math/crest.zig");
const view = @import("../view/view.zig");
const Opts = args.Opts;
const Emitter = output.Emitter;
const die = @import("../../../surface/cli/outcome.zig").die;
const oom = @import("../../../surface/cli/outcome.zig").oom;

const Matcher = @import("../../../kernel/regex/regex.zig").Matcher;
const pcre2 = @import("../../../kernel/regex/regex.zig").pcre2;
const Caps = @import("../../../kernel/regex/regex.zig").Caps;
/// `pub`: the CLI shell (`main.zig`) reuses the same hint module on the warm
/// daemon path, where no engine ran in-process but a no-match still deserves
/// the identical stderr guidance.
pub const hints = @import("../emit/hints.zig");
/// `pub` for the same reason `hints` is: the warm daemon path holds no bytes in
/// the client process, and the corpus-side half of the evidence never needed
/// them — so a warm miss can still name the file its scope excluded.
pub const witness = @import("../quarry/witness.zig");

// Per-file semantics live in `read/` — BOM/UTF-16 ingest and the rg line split
// in `legible.zig`, binary handling in `binary.zig`, the --stats tally in
// `stats.zig` — shared verbatim with the parallel pipeline so the two engines
// cannot drift. Walk-failure wording is `quarry/notice.zig`, likewise shared.
const stripBom = legible.stripBom;
const collectLines = legible.collectLines;
const Stats = stats.Stats;
const emitStats = stats.emitStats;

// ─────────────────────────── the published face ───────────────────────────

// The implementation moved out from under this module: the walk to
// `quarry/walk.zig` (sole authority on WHAT is in the tree, shared verbatim
// with the warm session), read shards and index admission to `quarry/intake.zig`,
// rg's canonical file order to `quarry/order.zig`, fd 0 to `quarry/stream.zig`,
// the pattern-derived gates to `writ/`, and per-file rendering to
// `emit/render.zig`. What stays here is the invocation state machine — plus the
// names this path publishes, since it is the tier's face (`irregex.engine.search`)
// and callers import through it: `resident.zig` and the FFI open path reach the
// walk selector this way, the warm session orders its FFI match stream by
// `pathLess`, and the daemon client probes fd 0 with `readableStdin` to decide
// whether a rootless query must answer cold.
pub const ExtraKind = walk.ExtraKind;
pub const Extra = walk.Extra;
pub const FileSet = walk.FileSet;
pub const defaultFileSetExtras = walk.defaultFileSetExtras;
pub const pathLess = order.pathLess;
pub const readableStdin = stream.readableStdin;
pub const pcreFaultExit = render.pcreFaultExit;

const InFile = intake.InFile;
const collectFiles = intake.collectFiles;
const readStdin = stream.readStdin;
const combinePatterns = directive.combinePatterns;
const compileCaps = arm.compileCaps;
const renderFile = render.renderFile;
const inFileWeight = render.inFileWeight;
const emitSharded = render.emitSharded;
const emitFileSharded = render.emitFileSharded;
const fileWithoutMatch = render.fileWithoutMatch;
const filesWithoutSharded = render.filesWithoutSharded;
const anyMatch = render.anyMatch;

// ─────────────────────────── run ───────────────────────────

/// Interactive long-line guard (native, TTY-only). A single multi-megabyte
/// minified line — a generated `*.gen.json`, a bundled asset — makes a terminal
/// spend ~a second reflowing ONE logical line; that render, not the search, is
/// the "hang near the end" of a high-hit query (we produce the whole result
/// in ~0.1s, faster than ripgrep). 16 KiB cleanly separates human-authored long
/// lines (observed max a few KB) from generated blobs (tens of KB and up), and a
/// 16 KiB line reflows instantly. Applied ONLY when stdout is a real terminal
/// and the user set no `--max-columns`, so piped/redirected output stays
/// byte-identical to ripgrep (the rgsuite differential harness and every agent
/// capture are untouched). Opt out with `-M0`.
const tty_long_line_cols: usize = 16 * 1024;

pub fn run(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, env: *const std.process.Environ.Map) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const parsed = args.parseArgv(a, argv);
    var o = parsed.opts;
    // Lower `--no-messages`/`--no-ignore-messages` onto the diagnostic policy
    // before anything can walk, open, or read an ignore source. Argv errors
    // above this line are usage faults, not the message lane, and stay audible
    // on purpose — you cannot silence the reason your flags were wrong.
    //
    // The muffle is process-wide (unlike the sink, which is thread-local), and
    // safely so: this function has exactly ONE caller (a face's own `main.zig`,
    // the cold CLI entry), so it runs once per process and before any worker
    // spawns.
    // A daemon never reaches here — the warm nier is a fail-closed allowlist
    // that does not admit these flags — so one client's silence can never become
    // another's. Should a second caller ever appear, this becomes a `scope`.
    assay.muffle(o.messages, o.ignore_messages);
    // Resolve the output budget for this run: the ~25k-token soft agent-context
    // guard + the hard OOM ceiling (corpus.zig), honoring `--uncap`/`<prefix>UNCAP`
    // and the `<prefix>MAX_OUTPUT_*` knobs. Applied at the single stdout seam
    // (`writeStdout`/`emitStdout`) every engine emits through, plus the serial
    // accumulation guard (`outputFull`) below.
    corpus_mod.initOutputBudget(o.uncap);
    // Enumeration modes list one compact line per file; lift the soft context
    // guard so the returned set is COMPLETE and reproducible instead of a
    // truncated (and, on the unordered parallel engine, nondeterministic) subset.
    // The hard OOM ceiling still bounds a genuine blowup. See `Opts.enumeration`.
    if (o.enumeration()) corpus_mod.exemptSoftCap();
    // Is a human watching? Four behaviors key on this one answer — the layout
    // below, the long-line guard, `--color auto` (inside `color.enabled`), and
    // the delivery cadence — and `--plain` is the single spelling that stands
    // all four down, so nothing the DESTINATION decides differs between a
    // terminal run and a redirected one. (Walk order is not one of them;
    // `--sort` owns it.)
    const interactive = !o.plain and (std.Io.File.stdout().isTty(io) catch false);
    // rg's terminal layout, and the one destination-conditional behavior that
    // changes the SHAPE of a row rather than its chrome: a human reading a wall
    // of `path:line:` prefixes is doing the grouping in their head, so a
    // terminal gets the path lifted onto a title line and the rows numbered
    // beneath it. Only silence is filled — `--no-heading` and `-N` still mean
    // what they say here — and a pipe answers `false`, so the byte contract
    // with ripgrep is untouched. See `answer.Locus`.
    //
    // The one terminal run rg leaves alone is the stdin-only search (the same
    // `roots.len == 0 and readableStdin()` the branch below takes): `printf … |
    // rg pat` prints bare lines, where `rg pat - file` numbers both. There is
    // one unnamed source and no walk, so a locator names nothing the reader did
    // not already have. Probed last, so only a rootless terminal run pays the
    // fd-0 stat — the piped agent runs that dominate never reach it.
    const layout = interactive and !(parsed.roots.len == 0 and readableStdin());
    o.heading = parsed.locus.headings(layout);
    o.line_num = parsed.locus.lines(o.vimgrep, layout);
    // Install the stdout buffering policy before the first result byte can be
    // written. `auto` reads the destination the way rg does: a terminal wants
    // each line as it is found, a pipe wants them coalesced. Neither changes a
    // byte of the answer — only how many trips through the kernel it takes.
    corpus_mod.armStdout(switch (o.buffering) {
        .line => .line,
        .block => .block,
        .off => .relay,
        .auto => if (interactive) .line else .block,
    }, o.buffer_size, o.recordTerm());
    // Resolved ONCE per run (not per file/emitter): stdout tty + `--color` +
    // env. Every emitter below shares this single yes/no.
    const use_color = color.enabled(o, io, env);
    // The OSC-8 click target, likewise resolved once and then read-only —
    // installed process-wide (before any worker spawns) rather than threaded
    // through six emit constructors, exactly like the diagnostic policy above.
    // Deliberately NOT keyed on `use_color`: a link is navigation, not paint.
    beacon.install(beacon.resolve(a, .{
        .when = o.hyperlink,
        .format = o.hyperlink_format,
        .hostname_bin = o.hostname_bin,
        // Who is on the other end, which decides how hard a no-link is.
        // `--json` and `-0` are byte protocols — a record's payload IS the
        // filename, so an escape inside it is corruption and nothing overrides
        // that, not even `always`. `--vimgrep` only *tends* to be parsed: it is
        // a plain text row a human also reads, so the probe declines by default
        // and an explicit `always` is still allowed to have its way.
        .reader = if (o.mode == .json or o.null_sep) .records else if (o.vimgrep) .parser else .human,
    }, io, env));

    // The content-transform pipeline (-z decompress / --pre preprocess / -E
    // transcode). `pre_error` latches a failed `--pre` invocation (exit 2, rg
    // parity); `transforming` disables index elision + whole-file trigram
    // prefilters below, since those are proven against raw on-disk bytes, not the
    // rewritten stream a candidate's needle actually lives in.
    var pre_error = std.atomic.Value(bool).init(false);
    const icfg = ingest.Config{ .io = io, .search_zip = o.search_zip, .pre = o.pre, .pre_globs = o.pre_globs, .pre_excludes = o.pre_excludes, .encoding = o.encoding, .pre_error = &pre_error };
    const transforming = icfg.active();

    // Cap absurdly long lines when writing to a terminal (see `tty_long_line_cols`):
    // a purely interactive convenience that leaves piped/file output byte-identical
    // to ripgrep. Keyed on the real stdout destination, independent of `--color`.
    if (!o.max_cols_set and interactive) o.max_cols = tty_long_line_cols;

    // --type-list: dump every `-t` name and the globs it recognizes, one name
    // per line, in ripgrep's exact presentation — names sorted lexicographically,
    // each row's globs sorted lexicographically (`../scope/types.zig`
    // `writeTypeList`). Our registry is a strict SUPERSET of ripgrep's, so the
    // listing is rg-shaped and rg-sorted while covering more types + globs.
    //
    // The run's own overlay goes with it: a `--type-add` shows up in the listing
    // and a `--type-clear` disappears from it, so the menu and the kitchen agree.
    //
    // A genus narrows the listing to the rows that genus is made of, which is the
    // only way to ask "what counts as docs here?" without reading genus.zig. Bare
    // `--type-list` passes no predicate, so rg parity is untouched.
    if (o.mode == .types) {
        var out: std.ArrayList(u8) = .empty;
        types.writeTypeList(a, &out, parsed.types, genus.listingFor(o.filter.genera)) catch oom();
        corpus_mod.emitStdout(out.items);
        std.process.exit(0);
    }

    // --files: list the files that would be searched (no pattern), path-sorted,
    // NUL-terminated under --null. Uses the same gather+filter as the search path.
    if (o.mode == .files) {
        // The parallel engine never opens a file in --files mode (a listing needs
        // paths, not bytes) — the serial path below reads every body it lists.
        if (swarm.eligible(io, parsed, o, null)) swarm.run(gpa, io, parsed, o, null, use_color, &.{}, null, crest.no_sieve, null, null, &icfg);
        // --files lists every file (no pattern) — nothing to prefilter, so no read
        // elision applies; pass an empty trigram filter and an inactive sieve.
        const c = collectFiles(a, gpa, io, parsed, &.{}, crest.no_sieve, null, &icfg);
        // `--files` gathered every path up front, so a path error is already known
        // and outranks the listing — quiet here is not the match short-circuit.
        if (o.quiet) (Outcome{ .matched = c.files.len > 0, .faulted = c.path_error }).exit();
        var out: std.ArrayList(u8) = .empty;
        // Every row here is a filename and nothing else, so the whole row is the
        // click target. `anchor` borrows the path back unchanged when the run
        // emits no links — which `--null` always is, since that list is bound
        // for `xargs -0` and an escape inside a record is corruption.
        for (c.files) |f| out.print(a, "{s}{c}", .{ beacon.anchor(a, f.path), if (o.null_sep) @as(u8, 0) else '\n' }) catch oom();
        corpus_mod.emitStdout(out.items);
        (Outcome{ .matched = c.files.len > 0, .faulted = c.path_error }).exit();
    }

    // Zero patterns (an empty `-f` file): ripgrep matches nothing — so without
    // `-v` there is no output (exit 1); with `-v` every line is a match. We model
    // the latter as "match-all (empty pattern), un-inverted".
    const eff = combinePatterns(a, io, parsed, &o) orelse blk: {
        if (!o.invert) std.process.exit(1);
        o.invert = false;
        break :blk "";
    };
    // `-m 0` (an explicit zero match cap): ripgrep's searcher short-circuits on
    // `max_count == Some(0)` and returns a no-match BEFORE emitting or counting a
    // single hit, so every mode (bare search, `--count[ --include-zero]`, `-l`,
    // `--files-without-match`, `--json`, `-q`) prints nothing and exits 1. Placed
    // after `--files`/`--type-list` (which never search, and exited above) so it
    // scopes to the pattern search alone. The 0-as-unlimited sentinel the per-file
    // emit guards read is untouched — only an explicit `-m0` trips this.
    if (o.max_per_file_set and o.max_per_file == 0) std.process.exit(1);
    // The engine-neutral match seam: the output layer (Emitter, --json, per-file
    // binary/stats) consumes `re` as a `Matcher` without knowing which engine
    // produced a span. `buildMatcher` resolves the engine choice — `-P`/`--engine
    // pcre2` builds the PCRE2 arm (lookaround, backreferences, Unicode
    // properties); `--engine auto` compiles the linear arm and escalates to PCRE2
    // only for a pattern the linear engine declines; the default is the linear
    // RE2/Pike arm. All honor `-U`/`--multiline` and `--multiline-dotall`.
    var w = writ.Writ.compile(gpa, a, o, eff, transforming);
    defer w.deinit();
    const re = &w.re;
    // The RESOLVED backend (an auto pattern may have escalated to PCRE2) — drives
    // the sticky-error latch, the `--rank` guard, and the `-r` capture engine
    // below so all three follow the engine actually chosen, not the one requested.
    const is_pcre = w.is_pcre;
    if (is_pcre) pcre2.clearMatchError(); // fresh sticky-error latch per run

    // rg's NUL policy: with binary detection live (no `-a`/`--text`/`--null-data`),
    // the searcher never feeds a `\0`, so a pattern that *requires* one — a NUL
    // literal or `[\x00]` singleton class — is impossible; rg refuses it (exit 2)
    // rather than silently matching nothing (`crates/regex/src/ban.rs`). Broad
    // classes that merely include NUL (`.`, `[^\x00]`) are fine, so `bansByte`
    // uses the singleton rule, not "can consume". `-a`/`--text` treats NUL as an
    // ordinary byte, so the check is skipped there.
    if (w.binary_detect and re.bansByte(0))
        die(
            \\gist: error: pattern contains "\0" but it is impossible to match
            \\gist: note: binary detection is enabled, so a NUL byte can never match
            \\gist: try -a / --text — treat NUL as ordinary bytes and match it
            \\
        , .{});

    // Our own ways of looking at a match — `--rank`, `--in-comments`/
    // `--in-code` — branch here, over the SAME compiled matcher and PATH scope,
    // and finish the run themselves. That early return is what keeps the
    // rg-parity certificate intact: the certified walk/emit paths below are
    // never threaded with lens awareness, because a lens never reaches them.
    // Adding one is a case in `view.dispatch`, not another branch here.
    if (try view.dispatch(.{
        .gpa = gpa,
        .a = a,
        .io = io,
        .parsed = parsed,
        .o = o,
        .w = &w,
        .icfg = &icfg,
        .pre_error = &pre_error,
    }) == .done) return;

    const line_needle = w.line_needle;
    // Both gates arrive already stood down where they would be unsound — the
    // `--include-zero` / every-byte-mode guards live in `gate.mayDropFileUnread`,
    // not here. See `writ.zig` on why this is a computed value, not a carried one.
    const file_needle = w.file_needle;

    // -r/--replace: build the group-aware capture matcher once and share it
    // across every emitter for template expansion. The PCRE2 arm captures from
    // real backreference/lookaround programs; the linear arm is the save-carrying
    // Pike VM over the same AST. Same engine choice as the search matcher above.
    var caps_store: ?Caps = if (o.replace != null) compileCaps(gpa, o, eff, is_pcre) else null;
    defer if (caps_store) |*cp| cp.deinit();
    const caps: ?*Caps = if (caps_store) |*cp| cp else null;

    // Stdin search (rg parity): with no PATH args and a readable stdin (pipe /
    // regular file), search the piped bytes as one unnamed source — no filename
    // prefix, rg exit codes. A tty or /dev/null stdin falls through to the walk.
    if (parsed.roots.len == 0 and readableStdin()) {
        // -z/--pre need a path and don't apply to stdin (rg parity); -E does —
        // transcode the stream, else the default BOM strip.
        const raw = readStdin(a);
        const body = if (o.encoding == .auto) stripBom(raw) else ingest.applyEncoding(a, o.encoding, raw);
        var out0: std.ArrayList(u8) = .empty;
        var em0 = Emitter{ .a = a, .re = re, .o = o, .show_name = false, .out = &out0, .base = @intFromPtr(body.ptr), .body_end = @intFromPtr(body.ptr) + body.len, .caps = caps, .use_color = use_color, .needle = line_needle };
        // A pipe is the one source with no size bound at all — `cat 200MB | … -F`
        // is the same scan a file argument gets, so it gets the same per-document
        // anchor re-pricing `renderFile` performs. Read whole before this point, so
        // the whole document really is in hand.
        em0.openOn(body);
        // `-U` with a pattern that can cross `\n`: match the whole stream as
        // one buffer; otherwise the per-line path over rg's line split.
        const hits = if (multiline.sliceModel(re, o)) em0.buffer("<stdin>", body) else blk: {
            var lines: std.ArrayList([]const u8) = .empty;
            collectLines(a, body, o.term(), &lines);
            break :blk em0.file("<stdin>", lines.items);
        };
        pcreFaultExit(re);
        // stdin has no walk, so no path can fault; `pcreFaultExit` already took
        // the engine-fault exit above.
        if (o.quiet) (Outcome{ .matched = hits > 0 }).exit();
        corpus_mod.emitStdout(out0.items);
        // `body` is the whole stream, still in hand — so a piped miss gets the
        // same checked findings a file miss does. Only the corpus-side witness is
        // out of reach here, and rightly: a stream has no scope to have widened.
        const stream_probe = [_]struct { bytes: []const u8 }{.{ .bytes = body }};
        const sh0 = hints.shapeStream(parsed.patterns, o);
        if (hits == 0)
            hints.noMatches(sh0, null, hints.probe(a, sh0, &stream_probe))
        else
            hints.deadBranches(sh0, out0.items);
        (Outcome{ .matched = hits > 0 }).exit();
    }

    // The persisted index (when present) accelerates the walk by eliding reads of
    // files that provably can't hold the pattern's required literal — a pure
    // acceleration, output-invisible (`../quarry/elide.zig`).
    // Empty / zero whenever elision is inadmissible — a transforming run, `-v`,
    // `--no-index`, `--include-zero`, or an every-byte output mode. That verdict
    // is `gate.mayElideByIndex`'s alone; this line used to re-spell half of it.
    const filters = w.filters;
    const plan = w.plan;
    const sieve = w.sieve;

    // Run-scoped monotonic stopwatch for the search proper — feeds the real
    // `elapsed`/`elapsed_total` in the `--stats`/`--json` summary (was hardcoded
    // `0.000000`) and the `.query`-lens stderr diagnostic. Opened before the walk
    // so it spans read + match + emit, exactly what rg's `elapsed_total` reports.
    const search_span = assay.Span.open(io);

    // The common recursive-walk case runs on the parallel fused engine
    // (swarm/): work-stealing directory walk, bulk-stat listings, inline
    // index/freshness elision, per-file render on every core — byte-identical
    // output, produced in parallel. Anything it declines (see `eligible`) falls
    // through to this proven serial engine.
    if (swarm.eligible(io, parsed, o, re))
        swarm.run(gpa, io, parsed, o, re, use_color, filters, plan, sieve, file_needle, line_needle, &icfg);

    // The serial collect path still asks the index with the flat OR of
    // `filters` (`fresh.candidates`); the cover rides the fused walk only.
    const c = collectFiles(a, gpa, io, parsed, filters, sieve, file_needle, &icfg);
    const files = c.files;
    // rg's implicit-path heuristic: a GUESSED search root (no PATH args) whose
    // walk admitted zero files means some filter excluded everything — stderr
    // note + exit 2 via rg's errored flag, never a silent exit-1 "no matches".
    // An explicit path stays silent (rg: "it can otherwise be noisy when it is
    // intended that there is nothing to search"). Search modes only — the
    // --files listing above never fires it (rg parity).
    const nothing_searched = parsed.roots.len == 0 and c.walked == 0;
    if (nothing_searched) notice.printNothingSearched();
    // A `--pre` invocation that failed during the reads above is an error (exit 2),
    // exactly like an unopenable explicit path — fold it into every exit below.
    const err_exit = c.path_error or pre_error.load(.seq_cst) or nothing_searched;

    // --json: ripgrep's JSON Lines record stream (own printer, shared engine).
    if (o.mode == .json) {
        var jf: std.ArrayList(json.File) = .empty;
        for (files) |f| jf.append(a, .{ .path = f.path, .body = ingest.visibleBody(o.encoding, f.bytes), .explicit = f.explicit }) catch oom();
        var out: std.ArrayList(u8) = .empty;
        const jst = json.runParallel(gpa, a, &out, re, caps, o, jf.items, line_needle, search_span.read(io));
        corpus_mod.emitStdout(out.items);
        stats.diagSearch(gpa, o.mode == .json, jst, search_span.read(io));
        pcreFaultExit(re);
        (Outcome{ .matched = jst.get(.files_with_match) > 0, .faulted = err_exit }).exit();
    }

    // `--vimgrep` forces the filename on even for a single explicit file —
    // rg's `with_filename` default is `vimgrep || !paths.is_one_file`.
    const show_name = switch (o.filename) {
        .always => true,
        .never => false,
        .auto => o.vimgrep or c.recursive or files.len > 1 or parsed.roots.len > 1,
    };

    var out: std.ArrayList(u8) = .empty;
    // Run-scoped boolean scratch, threaded through the Emitter so the per-file
    // loop below reuses one Sim instead of re-allocating it for every file
    // (mirrors the parallel engine's per-worker `workerSim`). Null on OOM ⇒
    // the Emitter degrades to its file-local build.
    var run_sim: ?Matcher.Sim = Matcher.Sim.init(a, re) catch null;
    defer if (run_sim) |*s| s.deinit();
    var em = Emitter{ .a = a, .re = re, .o = o, .show_name = if (o.groups()) false else show_name, .out = &out, .caps = caps, .use_color = use_color, .needle = line_needle, .sim = if (run_sim) |*s| s else null };

    // --quiet short-circuits on first match — unless --stats is also asked for,
    // which must run the full search to tally (then print only the stats block).
    // `--files-without-match` inverts the success predicate (a file that LACKS
    // the pattern is the "match"), so it falls through to that mode's own quiet
    // exit below rather than this match-presence one. Under quiet a found match
    // beats a path error (ripgrep's QuietMatched short-circuits the exit to 0
    // even when a later PATH failed to open — e.g. `-q p found missing` → 0).
    if (o.quiet and !o.stats and !o.mode.negated()) {
        const hit = anyMatch(a, re, o, line_needle, files);
        pcreFaultExit(re);
        (Outcome{ .matched = hit, .faulted = err_exit, .precedence = .quiet_short_circuit }).exit();
    }

    if (o.mode.negated()) {
        var lsim = Matcher.Sim.init(a, re) catch die("engine init failed\n", .{});
        defer lsim.deinit();
        var wss: ?Matcher.SpanSim = if (o.word) (Matcher.SpanSim.init(a, re) catch null) else null;
        defer if (wss) |*s| s.deinit();
        const wssp: ?*Matcher.SpanSim = if (wss) |*s| s else null;
        // Per-file independent with no output budget — fan out across cores like
        // the parallel READ that preceded it, falling back to the serial loop
        // below the corpus floor, on one core, or under the `<prefix>NO_PARALLEL`
        // parity-gate idiom (`assay.serialForced`). `-U`'s "match" is a
        // whole-buffer hit; the per-line path reuses the same `-w`/`-v`/
        // zero-width classify as the emit loop.
        // `--stats` owns a single `Stats` and must tally every file, so it keeps
        // the serial loop (no cross-shard fold to reconcile) and reports rg's
        // trailing block — the search it ran to decide the listing, which is the
        // same search the standard mode reports.
        var lstat = Stats{};
        // rg's success predicate for this mode is "some file's search found no
        // match" (`SummarySink::has_match` inverted), NOT "some path printed" —
        // a walked binary counts without ever being listed, so the verdict rides
        // back from the per-file decider rather than from `out`.
        var without = false;
        const bounds = if (o.stats or assay.serialForced()) null else par.shardBounds(InFile, files, {}, inFileWeight, par.min_bytes, par.max_shards, a);
        if (bounds) |b| {
            without = filesWithoutSharded(gpa, a, &out, re, o, line_needle, files, b);
        } else for (files) |f| {
            const one = if (o.stats)
                render.withoutMatchTallied(a, re, o, &em, &lsim, wssp, line_needle, f, &out, &lstat, w.binary_detect)
            else
                fileWithoutMatch(a, re, o, &em, &lsim, wssp, line_needle, f, &out);
            if (one) without = true;
        }
        if (o.stats) {
            lstat.set(.bytes_printed, stats.bytesPrinted(o, out.items.len));
            // `-q --stats` keeps the stats BLOCK and drops the path list, exactly
            // as the standard mode's tail does (rg prints its trailing block under
            // `-q` in every mode; this branch used to suppress the whole stream,
            // so `--files-without-match -q --stats` printed nothing at all).
            if (o.quiet) out.clearRetainingCapacity();
            emitStats(a, &out, lstat, search_span.read(io));
            stats.diagSearch(gpa, false, lstat, search_span.read(io));
            corpus_mod.emitStdout(out.items);
            pcreFaultExit(re);
            (Outcome{ .matched = without, .faulted = err_exit }).exit();
        }
        // Under -q the stream is suppressed; the found-a-without-match file still
        // decides the exit (0 = at least one file lacked the pattern, ripgrep's
        // `--files-without-match` success).
        if (!o.quiet) corpus_mod.emitStdout(out.items);
        pcreFaultExit(re);
        (Outcome{ .matched = without, .faulted = err_exit }).exit();
    }

    const heading = o.groups();
    const join_groups = o.wantsContext() and o.mode.frames() and !heading;
    var matched_files: usize = 0;
    var first = true;
    // Binary detection remains active for -l: a match after the buffer that
    // revealed a NUL must not turn the file into a false-positive path.
    // --binary/-uuu (o.binary) searches binary files in full — same as --text for
    // the quit-at-NUL decision, so detection is off for both (our superset
    // flavor prints every matching line rather than a binary summary).
    const binary_detect = w.binary_detect;
    var stat = Stats{};
    // `--include-zero` count: an empty file is still a searched file and rg
    // prints its `path:0`, so don't skip it (the emitter tallies 0 below).
    const count_zero = o.include_zero and o.mode.counting();
    // `--heading`/context `join_groups` carry cross-file separator state (the
    // leading blank line, the `--\n` between context groups) that an order-free
    // split can't reproduce; everything else here is per-file independent and
    // fans out across cores (`emitSharded`) exactly like the parallel READ that
    // preceded it. `shardBounds` returns null below the corpus floor / on one
    // core, keeping the small-corpus answer on this proven serial loop.
    // `<prefix>NO_PARALLEL` (the parity-gate idiom, shared with `json.runParallel`
    // and `swarm.eligible` via the one `assay.serialForced` joint) forces the
    // serial emit so the rgsuite runner's serial pass exercises this path too.
    // No production caller sets it.
    const no_par = assay.serialForced();
    const bounds = if (heading or join_groups or no_par) null else par.shardBounds(InFile, files, {}, inFileWeight, par.min_bytes, par.max_shards, a);
    // A single large file the multi-file shard gate leaves serial (`bounds` is
    // null for one file): fan the line-free literal fast path across cores over
    // its own body — the parallelism ripgrep can't apply to one file. `-l`
    // (files_only) is excluded (a lone first hit, nothing to parallelize).
    const solo_fast = files.len == 1 and !heading and !join_groups and !no_par and !o.stats and o.mode != .files_with_matches and em.litFastEligible();
    if (solo_fast and emitFileSharded(gpa, a, &out, &em, re, o, use_color, line_needle, files[0], &matched_files, binary_detect, show_name)) {
        // handled by the single-file shard driver
    } else if (bounds) |b| {
        emitSharded(gpa, a, &out, re, o, eff, is_pcre, use_color, line_needle, files, b, &stat, &matched_files, binary_detect, count_zero, show_name);
    } else {
        // `--line-buffered` promises a finished line is never held; rendering the
        // whole run into `out` and flushing once would hold every line until the
        // last file. So under a streaming policy this loop hands each file's bytes
        // over as it finishes it — the drain decides what leaves and what waits.
        // Not under `--stats` (it reports `out.items.len` as bytes printed) or
        // `-q` (which suppresses the stream), and `block` never needs it: one
        // whole-run buffer is exactly what a block policy would have produced.
        const push_per_file = corpus_mod.stdoutStreams() and !o.stats and !o.quiet;
        for (files) |f| {
            renderFile(&em, f, &stat, &matched_files, &first, binary_detect, count_zero, heading, join_groups, show_name);
            if (push_per_file and out.items.len != 0) {
                if (!corpus_mod.writeStdout(out.items)) break;
                out.clearRetainingCapacity();
            }
            // Serial engine renders into `out` before one flush — stop growing it once
            // the output budget is spent, bounding peak memory (the OOM guard) at the
            // exact point the flush below would truncate anyway. `--stats` runs the
            // full search regardless (it tallies over every file), so never short it.
            corpus_mod.noteChrome(em.chrome);
            if (!o.stats and corpus_mod.outputFull(out.items.len)) break;
        }
    }
    if (o.stats) {
        stat.set(.files_with_match, matched_files);
        // --quiet --stats: suppress the match stream, report 0 bytes printed —
        // as does every summary mode (`stats.bytesPrinted` owns rg's rule).
        stat.set(.bytes_printed, stats.bytesPrinted(o, out.items.len));
        if (o.quiet) out.clearRetainingCapacity();
        emitStats(a, &out, stat, search_span.read(io));
        stats.diagSearch(gpa, o.mode == .json, stat, search_span.read(io));
    }
    corpus_mod.emitStdout(out.items);
    pcreFaultExit(re);
    // The no-match hint seam: exit-1 with a clean run (no walk error) is the
    // moment an agent needs guidance — derived from the query's own shape, on
    // stderr, after the (empty) stdout flush. --json and --quiet stay silent
    // by contract; error exits already carry their own diagnostic.
    if (matched_files == 0 and !err_exit) {
        // `files` still holds the bytes this run searched, so the hint can be
        // derived from what the corpus actually says instead of only from what the
        // pattern looks like — one more pass over resident memory, on a run that
        // already came back empty. `sight` then asks the one question those bytes
        // cannot answer: whether the string lives in a file this scope excluded.
        const sh = hints.shape(parsed.patterns, o, parsed.roots, parsed.roots.len > 0);
        var ev = hints.probe(a, sh, files);
        witness.sight(a, io, o.no_index, sh, &ev);
        hints.noMatches(sh, files.len, ev);
    } else if (!err_exit) {
        // The mirror case, and the only hint this channel spends on a SUCCESS: a
        // bundled `A|B|C` whose results none of B's bytes appear in answered fewer
        // questions than it was asked, silently. `out` is what was just printed, so
        // the check costs one pass over the output rather than over the corpus.
        hints.deadBranches(hints.shape(parsed.patterns, o, parsed.roots, parsed.roots.len > 0), out.items);
    }
    (Outcome{ .matched = matched_files > 0, .faulted = err_exit }).exit();
}
