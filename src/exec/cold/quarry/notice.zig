//! The `rg` face — how a walk failure reads on stderr.
//!
//! A descent can fail in ways the search itself never sees: a path arg that
//! won't open, a directory that won't be entered, a `-L` symlink pointing at
//! its own ancestor, or a walk whose filters admitted nothing at all. ripgrep
//! answers each with a specific line and a specific exit class, and the
//! differential harness keys on that wording — so this is contract, not
//! cosmetics.
//!
//! Both descents render through here (`walk.zig`'s `std.Io` selective walk and
//! the swarm's raw `openat` + iterate), which is why it lives in `quarry/`
//! beside the walk rather than with the per-file read machinery: a directory
//! neither engine could enter must be reported byte-identically. Each engine
//! layers its own exit-2 flagging on top (a plain bool vs a queue atomic).
//!
//! Every line here writes through `assay.note(.corpus, …)` rather than
//! `assay.diag`: these ARE the messages ripgrep's `--no-messages` governs. That
//! silences the prose only. Flagging the run and reporting it are separate
//! statements at every call site above, so a quieted walk still exits 2 — which
//! is why the flagging lives with the engines and only the wording lives here.

const std = @import("std");
const fault = @import("../../../fault.zig");
const assay = @import("../../../assay/assay.zig");
const Dir = std.Io.Dir;

/// Everything the three descent call sites can hand this renderer: the serial
/// engine's `std.Io` open + selective walk, the parallel engine's raw `openat`
/// + iterate, and the explicit-PATH probe's `openat`. It is the UNION of the
/// two engines' own `WalkFault` sets, each of which coerces into it — naming it
/// (fault-channel law 2) rather than taking `anyerror` means a widened std set is a
/// build failure at the one place that decides how a walk failure reads, not a
/// mystery string on a user's stderr.
pub const WalkFault = Dir.OpenError || Dir.Iterator.Error || Dir.SelectiveWalker.Error || std.posix.OpenError;

/// ripgrep's `<bin>: <path>: <errno phrase>` line for a path that can't be
/// opened or descended — an explicit PATH arg, or an unreadable directory hit
/// mid-walk. THE one rendering, shared by both engines' `reportWalkError`, so a
/// directory neither could enter reads byte-identically. The differential
/// harness keys on the errno phrase and the exit class (never the `rg:`/`<bin>:`
/// prefix or the number — the rgsuite runner), so the phrases are contract.
///
/// Those phrases live in `fault.pathNoteOf`, whose `pathNote` switch is
/// exhaustive over `fault.Corpus` (fault-channel law 2) and which falls through to the
/// error's own name for the wider set a real descent produces. Naming
/// `WalkFault` here is what keeps that discipline local: the domain decides the
/// phrasing, this decides what the walk is allowed to fail with.
pub fn printWalkError(rel: []const u8, e: WalkFault) void {
    assay.note(.corpus, assay.tag ++ "{s}: {s}\n", .{ rel, fault.pathNoteOf(e) });
}

/// ripgrep's `-L` cycle report (walk_entry_err in its ignore crate): a symlink
/// directory pointing at an ancestor of the walk is announced with both
/// DISPLAY paths and refused — the walk continues past it, exit 2 (errored).
pub fn printLoopError(link: []const u8, ancestor: []const u8) void {
    assay.note(.corpus, assay.tag ++ "File system loop found: {s} points to an ancestor {s}\n", .{ link, ancestor });
}

/// ripgrep's implicit-path heuristic (`eprint_nothing_searched`, main.rs): the
/// walk of the GUESSED path — no PATH args, CWD assumed — yielded zero
/// searchable files, so some filter (type/glob/ignore/hidden) excluded
/// everything. rg treats this as an error (stderr message + exit 2), never a
/// silent exit-1 "no matches"; an EXPLICIT path stays silent by design (rg:
/// "it can otherwise be noisy when it is intended that there is nothing to
/// search"). Both engines print through here so the wording cannot drift.
pub fn printNothingSearched() void {
    assay.note(.corpus,
        \\gist: No files were searched, which means gist probably applied a filter you didn't expect.
        \\gist: try -uu (fold hidden + gitignored files in), or `gist --files` to see what the walk admits.
        \\
    , .{});
}
