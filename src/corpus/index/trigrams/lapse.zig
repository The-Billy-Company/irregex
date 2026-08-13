//! lapse — the retention half of generation-atomic publish.
//!
//! Every index build stages a new `gens/<id>/` and flips `pair.gen` to it
//! (`persist.zig`). Nothing ever retired the generation it replaced, so a tree
//! that re-indexes routinely accumulated one directory per invocation — 276 of
//! them, 8.7 GiB, on this repo, against a 208 MiB corpus. Publish minted
//! history; nobody spent it.
//!
//! A superseded generation has no heir, which is what makes retiring it safe
//! rather than merely tidy: generations are self-contained by construction.
//! `publishCodicil` hardlinks the base blobs FORWARD into each new directory
//! instead of pointing at them in place, so no generation is reachable from
//! another and `loadAt` resolves every blob it needs inside the one directory
//! `pair.gen` names. Removing an older sibling cannot make the live pair
//! incomplete.
//!
//! Retiring is still a delete inside a directory that other processes publish
//! into concurrently (~10 agents share this tree), so eligibility is fenced
//! four independent ways — any ONE of which alone keeps a directory:
//!
//!   • the PUBLISHED generation is never a candidate;
//!   • nor is any id at or above it: a builder mints its id *before* it
//!     stages, so a higher id is someone's build in flight, or a publish this
//!     process has not observed yet;
//!   • nor is any id younger than `grace`. An id IS a wall-clock nanosecond
//!     stamp, so it dates its own directory with no `stat`, and this covers
//!     the one case ordering misses — a build that minted an id, lost the
//!     publish race, and is still writing beneath it;
//!   • nor are the `keep` most recent survivors below that line, so a reader
//!     that resolved `pair.gen` an instant before the flip still finds the
//!     directory it is about to map.
//!
//! Correctness never rested on any of them. POSIX keeps an unlinked inode
//! alive for anyone holding it open or mapped; a reader that loses the race
//! maps nothing and answers by live scan; and `loadAt`'s seqlock recheck
//! already rejects a generation that moved mid-load. The fences buy *tier*,
//! not truth — which is why the whole pass is best-effort and a failed removal
//! is spared rather than propagated into a build.
//!
//! Bounded by design: at most `max_batch` directories go per publish, and the
//! survivor window is a fixed array, so retention allocates nothing and can
//! never turn a 2-second index build into a long stall clearing a backlog. A
//! deeper backlog simply drains over the next few publishes.

const std = @import("std");
const assay = @import("../../../assay/assay.zig");
const fault = @import("../../../fault.zig");
const Dir = std.Io.Dir;

/// Ceiling on `Policy.keep` — the survivor window is a fixed array.
const max_keep = 16;

/// Directories retired per publish. Caps the worst-case pause a publish can
/// inherit from a backlog; the remainder lapses on the next one.
const max_batch = 64;

/// How much superseded history survives a publish.
pub const Policy = struct {
    /// Generations kept below the published one, newest first. Zero is legal
    /// and only narrows the window a racing reader has to map what it already
    /// resolved.
    keep: usize = 2,
    /// No generation younger than this lapses, whatever its rank.
    grace_ns: u64 = 10 * std.time.ns_per_min,

    /// The policy this process runs — `<prefix>KEEP_GENS` overrides `keep`, the
    /// one knob worth exposing (raise it on a box where several checkouts of
    /// the same tree share an artifact directory; 0 to keep only the live
    /// generation). An unparseable value leaves the default standing.
    pub fn tuned() Policy {
        var p: Policy = .{};
        if (assay.knob("KEEP_GENS")) |v| {
            if (std.fmt.parseInt(usize, v, 10) catch null) |n| p.keep = @min(n, max_keep);
        }
        return p;
    }
};

/// What one pass did. `retired` counts directories removed, `kept` the
/// candidates a fence spared. Neither counts an entry whose name is not a
/// generation id this package could have minted — those are invisible here
/// because they are never candidates.
pub const Report = struct {
    retired: usize = 0,
    kept: usize = 0,
};

/// Retire the generations `live` superseded, under the process policy.
/// `gens_dir` is the directory holding `<id>/` children; `live` is the id
/// `pair.gen` now names. Best-effort and total: every failure — an
/// unparseable id, an unopenable directory, a removal that loses a race —
/// leaves the tree exactly as it was and reports what did happen.
pub fn reclaim(io: std.Io, gens_dir: []const u8, live: []const u8) Report {
    return reclaimWith(io, gens_dir, live, .tuned());
}

