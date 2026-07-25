//! gist `rg` — whether/how to paint output. Split from `output.zig` so the
//! TTY/env resolution (`--color auto|always|never|ansi`) and the ANSI palette
//! it feeds have their own home rather than growing an already-large emitter.
//!
//! The match style colors the letters — same family as ripgrep's foreground
//! swap, not a filled background block — but punchier: ripgrep's plain
//! `fg:red,style:bold` reads as a muddy dark-red on many default terminal
//! palettes (`31` is the dim/"normal" red; `bold` alone doesn't brighten it on
//! every emulator). gist adds `underline` on top of the *bright* red
//! foreground (`91`, the intensified SGR variant), so a match is unmistakable
//! at a glance without ever painting a background. Chrome (path/line
//! separators) is dimmed one notch so the match is the only thing competing
//! for the eye.

const std = @import("std");
const args = @import("../argv/args.zig");

pub const reset = "\x1b[0m";
pub const path_on = "\x1b[1;35m"; // bold magenta — ripgrep's hue, bolded for more presence
pub const line_on = "\x1b[32m"; // green — ripgrep's line-number color
pub const sep_on = "\x1b[2m"; // dim — recedes so the match text dominates
pub const match_on = "\x1b[1;4;91m"; // bold + underline + bright red — letters only, no fill

// gist paints its OWN palette (the constants above), so it does not APPLY a
// user `--colors` spec — but it still validates the spec's SYNTAX and fails loud
// (exit 2) on a malformed one exactly as ripgrep does, rather than silently
// accepting garbage (gist's fail-closed contract). The vocabularies mirror
// grep-printer's `UserColorSpec`/`Style`/`termcolor::Color` parsers.
const color_types = [_][]const u8{ "path", "line", "column", "match" };
const color_styles = [_][]const u8{ "nobold", "bold", "nointense", "intense", "nounderline", "underline", "noitalic", "italic" };
const named_colors = [_][]const u8{ "black", "blue", "green", "red", "cyan", "magenta", "yellow", "white" };

fn inSet(set: []const []const u8, s: []const u8) bool {
    for (set) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// A `--colors` value is a named color, a 0-255 ANSI number, or an `r,g,b`
/// triple (each component 0-255) — `termcolor::Color::from_str`.
fn validColorValue(v: []const u8) bool {
    if (inSet(&named_colors, v)) return true;
    if (std.fmt.parseInt(u8, v, 10) catch null) |_| return true;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, v, ',');
    while (it.next()) |p| : (n += 1) _ = std.fmt.parseInt(u8, p, 10) catch return false;
    return n == 3;
}

/// Validate one `--colors` spec (`{type}:none` or `{type}:{fg|bg|style}:{value}`),
/// returning a human diagnostic when malformed, else null. Mirrors ripgrep's
/// `UserColorSpec::from_str` failure taxonomy (unrecognized type / spec type /
/// style attribute / color value), so gist rejects exactly what rg rejects.
pub fn validateColorSpec(spec: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, spec, ':');
    const otype = it.next().?; // splitScalar always yields ≥1 piece
    if (!inSet(&color_types, otype)) return "unrecognized output type";
    const attr = it.next() orelse return "invalid color spec format (expected 'type:attribute:value')";
    if (std.mem.eql(u8, attr, "none")) return if (it.next() == null) null else "invalid color spec format";
    const value = it.next() orelse return "invalid color spec format (missing value)";
    if (it.next() != null) return "invalid color spec format (too many components)";
    if (std.mem.eql(u8, attr, "style")) return if (inSet(&color_styles, value)) null else "unrecognized style attribute";
    if (std.mem.eql(u8, attr, "fg") or std.mem.eql(u8, attr, "bg")) return if (validColorValue(value)) null else "unrecognized color value";
    return "unrecognized spec type";
}

/// ripgrep's env-override rules for `auto` mode: `NO_COLOR` (any value —
/// https://no-color.org) or an absent/`dumb` `TERM` suppresses color. An
/// explicit `--color=always`/`ansi` bypasses this entirely (see `enabled`).
fn envSuppresses(env: *const std.process.Environ.Map) bool {
    if (env.get("NO_COLOR")) |_| return true;
    const term = env.get("TERM") orelse return true;
    return std.mem.eql(u8, term, "dumb");
}

/// Resolve `--color` into a single yes/no for this run. `never` is always off;
/// `always`/`ansi` are always on (env can't veto an explicit request — rg's
/// rule). `auto` (the default) is on iff stdout is a real terminal, the
/// environment doesn't opt out, and no flag that implies plain text (`--json`,
/// `--vimgrep` — rg suppresses color under both) is active.
pub fn enabled(o: args.Opts, io: std.Io, env: *const std.process.Environ.Map) bool {
    return switch (o.color) {
        .never => false,
        .always, .ansi => true,
        .auto => !o.json and !o.vimgrep and
            (std.Io.File.stdout().isTty(io) catch false) and !envSuppresses(env),
    };
}
