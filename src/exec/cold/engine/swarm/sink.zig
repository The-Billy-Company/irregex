//! The one shared stdout writer every worker streams through.
//!
//! Each rendered fragment is written the instant it is ready, under a lock so
//! concurrent workers' output never interleaves, and a write that comes back
//! closed-pipe cancels the whole walk. That is what lets a `… | head -1` run
//! finish in single-digit milliseconds instead of paying for the entire corpus:
//! the trade is that output arrives in worker-discovery order rather than a
//! global path sort, which the rg-parity harness already treats as a soft pass.

const std = @import("std");
const corpus_mod = @import("../../../../corpus/tree/corpus.zig");
const queue = @import("queue.zig");

const Queue = queue.Queue;

/// What kind of fragment a worker just rendered — decides what inter-file
/// glue (if any) `Sink.emit` prepends before writing it.
pub const FragKind = enum { text_hit, text_plain, bin_hit, json };

/// The one shared stdout writer every worker streams through, the instant
/// each file's fragment is ready — replacing the old collect-everything →
/// sort-by-path → k-way-merge → single-write stitch. That buffered design
/// meant NOTHING reached a downstream reader until the entire corpus had
/// been walked, matched, and assembled: a piped `head -1` got zero benefit
/// from exiting early (measured: same wall-clock as capturing the full,
/// untruncated result — `rg | head -1` finishes in single-digit ms on the
/// same query by contrast, because ripgrep streams and cancels on the first
/// EPIPE). `emit` is the fix: write under a lock (so concurrent workers'
/// output never interleaves) the moment a match is found, and the moment a
/// write comes back closed-pipe, cancel the walk via `q.abort()` — the same
/// cooperative-cancellation shape ripgrep's own printer uses.
///
/// The trade: output now arrives in worker-discovery order, not the old
/// global path-sort — our own rgsuite harness already classifies an
/// order-only diff as a soft pass (`sort_lines(ours) == sort_lines(rg)`),
/// since a parallel walker's file order was never a byte-parity promise to
/// begin with. Every other framing (heading blank lines, `--` context-group
/// separators, per-file line order, the match/no-match exit code) is
/// unchanged — `first`/`matched_files` just move from a single-threaded
/// post-pass into this lock-guarded running state.
pub const Sink = struct {
    q: *Queue,
    io: std.Io,
    mu: std.Io.Mutex = .init,
    heading: bool,
    join_groups: bool,
    // `Opts.groupSep()`, resolved once by the driver: the sink writes bytes and
    // never re-derives a rule the printer already owns.
    group_sep: ?[2][]const u8 = .{ "--", "\n" },
    first: bool = true, // guarded by `mu`
    matched_files: usize = 0, // guarded by `mu`
    // `--files-without-match` only: files whose search found nothing — rg's
    // success for this mode — yet which its printer refuses to list, i.e. walked
    // binaries. Kept apart from `matched_files` because that counter doubles as
    // `--stats`'s `files_with_match`, and a suppressed binary contained no match;
    // only the exit code may read this.
    unlisted: usize = 0, // guarded by `mu`
    // Bytes actually written to stdout (match stream + separators). `--stats`
    // reads this after the walk for `bytes printed` (quiet ⇒ forced to 0).
    bytes_printed: usize = 0, // guarded by `mu`
    // Of those, color escapes and OSC-8 frames. Workers render concurrently, so
    // each fragment carries its own share and it is banked here, under the same
    // lock as the write — the ceiling must discount a fragment exactly when that
    // fragment lands, never when some other worker happened to render one.
    chrome: usize = 0, // guarded by `mu`

    fn noteWrite(self: *Sink, n: usize) void {
        self.bytes_printed += n;
    }

    /// Bank a landed fragment's chrome and republish the run's total.
    fn noteChrome(self: *Sink, n: usize) void {
        if (n == 0) return;
        self.chrome += n;
        corpus_mod.noteChrome(self.chrome);
    }

    /// Did this run succeed (rg's exit 0)? Read after the workers join, so both
    /// counters are quiescent. A row is success in every mode; a counted-but-
    /// unlisted file is success only in `--files-without-match`, which is the
    /// only mode that ever banks one.
    pub fn succeeded(self: *const Sink) bool {
        return self.matched_files > 0 or self.unlisted > 0;
    }

    /// Count a file toward `--files-without-match`'s success without printing a
    /// row for it (the walked-binary case — see `unlisted`). No bytes, no
    /// terminator, so no `writeStdout`: a lock and a counter, once per binary
    /// file, off every hot path.
    pub fn noteUnlisted(self: *Sink) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.unlisted += 1;
    }

    pub fn emit(self: *Sink, kind: FragKind, buf: []const u8, chrome: usize) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.q.aborted.load(.monotonic)) return; // pipe already gone — nothing left to do
        var ok = true;
        // `--json` fragments are a whole file's `begin`/records/`end`, already a
        // self-framed record block — write it verbatim (order-insensitive per the
        // parity harness's `sort -u` set compare). A non-empty buffer ⟺ the file
        // matched (`json.emitOne` emits nothing otherwise), so it also drives the
        // matched-files exit code; the `summary` record is written once by `run`.
        if (kind == .json) {
            self.matched_files += 1;
            if (!corpus_mod.writeStdout(buf)) self.q.abort() else self.noteWrite(buf.len);
            return;
        }
        switch (kind) {
            .text_hit => {
                if (self.heading and !self.first) {
                    ok = corpus_mod.writeStdout("\n");
                    if (ok) self.noteWrite(1);
                }
                if (ok and self.join_groups and !self.first and buf.len > 0) {
                    if (self.group_sep) |s| for (s) |piece| {
                        ok = ok and corpus_mod.writeStdout(piece);
                        if (ok) self.noteWrite(piece.len);
                    };
                }
                self.first = false;
                self.matched_files += 1;
            },
            .bin_hit => self.matched_files += 1,
            .text_plain => {},
            .json => unreachable, // handled above (self-framed record block)
        }
        if (ok) {
            ok = corpus_mod.writeStdout(buf);
            if (ok) {
                self.noteWrite(buf.len);
                self.noteChrome(chrome);
            }
        }
        if (!ok) self.q.abort();
    }

    /// Write ONE coalesced path-list chunk (`-l`/`--files`/`--files-without-match`):
    /// many `path+term` records a worker batched, plus their file count, in a
    /// single locked `write(2)`. This is the path-list twin of `emit` — the
    /// mutex + syscall is a per-chunk cost, not per file, so a high-hit scan
    /// stops serializing every worker behind the sink lock. Order-free (each
    /// chunk is a contiguous slice of one worker's matches).
    pub fn emitFilesChunk(self: *Sink, buf: []const u8, files: usize, chrome: usize) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.q.aborted.load(.monotonic)) return;
        self.matched_files += files;
        if (!corpus_mod.writeStdout(buf)) self.q.abort() else {
            self.noteWrite(buf.len);
            self.noteChrome(chrome);
        }
    }
};
