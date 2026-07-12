//! gist — the Haystack abstraction: WHAT to search/index, decoupled from HOW to
//! read it. Takes its shape from ripgrep's own split (`crates/core/haystack.rs`)
//! between classifying a walk entry as searchable and actually opening it, but
//! adapted to gist's general program: no ignore files, no explicit-file-arg
//! concept, one skip-dir policy (`isSkipDir`) shared by every corpus consumer.
//! Before this, `corpus.zig`'s index build, `ripgrep/run.zig`'s tree-walk
//! enumeration, `corpus/fresh.zig`'s mtime+ctime freshness stat-walk, and
//! `scan/sweep.zig`'s no-prefilter live scan each re-derived the identical
//! walk skeleton (open root → skip/enter dirs → join a file's path) around a
//! DIFFERENT per-file action (read bytes, keep the path, stat metadata, queue for
//! a worker pool). `Walker` is now the one place that skeleton lives; each
//! caller drives it and supplies only its own per-file action.
//!
//! `Haystack.dir`/`.name` borrow the underlying `std.Io.Dir.Walker.Entry`
//! exactly as it documents: valid only until the next `Walker.next` call. A
//! caller that needs the file's bytes or metadata must act on them
//! immediately (as every current caller already does); `path` is arena-owned
//! and safe to keep past that point (e.g. queued across threads, as
//! `scan/sweep.zig` does).

const std = @import("std");
const Dir = std.Io.Dir;

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
/// buckets these 35 names by length at comptime, so a lookup is one length
/// check + a compare against only the few same-length candidates, instead of
/// testing all 35 in the worst (most common) case of "not a skip dir".
/// Measured (standalone ReleaseFast micro-bench, 1786 real repo directory
/// basenames pulled from `git ls-tree`, 2000 passes): a linear `std.mem.eql`
/// scan over the flat list runs 18.5 ns/call; this runs 2.8 ns/call — a 6.6×
/// win — free of any hand-maintained per-length table (a hand-rolled `switch`
/// on length shaved a further ~6% but risks silently drifting out of sync
/// with this list; not worth it for noise-level gain on an already-cheap op).
const skip_dirs = std.StaticStringMap(void).initComptime(.{
    .{".git"},          .{".github"},     .{".hg"},           .{".svn"},        .{"node_modules"},
    .{"target"},        .{"dist"},        .{"dist-types"},    .{"build"},       .{".build"},
    .{"out"},           .{".next"},       .{"coverage"},      .{".venv"},       .{"venv"},
    .{"site-packages"}, .{"__pycache__"}, .{".pytest_cache"}, .{".mypy_cache"}, .{".ruff_cache"},
    .{".zig-cache"},    .{"zig-out"},     .{".cache"},        .{".local"},      .{".turbo"},
    .{"vendor"},        .{".swiftpm"},    .{"Pods"},          .{"DerivedData"}, .{".cursor"},
    .{".idea"},         .{".vscode"},     .{".parcel-cache"}, .{".pnpm-store"}, .{"graphify-out"},
});

pub fn isSkipDir(name: []const u8) bool {
    return skip_dirs.has(name);
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
pub fn joinPath(a: std.mem.Allocator, root: []const u8, rel: []const u8) ![]const u8 {
    const buf = try a.alloc(u8, root.len + 1 + rel.len);
    @memcpy(buf[0..root.len], root);
    buf[root.len] = '/';
    @memcpy(buf[root.len + 1 ..], rel);
    return buf;
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

    pub fn init(io: std.Io, a: std.mem.Allocator, root_path: []const u8) !Walker {
        var root = try Dir.cwd().openDir(io, root_path, .{ .iterate = true });
        errdefer root.close(io);
        const inner = try root.walkSelectively(a);
        return .{ .root = root, .inner = inner, .root_path = root_path, .a = a };
    }

    pub fn deinit(self: *Walker, io: std.Io) void {
        self.inner.deinit();
        self.root.close(io);
    }

    pub fn next(self: *Walker, io: std.Io) !?Haystack {
        while (true) {
            const entry = try self.inner.next(io) orelse return null;
            if (entry.kind == .directory) {
                if (!isSkipDir(entry.basename)) try self.inner.enter(io, entry);
                continue;
            }
            if (entry.kind != .file) continue;
            return .{
                .path = try joinPath(self.a, self.root_path, entry.path),
                .dir = entry.dir,
                .name = entry.basename,
            };
        }
    }
};
