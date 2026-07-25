//! The resident session's mutation store — how a live tree edit becomes an
//! answerable substitution without rebuilding the base mirror.
//!
//! The base corpus (`corpus.zig`) is immutable for the life of an index
//! generation. Every divergence since it loaded therefore lands here as one
//! entry per path: a replacement document, or a tombstone for a path that left
//! the certified walk set. An answer face reads (base ∪ overlay) − tombstones,
//! which is why the store's iteration order and its key lifetimes are as much
//! part of the read-your-writes invariant as the reconcile that fills it.
//!
//! Everything in this file is WRITER-side except `liveKeys`: `reconcile.zig`
//! calls it holding the exclusive lease. `put` is the single chokepoint every
//! mutation flows through, which is what lets the non-ASCII twin set below stay
//! exactly in step with the live key set at zero cost to the common path.

const std = @import("std");
const builtin = @import("builtin");
const corpus = @import("corpus.zig");
const answer = @import("../answer/answer.zig");
const resident = @import("resident.zig");
const ResidentSession = resident.ResidentSession;
const QueryError = answer.QueryError;

/// A case-INsensitive filesystem (macOS APFS/HFS+) folds ASCII case AND Unicode
/// normalization (NFC/NFD) to one on-disk spelling, so a scoped reconcile there
/// must sweep the corpus's non-ASCII keys against the `realpath` oracle to catch
/// a stale twin the ASCII fold can't equate. Linux only ever scopes over
/// case-SENSITIVE (byte-exact) roots (watch.zig gates casefold roots to coarse),
/// so no sweep is needed and the set stays unused (zero cost).
pub const is_macos = builtin.os.tag == .macos;

/// Set the overlay for `path`, freeing any prior value and reusing the key,
/// and keep the non-ASCII sweep set in step (`.doc` ⇒ live, `.tombstone` ⇒
/// retired) — the single overlay chokepoint every mutation flows through.
pub fn put(self: *ResidentSession, path: []const u8, ov: resident.Overlay) !void {
    const gop = try self.overlay.getOrPut(path);
    if (gop.found_existing) {
        freeValue(self, gop.value_ptr.*);
    } else {
        gop.key_ptr.* = self.gpa.dupe(u8, path) catch |e| {
            _ = self.overlay.remove(path);
            return e;
        };
    }
    gop.value_ptr.* = ov;
    try trackNonAscii(self, path, ov == .doc);
}

pub fn freeValue(self: *ResidentSession, ov: resident.Overlay) void {
    if (ov == .doc) self.gpa.free(ov.doc.bytes);
}

pub fn clear(self: *ResidentSession) void {
    var it = self.overlay.iterator();
    while (it.next()) |e| {
        self.gpa.free(e.key_ptr.*);
        freeValue(self, e.value_ptr.*);
    }
    self.overlay.clearRetainingCapacity();
}

/// Read `p` into an overlay entry with the SAME faithful ingest the base
/// mirror applies (full read, BOM/UTF-16 decode, whole-body NUL offset), or
/// a tombstone when it is gone/unreadable/empty — the only cases that can
/// never produce cold output. A file that turned binary stays IN the
/// overlay with its `nul` recorded, so each mode applies cold's binary rule.
pub fn readInto(self: *ResidentSession, p: []const u8) QueryError!void {
    const doc = corpus.readDocOwned(self.gpa, self.io, p) orelse
        return put(self, p, .tombstone);
    return put(self, p, .{ .doc = doc });
}

/// Iterate every key currently answerable from the session: base docs not
/// yet tombstoned, plus overlay replacement docs for paths outside the
/// base corpus. (A tombstoned key is already gone; re-checking it is
/// wasted work, and re-tombstoning would be a no-op anyway.)
pub fn liveKeys(self: *ResidentSession) LiveKeys {
    return .{ .session = self, .overlay_it = self.overlay.iterator() };
}

pub const LiveKeys = struct {
    session: *ResidentSession,
    base_idx: usize = 0,
    overlay_it: std.StringHashMap(resident.Overlay).Iterator,

    pub fn next(self: *LiveKeys) ?[]const u8 {
        const s = self.session;
        while (self.base_idx < s.mir.paths.len) {
            const p = s.mir.paths[self.base_idx];
            self.base_idx += 1;
            if (s.overlay.get(p)) |ov| if (ov == .tombstone) continue;
            return p;
        }
        while (self.overlay_it.next()) |e| {
            if (e.value_ptr.* != .doc) continue;
            if (s.by_path.contains(e.key_ptr.*)) continue; // yielded above
            return e.key_ptr.*;
        }
        return null;
    }
};

/// True when `s` carries any byte outside 7-bit ASCII — the keys the scoped
/// reconcile's ASCII fold cannot canonicalize, and thus the ones the sweep
/// must re-verify against the `realpath` oracle on a case-insensitive fs.
pub fn hasNonAscii(s: []const u8) bool {
    for (s) |b| if (b >= 0x80) return true;
    return false;
}

/// Build the non-ASCII key set (owned dupes) from a path list — a no-op
/// returning empty off macOS, where the fs is byte-exact and no sweep runs.
pub fn buildNonAscii(gpa: std.mem.Allocator, paths: []const []const u8) std.mem.Allocator.Error!std.StringHashMapUnmanaged(void) {
    var set: std.StringHashMapUnmanaged(void) = .empty;
    if (comptime !is_macos) return set;
    errdefer freeNonAscii(&set, gpa);
    for (paths) |p| if (hasNonAscii(p)) {
        const owned = try gpa.dupe(u8, p);
        set.put(gpa, owned, {}) catch |e| {
            gpa.free(owned);
            return e;
        };
    };
    return set;
}

/// Free every owned key and the set itself.
pub fn freeNonAscii(set: *std.StringHashMapUnmanaged(void), gpa: std.mem.Allocator) void {
    var it = set.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    set.deinit(gpa);
    set.* = .empty;
}

/// Keep the non-ASCII key set in step with one overlay mutation: a `.doc`
/// makes a non-ASCII key live (tracked), a `.tombstone` retires it. Zero
/// cost off macOS and for the ASCII-only common case. A tracking OOM
/// propagates so the reconcile declines to cold rather than sweep an
/// incomplete set (fail-closed).
fn trackNonAscii(self: *ResidentSession, path: []const u8, live: bool) std.mem.Allocator.Error!void {
    if (comptime !is_macos) return;
    if (!hasNonAscii(path)) return;
    if (live) {
        if (self.nonascii_keys.contains(path)) return;
        const owned = try self.gpa.dupe(u8, path);
        self.nonascii_keys.put(self.gpa, owned, {}) catch |e| {
            self.gpa.free(owned);
            return e;
        };
    } else if (self.nonascii_keys.fetchRemove(path)) |kv| {
        self.gpa.free(kv.key);
    }
}
