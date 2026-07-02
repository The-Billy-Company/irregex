//! gist — corpus loading, shared by the CLI drivers (`commands/cli/`), the
//! unified search engine (`commands/ripgrep/`) and the bench/verify harness
//! (`bench/harness/bench.zig`). The corpus is every non-binary file under the roots
//! (rg-style: a NUL byte ⇒ binary ⇒ skipped), minus the build/VCS subtrees rg
//! also skips. Also owns the stdout results contract (`emitResults`) every
//! search path emits through.

const std = @import("std");
const haystack = @import("haystack.zig");

pub const per_file_cap: usize = 4 << 20; // 4 MiB
pub const out_dir = ".local/gist-verify";
pub const default_roots = [_][]const u8{ "services", "libs", "clients", "contracts", "scripts", "quality" };

/// Emit query RESULTS (the match list / ranked rows) on **stdout** — the Unix
/// convention `rg` follows: data on stdout, any diagnostic (`[pipeline]`, "no
/// index"/"bad pattern" guidance, `--rank`'s timing line) stays on stderr via
/// `std.debug.print`. This is what makes gist agent-friendly in a shell: `gist
/// foo -l > files` captures the paths and `gist foo | head` shows only
/// results. A raw `posix.write` loop (handling partial
/// writes) mirrors the blocking-syscall idiom the read path already uses, and
/// sidesteps the std Io.Writer surface churn. Write errors are swallowed: a
/// closed stdout (e.g. `| head` exiting early) must not crash the query.
pub fn emitStdout(bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        // `std.posix.system.write` is the raw C-ABI extern (returns isize; <=0 ⇒
        // error/closed-pipe), the same `std.posix.system.*` layer the read path's
        // `close` already rides on — `std.posix.write` is absent this Zig cut.
        const n = std.posix.system.write(1, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return; // EPIPE (`| head` exited) / EINTR ⇒ stop, never crash
        off += @intCast(n);
    }
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
