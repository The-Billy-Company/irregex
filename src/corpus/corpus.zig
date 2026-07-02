//! gist — corpus loading, shared by the CLI drivers (`commands/cli/`), the
//! `search` verb (`commands/search/`) and the bench/verify harness
//! (`bench/bench.zig`). The corpus is every non-binary file under the roots
//! (rg-style: a NUL byte ⇒ binary ⇒ skipped), minus the build/VCS subtrees rg
//! also skips. Also owns the stdout results contract (`emitResults`) every
//! search path emits through.

const std = @import("std");
const Dir = std.Io.Dir;

pub const per_file_cap: usize = 4 << 20; // 4 MiB
pub const out_dir = ".local/gist-verify";
pub const default_roots = [_][]const u8{ "services", "libs", "clients", "contracts", "scripts", "quality" };

/// Emit query RESULTS (the match list / ranked rows) on **stdout** — the Unix
/// convention `rg` follows: data on stdout, diagnostics (timing, `[pipeline]`,
/// guidance) stay on stderr via `std.debug.print`. This is what makes gist
/// agent-friendly in a shell: `gist search foo --show files > files` captures the
/// paths and `gist search foo | head` shows only results, with the summary line
/// still visible on the terminal. A raw `posix.write` loop (handling partial
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

/// Directory basenames rg skips by default (gitignore + VCS + build output).
pub fn isSkipDir(name: []const u8) bool {
    const skip = [_][]const u8{
        ".git",          ".github",     ".hg",           ".svn",        "node_modules",
        "target",        "dist",        "dist-types",    "build",       ".build",
        "out",           ".next",       "coverage",      ".venv",       "venv",
        "site-packages", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache",
        ".zig-cache",    "zig-out",     ".cache",        ".local",      ".turbo",
        "vendor",        ".swiftpm",    "Pods",          "DerivedData", ".cursor",
        ".idea",         ".vscode",     ".parcel-cache", ".pnpm-store", "graphify-out",
    };
    for (skip) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

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
        var root = Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch |e| {
            std.debug.print("  skip {s}: {s}\n", .{ root_path, @errorName(e) });
            continue;
        };
        defer root.close(io);

        var walker = try root.walkSelectively(a);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind == .directory) {
                if (!isSkipDir(entry.basename)) try walker.enter(io, entry);
                continue;
            }
            if (entry.kind != .file) continue;
            const buf = entry.dir.readFileAlloc(io, entry.basename, a, .limited(per_file_cap)) catch continue;
            if (buf.len == 0 or isBinary(buf)) continue;
            const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ root_path, entry.path });
            try docs.append(a, buf);
            try paths.append(a, full);
            total += buf.len;
        }
    }
    return .{ .docs = docs.items, .paths = paths.items, .bytes = total, .arena = arena };
}
