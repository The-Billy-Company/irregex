//! gist search — the one verb, and the dispatcher that routes it to the right
//! engine. `gist search <pattern> [PATH…]` replaces the old `query`/`regex`/
//! `rank`/`grep` quartet: they were four verbs answering one question ("what
//! matches, and how do you want it shaped"), so the SHAPE is now a flag
//! (`--show`/`--rank`/`--json`), not a different verb name.
//!
//! Routing (fastest correct engine for the requested shape):
//!
//!   --show ranked / --rank[=N]   → drivers.runRank   (RRF top-K, definition-first)
//!   --live                       → live.runLive      (index-free live-tree scan)
//!   --show files, no line flags  → drivers.runQuery / runRegex  (the benchmarked
//!                                   cold path: SIMD substring for a plain literal,
//!                                   Thompson-NFA for a regex — paths only)
//!   everything else              → emit.runGrep      (the full `path:line:text`
//!                                   line engine: context, -o, -r, --json, filters)
//!
//! The `--show files` fast path exists purely for parity with the old `query`/
//! `regex` cold-query benchmarks: a bare pattern with no line-engine feature
//! (case-fold, word, invert, context, replace, only-matching, limit, json, path
//! filter) rides the specialized path-only driver. The moment any of those is
//! present, correctness needs the line engine, so we route there — it also serves
//! `--show files`/`count`, just via the full read+line-walk instead of the
//! path-level `docMatch`.

const std = @import("std");
const args = @import("args.zig");
const drivers = @import("drivers.zig");
const emit = @import("emit.zig");
const live = @import("live.zig");

/// Build + persist the trigram index (the `gist index` verb). Re-exported here
/// so `main` reaches every real operation through `commands.search`.
pub const runIndex = drivers.runIndex;

/// RE2 metacharacters: a pattern containing any of these is a regex, otherwise
/// it's a plain literal an SIMD substring scan can serve directly (the fast
/// `runQuery` path). `--fixed` forces literal regardless (the whole string is
/// data), so it's checked by the caller before this.
fn looksLikeRegex(pat: []const u8) bool {
    for (pat) |c| switch (c) {
        '.', '^', '$', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '\\' => return true,
        else => {},
    };
    return false;
}

/// Can this invocation ride the specialized `--show files` cold driver (paths
/// only, no line engine)? Only when the shape is exactly "which files match" AND
/// no feature the path-level driver can't honor is requested. Any case-fold,
/// word-boundary, invert, context, replace, only-matching, per-file limit,
/// count, json, or path filter forces the full line engine (`emit.runGrep`).
fn canRideFilesFastPath(opts: args.Options) bool {
    return opts.files_only and opts.filter.isEmpty() and
        !opts.json and !opts.caseless and !opts.smart_case and !opts.word and
        !opts.fixed and !opts.invert and !opts.only_matching and
        !opts.count_only and !opts.count_matches and !opts.no_line_num and
        opts.replace == null and opts.max_per_file == 0 and !opts.wantsContext();
}

/// Parse `gist search` argv (tokens AFTER the verb) and dispatch. Returns after
/// the engine emits (results → stdout, summary → stderr); a parse error / missing
/// pattern already printed guidance in `parseSearch` and we return quietly.
pub fn runSearch(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    var parsed = (try args.parseSearch(gpa, argv)) orelse return;
    defer parsed.deinit(gpa);
    const opts = parsed.opts;

    // `--files`: list the corpus (no pattern, no read) — always the in-memory
    // index projection, gist's structural edge over rg's whole-tree walk.
    if (opts.files_list) return emit.runFilesList(gpa, io, opts);

    // `--show ranked` / `--rank[=N]`: the flagship shape — a symbol's definition
    // outranks its call sites, RRF-fused. Its own output contract (not lines), so
    // it dispatches before the line engine; `rank_k` caps the surfaced rows.
    if (opts.ranked) return drivers.runRank(gpa, io, parsed.pattern, opts.rank_k);

    // `--live`: skip the index entirely, scan current bytes off the live tree.
    if (opts.live) return live.runLive(gpa, io, parsed.pattern, opts);

    // `--show files` with no line-engine feature ⇒ the benchmarked cold driver:
    // SIMD substring for a plain literal, Thompson-NFA for a regex (paths only).
    if (canRideFilesFastPath(opts)) {
        if (looksLikeRegex(parsed.pattern)) return drivers.runRegex(gpa, io, parsed.pattern);
        return drivers.runQuery(gpa, io, parsed.pattern);
    }

    // The default and the general case: the full `path:line:text` line engine.
    return emit.runGrep(gpa, io, parsed.pattern, opts);
}
