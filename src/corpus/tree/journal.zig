//! irregex — the filesystem change journal (macOS FSEvents historical replay).
//!
//! The T3 freshness stat walk is at its syscall floor: ~23k directories of
//! `getattrlistbulk` cost ~100 ms wall no matter how parallel the pool is
//! (measured on this corpus — `fresh.zig`'s walk at 620% CPU). The OS already
//! keeps the answer: fseventsd journals every vnode change to disk, and an
//! FSEventStream created with `sinceWhen = <persisted event id>` replays
//! exactly the paths that changed since that instant — the same since-token
//! design watchman rides. This module is the one-shot replay: capture a token
//! (global event id + device) at full-build time, persist it beside the pair,
//! and at amend time ask the journal for everything since — milliseconds
//! instead of a whole-tree walk.
//!
//! PURE ACCELERATOR, NEVER A CORRECTNESS DEPENDENCY (the exact posture of the
//! resident watcher in `surface/exec/session/watch.zig`, whose dlopen'd
//! framework surface this mirrors — runtime `dlopen`, never link-time, so the
//! cold search binary keeps zero framework load commands). Every uncertainty
//! degrades to "journal can't answer" and the caller runs the proven walk:
//!   • non-macOS target, missing framework/symbol, stream-create/start failure;
//!   • a token minted on a DIFFERENT device (the repo moved volumes);
//!   • any event flagged MustScanSubDirs / kernel-or-user drop / id-wrap /
//!     root-change / mount churn — the paths are not an exact account;
//!   • an event record missing its Item kind bits (pre-FileEvents journal era);
//!   • replay deadline exceeded, or an event flood past the cap (a base so old
//!     the walk is cheaper anyway).
//!
//! Deliveries are ABSOLUTE paths; `replay` maps them back under the caller's
//! roots (including the `/System/Volumes/Data` firmlink alias macOS journals
//! under) and returns repo-relative entries tagged file/dir. Vanished paths
//! (deletes, rename-away) still surface — the one signal the stat walk is
//! structurally blind to.

const std = @import("std");
const builtin = @import("builtin");
const haystack = @import("haystack.zig");

pub const supported = builtin.os.tag == .macos;

/// The persisted token file (a top-level artifact beside `built.ns`).
pub const file_name = "journal.tok";
const magic = "GISTJRN1";
pub const encoded_len = 32; // magic(8) + event_id u64 + dev u64 + captured_ns i64

/// Replay budget: a journal answer must stay decisively cheaper than the
/// ~100 ms walk it replaces, and an event flood means the base is so stale
/// the walk wins anyway.
const deadline_ns: i128 = 500 * std.time.ns_per_ms;
const max_events: usize = 1 << 17;

pub const Token = struct {
    event_id: u64,
    dev: u64,
    /// The wall instant the id was minted. A replay from this token covers
    /// every change in (captured_ns, now); a caller asking "changed since S"
    /// may use it only when `captured_ns <= S` (an older token over-covers —
    /// sound; a newer one has a blind window — never).
    captured_ns: i128,
};

/// One replayed change, root-relative under the caller's roots.
pub const Entry = struct { path: []const u8, is_dir: bool };

/// Mint a token for THIS instant: the global FSEvents id + the device the
/// corpus lives on. Null ⇒ the platform/journal can't back a replay.
pub fn capture(io: std.Io) ?Token {
    if (comptime !supported) return null;
    const s = Syms.get() orelse return null;
    return .{
        .event_id = s.FSEventsGetCurrentEventId(),
        .dev = cwdDev() orelse return null,
        .captured_ns = std.Io.Clock.now(.real, io).nanoseconds,
    };
}

pub fn encode(t: Token) [encoded_len]u8 {
    var buf: [encoded_len]u8 = undefined;
    @memcpy(buf[0..8], magic);
    std.mem.writeInt(u64, buf[8..16], t.event_id, .little);
    std.mem.writeInt(u64, buf[16..24], t.dev, .little);
    std.mem.writeInt(i64, buf[24..32], @intCast(t.captured_ns), .little);
    return buf;
}

pub fn decode(bytes: []const u8) ?Token {
    if (bytes.len < encoded_len or !std.mem.eql(u8, bytes[0..8], magic)) return null;
    return .{
        .event_id = std.mem.readInt(u64, bytes[8..16], .little),
        .dev = std.mem.readInt(u64, bytes[16..24], .little),
        .captured_ns = std.mem.readInt(i64, bytes[24..32], .little),
    };
}