/// `reclaim` under an explicit policy — the seam tests drive (a zero `grace_ns`
/// makes eligibility depend only on ordering, so a fixture need not sleep).
pub fn reclaimWith(io: std.Io, gens_dir: []const u8, live: []const u8, policy: Policy) Report {
    var report: Report = .{};
    // An id we cannot read is an id we cannot reason about: retire nothing.
    const live_id = parseGen(live) orelse return report;

    // The two ordering fences collapse into one line. "At or above the
    // published id" and "younger than grace" are both "id >= X" for some X, so
    // the stricter of the two is the only threshold that matters, and every
    // candidate is simply an id strictly below it.
    const now: u64 = @truncate(@as(u128, @intCast(std.Io.Clock.now(.real, io).nanoseconds)));
    const threshold = @min(live_id, now -| policy.grace_ns);

    var dir = Dir.cwd().openDir(io, gens_dir, .{ .iterate = true }) catch return report;
    defer dir.close(io);

    // One pass. The survivor window keeps the `keep` highest ids it has seen;
    // whatever it declines or displaces is, by construction, eligible — so the
    // victims fall out of the same walk that ranks the survivors, with no
    // second listing and no name buffer.
    var window: Window = .{ .cap = @min(policy.keep, max_keep) };
    var victims: [max_batch]u64 = undefined;
    var n: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const id = parseGen(entry.name) orelse continue;
        if (id >= threshold) continue; // fenced: published, newer, or too young
        const lapsed = window.offer(id) orelse continue;
        if (n == victims.len) continue; // batch full — it lapses next publish
        victims[n] = lapsed;
        n += 1;
    }
    report.kept = window.len;

    // Remove only after the walk closes: mutating a directory mid-iteration is
    // not something POSIX promises a coherent listing across.
    for (victims[0..n]) |id| {
        var buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{x}", .{ gens_dir, id }) catch continue;
        if (Dir.cwd().deleteTree(io, path)) |_| {
            report.retired += 1;
        } else |e| fault.spare("retire a superseded generation", @as(anyerror!void, e));
    }
    if (report.retired > 0) assay.trace(.index, "index phase: retired {d} superseded generation(s) · kept {d}\n", .{ report.retired, report.kept });
    return report;
}

/// The `keep` highest generation ids seen so far, descending. Fixed capacity,
/// so ranking costs no allocation; `offer` hands back whatever the window will
/// not hold, which is exactly the eligibility test the caller needs.
const Window = struct {
    ids: [max_keep]u64 = undefined,
    len: usize = 0,
    cap: usize,

    /// Admit `id` and return the generation this displaces — `id` itself when
    /// it ranks below every survivor, the evicted oldest survivor when it does
    /// not, and null while the window still has room.
    fn offer(w: *Window, id: u64) ?u64 {
        var i: usize = 0;
        while (i < w.len and w.ids[i] > id) i += 1;
        if (w.len < w.cap) {
            var j = w.len;
            while (j > i) : (j -= 1) w.ids[j] = w.ids[j - 1];
            w.ids[i] = id;
            w.len += 1;
            return null;
        }
        if (i == w.cap) return id;
        const evicted = w.ids[w.cap - 1];
        var j = w.cap - 1;
        while (j > i) : (j -= 1) w.ids[j] = w.ids[j - 1];
        w.ids[i] = id;
        return evicted;
    }
};

/// A directory name as a generation id, or null when this package could not
/// have minted it. Round-tripping through the exact `{x}` rendering
/// `persist.newGenId` uses makes the check bijective, so an alien directory —
/// uppercase, zero-padded, a temp, a human's note — parses as nothing and is
/// therefore never a candidate for removal.
fn parseGen(name: []const u8) ?u64 {
    if (name.len == 0 or name.len > 16) return null;
    const id = std.fmt.parseInt(u64, name, 16) catch return null;
    var buf: [16]u8 = undefined;
    const canonical = std.fmt.bufPrint(&buf, "{x}", .{id}) catch return null;
    return if (std.mem.eql(u8, canonical, name)) id else null;
}
