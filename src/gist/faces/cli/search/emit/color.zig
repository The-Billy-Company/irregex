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
