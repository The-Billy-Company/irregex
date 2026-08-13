//! irregex — the Haystack abstraction: WHAT to search/index, decoupled from HOW to
//! read it. Takes its shape from ripgrep's own split (`crates/core/haystack.rs`)
//! between classifying a walk entry as searchable and actually opening it, but
//! adapted to irregex's general program: the shared gitignore engine plus one
//! corpus-only skip-dir policy (`isSkipDir`) govern every consumer.
//! Before this, `corpus.zig`'s index build, `exec/cold/engine/serial.zig`'s tree-walk
//! enumeration, `index/trigrams/fresh.zig`'s mtime+ctime freshness stat-walk, and the
//! no-prefilter live scan each re-derived the identical
//! walk skeleton (open root → skip/enter dirs → join a file's path) around a
//! DIFFERENT per-file action (read bytes, keep the path, stat metadata, queue for
//! a worker pool). `Walker` is now the one place that skeleton lives; each
//! caller drives it and supplies only its own per-file action.
//!
//! `Haystack.dir`/`.name` borrow the underlying `std.Io.Dir.Walker.Entry`
//! exactly as it documents: valid only until the next `Walker.next` call. A
//! caller that needs the file's bytes or metadata must act on them
//! immediately (as every current caller already does); `path` is arena-owned
//! and safe to keep past that point (e.g. queued across threads by a
//! work-stealing consumer).

const std = @import("std");
const Dir = std.Io.Dir;
const assay = @import("../../assay/assay.zig");
const charter = @import("../scope/charter.zig");
const corpus_mod = @import("corpus.zig"); // mutual import; only `outDir()` is touched
const ignore = @import("ignore.zig");
const paths = @import("../scope/paths.zig");
const portal = @import("../../portal.zig");
const home = @import("../index/frame/home.zig");

/// A file discovered by the walk: a resolved, root-joined path plus the
/// directory handle + basename needed to read or stat it right now.
pub const Haystack = struct {
    path: []const u8,
    dir: Dir,
    name: []const u8,
};

/// Directory basenames every corpus walk skips (gitignore + VCS + build
/// output) — the one skip-dir policy shared by the index build, `--live`,
/// the freshness overlay, and the no-prefilter live scan. `isSkipDir` runs
/// once per DIRECTORY the walk enters (not per file), but a monorepo this
/// size still enters thousands of them per index build, so it's worth
/// keeping O(1)-ish rather than a linear membership scan.
///
/// `std.StaticStringMap` — the same technique Zig's own tokenizer keyword
/// lookup uses (`std.zig.primitives.names`, `std.zig.Token.getKeyword`) —
/// buckets these 36 names by length at comptime, so a lookup is one length
/// check + a compare against only the few same-length candidates, instead of
/// testing all 36 in the worst (most common) case of "not a skip dir".
/// Measured (standalone ReleaseFast micro-bench, 1786 real repo directory
/// basenames pulled from `git ls-tree`, 2000 passes): a linear `std.mem.eql`
/// scan over the flat list runs 18.5 ns/call; this runs 2.8 ns/call — a 6.6×
/// win — free of any hand-maintained per-length table (a hand-rolled `switch`
/// on length shaved a further ~6% but risks silently drifting out of sync
/// with this list; not worth it for noise-level gain on an already-cheap op).
/// Every name is a cross-ecosystem convention (VCS, package caches, build
/// output) — nothing project-specific; a tree with its own heavy dirs extends
/// the policy per invocation via `<prefix>SKIP`. The artifact directory is here
/// on the same footing as `.zig-cache`: it is this engine's OWN artifact home,
/// it sits inside the walk root by default, and indexing an index is a tool
/// reading its own exhaust. A caller who really wants those bytes names the
/// directory as a root, which the walk still honors.
const skip_dirs = std.StaticStringMap(void).initComptime(.{
    .{".git"},          .{".github"},     .{".hg"},           .{".svn"},          .{"node_modules"},
    .{"target"},        .{"dist"},        .{"dist-types"},    .{"build"},         .{".build"},
    .{"out"},           .{".next"},       .{"coverage"},      .{".venv"},         .{"venv"},
    .{"site-packages"}, .{"__pycache__"}, .{".pytest_cache"}, .{".mypy_cache"},   .{".ruff_cache"},
    .{".zig-cache"},    .{"zig-out"},     .{"zig-pkg"},       .{".cache"},        .{".local"},
    .{".turbo"},        .{"vendor"},      .{".swiftpm"},      .{"Pods"},          .{"DerivedData"},
    .{".cursor"},       .{".idea"},       .{".vscode"},       .{".parcel-cache"}, .{".pnpm-store"},
    .{".gist"},
});

