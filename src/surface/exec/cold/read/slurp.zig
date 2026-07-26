//! gist `rg` — one candidate's bytes, off disk.
//!
//! The read strategy every walk engine shares: a two-stage open (the first
//! `BUFCAP` bytes now, the tail only if still wanted), a plain drain into a
//! caller-owned buffer, and the mmap path large files take instead of a copy
//! loop. Both engines read through here, so neither can invent a different
//! notion of how much of a file was actually looked at — the geometry
//! `binary.committedPrefix` reasons about is the geometry produced here.

const std = @import("std");
const fault = @import("../../../../fault.zig");
const inode = @import("inode.zig");

/// ripgrep's default read-buffer capacity. Binary detection scans each fill's
/// newly-read bytes for a NUL; the searched region is what
/// `binary.committedPrefix` computes from that fill geometry.
pub const BUFCAP: usize = 65536;

/// One candidate's raw bytes: POSIX open/read/close into the caller's reused
/// `scratch` (sized `corpus.per_file_cap`); a file that fills `scratch`
/// completely is ambiguous (exactly cap-sized, or bigger), so `readTail` keeps
/// reading past it into a growable `a`-owned buffer instead of silently
/// truncating (ripgrep has no default max file size). Returns null when the
/// file can't be opened — the walk's truth degrades to "found nothing here",
/// never an invented match. The returned slice may alias `scratch`: consume it
/// before the next call.
pub fn readFileRaw(a: std.mem.Allocator, scratch: []u8, disk: []const u8) ?[]const u8 {
    const sf = StagedFile.open(scratch, std.posix.AT.FDCWD, disk) orelse return null;
    defer sf.close();
    return sf.readRest(a, scratch);
}

/// Read one file fully into `scratch` (capped at its length); returns bytes
/// read or null when the file can't be opened. The allocation-free sibling of
/// `readFileRaw` for callers that own a fixed per-worker buffer.
pub fn readFileInto(path: []const u8, scratch: []u8) ?usize {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = std.posix.system.close(fd);
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
        const r = std.posix.read(fd, buf[n..]) catch break;
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

    pub fn open(scratch: []u8, dirfd: std.posix.fd_t, name: []const u8) ?StagedFile {
        const fd = std.posix.openat(dirfd, name, .{ .ACCMODE = .RDONLY }, 0) catch return null;
        const cap = @min(scratch.len, BUFCAP);
        const n = drain(fd, scratch[0..cap]);
        return .{ .fd = fd, .prefix = scratch[0..n], .more = n == cap };
    }

    /// The whole body: the prefix plus whatever remains on `fd`, contiguous in
    /// `scratch` (spilling to `readTail` past the scratch cap). Call at most once.
    pub fn readRest(self: *const StagedFile, a: std.mem.Allocator, scratch: []u8) ?[]const u8 {
        if (!self.more) return self.prefix;
        const n = self.prefix.len + drain(self.fd, scratch[self.prefix.len..]);
        if (n == scratch.len) return readTail(a, self.fd, scratch);
        return scratch[0..n];
    }

    pub fn close(self: *const StagedFile) void {
        _ = std.posix.system.close(self.fd);
    }
};

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
/// large single files (grep-searcher's mmap strategy). The mapping is never
/// munmapped — both walk engines are one-shot processes (the resident session
/// reads through its own mirror, not this path) — and any fstat/mmap failure
/// (FIFO stdin, racing truncation below the already-read prefix) falls back to
/// the proven read loop, so no input shape is lost.
pub fn readTail(a: std.mem.Allocator, fd: std.posix.fd_t, scratch: []const u8) ?[]const u8 {
    if (mapWhole(fd, scratch.len)) |mapped| return mapped;
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, scratch) catch return null;
    var tmp: [64 * 1024]u8 = undefined;
    var r = std.posix.read(fd, &tmp) catch 0;
    while (r > 0) : (r = std.posix.read(fd, &tmp) catch 0)
        out.appendSlice(a, tmp[0..r]) catch return null;
    return out.toOwnedSlice(a) catch null;
}

/// Map a regular file at `disk` read-only when it is at least `min` bytes — the
/// large-file path that skips the read-loop + arena dupe entirely: the bytes
/// fault in lazily during the scan, and a SHARDED scan faults its ranges in
/// PARALLEL (the copy this replaces was serial, the Amdahl tail under single-file
/// sharding). Null — caller takes the copying read path — for a sub-`min` file, a
/// non-regular fd, or any open/stat/mmap failure, so no input shape is lost. The
/// map is never unmapped (the cold engine is a one-shot process; the OS reclaims
/// it at exit), matching the `readTail` large-file mapping's lifetime.
pub fn mapFile(disk: []const u8, min: usize) ?[]const u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, disk, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = std.posix.system.close(fd);
    return mapWhole(fd, min);
}

/// Map the whole regular file behind `fd` read-only, from offset 0 (the bytes
/// already drained into scratch are simply re-viewed through the mapping — one
/// consistent snapshot instead of a scratch+tail stitch). Null when the fd is
/// not a regular file, the file shrank below what was already read (a racing
/// truncation the read loop handles conservatively), or `mmap` itself fails —
/// the caller then takes the copying path, never a silent drop.
fn mapWhole(fd: std.posix.fd_t, min_len: usize) ?[]const u8 {
    const st = inode.statFd(fd) orelse return null;
    if (st.mode & std.posix.S.IFMT != std.posix.S.IFREG) return null;
    const size = std.math.cast(usize, st.size) orelse return null;
    if (size < min_len) return null;
    const mapped = std.posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) catch return null;
    // The scan is one strictly-forward SIMD pass, so tell the pager: SEQUENTIAL
    // widens readahead + drops pages behind the cursor, WILLNEED starts the
    // fault-in immediately instead of one page-cluster per fault. Measured on
    // the 2.1 GiB page-cached blob this mapping exists for: 13.7 → ~40 GiB/s
    // (~160 ms → ~54 ms), the difference between fault-per-cluster and
    // batched fault-ahead. Advice is best-effort; failure changes nothing.
    fault.spare("advise sequential access", std.posix.madvise(mapped.ptr, size, std.posix.MADV.SEQUENTIAL));
    fault.spare("advise fault-ahead", std.posix.madvise(mapped.ptr, size, std.posix.MADV.WILLNEED));
    return mapped[0..size];
}
