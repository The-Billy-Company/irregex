//! gist `rg` — how a walk failure reads on stderr.
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

const std = @import("std");
const fault = @import("../../../../fault.zig");
const assay = @import("../../../../assay/assay.zig");
const Dir = std.Io.Dir;

/// Everything the three descent call sites can hand this renderer: the serial
/// engine's `std.Io` open + selective walk, the parallel engine's raw `openat`
/// + iterate, and the explicit-PATH probe's `openat`. It is the UNION of the
/// two engines' own `WalkFault` sets, each of which coerces into it — naming it
/// (ADR-373 law 2) rather than taking `anyerror` means a widened std set is a
/// build failure at the one place that decides how a walk failure reads, not a
/// mystery string on a user's stderr.
pub const WalkFault = Dir.OpenError || Dir.Iterator.Error || Dir.SelectiveWalker.Error || std.posix.OpenError;

/// ripgrep's `<bin>: <path>: <errno phrase>` note for a path that can't be
/// opened/descended — an explicit PATH arg or an unreadable directory hit
/// mid-walk. The differential harness keys only on the errno phrase and the
/// exit class (never the `rg:`/`gist:` prefix or the exact number — see
/// `bench/rgsuite/run.py`), so the phrases are contract.
///
/// The phrases themselves live in `fault.pathNote`, whose switch is exhaustive
/// over `fault.Corpus` (ADR-373 law 2). All this decides is whether a walk
/// error IS one of that domain's members, and it asks the domain instead of
/// re-listing it: a sixth corpus member picks up rg's phrasing here the moment
/// `fault.pathNote` names it, and cannot reach the arm below by omission.
///
/// A real descent produces a much wider set than the corpus domain (EMFILE,
/// ENODEV, a bad UTF-8 name), and ripgrep prints the OS string for those too,
/// so the widening is the walk's truth rather than an erased domain.
fn pathErrNote(err: WalkFault) []const u8 {
    inline for (@typeInfo(fault.Corpus).error_set.?) |m| {
        const member = @field(fault.Corpus, m.name);
        if (err == member) return fault.pathNote(member);
    }
    return @errorName(err);
}

/// ripgrep's walk-error stderr line (`rg: <path>: <errno>` → `gist: …`) — THE
/// one rendering, shared by the serial and parallel engines' `reportWalkError`
/// so a directory neither could descend is reported byte-identically.
pub fn printWalkError(rel: []const u8, e: WalkFault) void {
    assay.diag("gist: {s}: {s}\n", .{ rel, pathErrNote(e) });
}

/// ripgrep's `-L` cycle report (walk_entry_err in its ignore crate): a symlink
/// directory pointing at an ancestor of the walk is announced with both
/// DISPLAY paths and refused — the walk continues past it, exit 2 (errored).
pub fn printLoopError(link: []const u8, ancestor: []const u8) void {
    assay.diag("gist: File system loop found: {s} points to an ancestor {s}\n", .{ link, ancestor });
}

/// ripgrep's implicit-path heuristic (`eprint_nothing_searched`, main.rs): the
/// walk of the GUESSED path — no PATH args, CWD assumed — yielded zero
/// searchable files, so some filter (type/glob/ignore/hidden) excluded
/// everything. rg treats this as an error (stderr message + exit 2), never a
/// silent exit-1 "no matches"; an EXPLICIT path stays silent by design (rg:
/// "it can otherwise be noisy when it is intended that there is nothing to
/// search"). Both engines print through here so the wording cannot drift.
pub fn printNothingSearched() void {
    assay.diag(
        \\gist: No files were searched, which means gist probably applied a filter you didn't expect.
        \\gist: try -uu (fold hidden + gitignored files in), or `gist --files` to see what the walk admits.
        \\
    , .{});
}