/// The extra directory basenames a tree declared out of its corpus, beyond the
/// generic comptime baseline above — the POLICY half of the skip decision,
/// split from the walk that consults it for the same reason the output budget
/// is split from its run counters: it is the only half a caller ever states. A
/// CLI resolves it from the environment, the committed charter, and the
/// machine-local seeded list (`resolveSkipOverlay`); a caller with none of
/// those to read — an embedder standing the engine up over a corpus it chose
/// itself, a test that builds its own fixture tree and must not have the
/// operator's machine prune a directory out of it — states it outright and
/// hands it to `installSkipOverlay`. Same shape, and the same reason, as
/// `corpus.Budget` on `installOutputBudget` and the explicit `lenses` mask on
/// `assay.install`.
pub const SkipOverlay = struct {
    /// Directory basenames to prune on top of the baseline. Borrowed: every
    /// current producer hands over strings that outlive the process.
    names: []const []const u8 = &.{},

    /// What a walk with no `<prefix>SKIP`, no charter `skip`, and no seeded
    /// `skips.list` prunes: nothing beyond the comptime baseline.
    pub const none: SkipOverlay = .{};
};

/// An overlay held for the duration of a scope, with whatever was in force
/// before put back on the way out. The restore is what makes the seam safe to
/// use from a fixture: a test that states its own scope must not leave the
/// process describing a corpus the next caller never asked for.
pub const StatedSkipOverlay = struct {
    ambient: SkipOverlay,

    pub fn release(self: StatedSkipOverlay) void {
        installSkipOverlay(self.ambient);
    }
};

