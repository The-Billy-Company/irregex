//! gist resident session — the eligible-request classifier (ADR-352 rung 2.5).
//!
//! Warm surface: rootless `-l` / `-c` / bare `lines`, literal (`-F`) or plain
//! regex, ±case (`-i`/`-s`/`-S`), optional `-w` / `-n`. Everything else
//! (`--json`, context, `--rank`, PATH args, globs, stdin, …) → cold.
//!
//! Rootless-only: the daemon serves the bare-`gist <pattern>` CWD tree (no
//! `./` prefix). An explicit PATH — even `.` — stays cold. `classify` is a
//! narrow argv scanner (not a fork of `args.zig`); it returns typed errors and
//! never calls `die()`.

const std = @import("std");
// `hasUpper` only — shared smart-case authority with cold's finalize fold.
// One-way edge: args.zig never imports session.
const args = @import("../cold/argv/args.zig");

/// Eligible answer shapes — shared with the search core (`engine/query.zig`).
pub const Mode = @import("../../search/match/query.zig").Mode;

/// Classified eligible request. `pattern` aliases into argv / the frame buffer.
pub const Request = struct {
    pattern: []const u8,
    mode: Mode,
    fixed: bool = false,
    ignore_case: bool = false,
    /// `-n`/`--line-number` (ignored for `-l`/`-c`, as cold does).
    line_num: bool = false,
    /// `-S`/`--smart-case`, raw on the wire; resolved via `effectiveIgnoreCase`.
    smart_case: bool = false,
    /// `-w`/`--word-regexp` — see `search/match/query.zig::wordOk`.
    word: bool = false,

    /// Engine-effective caseless state. `-S` folds only when the pattern has no
    /// (Unicode) uppercase (`args.hasUpper`). Compile sites must use this, not
    /// raw `ignore_case`.
    pub fn effectiveIgnoreCase(self: Request) bool {
        return self.ignore_case or (self.smart_case and !args.hasUpper(self.pattern));
    }
};

pub const ClassifyError = error{
    /// Outside the resident fast path — answer cold.
    Unsupported,
    /// No pattern (a bare `-l`) — also cold.
    NoPattern,
};

/// Classify rg-style argv into an eligible `Request`, or fail → cold.
/// Recognizes `-l`/`-c`/`-F`, case family `-i`/`-s`/`-S`, `-w`, `-n`/`-N`,
/// pattern via bare token or `-e`/`--regexp`. Bare pattern → `mode = .lines`.
/// Any positional PATH (incl. `.` / after `--`) or other flag → ineligible.
pub fn classify(argv: []const []const u8) ClassifyError!Request {
    var pattern: ?[]const u8 = null;
    var mode: ?Mode = null;
    var fixed = false;
    var ignore_case = false;
    var smart_case = false;
    var word = false;
    var line_num = false;
    var end_of_flags = false;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (arg.len == 0) return ClassifyError.Unsupported;
        if (!end_of_flags and std.mem.eql(u8, arg, "--")) {
            end_of_flags = true; // rg parity: everything after `--` is a path
        } else if (!end_of_flags and (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--files-with-matches"))) {
            if (mode != null and mode.? != .files) return ClassifyError.Unsupported;
            mode = .files;
        } else if (!end_of_flags and (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--count"))) {
            if (mode != null and mode.? != .count) return ClassifyError.Unsupported;
            mode = .count;
        } else if (!end_of_flags and (std.mem.eql(u8, arg, "-F") or std.mem.eql(u8, arg, "--fixed-strings"))) {
            fixed = true;
        } else if (!end_of_flags and (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-case"))) {
            // Case mode is last-wins across -i/-s/-S (each clears the other two).
            ignore_case, smart_case = .{ true, false };
        } else if (!end_of_flags and (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--case-sensitive"))) {
            ignore_case, smart_case = .{ false, false };
        } else if (!end_of_flags and (std.mem.eql(u8, arg, "-S") or std.mem.eql(u8, arg, "--smart-case"))) {
            ignore_case, smart_case = .{ false, true };
        } else if (!end_of_flags and (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--word-regexp"))) {
            word = true;
        } else if (!end_of_flags and (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--line-number"))) {
            line_num = true;
        } else if (!end_of_flags and (std.mem.eql(u8, arg, "-N") or std.mem.eql(u8, arg, "--no-line-number"))) {
            line_num = false; // rg's left-to-right undo rule
        } else if (!end_of_flags and (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--regexp"))) {
            i += 1;
            if (i >= argv.len or pattern != null) return ClassifyError.Unsupported;
            pattern = argv[i];
        } else if (!end_of_flags and std.mem.startsWith(u8, arg, "--regexp=")) {
            if (pattern != null) return ClassifyError.Unsupported;
            pattern = arg["--regexp=".len..];
        } else if (!end_of_flags and arg[0] == '-') {
            // Any other flag (context, --json, -v, -g/-t, --hidden, …)
            // is outside the fast path — hand the whole request to cold.
            return ClassifyError.Unsupported;
        } else if (pattern == null) {
            pattern = arg; // the first bare token is the pattern
        } else {
            // A PATH arg: the daemon serves only the rootless CWD tree, so any
            // explicit scope (subtree, foreign path, or even `.`, which cold
            // renders with a `./` prefix) is answered cold, unchanged.
            return ClassifyError.Unsupported;
        }
    }

    const m = mode orelse Mode.lines; // no -l/-c ⇒ the default line search
    const p = pattern orelse return ClassifyError.NoPattern;
    if (p.len == 0) return ClassifyError.Unsupported;
    // A pattern carrying a newline or NUL steps outside rg's per-line model
    // (warm whole-doc gates would match ACROSS lines where cold cannot; a NUL
    // interacts with binary detection) — the cold engine owns those bytes.
    if (std.mem.indexOfAny(u8, p, "\n\x00") != null) return ClassifyError.Unsupported;
    return .{ .pattern = p, .mode = m, .fixed = fixed, .ignore_case = ignore_case, .line_num = line_num, .smart_case = smart_case, .word = word };
}
