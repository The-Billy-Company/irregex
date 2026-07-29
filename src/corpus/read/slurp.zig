//! gist `rg` — one candidate's bytes, off disk.
//!
//! The read strategy every walk engine shares: a two-stage open (the first
//! `BUFCAP` bytes now, the tail only if still wanted), a plain drain into a
//! caller-owned buffer, and the mmap path large files take instead of a copy
//! loop. Both engines read through here, so neither can invent a different
//! notion of how much of a file was actually looked at — the geometry
//! `binary.committedPrefix` reasons about is the geometry produced here.

const std = @import("std");
const fault = @import("../../fault.zig");
const inode = @import("inode.zig");
const portal = @import("../../portal.zig");

/// ripgrep's default read-buffer capacity. Binary detection scans each fill's
/// newly-read bytes for a NUL; the searched region is what
/// `binary.committedPrefix` computes from that fill geometry.
pub const BUFCAP: usize = 65536;

/// Why a candidate the walk already admitted could not be opened — named rather
/// than folded into a null (ADR-373 law 2), because the two outcomes have
/// DIFFERENT exit classes and rg distinguishes them. A file that opens and holds
/// no match is exit 1; a file that will not open at all is a gap in what was
/// searched, and ripgrep reports it on stderr and exits 2 even when other files
/// matched. Returning `?` for both made an unreadable file present as a silent
/// "found nothing here" — measured against live rg by `bench/rgsuite/fuzz.py`,
/// which is where this seam came from. `notice.WalkFault` already covers this
/// set, so the shared renderer takes these errors unchanged.
pub const OpenFault = std.posix.OpenError;

/// One candidate's raw bytes: POSIX open/read/close into the caller's reused
/// `scratch` (sized `corpus.per_file_cap`); a file that fills `scratch`
/// completely is ambiguous (exactly cap-sized, or bigger), so `readTail` keeps
/// reading past it into a growable `a`-owned buffer instead of silently
/// truncating (ripgrep has no default max file size). Errors when the file
/// cannot be OPENED (the caller owes stderr + exit 2); null when it opened but
/// its bytes could not be assembled (an allocation failure downstream of a file
/// that is genuinely there) — never an invented match either way. The returned
/// slice may alias `scratch`: consume it before the next call.
pub fn readFileRaw(a: std.mem.Allocator, scratch: []u8, disk: []const u8) OpenFault!?[]const u8 {
    const sf = try StagedFile.open(scratch, portal.cwd(), disk);
    defer sf.close();
    return sf.readRest(a, scratch);
}

/// Read one file fully into `scratch` (capped at its length); returns bytes
/// read or null when the file can't be opened. The allocation-free sibling of
/// `readFileRaw` for callers that own a fixed per-worker buffer.
pub fn readFileInto(path: []const u8, scratch: []u8) ?usize {
    const fd = portal.openFile(portal.cwd(), path) catch return null;
    defer portal.close(fd);
    return drain(fd, scratch);
}

/// Fill `buf` from `fd`; returns bytes read. A short read on a regular
/// local file means EOF (the walk only yields regular files, and gist's
/// corpus model is a local filesystem — see `corpus/README.md`), so the
/// common sub-cap file costs ONE read syscall, not read-then-read-zero.
fn drain(fd: std.posix.fd_t, buf: []u8) usize {
    var n: usize = 0;
    while (n < buf.len) {
        const want = buf.len - n;
        const r = portal.read(fd, buf[n..]) catch break;
        n += r;
        if (r < want) break;
    }
    return n;
}

/// A candidate opened and read in TWO stages: the first `BUFCAP` bytes now, the
/// tail only if the caller still needs it. ripgrep's streaming reader decides
/// most files from its first 64 KiB buffer — binary triage (a NUL in buffer 0
/// makes an implicit file contribute nothing) and the `-l` first-match exit
/// both fire there — and on this corpus 86% of all bytes are tails of >64 KiB
/// files, so NOT reading them is the single biggest IO saving available.
///
/// Opens relative to `dirfd`: the parallel walk holds each directory open
/// while searching its files, so the kernel resolves ONE path component
/// instead of re-walking the full `dir/sub/…/name` chain per file (namei is
/// the dominant per-file open cost on a deep monorepo tree; ~21k opens/scan).
pub const StagedFile = struct {
    fd: std.posix.fd_t,
    prefix: []const u8, // first ≤BUFCAP bytes, in the caller's scratch
    more: bool, // the prefix filled BUFCAP exactly ⇒ a tail may exist

    pub fn open(scratch: []u8, dirfd: std.posix.fd_t, name: []const u8) OpenFault!StagedFile {
        const fd = try portal.openFile(dirfd, name);
        const cap = @min(scratch.len, BUFCAP);
        const n = drain(fd, scratch[0..cap]);
        return .{ .fd = fd, .prefix = scratch[0..n], .more = n == cap };
    }

    /// The whole body: the prefix plus whatever remains on `fd`, contiguous in
    /// `scratch` (spilling to `readTail` past the scratch cap). Call at most once.
    pub fn readRest(self: *const StagedFile, a: std.mem.Allocator, scratch: []u8) ?[]const u8 {
        return (self.readWhole(a, scratch) orelse return null).bytes;
    }

    /// `readRest`, plus the mapping the read borrowed when the file was too big
    /// for `scratch`. A caller that finishes with the bytes inside its own frame
    /// hands `map` to `release` and keeps the resident set at one large file per
    /// worker; `readRest` is the same read for the callers that pass the body
    /// onward and let the one-shot process's exit reclaim it.
    pub fn readWhole(self: *const StagedFile, a: std.mem.Allocator, scratch: []u8) ?Body {
        if (!self.more) return .{ .bytes = self.prefix };
        const n = self.prefix.len + drain(self.fd, scratch[self.prefix.len..]);
        if (n == scratch.len) return readTail(a, self.fd, scratch);
        return .{ .bytes = scratch[0..n] };
    }

    pub fn close(self: *const StagedFile) void {
        portal.close(self.fd);
    }
};

