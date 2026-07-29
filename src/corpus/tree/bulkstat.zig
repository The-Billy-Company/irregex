//! irregex — batched directory metadata, the platform-correct answer to the
//! freshness overlay's dominant cold-query cost (see `fresh.zig`'s doc comment and
//! the README's "make the freshness walk incremental" next rung). That rung's own
//! text pointed at `io_uring` batching — a Linux-only API that doesn't exist on
//! this box (Darwin/Apple Silicon, confirmed via `uname`/`sysctl`). The portable
//! form of "stop paying one syscall per file" is whatever batched-enumeration call
//! the host actually has, and gathering one is [`sheaf.zig`](sheaf.zig)'s whole
//! job: `getattrlistbulk(2)` on Darwin, `getdents64(2)` on Linux,
//! `NtQueryDirectoryFile` on Windows. Unlike `readdir()` + `stat()` per entry
//! (2 syscalls/file), one bulk call returns name + type + mtime + ctime for many
//! siblings at once — Apple's own filesystem-dev list documents 4–50× fewer
//! syscalls (readdir vs getdirentriesattr thread, Dec 2014; independently
//! reproduced: ~1,600× fewer syscalls, ~4-5× faster on a warm NVMe SSD,
//! quivent/getattrlistbulk-rs, 2025 benchmark on M1).
//! `pkg/kernels/irregex/changelog.d/+bulkstat-freshness.changed.md` cites the
//! measurement on THIS corpus.
//!
//! This file owns the *policy*: which entries a freshness walk cares about, how a
//! declined batch degrades, and how a listing is handed to a caller that must
//! outlive the batch buffer. The syscalls themselves live next door, so that the
//! rule "uncertain metadata forces a live read" has one statement rather than one
//! per platform.
//!
//! Why hand-rolled instead of `mmap`-ing files or another IO trick: the freshness
//! walk never reads file *bytes* — it only needs each file's change timestamps, so
//! the lever is metadata syscalls, not data IO. (Candidate file *reads* are a
//! different, already-solved problem: ripgrep's own author documents why `mmap` is
//! a net loss for "open many small files" — open+mmap+munmap has a *higher* fixed
//! cost per file than open+read+close on typical source-sized files — which is
//! exactly why `emit.zig`/`drivers.zig` already use blocking `read()`, not `mmap`;
//! this module doesn't touch that path at all.)
//!
//! FAIL-SOFT, NEVER FAIL-OPEN: a bulk call failing on some directory (an unusual
//! mount, a permissions edge, or simply a filesystem that doesn't implement it)
//! falls back to the proven stat-based walk for *that* subtree only. Under
//! `README.md`'s local-filesystem model, uncertain bulk metadata therefore loses
//! speed rather than weakening the conservative live-read decision.

const std = @import("std");
const fault = @import("../../fault.zig");
const haystack = @import("haystack.zig");
const sheaf = @import("sheaf.zig");
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;

/// Whether this target batches names + kinds + both change clocks in one call —
/// the fact that lets a walk elide unchanged indexed files inline. Checked once,
/// not per directory; every other target statically falls back to the caller's
/// stat-based walk.
pub const supported = sheaf.supported;

/// Whether `listNamesOnly` — the cheaper names+kinds drain, no metadata — has a
/// raw batched implementation on this target. Broader than `supported`, because
/// Linux's `getdents64(2)` enumerates without resolving attributes.
///
/// The two facts are separate constants because they fail differently. A target
/// outside `supported` still has correct freshness (it stats); a target outside
/// this one cannot enumerate a directory here at all, which is why
/// `phantom/treemap.zig` refuses to publish a snapshot there rather than recording
/// every directory as childless.
pub const names_supported = sheaf.names_supported;

/// Whether `listNamesOnly` actually *undercuts* this platform's `Dir.Iterator`,
/// which is what a caller wanting names alone should ask instead of
/// `names_supported`. See the sheaf's own declaration: on Windows the portable
/// iterator is already the batched syscall, so only a caller that wants metadata
/// (or an owned listing) gains anything there.
pub const names_undercut_iterator = sheaf.names_undercut_iterator;

/// One directory entry's freshness metadata, one bulk call away instead of one
/// `stat()` syscall away. `name` aliases the iterator's internal buffer — valid
/// only until the next `next()` call (mirrors `haystack.Haystack`).
pub const Entry = sheaf.Entry;

/// The batched metadata drain for this platform. Historically the Darwin
/// `getattrlistbulk` iterator and still that on Darwin; on Windows the same shape
/// over `NtQueryDirectoryFile`.
pub const BulkDir = sheaf.Sheaf;

/// Only metadata strictly older than the build anchor proves an indexed file
/// unchanged. Either timestamp at/after the anchor, or either one unavailable,
/// forces a live read. `>=` intentionally keeps same-tick/coarse-clock boundary
/// values conservative.
pub fn needsLiveRead(anchor_ns: i128, mtime_ns: ?i128, ctime_ns: ?i128) bool {
    const mtime = mtime_ns orelse return true;
    const ctime = ctime_ns orelse return true;
    return mtime >= anchor_ns or ctime >= anchor_ns;
}

