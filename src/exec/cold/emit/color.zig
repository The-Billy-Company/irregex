//! The `rg` face — whether/how to paint output. Split from `output.zig` so the
//! TTY/env resolution (`--color auto|always|never|ansi`) and the ANSI palette
//! it feeds have their own home rather than growing an already-large emitter.
//!
//! The match style colors the letters — same family as ripgrep's foreground
//! swap, not a filled background block — but punchier: ripgrep's plain
//! `fg:red,style:bold` reads as a muddy dark-red on many default terminal
//! palettes (`31` is the dim/"normal" red; `bold` alone doesn't brighten it on
//! every emulator). We add `underline` on top of the *bright* red
//! foreground (`91`, the intensified SGR variant), so a match is unmistakable
//! at a glance without ever painting a background. Chrome (path/line
//! separators) is dimmed one notch so the match is the only thing competing
//! for the eye.

const std = @import("std");
const builtin = @import("builtin");
const args = @import("../argv/args.zig");

pub const reset = "\x1b[0m";
pub const path_on = "\x1b[1;35m"; // bold magenta — ripgrep's hue, bolded for more presence
pub const line_on = "\x1b[32m"; // green — ripgrep's line-number color
pub const sep_on = "\x1b[2m"; // dim — recedes so the match text dominates
pub const match_on = "\x1b[1;4;91m"; // bold + underline + bright red — letters only, no fill

// The constants above are our DEFAULT palette; `--colors` overrides them per
// element, attribute by attribute, exactly as ripgrep's specs do. The
// vocabularies mirror grep-printer's `UserColorSpec`/`Style`/`termcolor::Color`
// parsers, and a malformed spec still fails loud (exit 2) rather than being
// silently accepted (our fail-closed contract).
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
/// style attribute / color value), so we reject exactly what rg rejects.
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

// ───────────────────────────── the run's palette ─────────────────────────────

/// What paints one element. Four SGR prefixes, resolved once per run and then
/// carried by `Opts`, so no emitter signature has to grow a parameter to learn
/// a caller's `--colors`. `.{}` is our own palette, byte-for-byte what a run
/// with no spec has always printed.
///
/// `sep` (the dimmed field separators) has no ripgrep `--colors` type and stays
/// native chrome. `column` defaults to EMPTY rather than to ripgrep's green: we
/// have never painted column numbers, and honoring a spec must not repaint an
/// element nobody asked about.
pub const Palette = struct {
    path: []const u8 = path_on,
    line: []const u8 = line_on,
    column: []const u8 = "",
    match: []const u8 = match_on,
    sep: []const u8 = sep_on,
};

/// One element's styling while specs are still folding into it. ripgrep merges
/// each spec into the default rather than replacing it — `--colors match:fg:blue`
/// keeps the default's bold — so the defaults arrive here as attributes and only
/// become bytes at the end.
const Attrs = struct {
    fg: ?[]const u8 = null, // rendered SGR parameter(s), e.g. "35" or "38;5;120"
    bg: ?[]const u8 = null,
    bold: bool = false,
    underline: bool = false,
    italic: bool = false,
    intense: bool = false,

    /// `{type}:none` clears the element outright — the caller wants this element
    /// unstyled, not restyled.
    fn clear(self: *Attrs) void {
        self.* = .{};
    }

    /// SGR prefix for these attributes, or "" when nothing is set (which `paint`
    /// treats as "add the text and no escapes").
    fn render(self: Attrs, a: std.mem.Allocator) []const u8 {
        var p: std.ArrayList(u8) = .empty;
        if (self.bold) p.appendSlice(a, "1;") catch return "";
        if (self.italic) p.appendSlice(a, "3;") catch return "";
        if (self.underline) p.appendSlice(a, "4;") catch return "";
        if (self.fg) |f| p.print(a, "{s};", .{f}) catch return "";
        if (self.bg) |b| p.print(a, "{s};", .{b}) catch return "";
        if (p.items.len == 0) return "";
        return std.fmt.allocPrint(a, "\x1b[{s}m", .{p.items[0 .. p.items.len - 1]}) catch "";
    }
};

/// A named color's offset from its plane's base code. Spelled out rather than
/// derived from `named_colors`, whose order is the validation set's, not SGR's.
fn namedOffset(v: []const u8) ?u8 {
    const sgr = [_][]const u8{ "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white" };
    for (sgr, 0..) |n, i| if (std.mem.eql(u8, n, v)) return @intCast(i);
    return null;
}