/// A body plus the mapping it borrowed, if any: `map` is non-null exactly when
/// `bytes` is a view of a whole-file mapping rather than owned or scratch bytes.
/// Naming it is what lets one caller drop the view the moment it is done while
/// another keeps it — the two are a real policy difference (see `readTail`), not
/// an accident, and a plain slice could express neither.
pub const Body = struct { bytes: []const u8, map: ?portal.Mapping = null };

/// `scratch` (already full) plus whatever remains on `fd`, as one contiguous
/// buffer — the uncommon path for a file at/above `per_file_cap`, kept out of
/// the hot common-case function above. A regular file this large is
/// memory-MAPPED read-only rather than slurped through a read loop: the copy
/// loop paid 2× the bytes (kernel→ArrayList reads plus growth memcpys) on
/// multi-GB leaked-in blobs (explicit-root scoping admits gitignored
/// training corpora — `gist pat services libs` spent ~0.5 s copying one 2.1 GB
/// text file rg mmaps in ~0.2 s), while the map costs one syscall, faults in
/// only the pages the SIMD gate actually touches before its first hit, and
/// rides the page cache across runs. ripgrep's own default does the same for
/// large single files (grep-searcher's mmap strategy). Any fstat/mmap failure
/// (FIFO stdin, racing truncation below the already-read prefix) falls back to
/// the proven read loop, so no input shape is lost.
///
/// Whether the view is dropped is the CALLER's to decide, which is why the
/// mapping comes back beside the bytes. A worker that renders the file inside
/// one frame drops it there (`Body.map` → `release`) and never holds two large
/// files at once; a caller that hands the body onward keeps it to exit, which is
/// sound because both walk engines are one-shot processes (the resident session
/// reads through its own mirror, not this path).
pub fn readTail(a: std.mem.Allocator, fd: std.posix.fd_t, scratch: []const u8) ?Body {
    if (mapWhole(fd, scratch.len)) |mapped| return .{ .bytes = mapped, .map = mapped };
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, scratch) catch return null;
    var tmp: [64 * 1024]u8 = undefined;
    var r = portal.read(fd, &tmp) catch 0;
    while (r > 0) : (r = portal.read(fd, &tmp) catch 0)
        out.appendSlice(a, tmp[0..r]) catch return null;
    return .{ .bytes = out.toOwnedSlice(a) catch return null };
}

/// Map a regular file at `disk` read-only when it is at least `min` bytes — the
/// large-file path that skips the read-loop + arena dupe entirely: the bytes
/// fault in lazily during the scan, and a SHARDED scan faults its ranges in
/// PARALLEL (the copy this replaces was serial, the Amdahl tail under single-file
/// sharding). Null — caller takes the copying read path — for a sub-`min` file, a
/// non-regular fd, or any open/stat/mmap failure, so no input shape is lost.
///
/// Returns the ALIGNED view rather than a plain slice, so a caller that learns
/// the file is irrelevant can hand it to `release`. Keeping every large map alive
/// until exit is sound (the cold engine is one-shot) but it is not free: on an
/// 11 GiB tree, a query matching nothing mapped every multi-megabyte file and
/// held all of them, reporting 274 MiB of resident set against ripgrep's 41 MiB
/// for the same zero-match answer. Those were clean page-cache pages the kernel
/// could evict on demand — the process OWNED 37 MiB throughout — but "rg wins on
/// a memory number" is not a thing we ship, and the required-literal gate already
/// knows which files it just proved irrelevant.
pub fn mapFile(disk: []const u8, min: usize) ?portal.Mapping {
    const fd = portal.openFile(portal.cwd(), disk) catch return null;
    defer portal.close(fd);
    return mapWhole(fd, min);
}

/// Drop a `mapFile` view. Only sound once nothing borrows its bytes — which is
/// why the one caller does this on the path where a gate proved the file cannot
/// match, never on the path that returns the body onward.
pub fn release(m: portal.Mapping) void {
    portal.unmap(m);
}

/// Map the whole regular file behind `fd` read-only, from offset 0 (the bytes
/// already drained into scratch are simply re-viewed through the mapping — one
/// consistent snapshot instead of a scratch+tail stitch). Null when the fd is
/// not a regular file, the file shrank below what was already read (a racing
/// truncation the read loop handles conservatively), or `mmap` itself fails —
/// the caller then takes the copying path, never a silent drop.
fn mapWhole(fd: std.posix.fd_t, min_len: usize) ?portal.Mapping {
    const st = inode.statFd(fd) orelse return null;
    if (st.kind != .file) return null;
    const size = std.math.cast(usize, st.size) orelse return null;
    if (size < min_len) return null;
    const mapped = portal.map(fd, size) catch return null;
    // The scan is one strictly-forward SIMD pass, so tell the pager: SEQUENTIAL
    // widens readahead + drops pages behind the cursor, WILLNEED starts the
    // fault-in immediately instead of one page-cluster per fault. Measured on
    // the 2.1 GiB page-cached blob this mapping exists for: 13.7 → ~40 GiB/s
    // (~160 ms → ~54 ms), the difference between fault-per-cluster and
    // batched fault-ahead. Advice is best-effort; failure changes nothing.
    fault.spare("advise sequential access", portal.advise(mapped, .sequential));
    fault.spare("advise fault-ahead", portal.advise(mapped, .will_need));
    return mapped[0..size];
}
