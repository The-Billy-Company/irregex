//! gist search `--live` — the index-free path: walk the tree, scan current bytes.
//!
//! The indexed engine (`emit.runGrep`) is already *correct* under churn (the
//! freshness overlay widens candidates to files touched since the build, and the
//! verify pass reads live bytes), so `--live` is not about correctness — it's the
//! capability the old `gist rg` verb had, re-homed onto one flag: search a tree
//! with NO index at all (a fresh clone, or a root outside the indexed corpus), or
//! force a guaranteed one-shot that reads every current file with zero dependence
//! on `.local/gist-verify`.
//!
//! It is deliberately thin: enumerate every non-skipped path under the roots
//! (positional PATHs if given, else the default corpus roots), then hand that
//! full path set to the SAME line engine the indexed path uses
//! (`emit.grepOverPaths`) — so `--show lines|files|count`, `-A/-B/-C`, `-o`, `-r`,
//! `--json`, `--limit`, `-i/-w/-F/-v` all behave identically; only the candidate
//! source differs (every live path vs the trigram-prefiltered set). There is no
//! prefilter here by design: skipping the index means scanning the whole tree,
//! exactly as ripgrep does, which is the honest cost of `--live`.

const std = @import("std");
const corpus_mod = @import("../../corpus/corpus.zig");
const glob = @import("../scope/glob.zig");
const emit = @import("emit.zig");
const args = @import("args.zig");
const Regex = @import("../../regex/core.zig").Regex;
const Dir = std.Io.Dir;
const Options = args.Options;

fn nowNs(io: std.Io) i128 {
    return std.Io.Clock.now(.awake, io).nanoseconds;
}

/// Walk `root` (non-recursively skipping the build/VCS subtrees the indexed
/// corpus also skips), appending every file's repo-root-relative path into `a`
/// (arena-owned, alive for the whole search). Path-only — no bytes are read here;
/// the line engine reads the candidate files itself. A failure degrades to
/// "found nothing under this root" (never a crash, never an invented path).
fn walkRoot(io: std.Io, a: std.mem.Allocator, root_path: []const u8, out: *std.ArrayList([]const u8)) void {
    var root = Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch return;
    defer root.close(io);
    var walker = root.walkSelectively(a) catch return;
    defer walker.deinit();
    while (walker.next(io) catch return) |entry| {
        if (entry.kind == .directory) {
            if (!corpus_mod.isSkipDir(entry.basename)) walker.enter(io, entry) catch return;
            continue;
        }
        if (entry.kind != .file) continue;
        const full = std.fmt.allocPrint(a, "{s}/{s}", .{ root_path, entry.path }) catch return;
        out.append(a, full) catch return;
    }
}

/// `--live`: scan the live tree with no index. Compiles the same effective
/// pattern (`--fixed`/`--word`) and caseless mode the indexed path does,
/// enumerates every candidate path under the scope roots, prunes by the
/// `--lang`/`--glob` filter, and runs the shared line engine over them.
pub fn runLive(gpa: std.mem.Allocator, io: std.Io, pattern: []const u8, opts: Options) !void {
    const eff = try emit.effectivePattern(gpa, pattern, opts);
    defer if (eff.owned) gpa.free(eff.s);
    var re = Regex.compileOpts(gpa, eff.s, .{ .caseless = opts.caseless }) catch {
        std.debug.print("bad pattern /{s}/ — supported: literals . [] [^] a-z * + ? {{n,m}} | () ^ $ and \\d \\w \\s \\t \\n \\r (see src/regex/syntax.zig)\n", .{pattern});
        return;
    };
    defer re.deinit();

    const w0 = nowNs(io);
    // Scope roots: the positional PATH args if any, else the default corpus roots
    // (`--live` outside the indexed set is the whole point, so honor explicit PATHs).
    const roots: []const []const u8 = if (opts.filter.roots.len > 0) opts.filter.roots else &corpus_mod.default_roots;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var paths: std.ArrayList([]const u8) = .empty;
    for (roots) |r| walkRoot(io, a, glob.normalizeRoot(r), &paths);

    // Every enumerated path is a candidate (no trigram prefilter without an
    // index); the filter still prunes by `--lang`/`--glob`/`--exclude` before any
    // read. ids are the identity 0..n over the walked path list.
    const ids = try gpa.alloc(u32, paths.items.len);
    defer gpa.free(ids);
    for (ids, 0..) |*d, k| d.* = @intCast(k);
    const scoped = opts.filter.prune(paths.items, ids);
    const walk_ns = nowNs(io) - w0;

    try emit.grepOverPaths(gpa, io, opts, &re, paths.items, scoped, paths.items.len, walk_ns);
}