/// Render one color value as SGR parameters for the given plane (30 = fg,
/// 40 = bg). A name becomes the base code (brightened by `intense`, ripgrep's
/// rule), a 0-255 number becomes `38;5;N`, and an `r,g,b` triple `38;2;R;G;B`.
fn renderColor(a: std.mem.Allocator, base: u8, v: []const u8, intense: bool) ?[]const u8 {
    if (namedOffset(v)) |i|
        return std.fmt.allocPrint(a, "{d}", .{base + i + @as(u8, if (intense) 60 else 0)}) catch null;
    if (std.fmt.parseInt(u8, v, 10) catch null) |n|
        return std.fmt.allocPrint(a, "{d};5;{d}", .{ base + 8, n }) catch null;
    var rgb: [3]u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, v, ',');
    while (it.next()) |p| : (n += 1) {
        if (n == 3) return null;
        rgb[n] = std.fmt.parseInt(u8, p, 10) catch return null;
    }
    if (n != 3) return null;
    return std.fmt.allocPrint(a, "{d};2;{d};{d};{d}", .{ base + 8, rgb[0], rgb[1], rgb[2] }) catch null;
}

/// Fold one already-validated spec into the four accumulators.
fn fold(a: std.mem.Allocator, at: *[4]Attrs, spec: []const u8) void {
    var it = std.mem.splitScalar(u8, spec, ':');
    const otype = it.next().?;
    const slot = for (color_types, 0..) |known, i| {
        if (std.mem.eql(u8, known, otype)) break i;
    } else return;
    const e = &at[slot];
    const attr = it.next() orelse return;
    if (std.mem.eql(u8, attr, "none")) return e.clear();
    const value = it.next() orelse return;
    if (std.mem.eql(u8, attr, "style")) {
        // `intense` re-renders an already-set named foreground, so keep the raw
        // name out of reach and just re-fold: ripgrep applies intensity to the
        // color, not to the text.
        if (std.mem.eql(u8, value, "bold")) e.bold = true;
        if (std.mem.eql(u8, value, "nobold")) e.bold = false;
        if (std.mem.eql(u8, value, "underline")) e.underline = true;
        if (std.mem.eql(u8, value, "nounderline")) e.underline = false;
        if (std.mem.eql(u8, value, "italic")) e.italic = true;
        if (std.mem.eql(u8, value, "noitalic")) e.italic = false;
        if (std.mem.eql(u8, value, "intense")) e.intense = true;
        if (std.mem.eql(u8, value, "nointense")) e.intense = false;
        return;
    }
    if (std.mem.eql(u8, attr, "fg")) e.fg = renderColor(a, 30, value, e.intense);
    if (std.mem.eql(u8, attr, "bg")) e.bg = renderColor(a, 40, value, e.intense);
}

/// Resolve `--colors` specs into the palette this run paints with. With no
/// specs the result is `.{}` — the same four constants we have always used —
/// so the default path allocates nothing and cannot drift.
pub fn resolve(a: std.mem.Allocator, specs: []const []const u8) Palette {
    if (specs.len == 0) return .{};
    // Our defaults, as attributes, so a spec merges into them the way
    // ripgrep's merge into its own.
    var at = [4]Attrs{
        .{ .fg = "35", .bold = true }, // path
        .{ .fg = "32" }, // line
        .{}, // column — unpainted unless asked for
        .{ .fg = "91", .bold = true, .underline = true }, // match
    };
    for (specs) |s| fold(a, &at, s);
    return .{
        .path = at[0].render(a),
        .line = at[1].render(a),
        .column = at[2].render(a),
        .match = at[3].render(a),
    };
}

/// ripgrep's env-override rules for `auto` mode: `NO_COLOR` (any value —
/// https://no-color.org) or a `dumb` `TERM` suppresses color. An explicit
/// `--color=always`/`ansi` bypasses this entirely (see `enabled`).
///
/// An ABSENT `TERM` suppresses on POSIX and does not on Windows, which is
/// `termcolor`'s own asymmetry (`ColorChoice::should_attempt_color` falls back
/// to `cfg!(windows)`) and so ripgrep's: no Windows console sets `TERM`, so
/// treating its absence as "not a terminal" would make color unreachable on the
/// platform. The console-mode question is asked separately, by `ansiCapable`.
fn envSuppresses(env: *const std.process.Environ.Map) bool {
    if (env.get("NO_COLOR")) |_| return true;
    const term = env.get("TERM") orelse return builtin.os.tag != .windows;
    return std.mem.eql(u8, term, "dumb");
}