// ── FSEvents event-flag ABI (<FSEvents.h>) ──
const flag_must_scan: u32 = 0x00000001;
const flag_user_dropped: u32 = 0x00000002;
const flag_kernel_dropped: u32 = 0x00000004;
const flag_ids_wrapped: u32 = 0x00000008;
const flag_history_done: u32 = 0x00000010;
const flag_root_changed: u32 = 0x00000020;
const flag_mount: u32 = 0x00000040;
const flag_unmount: u32 = 0x00000080;
const flag_item_is_file: u32 = 0x00010000;
const flag_item_is_dir: u32 = 0x00020000;
const flag_item_is_symlink: u32 = 0x00040000;
const flag_item_is_hardlink: u32 = 0x00100000;
/// Any of these ⇒ the delivered paths are NOT an exact account of the window.
const doubt_flags: u32 = flag_must_scan | flag_user_dropped | flag_kernel_dropped |
    flag_ids_wrapped | flag_root_changed | flag_mount | flag_unmount;

const kCFStringEncodingUTF8: u32 = 0x0800_0100;
const kFSEventStreamCreateFlagNoDefer: u32 = 0x0000_0002;
const kFSEventStreamCreateFlagFileEvents: u32 = 0x0000_0010;
/// The Data-volume firmlink prefix the journal records user paths under.
const data_volume_prefix = "/System/Volumes/Data";

const Ref = ?*anyopaque;
const CFIndex = isize;
const FsCallback = *const fn (Ref, ?*anyopaque, usize, ?[*]const [*:0]const u8, [*]const u32, [*]const u64) callconv(.c) void;

const CFContext = extern struct {
    version: CFIndex = 0,
    info: ?*anyopaque = null,
    retain: ?*const anyopaque = null,
    release: ?*const anyopaque = null,
    copy_description: ?*const anyopaque = null,
};