/// The overlay's three optional sources and the one slot they land in: the
/// `<prefix>SKIP` env (`:`/`,`/space separated — one-shot override), the tree's
/// committed charter (`.irregex.toml skip` — the durable, SHARED policy, and
/// the one a fresh clone gets for free), and the machine-local
/// `<outDir()>/skips.list` (one name per line, `#` comments). The charter is
/// why the last of those is no longer the only durable rung: `outDir()`
/// defaults inside the gitignored artifact directory, so a skips.list policy
/// was per-machine folklore that a fresh clone silently lacked — two clones of
/// one tree walking two different corpora. It stays honored for the
/// machine-specific case.
/// The comptime baseline above stays generic; anything project-specific rides
/// these. Env and charter tokens borrow strings that outlive the process; file
/// tokens borrow a static buffer filled under the same lock. The spinlock idiom
/// matches
/// `home.ArtifactPath` (per-directory lookups against a near-always-empty
/// list, never a hot loop once `done` publishes).
const extra_skips = struct {
    var locked: std.atomic.Value(bool) = .init(false);
    var done: std.atomic.Value(bool) = .init(false);
    var file_buf: [4096]u8 = undefined;
    var names: [32][]const u8 = undefined;
    var count: usize = 0;
    /// The overlay actually in force — the environment's, or a caller's. Empty
    /// until `done` publishes, which is the only state `list` reads it in.
    var installed: []const []const u8 = &.{};

    fn add(tok: []const u8) void {
        if (count < names.len) {
            names[count] = tok;
            count += 1;
        }
    }

    fn fill() void {
        if (assay.knob("SKIP")) |v| {
            var it = std.mem.tokenizeAny(u8, v, ": ,");
            while (it.next()) |tok| add(tok);
        }
        if (charter.governing()) |c| for (c.skip) |name| add(name);
        var path_buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/skips.list", .{home.outDir()}) catch return;
        const fd = portal.openFile(portal.cwd(), path) catch return;
        defer portal.close(fd);
        const n = portal.read(fd, &file_buf) catch return;
        var lines = std.mem.tokenizeAny(u8, file_buf[0..n], "\r\n");
        while (lines.next()) |line| {
            const t = std.mem.trim(u8, line, " \t");
            if (t.len == 0 or t[0] == '#') continue;
            add(t);
        }
    }

    fn lock() void {
        while (locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn unlock() void {
        locked.store(false, .release);
    }

    fn list() []const []const u8 {
        if (!done.load(.acquire)) {
            lock();
            defer unlock();
            if (!done.load(.acquire)) {
                fill();
                installed = names[0..count];
                done.store(true, .release);
            }
        }
        return installed;
    }
};

/// The overlay in force: whatever a caller stated, or — if nobody has — what
/// `<prefix>SKIP`, the tree's charter, and `<outDir()>/skips.list` say, resolved
/// now and at most once per process, exactly as the first walk would have
/// resolved it. The read half of the split, so `installSkipOverlay` below can
/// be driven by a caller with no environment to read, and so a caller that
/// wants its own scope back afterwards has something to put back.
pub fn resolveSkipOverlay() SkipOverlay {
    return .{ .names = extra_skips.list() };
}

/// Bind every subsequent walk to `overlay` — the one place a skip policy takes
/// effect, whether it came from the environment or from a caller stating it.
/// Installing also settles the lazy resolution, so a caller that states a
/// policy before the first walk is never overwritten by one. State the policy
/// before the walks that must see it: this rebinds a slice the walk reads
/// unsynchronized once `done` has published, the same footing the resolved
/// answer has always been read on.
pub fn installSkipOverlay(overlay: SkipOverlay) void {
    extra_skips.lock();
    defer extra_skips.unlock();
    extra_skips.installed = overlay.names;
    extra_skips.done.store(true, .release);
}

/// Install `overlay` and hand back the scope that puts the previous one back.
/// The pairing every fixture wants: one call in `init`, `release` in `deinit`.
pub fn stateSkipOverlay(overlay: SkipOverlay) StatedSkipOverlay {
    const ambient = resolveSkipOverlay();
    installSkipOverlay(overlay);
    return .{ .ambient = ambient };
}

/// Comptime-baseline membership only — the generic VCS/build/cache basenames,
/// with no runtime `<prefix>SKIP`/`skips.list` overlay folded in. This is the pure
/// decision the `StaticStringMap`↔linear differential guardrail pins; it stays
/// deterministic regardless of a machine's seeded per-tree policy. Production
/// callers want the full-policy `isSkipDir` below.
pub fn inBaselineSkipSet(name: []const u8) bool {
    return skip_dirs.has(name);
}

/// Is `name` a directory basename every corpus walk skips? (`skip_dirs`
/// baseline + `<prefix>SKIP`/`skips.list` extension.)
pub fn isSkipDir(name: []const u8) bool {
    if (inBaselineSkipSet(name)) return true;
    return isPolicySkip(name);
}

/// Is `name` a directory basename declared out of the corpus by the overlay in
/// force — resolved from charter `skip`, `<prefix>SKIP`, and
/// `<outDir()>/skips.list` unless a caller stated one — and nothing else?
/// Cold search (including `-uu`) consults this and not the generic baseline:
/// ripgrep parity requires `-uu` to enter `.git`/`node_modules`, but a
/// committed charter skip is a fact about the repository, not an ignore rule
/// `--no-ignore` can undo. Pointing a root at the directory itself still
/// searches it; only descending into it from a parent is refused.
pub fn isPolicySkip(name: []const u8) bool {
    for (extra_skips.list()) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

/// Whether any directory component of `path` is excluded from the corpus.
/// The basename is deliberately ignored: a file named like a skipped directory
/// remains admissible, matching the walk.
pub fn underSkippedDir(path: []const u8) bool {
    var rest = path;
    while (std.mem.indexOfScalar(u8, rest, '/')) |i| {
        if (isSkipDir(rest[0..i])) return true;
        rest = rest[i + 1 ..];
    }
    return false;
}

/// `root/rel`, exactly sized + `memcpy`'d — this runs once per FILE the walk
/// yields (18.9k times over the current corpus, an order of magnitude hotter
/// than `isSkipDir`), so it's the walker's actual hot spot. Measured
/// (standalone ReleaseFast micro-bench, arena allocator, 200k calls over a
/// handful of representative root/rel pairs): `std.fmt.allocPrint(a,
/// "{s}/{s}", .{root, rel})` runs 20.9 ns/call — the `Io.Writer` interface
/// dispatch per `{s}` arg costs more than the actual copy for a string this
/// short; two `@memcpy`s + one byte store is 9.9 ns/call, a 2.1× win, for a
/// format string simple enough that neither version does any real
/// "formatting" work; `haystack_test.zig` pins the byte-identical output.
pub fn joinPath(a: std.mem.Allocator, root: []const u8, rel: []const u8) ![]u8 {
    const buf = try a.alloc(u8, root.len + 1 + rel.len);
    @memcpy(buf[0..root.len], root);
    buf[root.len] = '/';
    @memcpy(buf[root.len + 1 ..], rel);
    return buf;
}

/// `joinPath` with the whole-tree root normalized away: a corpus rooted at
/// `.` yields plain CWD-relative paths (`Lib/os.py`, never `./Lib/os.py`),
/// so indexed paths, walk output, and query root-scoping all compare
/// byte-equal — the same shape a rootless bare-pattern walk emits.
pub fn joinRoot(a: std.mem.Allocator, root: []const u8, rel: []const u8) ![]u8 {
    if (std.mem.eql(u8, root, ".")) return a.dupe(u8, rel);
    return joinPath(a, root, rel);
}

/// Recursively walks one root, transparently entering every non-skipped
/// subdirectory (`isSkipDir`) and yielding a `Haystack` for each plain file —
/// directories themselves are never yielded, only their contents. A thin
/// shape over `std.Io.Dir.SelectiveWalker`; every error (a bad root, a
/// mid-walk OS failure, an OOM path join) propagates through `next` so each
/// caller keeps its own existing choice of "surface the error" (`try`, as the
/// index build does) or "degrade to found-nothing" (`catch return`, as every
/// live/freshness walker does).
pub const Walker = struct {
    root: Dir,
    inner: Dir.SelectiveWalker,
    root_path: []const u8,
    a: std.mem.Allocator,
    ig: ignore.Ignore,

    pub fn init(io: std.Io, a: std.mem.Allocator, root_path: []const u8) !Walker {
        return initWithRoots(io, a, root_path, &.{root_path});
    }

    /// Initialize one root while compiling ignore precedence against the full
    /// invocation's roots, so a shared ancestor's rules apply order-independently
    /// across every root (rg 15.2's #3320/#3376 multi-directory behavior).
    pub fn initWithRoots(io: std.Io, a: std.mem.Allocator, root_path: []const u8, roots: []const []const u8) !Walker {
        var root = try Dir.cwd().openDir(io, root_path, .{ .iterate = true });
        errdefer root.close(io);
        const inner = try root.walkSelectively(a);
        var ig = try ignore.Ignore.init(a, io, .{}, roots);
        const rel = paths.stripDot(root_path);
        ig.scopeToRoot(rel);
        try ig.loadDir(root_path, rel);
        return .{ .root = root, .inner = inner, .root_path = root_path, .a = a, .ig = ig };
    }

    pub fn deinit(self: *Walker, io: std.Io) void {
        self.inner.deinit();
        self.root.close(io);
    }

    pub fn next(self: *Walker, io: std.Io) !?Haystack {
        while (true) {
            const entry = try self.inner.next(io) orelse return null;
            // This engine's separator, not the platform's, before the path
            // reaches the ignore protocol or a caller's output — rewritten in
            // the join's own buffer, so a platform that needs it pays no second
            // allocation.
            const path = try joinRoot(self.a, self.root_path, entry.path);
            paths.slashInPlace(path);
            if (entry.kind == .directory) {
                if (isSkipDir(entry.basename) or self.ig.shouldSkip(path, true, entry.basename, false, false)) continue;
                try self.ig.loadDir(path, path);
                try self.inner.enter(io, entry);
                continue;
            }
            if (entry.kind != .file) continue;
            if (self.ig.shouldSkip(path, false, entry.basename, false, false)) continue;
            return .{
                .path = path,
                .dir = entry.dir,
                .name = entry.basename,
            };
        }
    }
};
