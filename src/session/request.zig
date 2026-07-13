//! gist resident session — the eligible-request classifier (ADR-352 rung 2.5).
//!
//! The resident daemon accelerates exactly the two broad-tree request shapes an
//! agent reaches for most — "which files contain this" (`-l`) and "how many
//! matching lines" (`-c`) — over the repo's DEFAULT roots, for a literal (`-F`)
//! or a plain (linear-time) regex, optionally ASCII-caseless (`-i`). Everything
//! else — line output, `--json`, context, `--rank`, replace, invert, `-w`,
//! multiline, explicit PATH args, globs/types, stdin — is deliberately NOT
//! eligible and is answered by the certified cold subprocess, byte-for-byte.
//!
//! `classify` is a self-contained argv scanner, NOT a second copy of
//! `commands/ripgrep/args.zig`: it recognizes only the supported surface and
//! returns `error.Unsupported` for anything outside it (so the client falls
//! back to cold), and — crucially — it never calls `die()`. That is the whole
//! reason the resident path sidesteps the ADR-352 exit hazard: an ineligible or
//! malformed request is a typed error on the wire, never a dead daemon.

const std = @import("std");

/// The two eligible answer shapes. Aliases the shared search core's `Mode`
/// (`engine/query.zig`) so the classifier, the wire protocol, and the compiled
/// query all speak one enum — no cross-layer conversion, no drift.
pub const Mode = @import("../engine/query.zig").Mode;

/// A classified, eligible resident request. `pattern` aliases into the argv the
/// classifier scanned (or, for the wire path, the frame buffer) — the caller
/// keeps that memory alive across the query.
pub const Request = struct {
    pattern: []const u8,
    mode: Mode,
    fixed: bool = false,
    ignore_case: bool = false,
};

pub const ClassifyError = error{
    /// The argv is outside the resident fast path — answer it cold.
    Unsupported,
    /// No pattern at all (a bare `-l`) — also cold (the walk lists files).
    NoPattern,
};

/// Classify an rg-style argv into an eligible `Request`, or fail so the caller
/// uses the cold transport. Recognizes: `-l`/`--files-with-matches`,
/// `-c`/`--count`, `-F`/`--fixed-strings`, `-i`/`--ignore-case`, and the
/// pattern via a leading bare token or `-e`/`--regexp[=]VALUE`. A second bare
/// token (a PATH), a `--` separator, or ANY other flag makes the request
/// ineligible — the cold engine owns those, unchanged.
pub fn classify(argv: []const []const u8) ClassifyError!Request {
    var pattern: ?[]const u8 = null;
    var mode: ?Mode = null;
    var fixed = false;
    var ignore_case = false;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (arg.len == 0) return ClassifyError.Unsupported;
        if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--files-with-matches")) {
            if (mode != null and mode.? != .files) return ClassifyError.Unsupported;
            mode = .files;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--count")) {
            if (mode != null and mode.? != .count) return ClassifyError.Unsupported;
            mode = .count;
        } else if (std.mem.eql(u8, arg, "-F") or std.mem.eql(u8, arg, "--fixed-strings")) {
            fixed = true;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-case")) {
            ignore_case = true;
        } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--regexp")) {
            i += 1;
            if (i >= argv.len or pattern != null) return ClassifyError.Unsupported;
            pattern = argv[i];
        } else if (std.mem.startsWith(u8, arg, "--regexp=")) {
            if (pattern != null) return ClassifyError.Unsupported;
            pattern = arg["--regexp=".len..];
        } else if (arg[0] == '-') {
            // Any other flag (context, --json, -w, -v, -g/-t, --hidden, -n, …)
            // is outside the fast path — hand the whole request to cold.
            return ClassifyError.Unsupported;
        } else {
            // A bare token: the pattern (first) — a SECOND one is a PATH arg,
            // which the resident path (default-roots only) does not serve.
            if (pattern != null) return ClassifyError.Unsupported;
            pattern = arg;
        }
    }

    const m = mode orelse return ClassifyError.Unsupported; // fast path only serves -l/-c
    const p = pattern orelse return ClassifyError.NoPattern;
    if (p.len == 0) return ClassifyError.Unsupported;
    return .{ .pattern = p, .mode = m, .fixed = fixed, .ignore_case = ignore_case };
}