/// Recursively collect every file under `dir` (relative path `prefix`) whose mtime
/// or ctime is `>= built_ns` (or metadata is unavailable), applying the shared
/// `haystack.isSkipDir` policy — the bulk-enumeration twin of `fresh.zig`'s
/// portable per-file-`statFile` walk.
/// Degrades directory-by-directory: a bulk failure on one directory falls back to
/// `fallbackWalk` (the proven stat-based path) for that subtree only, preserving
/// the same metadata rule.
pub fn visitFresh(a: Allocator, io: std.Io, dir: Dir, prefix: []const u8, built_ns: i128, out: *std.ArrayList([]const u8)) void {
    var bd = BulkDir.init(dir.handle);
    while (true) {
        const entry = bd.next() catch {
            fallbackWalk(a, io, prefix, built_ns, out);
            return;
        } orelse break;
        if (entry.is_dir) {
            if (haystack.isSkipDir(entry.name)) continue;
            var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
            defer sub.close(io);
            const sub_prefix = haystack.joinRoot(a, prefix, entry.name) catch return;
            visitFresh(a, io, sub, sub_prefix, built_ns, out);
            continue;
        }
        if (!entry.is_file) continue; // symlinks/etc — never followed, matches haystack.Walker
        if (!needsLiveRead(built_ns, entry.mtime_ns, entry.ctime_ns)) continue;
        const full = haystack.joinRoot(a, prefix, entry.name) catch return;
        out.append(a, full) catch return;
    }
}

/// One directory entry, name durably owned (`gpa`-allocated) rather than aliasing
/// the drain's reused scratch buffer — for callers that must hold entries past the
/// next `next()` call, i.e. the two `list*` drains below.
pub const OwnedEntry = struct {
    name: []u8,
    is_dir: bool,
    is_file: bool,
    mtime_ns: ?i128,
    ctime_ns: ?i128,
};

/// Fully drains ONE level of `dirfd` **with** per-entry metadata, duping every
/// name into `gpa` up front. All-or-nothing: any parse/syscall failure partway
/// discards what's been collected and declines rather than handing back a
/// truncated listing — the caller re-opens a fresh handle and retries with the
/// portable `Dir.Iterator`, never mixes a partial bulk result with a partial
/// iterate one (which could double- or under-count an entry).
///
/// The module boundary (ADR-373 law 1): a declinature crosses in the SUCCESS
/// position, so a caller cannot `try` its way past the fallback, while
/// `OutOfMemory` stays in the error channel where it belongs.
pub fn listOneLevel(gpa: Allocator, dirfd: std.posix.fd_t) error{OutOfMemory}!fault.Answer([]OwnedEntry) {
    var drain = BulkDir.init(dirfd);
    return collect(gpa, &drain);
}

/// Fully drains ONE level of `dirfd` via the platform's raw batched readdir —
/// names + kinds only, no timestamps on the platforms where those cost extra. When
/// the caller doesn't need per-entry metadata (the parallel walk without index
/// elision), this is strictly cheaper than `listOneLevel` on POSIX:
/// `getattrlistbulk` makes the kernel resolve and pack attributes per entry, while
/// this is the same thin readdir path ripgrep rides. Gated on `names_supported`,
/// NOT on `supported`: Darwin rides `getdirentries(2)` and Linux `getdents64(2)`.
///
/// On Windows the two are one call, so the timestamps arrive here too rather than
/// being suppressed to imitate a saving that platform does not have.
///
/// Same boundary contract as `listOneLevel`: declining is a value, OOM is an error.
pub fn listNamesOnly(gpa: Allocator, dirfd: std.posix.fd_t) error{OutOfMemory}!fault.Answer([]OwnedEntry) {
    if (comptime !names_supported) return .{ .declined = .capability_missing };
    var drain = sheaf.Names.init(dirfd);
    return collect(gpa, &drain);
}

/// Drain an iterator into an owned listing, or decline having freed everything it
/// had already taken. Shared by both drains so the all-or-nothing promise has one
/// implementation rather than an `errdefer` that no longer fires once the failure
/// became a success-position value.
fn collect(gpa: Allocator, drain: anytype) error{OutOfMemory}!fault.Answer([]OwnedEntry) {
    var list: std.ArrayList(OwnedEntry) = .empty;
    errdefer {
        for (list.items) |e| gpa.free(e.name);
        list.deinit(gpa);
    }
    while (true) {
        const entry = drain.next() catch {
            for (list.items) |e| gpa.free(e.name);
            list.deinit(gpa);
            return .{ .declined = .capability_missing };
        } orelse break;
        try list.append(gpa, .{
            .name = try gpa.dupe(u8, entry.name),
            .is_dir = entry.is_dir,
            .is_file = entry.is_file,
            .mtime_ns = entry.mtime_ns,
            .ctime_ns = entry.ctime_ns,
        });
    }
    return .{ .got = try list.toOwnedSlice(gpa) };
}

/// The pre-bulkstat walk (readdir + `statFile` per entry), scoped to one subtree —
/// reused verbatim as `visitFresh`'s degrade path so a bulk-call failure can only
/// fall back to previously-proven-correct behavior.
/// `pub` because `fresh.zig::visitItem` is the same walk on a target without a
/// metadata batch — one definition, so the two paths cannot drift (§Boilerplate).
pub fn fallbackWalk(a: Allocator, io: std.Io, root_path: []const u8, built_ns: i128, out: *std.ArrayList([]const u8)) void {
    var w = haystack.Walker.init(io, a, root_path) catch return;
    defer w.deinit(io);
    while (w.next(io) catch return) |hay| {
        const st = hay.dir.statFile(io, hay.name, .{}) catch {
            out.append(a, hay.path) catch return;
            continue;
        };
        if (!needsLiveRead(built_ns, st.mtime.nanoseconds, st.ctime.nanoseconds)) continue;
        out.append(a, hay.path) catch return;
    }
}