/// Whether stdout will actually render an escape sequence, asking the platform
/// to start if it isn't already. On POSIX this is `isTty` under another name.
/// On Windows it is the console-mode question: Windows Terminal arrives with VT
/// processing enabled, legacy conhost has to be asked, and a console that
/// refuses is one where emitting escapes would look worse than emitting none.
/// `std.Io` also recognizes a Cygwin/MSYS pty here — not a console at all, and
/// a case `isTty` alone answers wrong.
fn ansiCapable(io: std.Io) bool {
    std.Io.File.stdout().enableAnsiEscapeCodes(io) catch return false;
    return true;
}

/// Resolve `--color` into a single yes/no for this run. `never` is always off;
/// `always`/`ansi` are always on (env can't veto an explicit request — rg's
/// rule), though the console is still asked to interpret escapes so an explicit
/// request renders instead of printing its own bytes. `auto` (the default) is on
/// iff stdout will render escapes, the environment doesn't opt out, and no flag
/// implying plain text (`--json`, `--vimgrep` — rg suppresses color under both)
/// is active.
pub fn enabled(o: args.Opts, io: std.Io, env: *const std.process.Environ.Map) bool {
    return switch (o.color) {
        .never => false,
        .always, .ansi => blk: {
            _ = ansiCapable(io); // asked, never vetoed — the request was explicit
            break :blk true;
        },
        .auto => o.mode != .json and !o.vimgrep and
            !envSuppresses(env) and ansiCapable(io),
    };
}

// ─────────────────────────────────── tests ───────────────────────────────────

const t = std.testing;

test "the default attributes render to the palette constants, byte for byte" {
    // The safety property behind `--colors`: our defaults now live twice —
    // once as constants for the no-spec path, once as attributes for the merge.
    // A spec that names only `column` must leave the other three EXACTLY as a
    // run with no spec at all would have printed them.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const p = resolve(arena.allocator(), &.{"column:none"});
    try t.expectEqualStrings(path_on, p.path);
    try t.expectEqualStrings(line_on, p.line);
    try t.expectEqualStrings(match_on, p.match);
}

test "no spec allocates nothing and cannot drift" {
    const p = resolve(t.failing_allocator, &.{});
    try t.expectEqualStrings(match_on, p.match);
    try t.expectEqualStrings("", p.column); // we have never painted columns
}

test "--colors merges into gist's defaults the way ripgrep merges into its own" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Naming the foreground keeps the default's bold+underline.
    try t.expectEqualStrings("\x1b[1;4;34m", resolve(a, &.{"match:fg:blue"}).match);
    // `none` clears the element outright — this is the case ripgrep users reach
    // for to keep path color while unstyling matches, which we used to ignore.
    try t.expectEqualStrings("", resolve(a, &.{"match:none"}).match);
    try t.expectEqualStrings(path_on, resolve(a, &.{"match:none"}).path);
    // Specs accumulate in argv order, and a later one wins its attribute.
    try t.expectEqualStrings("\x1b[35m", resolve(a, &.{ "path:style:nobold", "path:fg:magenta" }).path);
    // 256-color and r,g,b, both planes.
    try t.expectEqualStrings("\x1b[38;5;120m", resolve(a, &.{"line:fg:120"}).line);
    try t.expectEqualStrings("\x1b[1;4;38;2;1;2;3m", resolve(a, &.{"match:fg:1,2,3"}).match);
    try t.expectEqualStrings("\x1b[48;5;7m", resolve(a, &.{ "column:bg:7", "column:style:nobold" }).column);
    // `intense` brightens the color it precedes — ripgrep applies intensity to
    // the color, not to the text, so it must be set before the fg it lifts.
    try t.expectEqualStrings("\x1b[1;91m", resolve(a, &.{ "path:style:intense", "path:fg:red" }).path);
    // Style toggles compose and cancel.
    try t.expectEqualStrings("\x1b[3;4;91m", resolve(a, &.{ "match:style:nobold", "match:style:italic" }).match);
}
