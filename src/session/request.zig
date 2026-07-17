//! gist resident session — the eligible-request classifier (ADR-352 rung 2.5).
//!
//! The resident daemon accelerates exactly the three broad-tree request shapes
//! an agent reaches for most — the bare default `path:text` line search (the
//! `gist <pattern>` reflex itself, mode `lines`), "which files contain this"
//! (`-l`), and "how many matching lines" (`-c`) — over the ROOTLESS
//! current-working-directory tree, for a literal (`-F`) or a plain
//! (linear-time) regex, optionally caseless (`-i`), with `-n`/`--line-number`
//! carried for the lines shape. Everything else — `--json`, context, `--rank`,
//! replace, invert, `-w`, multiline, ANY explicit PATH arg, globs/types,
//! stdin — is deliberately NOT eligible and is answered by the certified cold
//! subprocess, byte-for-byte.
//!
//! Rootless-only is the parity contract: the daemon serves exactly the tree a
//! bare `gist <pattern>` walks (`gather` with empty roots → `walkDir(".", "")`,
//! CWD-relative paths with no `./` prefix). An explicit `PATH` arg — even `.`,
//! which cold prefixes as `./file` — would scope or shape the output
//! differently from the daemon's served corpus, so it stays cold. The wire
//! carries no roots; the daemon always answers over its whole served corpus, so
//! only the rootless query is byte-parity-safe to route warm.
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
    /// `-n`/`--line-number`: prefix each `lines`-mode row with its 1-based
    /// line number. Carried (and ignored) for `-l`/`-c`, exactly as cold does.
    line_num: bool = false,
};

pub const ClassifyError = error{
    /// The argv is outside the resident fast path — answer it cold.
    Unsupported,
    /// No pattern at all (a bare `-l`) — also cold (the walk lists files).
    NoPattern,
};

/// Classify an rg-style argv into an eligible `Request`, or fail so the caller
/// uses the cold transport. Recognizes: `-l`/`--files-with-matches`,
/// `-c`/`--count`, `-F`/`--fixed-strings`, `-i`/`--ignore-case`,
/// `-n`/`--line-number` (and `-N`/`--no-line-number`), and the pattern via a
/// leading bare token or `-e`/`--regexp[=]VALUE`; a bare pattern with no mode
/// flag is the default LINE search (`mode = .lines`). The query must be
/// ROOTLESS: ANY positional PATH arg (including after a `--` separator, and
/// including `.`) makes it ineligible, because the daemon serves only the
/// rootless CWD tree and the wire carries no roots — a scoped or `./`-prefixed
/// answer would not match. Any other flag is likewise ineligible; the cold
/// engine owns all of those, unchanged.
pub fn classify(argv: []const []const u8) ClassifyError!Request {
    var pattern: ?[]const u8 = null;
    var mode: ?Mode = null;
    var fixed = false;
    var ignore_case = false;
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
            ignore_case = true;
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
            // Any other flag (context, --json, -w, -v, -g/-t, --hidden, …)
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
    return .{ .pattern = p, .mode = m, .fixed = fixed, .ignore_case = ignore_case, .line_num = line_num };
}
