//! gist — corpus loading, shared by the CLI drivers (`commands/cli/`), the
//! unified search engine (`commands/ripgrep/`) and the bench/verify harness
//! (`bench/harness/bench.zig`). The corpus is every non-binary file under the roots
//! (rg-style: a NUL byte ⇒ binary ⇒ skipped), minus the build/VCS subtrees rg
//! also skips. Also owns the stdout results contract (`emitResults`) every
//! search path emits through.

const std = @import("std");
const haystack = @import("haystack.zig");
const Dir = std.Io.Dir;

pub const per_file_cap: usize = 4 << 20; // 4 MiB
pub const out_dir = ".local/gist-verify";
pub const default_roots = [_][]const u8{ "services", "libs", "clients", "contracts", "scripts", "quality" };

/// Write RESULTS (the match list / ranked rows) to **stdout** — the Unix
/// convention `rg` follows: data on stdout, any diagnostic (`[pipeline]`, "no
/// index"/"bad pattern" guidance, `--rank`'s timing line) stays on stderr via
/// `std.debug.print`. This is what makes gist agent-friendly in a shell: `gist
/// foo -l > files` captures the paths and `gist foo | head` shows only
/// results. A raw `posix.write` loop (handling partial writes) mirrors the
/// blocking-syscall idiom the read path already uses, and sidesteps the std
/// Io.Writer surface churn. Returns whether every byte was accepted — `false`
/// means the pipe is gone (EPIPE, e.g. `| head` already exited) or a signal
/// interrupted the call (EINTR); the caller decides what that means (the
/// parallel engine's streaming sink, `pipeline.zig`, treats it as "cancel the
/// rest of the walk", the same EPIPE-triggered shape ripgrep itself uses).
pub fn writeStdout(bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        // `std.posix.system.write` is the raw C-ABI extern (returns isize; <=0 ⇒
        // error/closed-pipe), the same `std.posix.system.*` layer the read path's
        // `close` already rides on — `std.posix.write` is absent this Zig cut.
        const n = std.posix.system.write(1, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

/// `writeStdout` for a fire-and-forget one-shot emit: write errors are
/// swallowed (a closed stdout must not crash the query) because these
/// callers have nothing left to cancel — they're already at their last write.
pub fn emitStdout(bytes: []const u8) void {
    _ = writeStdout(bytes);
}

/// Directory basenames rg skips by default (gitignore + VCS + build output) —
/// re-exported for anyone still spelling it `corpus.isSkipDir`; the canonical
/// definition (and the walk that applies it) now lives in `haystack.zig`.
pub const isSkipDir = haystack.isSkipDir;

/// rg-style binary detection: a NUL byte in the first 8 KiB ⇒ treat as binary.
pub fn isBinary(bytes: []const u8) bool {
    const window = bytes[0..@min(bytes.len, 8192)];
    return std.mem.indexOfScalar(u8, window, 0) != null;
}

pub const Corpus = struct {
    docs: [][]const u8,
    paths: [][]const u8,
    bytes: u64,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Corpus) void {
        self.arena.deinit();
    }
};

pub fn load(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8) !Corpus {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    var docs: std.ArrayList([]const u8) = .empty;
    var paths: std.ArrayList([]const u8) = .empty;
    var total: u64 = 0;

    for (roots) |root_path| {
        var w = haystack.Walker.init(io, a, root_path) catch |e| {
            std.debug.print("  skip {s}: {s}\n", .{ root_path, @errorName(e) });
            continue;
        };
        defer w.deinit(io);
        while (try w.next(io)) |hay| {
            const buf = hay.dir.readFileAlloc(io, hay.name, a, .limited(per_file_cap)) catch continue;
            if (buf.len == 0 or isBinary(buf)) continue;
            try docs.append(a, buf);
            try paths.append(a, hay.path);
            total += buf.len;
        }
    }
    return .{ .docs = docs.items, .paths = paths.items, .bytes = total, .arena = arena };
}

/// Read an explicit, pre-selected path list into a corpus (no walk). The caller
/// supplies the authoritative file set — for the resident daemon, the certified
/// rg-default walk (`commands/ripgrep/run.zig::defaultFileSet`) — so the corpus
/// membership matches cold's live walk exactly, rather than `load`'s coarse
/// `haystack` superset. Same per-file admission as `load` (skip empty/binary,
/// unreadable) so the two loaders agree on what counts as a searchable doc; a
/// path that vanished or turned binary since selection is simply dropped. Path
/// strings are duped into the corpus arena, so the caller's slice may be freed.
pub fn loadPaths(gpa: std.mem.Allocator, io: std.Io, in_paths: []const []const u8) !Corpus {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    var docs: std.ArrayList([]const u8) = .empty;
    var paths: std.ArrayList([]const u8) = .empty;
    var total: u64 = 0;
    for (in_paths) |p| {
        const buf = Dir.cwd().readFileAlloc(io, p, a, .limited(per_file_cap)) catch continue;
        if (buf.len == 0 or isBinary(buf)) continue;
        try docs.append(a, buf);
        try paths.append(a, try a.dupe(u8, p));
        total += buf.len;
    }
    return .{ .docs = docs.items, .paths = paths.items, .bytes = total, .arena = arena };
}
