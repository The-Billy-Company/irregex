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
//! Backends: Linux `inotify` (recursive watches, arm-only-on-full-success) and
//! macOS `FSEvents` (one recursive stream over the roots, driven on a private
//! CFRunLoop thread — the OS's native subtree watcher, coalesced at the kernel);
//! every other target uses the reconcile-always baseline. Each backend only ever
//! calls `markDirty`/`armWatcher`, so the barrier and the query path never learn
//! which one armed them — the acceleration is fully behind that two-call seam.

const std = @import("std");
const builtin = @import("builtin");
const haystack = @import("../corpus/haystack.zig");
const ResidentSession = @import("resident.zig").ResidentSession;
const Dir = std.Io.Dir;

const is_macos = builtin.os.tag == .macos;

/// The minimal CoreServices/CoreFoundation surface the macOS FSEvents backend
/// needs — analyzed only on macOS (the `if (is_macos)` guard is comptime, so no
/// other target ever references these externs). FSEvents is a recursive,
/// kernel-coalesced subtree watcher: one stream over the roots reports any
/// change beneath them, which is all the barrier needs (it re-derives the
/// precise changed set with its own metadata walk). Ref-counting note: we
/// build the paths array with the retaining `kCFTypeArrayCallBacks`, so we drop
/// our own string references immediately and the stream copies the list on
/// create. Frameworks are linked in `build.zig` (`CoreServices`+`CoreFoundation`).
const darwin = if (is_macos) struct {
    const Ref = ?*anyopaque;
    const CFIndex = isize;
    const kCFStringEncodingUTF8: u32 = 0x0800_0100;
    const kFSEventStreamEventIdSinceNow: u64 = 0xFFFF_FFFF_FFFF_FFFF;
    // NoDefer: deliver the first event immediately, then coalesce at `latency`.
    const kFSEventStreamCreateFlagNoDefer: u32 = 0x0000_0002;
    // Coalescing window (s): small keeps the read-your-writes stale window tight
    // while still folding a build's event storm into a handful of markDirty calls.
    const latency: f64 = 0.05;

    const Context = extern struct {
        version: CFIndex = 0,
        info: ?*anyopaque = null,
        retain: ?*const anyopaque = null,
        release: ?*const anyopaque = null,
        copy_description: ?*const anyopaque = null,
    };
    const Callback = *const fn (Ref, ?*anyopaque, usize, ?*anyopaque, [*c]const u32, [*c]const u64) callconv(.c) void;

    extern var kCFRunLoopDefaultMode: Ref;
    extern var kCFTypeArrayCallBacks: anyopaque;

    extern fn CFStringCreateWithBytes(Ref, [*]const u8, CFIndex, u32, u8) Ref;
    extern fn CFArrayCreate(Ref, [*]const ?*const anyopaque, CFIndex, ?*const anyopaque) Ref;
    extern fn CFRelease(Ref) void;
    extern fn CFRunLoopGetCurrent() Ref;
    extern fn CFRunLoopRunInMode(Ref, f64, u8) i32;
    extern fn CFRunLoopStop(Ref) void;

    extern fn FSEventStreamCreate(Ref, Callback, ?*const Context, Ref, u64, f64, u32) Ref;
    extern fn FSEventStreamScheduleWithRunLoop(Ref, Ref, Ref) void;
    extern fn FSEventStreamStart(Ref) u8;
    extern fn FSEventStreamStop(Ref) void;
    extern fn FSEventStreamInvalidate(Ref) void;
    extern fn FSEventStreamRelease(Ref) void;
} else struct {};