/// The dlopen'd CoreFoundation + CoreServices entry points — the one-shot
/// twin of the resident watcher's `Syms` (`surface/exec/session/watch.zig`);
/// duplicated here because the tree layer must not import the surface layer.
const Syms = struct {
    cf: std.DynLib,
    cs: std.DynLib,
    CFStringCreateWithBytes: *const fn (Ref, [*]const u8, CFIndex, u32, u8) callconv(.c) Ref,
    CFArrayCreate: *const fn (Ref, [*]const Ref, CFIndex, ?*const anyopaque) callconv(.c) Ref,
    CFRelease: *const fn (Ref) callconv(.c) void,
    CFRunLoopGetCurrent: *const fn () callconv(.c) Ref,
    CFRunLoopRunInMode: *const fn (Ref, f64, u8) callconv(.c) i32,
    FSEventsGetCurrentEventId: *const fn () callconv(.c) u64,
    FSEventStreamCreate: *const fn (Ref, FsCallback, ?*const CFContext, Ref, u64, f64, u32) callconv(.c) Ref,
    FSEventStreamFlushSync: *const fn (Ref) callconv(.c) void,
    FSEventStreamSetExclusionPaths: *const fn (Ref, Ref) callconv(.c) u8,
    FSEventStreamScheduleWithRunLoop: *const fn (Ref, Ref, Ref) callconv(.c) void,
    FSEventStreamStart: *const fn (Ref) callconv(.c) u8,
    FSEventStreamStop: *const fn (Ref) callconv(.c) void,
    FSEventStreamInvalidate: *const fn (Ref) callconv(.c) void,
    FSEventStreamRelease: *const fn (Ref) callconv(.c) void,
    run_loop_default_mode: Ref,
    array_callbacks: ?*const anyopaque,

    const cf_path = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation";
    const cs_path = "/System/Library/Frameworks/CoreServices.framework/CoreServices";

    /// Process-lifetime cache: `dlopen` of CoreServices costs ~1–3 ms (dyld +
    /// CF initializers) and an amend calls into the journal twice (capture +
    /// replay) — bind once, never close (the OS reclaims at exit; the resident
    /// daemon legitimately keeps them for its own watcher anyway). Same
    /// spinlock-once idiom as `haystack.extra_skips`.
    const cache = struct {
        var locked: std.atomic.Value(bool) = .init(false);
        var done: std.atomic.Value(bool) = .init(false);
        var syms: ?Syms = null;
    };

    fn get() ?*Syms {
        if (!cache.done.load(.acquire)) {
            while (cache.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
            defer cache.locked.store(false, .release);
            if (!cache.done.load(.acquire)) {
                cache.syms = load();
                cache.done.store(true, .release);
            }
        }
        return if (cache.syms) |*s| s else null;
    }

    fn load() ?Syms {
        if (comptime !supported) return null;
        var cf = std.DynLib.open(cf_path) catch return null;
        var cs = std.DynLib.open(cs_path) catch {
            cf.close();
            return null;
        };
        var s: Syms = undefined;
        s.cf = cf;
        s.cs = cs;
        s.CFStringCreateWithBytes = cf.lookup(@TypeOf(s.CFStringCreateWithBytes), "CFStringCreateWithBytes") orelse return s.fail();
        s.CFArrayCreate = cf.lookup(@TypeOf(s.CFArrayCreate), "CFArrayCreate") orelse return s.fail();
        s.CFRelease = cf.lookup(@TypeOf(s.CFRelease), "CFRelease") orelse return s.fail();
        s.CFRunLoopGetCurrent = cf.lookup(@TypeOf(s.CFRunLoopGetCurrent), "CFRunLoopGetCurrent") orelse return s.fail();
        s.CFRunLoopRunInMode = cf.lookup(@TypeOf(s.CFRunLoopRunInMode), "CFRunLoopRunInMode") orelse return s.fail();
        s.run_loop_default_mode = (cf.lookup(*Ref, "kCFRunLoopDefaultMode") orelse return s.fail()).*;
        s.array_callbacks = cf.lookup(*const anyopaque, "kCFTypeArrayCallBacks") orelse return s.fail();
        s.FSEventsGetCurrentEventId = cs.lookup(@TypeOf(s.FSEventsGetCurrentEventId), "FSEventsGetCurrentEventId") orelse return s.fail();
        s.FSEventStreamCreate = cs.lookup(@TypeOf(s.FSEventStreamCreate), "FSEventStreamCreate") orelse return s.fail();
        s.FSEventStreamFlushSync = cs.lookup(@TypeOf(s.FSEventStreamFlushSync), "FSEventStreamFlushSync") orelse return s.fail();
        s.FSEventStreamSetExclusionPaths = cs.lookup(@TypeOf(s.FSEventStreamSetExclusionPaths), "FSEventStreamSetExclusionPaths") orelse return s.fail();
        s.FSEventStreamScheduleWithRunLoop = cs.lookup(@TypeOf(s.FSEventStreamScheduleWithRunLoop), "FSEventStreamScheduleWithRunLoop") orelse return s.fail();
        s.FSEventStreamStart = cs.lookup(@TypeOf(s.FSEventStreamStart), "FSEventStreamStart") orelse return s.fail();
        s.FSEventStreamStop = cs.lookup(@TypeOf(s.FSEventStreamStop), "FSEventStreamStop") orelse return s.fail();
        s.FSEventStreamInvalidate = cs.lookup(@TypeOf(s.FSEventStreamInvalidate), "FSEventStreamInvalidate") orelse return s.fail();
        s.FSEventStreamRelease = cs.lookup(@TypeOf(s.FSEventStreamRelease), "FSEventStreamRelease") orelse return s.fail();
        return s;
    }

    fn fail(s: *Syms) ?Syms {
        s.close();
        return null;
    }

    fn close(s: *Syms) void {
        s.cf.close();
        s.cs.close();
    }
};

fn tracePhase(io: std.Io, name: []const u8, tlast: i128) i128 {
    const now = std.Io.Clock.now(.awake, io).nanoseconds;
    std.debug.print("journal: {s} {d:.1} ms\n", .{ name, @as(f64, @floatFromInt(now - tlast)) / 1e6 });
    return now;
}

fn cwdDev() ?u64 {
    var st: std.posix.Stat = undefined;
    if (std.c.fstatat(std.posix.AT.FDCWD, ".", &st, 0) != 0) return null;
    return @bitCast(@as(i64, st.dev));
}

/// A resolved root: the relative name the corpus uses + the absolute
/// realpath(s) journal deliveries may carry for it.
const RootPrefix = struct {
    rel: []const u8,
    abs: []const u8, // a-owned
};

const Ctx = struct {
    a: std.mem.Allocator,
    raw: std.ArrayList(Entry) = .empty, // abs paths during collection
    doubt: bool = false,
    done: bool = false,
};

fn onEvents(_: Ref, info: ?*anyopaque, num_events: usize, event_paths: ?[*]const [*:0]const u8, event_flags: [*]const u32, _: [*]const u64) callconv(.c) void {
    const ctx: *Ctx = @ptrCast(@alignCast(info orelse return));
    const paths = event_paths orelse {
        ctx.doubt = true;
        return;
    };
    for (0..num_events) |i| {
        const flags = event_flags[i];
        if (flags & flag_history_done != 0) {
            ctx.done = true;
            continue;
        }
        if (flags & doubt_flags != 0) {
            ctx.doubt = true;
            continue;
        }
        if (ctx.raw.items.len >= max_events) {
            ctx.doubt = true; // flood — the walk is the cheaper answer now
            continue;
        }
        // Symlinks/specials: the corpus walk never follows them. A record with
        // NO item-kind bits predates per-file journaling — not an exact account.
        const is_dir = flags & flag_item_is_dir != 0;
        const is_file = flags & (flag_item_is_file | flag_item_is_hardlink) != 0;
        if (!is_dir and !is_file) {
            if (flags & flag_item_is_symlink == 0) ctx.doubt = true;
            continue;
        }
        const abs = std.mem.span(paths[i]);
        const owned = ctx.a.dupe(u8, abs) catch {
            ctx.doubt = true;
            continue;
        };
        ctx.raw.append(ctx.a, .{ .path = owned, .is_dir = is_dir }) catch {
            ctx.doubt = true;
            continue;
        };
    }
}

/// Strip a delivered absolute path down to `root`-relative form, accepting
/// both the realpath spelling and its `/System/Volumes/Data` firmlink alias.
/// Null when the path is not under this root.
fn relativize(a: std.mem.Allocator, rp: RootPrefix, abs: []const u8) !?[]const u8 {
    var rest: ?[]const u8 = null;
    if (std.mem.startsWith(u8, abs, rp.abs)) {
        rest = abs[rp.abs.len..];
    } else if (std.mem.startsWith(u8, abs, data_volume_prefix) and
        std.mem.startsWith(u8, abs[data_volume_prefix.len..], rp.abs))
    {
        rest = abs[data_volume_prefix.len + rp.abs.len ..];
    }
    const r = rest orelse return null;
    if (r.len == 0) return try a.dupe(u8, rp.rel);
    if (r[0] != '/') return null; // prefix ended mid-component (e.g. /repo2 vs /repo)
    return try haystack.joinRoot(a, rp.rel, r[1..]);
}

/// Replay every journaled change under `roots` since `token` into `out`
/// (repo-relative, file/dir tagged, strings owned by `a`). False ⇒ the
/// journal cannot give an exact account — run the stat walk instead.
pub fn replay(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, token: Token, a: std.mem.Allocator, out: *std.ArrayList(Entry)) bool {
    if (comptime !supported) return false;
    if (roots.len == 0) return false;
    const trace = std.c.getenv("GIST_JOURNAL_TRACE") != null;
    var tlast: i128 = std.Io.Clock.now(.awake, io).nanoseconds;
    const dev = cwdDev() orelse return false;
    if (dev != token.dev) return false; // the corpus moved volumes — foreign id space

    const s = Syms.get() orelse return false;
    if (trace) tlast = tracePhase(io, "dlopen", tlast);

    // Resolve each root to the absolute prefix deliveries are keyed under.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    const prefixes = aa.alloc(RootPrefix, roots.len) catch return false;
    var pathbuf: [std.fs.max_path_bytes]u8 = undefined;
    for (roots, prefixes) |root, *rp| {
        const rootz = aa.dupeZ(u8, root) catch return false;
        const resolved = std.c.realpath(rootz, &pathbuf) orelse return false;
        rp.* = .{ .rel = root, .abs = aa.dupe(u8, std.mem.span(resolved)) catch return false };
    }

    // The watched-paths CFArray (the array retains; drop our refs after).
    const refs = aa.alloc(Ref, roots.len) catch return false;
    var made: usize = 0;
    defer for (refs[0..made]) |r| s.CFRelease(r);
    for (prefixes) |rp| {
        refs[made] = s.CFStringCreateWithBytes(null, rp.abs.ptr, @intCast(rp.abs.len), kCFStringEncodingUTF8, 0) orelse return false;
        made += 1;
    }
    const paths_arr = s.CFArrayCreate(null, refs.ptr, @intCast(made), s.array_callbacks) orelse return false;
    defer s.CFRelease(paths_arr);

    var ctx = Ctx{ .a = aa };
    var cfctx = CFContext{ .info = @ptrCast(&ctx) };
    const stream = s.FSEventStreamCreate(
        null,
        onEvents,
        &cfctx,
        paths_arr,
        token.event_id,
        0.0, // historical replay: no coalescing latency
        kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents,
    ) orelse return false;
    defer {
        s.FSEventStreamStop(stream);
        s.FSEventStreamInvalidate(stream);
        s.FSEventStreamRelease(stream);
    }

    // Exclude the heaviest known churners at the daemon (≤ 8 paths — the
    // kernel-side cousin of `haystack.isSkipDir`; everything else the skip
    // filter below still drops in-process). Best-effort: a refusal only
    // costs replay volume, never exactness.
    excludeNoise(s, stream, prefixes, aa);

    if (trace) tlast = tracePhase(io, "create", tlast);
    const rl = s.CFRunLoopGetCurrent();
    s.FSEventStreamScheduleWithRunLoop(stream, rl, s.run_loop_default_mode);
    if (s.FSEventStreamStart(stream) == 0) return false;
    if (trace) tlast = tracePhase(io, "start", tlast);
    // Force the daemon to push everything it owes us NOW instead of on its
    // own batching cadence — FlushSync blocks until the callback has seen
    // every event up to the flush point (historical replay included).
    if (std.c.getenv("GIST_JOURNAL_NOFLUSH") == null) s.FSEventStreamFlushSync(stream);
    if (trace) tlast = tracePhase(io, "flush", tlast);

    // Drain until the HistoryDone sentinel: replay is delivered on THIS
    // run loop, so bounded slices observe it promptly; a wedged daemon
    // hits the deadline and the caller walks.
    const deadline = std.Io.Clock.now(.real, io).nanoseconds + deadline_ns;
    while (!ctx.done and !ctx.doubt) {
        if (std.Io.Clock.now(.real, io).nanoseconds > deadline) return false;
        _ = s.CFRunLoopRunInMode(s.run_loop_default_mode, 0.05, 1);
    }
    if (trace) tlast = tracePhase(io, "drain", tlast);
    if (ctx.doubt) return false;

    // Map deliveries back under the roots. A path under none of them is a
    // stale pre-exclusion record for a subtree we don't index — droppable
    // only because the stream was CREATED over exactly these roots; anything
    // else delivered here is the OS disagreeing with us, which is doubt.
    for (ctx.raw.items) |e| {
        var matched = false;
        for (prefixes) |rp| {
            const rel = relativize(a, rp, e.path) catch return false;
            if (rel) |r| {
                out.append(a, .{ .path = r, .is_dir = e.is_dir }) catch return false;
                matched = true;
                break;
            }
        }
        if (!matched) return false;
    }
    return true;
}

/// Kernel-side exclusion of the noisiest non-corpus subtrees (VCS, machine-
/// local scratch, build caches at the root). `setExclusionPaths` caps at 8.
fn excludeNoise(s: *Syms, stream: Ref, prefixes: []const RootPrefix, aa: std.mem.Allocator) void {
    const noisy = [_][]const u8{ ".git", ".local", ".zig-cache", "zig-out", "node_modules", ".etc", "graphify-out", ".cursor" };
    var refs: [8]Ref = undefined;
    var made: usize = 0;
    defer for (refs[0..made]) |r| s.CFRelease(r);
    const base = prefixes[0].abs;
    for (noisy) |n| {
        if (made == refs.len) break;
        const abs = std.fmt.allocPrint(aa, "{s}/{s}", .{ base, n }) catch return;
        refs[made] = s.CFStringCreateWithBytes(null, abs.ptr, @intCast(abs.len), kCFStringEncodingUTF8, 0) orelse return;
        made += 1;
    }
    const arr = s.CFArrayCreate(null, &refs, @intCast(made), s.array_callbacks) orelse return;
    defer s.CFRelease(arr);
    _ = s.FSEventStreamSetExclusionPaths(stream, arr);
}
