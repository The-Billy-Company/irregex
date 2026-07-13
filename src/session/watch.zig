//! gist resident session — the freshness watcher (ADR-352 rung 2.5).
//!
//! The watcher is a pure *accelerator* for the freshness barrier, never a
//! correctness dependency. Its only job is to keep a session honest about when
//! it may skip the reconcile walk: on any filesystem event under the watched
//! roots it calls `session.markDirty()`, forcing the next query to reconcile;
//! when it has proven no event since the last reconcile the session takes the
//! microsecond fast path. If a watcher cannot be started (unsupported platform,
//! a watch that won't register, a queue that could overflow), the session is
//! simply **never armed** — `watcher_active` stays false and every query
//! reconciles the changed set against the live filesystem. Correctness rests on
//! that reconcile (`resident.zig`), so a missing or degraded watcher only costs
//! speed, never soundness (fail-closed).
//!
//! Backends: Linux `inotify` (recursive watches, arm-only-on-full-success);
//! every other target (incl. macOS today) uses the reconcile-always baseline —
//! FSEvents elision is the next acceleration rung and slots in here without
//! touching the barrier or the query path.

const std = @import("std");
const builtin = @import("builtin");
const haystack = @import("../corpus/haystack.zig");
const ResidentSession = @import("resident.zig").ResidentSession;
const Dir = std.Io.Dir;

pub const Watcher = struct {
    session: *ResidentSession,
    io: std.Io,
    gpa: std.mem.Allocator,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),
    inotify_fd: i32 = -1,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, session: *ResidentSession) Watcher {
        return .{ .session = session, .io = io, .gpa = gpa };
    }

    /// Best-effort start. Arms the session (enabling the clean fast path) only
    /// when a watcher backend fully registers; otherwise leaves the session in
    /// the reconcile-always baseline and returns without error.
    pub fn start(self: *Watcher) void {
        if (comptime builtin.os.tag == .linux) {
            self.startInotify();
        }
        // Other targets: no watcher → reconcile-always baseline (already the
        // session's default; nothing to arm).
    }

    pub fn stop(self: *Watcher) void {
        self.running.store(false, .release);
        if (comptime builtin.os.tag == .linux) {
            if (self.inotify_fd >= 0) {
                std.posix.close(self.inotify_fd);
                self.inotify_fd = -1;
            }
        }
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn startInotify(self: *Watcher) void {
        if (comptime builtin.os.tag == .linux) {
            const linux = std.os.linux;
            const fd_usize = linux.inotify_init1(linux.IN.NONBLOCK);
            const fd: i32 = @intCast(fd_usize);
            if (fd < 0) return; // no inotify → stay in baseline
            errdefer std.posix.close(fd);

            // Recursively watch every directory under the roots. If ANY watch
            // fails to register we cannot prove quiescence for that subtree, so
            // we bail out unarmed (fail-closed): the session keeps reconciling.
            const mask = linux.IN.MODIFY | linux.IN.CREATE | linux.IN.DELETE |
                linux.IN.MOVED_FROM | linux.IN.MOVED_TO | linux.IN.ATTRIB |
                linux.IN.CLOSE_WRITE | linux.IN.ONLYDIR;
            for (self.session.roots) |root| {
                if (!self.addWatchesRecursive(fd, root, mask)) {
                    std.posix.close(fd);
                    return;
                }
            }

            self.inotify_fd = fd;
            self.running.store(true, .release);
            self.session.armWatcher();
            self.thread = std.Thread.spawn(.{}, inotifyLoop, .{self}) catch {
                self.running.store(false, .release);
                self.inotify_fd = -1;
                std.posix.close(fd);
                return; // spawn failed — unarm by leaving watcher inactive
            };
        }
    }

    /// Register a watch on `path` and every non-skipped subdirectory. Returns
    /// false on the first failure (caller bails unarmed).
    fn addWatchesRecursive(self: *Watcher, fd: i32, path: []const u8, mask: u32) bool {
        if (comptime builtin.os.tag == .linux) {
            const linux = std.os.linux;
            const cpath = std.posix.toPosixPath(path) catch return false;
            const wd = linux.inotify_add_watch(fd, &cpath, mask);
            if (@as(isize, @bitCast(wd)) < 0) return false;

            var dir = Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch return true;
            defer dir.close(self.io);
            var it = dir.iterate();
            while (it.next(self.io) catch null) |e| {
                if (e.kind != .directory) continue;
                if (haystack.isSkipDir(e.name)) continue;
                const child = haystack.joinPath(self.gpa, path, e.name) catch return false;
                defer self.gpa.free(child);
                if (!self.addWatchesRecursive(fd, child, mask)) return false;
            }
            return true;
        }
        return false;
    }

    fn inotifyLoop(self: *Watcher) void {
        if (comptime builtin.os.tag == .linux) {
            var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
            var pfd = [_]std.posix.pollfd{.{ .fd = self.inotify_fd, .events = std.posix.POLL.IN, .revents = 0 }};
            while (self.running.load(.acquire)) {
                const ready = std.posix.poll(&pfd, 500) catch break;
                if (ready == 0) continue;
                const n = std.posix.read(self.inotify_fd, &buf) catch |e| switch (e) {
                    error.WouldBlock => continue,
                    else => break,
                };
                if (n == 0) continue;
                // Any event (including a queue overflow, which zeroes wd) means
                // something under the roots may have changed: mark dirty and let
                // the next query reconcile precisely. We deliberately don't parse
                // per-file detail — the reconcile walk is the source of truth.
                self.session.markDirty();
            }
        }
    }
};