pub const Watcher = struct {
    session: *ResidentSession,
    io: std.Io,
    gpa: std.mem.Allocator,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),
    inotify_fd: i32 = -1,
    /// macOS: the watch thread's CFRunLoop, published so `stop` can wake it. Null
    /// until the loop thread stores it (before it signals `ready`).
    run_loop: std.atomic.Value(?*anyopaque) = .init(null),
    /// macOS start handshake: 0 pending, 1 stream armed, 2 failed. The loop
    /// thread publishes it once; `startFsevents` polls it to decide whether to
    /// arm the session (kept on the main thread so the plain `watcher_active`
    /// bool the query path reads is never written concurrently).
    start_result: std.atomic.Value(u8) = .init(0),

    pub fn init(gpa: std.mem.Allocator, io: std.Io, session: *ResidentSession) Watcher {
        return .{ .session = session, .io = io, .gpa = gpa };
    }

    /// Best-effort start. Arms the session (enabling the clean fast path) only
    /// when a watcher backend fully registers; otherwise leaves the session in
    /// the reconcile-always baseline and returns without error.
    pub fn start(self: *Watcher) void {
        if (comptime builtin.os.tag == .linux) {
            self.startInotify();
        } else if (comptime is_macos) {
            self.startFsevents();
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
        } else if (comptime is_macos) {
            // Wake the CFRunLoop out of its wait so the loop re-checks `running`
            // and exits promptly instead of idling out its timeout slice.
            if (self.run_loop.load(.acquire)) |rl| darwin.CFRunLoopStop(rl);
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

    // ── macOS FSEvents backend ──

    /// Spawn the CFRunLoop thread and arm the session iff the stream started —
    /// same fail-closed contract as inotify: an unstarted watcher leaves the
    /// session in the reconcile-always baseline (correct, just not fast). The
    /// handshake keeps `armWatcher` on THIS thread so the plain `watcher_active`
    /// bool the query path reads is never written concurrently.
    fn startFsevents(self: *Watcher) void {
        if (comptime !is_macos) return;
        self.thread = std.Thread.spawn(.{}, fseventsLoop, .{self}) catch return;
        // Wait for the loop thread to publish its start result — FSEventStreamStart
        // returns in microseconds, so this bounded spin (a one-time daemon-boot
        // cost) resolves near-instantly; the 2 s deadline only guards a wedged
        // launch, after which we stay unarmed (reconcile-always, still correct).
        const deadline = std.Io.Clock.now(.real, self.io).nanoseconds + 2 * std.time.ns_per_s;
        while (self.start_result.load(.acquire) == 0 and std.Io.Clock.now(.real, self.io).nanoseconds < deadline)
            std.atomic.spinLoopHint();
        if (self.start_result.load(.acquire) == 1) self.session.armWatcher();
    }

    /// Build one recursive FSEvents stream over the roots, run its CFRunLoop
    /// until `stop`, then tear the stream down. Any setup failure publishes
    /// `start_result = 2` and returns unarmed.
    fn fseventsLoop(self: *Watcher) void {
        if (comptime !is_macos) return;
        const fail = struct {
            fn f(w: *Watcher) void {
                w.start_result.store(2, .release);
            }
        }.f;

        const paths = self.buildPathsArray() orelse return fail(self);
        defer darwin.CFRelease(paths);

        // intFromPtr/ptrFromInt keeps the FFI opaque seam free of @ptrCast
        // (zig-safety ratchet — new files are born clean).
        var ctx = darwin.Context{ .info = @ptrFromInt(@intFromPtr(self.session)) };
        const stream = darwin.FSEventStreamCreate(
            null,
            fseventsCallback,
            &ctx,
            paths,
            darwin.kFSEventStreamEventIdSinceNow,
            darwin.latency,
            darwin.kFSEventStreamCreateFlagNoDefer,
        ) orelse return fail(self);
        defer {
            darwin.FSEventStreamStop(stream);
            darwin.FSEventStreamInvalidate(stream);
            darwin.FSEventStreamRelease(stream);
        }

        const rl = darwin.CFRunLoopGetCurrent();
        self.run_loop.store(rl, .release);
        darwin.FSEventStreamScheduleWithRunLoop(stream, rl, darwin.kCFRunLoopDefaultMode);
        if (darwin.FSEventStreamStart(stream) == 0) return fail(self);

        self.running.store(true, .release);
        self.start_result.store(1, .release);

        // Run in bounded slices so `stop` (which also calls CFRunLoopStop to
        // wake us immediately) is observed even if it raced the loop entry —
        // no unstoppable CFRunLoopRun, no CFRunLoopStop/entry ordering hazard.
        while (self.running.load(.acquire))
            _ = darwin.CFRunLoopRunInMode(darwin.kCFRunLoopDefaultMode, 1.0, 0);
    }

    /// Realpath each root into a retaining CFArray of CFStrings (FSEvents wants
    /// absolute paths; the daemon's cwd is the repo root). Returns null on any
    /// allocation/CF failure so the caller stays unarmed. The array retains the
    /// strings, so we release our own references before returning it.
    fn buildPathsArray(self: *Watcher) ?darwin.Ref {
        if (comptime !is_macos) return null;
        const refs = self.gpa.alloc(darwin.Ref, self.session.roots.len) catch return null;
        defer self.gpa.free(refs);

        var made: usize = 0;
        defer for (refs[0..made]) |r| darwin.CFRelease(r);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        for (self.session.roots) |root| {
            const rootz = self.gpa.dupeZ(u8, root) catch return null;
            defer self.gpa.free(rootz);
            const resolved = std.c.realpath(rootz, &buf) orelse return null;
            const abs = std.mem.span(resolved);
            const s = darwin.CFStringCreateWithBytes(null, abs.ptr, @intCast(abs.len), darwin.kCFStringEncodingUTF8, 0) orelse return null;
            refs[made] = s;
            made += 1;
        }
        const items: [*]const ?*const anyopaque = @ptrFromInt(@intFromPtr(refs.ptr));
        return darwin.CFArrayCreate(null, items, @intCast(made), &darwin.kCFTypeArrayCallBacks);
    }

    /// FSEvents delivers here on any change under the roots. We don't inspect the
    /// paths/flags — an event (including a coalesced drop, which sets an overflow
    /// flag) only means "reconcile next query"; the barrier's own metadata walk
    /// re-derives the exact changed set. `markDirty` is lock-free, callable from
    /// this CFRunLoop thread.
    fn fseventsCallback(_: darwin.Ref, info: ?*anyopaque, _: usize, _: ?*anyopaque, _: [*c]const u32, _: [*c]const u64) callconv(.c) void {
        if (info) |p| {
            const session: *ResidentSession = @ptrFromInt(@intFromPtr(p));
            session.markDirty();
        }
    }
};
