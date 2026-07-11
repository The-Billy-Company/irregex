//! gist `rg` — the argv-parse accumulator + the value primitives that feed it.
//!
//! Split from `flags.zig`: the flag dispatch (short flags in `flags.zig`, the
//! `--long` catalog in `longopts.zig`) lowers each argv token by mutating a
//! `Builder` — the mutable parse state that collects patterns, `-t/-g` type and
//! glob selectors (with `{a,b}` brace expansion, `!`-exclude, and leading-`/`
//! anchoring), and the `-A/-B/-C` context values `parseArgv` finalizes into
//! `Opts`/`Filter`. The small token helpers (`takeVal`/`nextTok` argv-cursor,
//! `toU`/`unescape`/`toBytes` value decoders) live here too: they exist only to
//! pull and decode the value a flag stores into the builder.

const std = @import("std");
const types = @import("../scope/types.zig");
const opts = @import("opts.zig");
const Opts = opts.Opts;
const die = opts.die;

/// A `--type-add name:...` definition, resolved to the globs `-t name` scopes by.
const CustomType = struct { name: []const u8, globs: []const []const u8 };

/// A leading `/` anchors a gitignore-style glob to the search root; gist already
/// matches such (slash-bearing) globs against the full path, so dropping the
/// anchor byte yields the same root-relative semantics.
fn stripAnchor(g: []const u8) []const u8 {
    return if (g.len > 0 and g[0] == '/') g[1..] else g;
}

/// Mutable parse state: resolves flags into Opts, collects type/glob sets, and
/// records -A/-B/-C values so -A/-B can take precedence over -C regardless of
/// argv order (ripgrep's rule), plus the `-u` repetition level.
pub const Builder = struct {
    a: std.mem.Allocator,
    o: Opts = .{},
    pat: ?[]const u8 = null,
    roots: std.ArrayList([]const u8) = .empty,
    exts: std.ArrayList([]const u8) = .empty,
    neg_exts: std.ArrayList([]const u8) = .empty,
    includes: std.ArrayList([]const u8) = .empty,
    iglobs: std.ArrayList([]const u8) = .empty,
    excludes: std.ArrayList([]const u8) = .empty,
    pat_files: std.ArrayList([]const u8) = .empty, // -f/--file
    extra_pats: std.ArrayList([]const u8) = .empty, // 2nd+ -e/--regexp
    ignore_files: std.ArrayList([]const u8) = .empty, // --ignore-file
    custom_types: std.ArrayList(CustomType) = .empty, // --type-add
    type_all: bool = false,
    ntype_all: bool = false,
    glob_ci: bool = false, // --glob-case-insensitive
    a_val: ?usize = null,
    b_val: ?usize = null,
    c_val: ?usize = null,
    urestrict: u8 = 0,

    /// Accumulate a pattern from `-e/--regexp` (or a bare pattern arg). The first
    /// becomes `pat`; each subsequent one is OR-combined at finalize (ripgrep ORs
    /// multiple `-e`). A literal (`-F`) alternation is handled downstream.
    pub fn addPat(self: *Builder, p: []const u8) void {
        if (self.pat == null) self.pat = p else self.extra_pats.append(self.a, p) catch die("oom\n", .{});
    }
    pub fn addType(self: *Builder, name: []const u8, negate: bool) void {
        if (std.mem.eql(u8, name, "all")) {
            if (negate) self.ntype_all = true else self.type_all = true;
            return;
        }
        // A user-defined `--type-add` type resolves to include/exclude globs; a
        // built-in resolves to its own glob set (scope/types.zig).
        if (self.customGlobs(name)) |globs| {
            (if (negate) &self.excludes else &self.includes).appendSlice(self.a, globs) catch die("oom\n", .{});
            return;
        }
        const e = types.extsForType(name) orelse die("unrecognized type: {s}\n", .{name});
        (if (negate) &self.neg_exts else &self.exts).appendSlice(self.a, e) catch die("oom\n", .{});
    }
    /// Register a `--type-add` spec: `name:glob` appends a glob to `name`; the
    /// `name:include:t1,t2` form aliases `name` to the union of other types.
    pub fn addTypeDef(self: *Builder, spec: []const u8) void {
        const colon = std.mem.findScalar(u8, spec, ':') orelse die("invalid --type-add: {s}\n", .{spec});
        const name = spec[0..colon];
        const rest = spec[colon + 1 ..];
        var globs: std.ArrayList([]const u8) = .empty;
        if (std.mem.startsWith(u8, rest, "include:")) {
            var it = std.mem.splitScalar(u8, rest["include:".len..], ',');
            while (it.next()) |t| {
                if (self.customGlobs(t)) |g| {
                    globs.appendSlice(self.a, g) catch die("oom\n", .{});
                } else if (types.extsForType(t)) |exts| {
                    // A built-in type's rows are already valid globs (scope/types.zig),
                    // so they slot straight into the `include:` union with no conversion.
                    globs.appendSlice(self.a, exts) catch die("oom\n", .{});
                } else die("unrecognized type: {s}\n", .{t});
            }
        } else {
            globs.append(self.a, rest) catch die("oom\n", .{});
        }
        self.custom_types.append(self.a, .{ .name = name, .globs = globs.toOwnedSlice(self.a) catch die("oom\n", .{}) }) catch die("oom\n", .{});
    }
    /// The accumulated globs for a user-defined type, or null if `name` is not one.
    fn customGlobs(self: *Builder, name: []const u8) ?[]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var found = false;
        for (self.custom_types.items) |ct| if (std.mem.eql(u8, ct.name, name)) {
            out.appendSlice(self.a, ct.globs) catch die("oom\n", .{});
            found = true;
        };
        return if (found) out.items else null;
    }
    pub fn addGlob(self: *Builder, g: []const u8, insensitive: bool) void {
        // `{a,b,c}` alternation (ripgrep/git glob): expand into the cartesian
        // product of every brace group up front, then register each variant.
        var variants: std.ArrayList([]const u8) = .empty;
        braceExpand(self.a, g, &variants);
        for (variants.items) |v| self.addGlobOne(v, insensitive);
    }
    fn addGlobOne(self: *Builder, g: []const u8, insensitive: bool) void {
        if (g.len > 0 and g[0] == '!') {
            self.excludes.append(self.a, stripAnchor(g[1..])) catch die("oom\n", .{});
        } else if (insensitive) {
            self.iglobs.append(self.a, stripAnchor(g)) catch die("oom\n", .{});
        } else {
            self.includes.append(self.a, stripAnchor(g)) catch die("oom\n", .{});
        }
    }
};

/// Expand glob `{a,b,c}` alternations into every concrete pattern (cartesian
/// product across groups, nesting-aware). A pattern with no brace group yields
/// itself; an unbalanced `{` is left literal.
fn braceExpand(a: std.mem.Allocator, pat: []const u8, out: *std.ArrayList([]const u8)) void {
    const open = std.mem.findScalar(u8, pat, '{') orelse {
        out.append(a, a.dupe(u8, pat) catch die("oom\n", .{})) catch die("oom\n", .{});
        return;
    };
    var depth: usize = 0;
    var close: ?usize = null;
    var i = open;
    while (i < pat.len) : (i += 1) {
        if (pat[i] == '{') depth += 1 else if (pat[i] == '}') {
            depth -= 1;
            if (depth == 0) {
                close = i;
                break;
            }
        }
    }
    const c = close orelse {
        out.append(a, a.dupe(u8, pat) catch die("oom\n", .{})) catch die("oom\n", .{});
        return;
    };
    const prefix = pat[0..open];
    const suffix = pat[c + 1 ..];
    const inner = pat[open + 1 .. c];
    var start: usize = 0;
    var d: usize = 0;
    var j: usize = 0;
    while (j <= inner.len) : (j += 1) {
        const at_end = j == inner.len;
        if (!at_end and inner[j] == '{') d += 1 else if (!at_end and inner[j] == '}') d -= 1;
        if (at_end or (inner[j] == ',' and d == 0)) {
            const combined = std.fmt.allocPrint(a, "{s}{s}{s}", .{ prefix, inner[start..j], suffix }) catch die("oom\n", .{});
            braceExpand(a, combined, out); // recurse to expand any remaining groups
            start = j + 1;
        }
    }
}

/// Value of a bundled short flag: the rest of `-Xval` if attached, else the next
/// argv token (`-X val`). Fails loud when neither is present.
pub fn takeVal(a: []const u8, k: usize, i: *usize, all: []const []const u8) []const u8 {
    if (k + 1 < a.len) return a[k + 1 ..];
    if (i.* + 1 < all.len) {
        i.* += 1;
        return all[i.*];
    }
    die("flag -{c} needs a value\n", .{a[k]});
}
/// The next argv token, advancing the cursor (a `--flag value` value with no
/// inline `=`). Fails loud at end of argv.
pub fn nextTok(i: *usize, all: []const []const u8) []const u8 {
    if (i.* + 1 < all.len) {
        i.* += 1;
        return all[i.*];
    }
    die("flag needs a value\n", .{});
}
pub fn toU(s: []const u8) usize {
    return std.fmt.parseInt(usize, s, 10) catch die("bad number '{s}'\n", .{s});
}

/// Decode ripgrep's C-style escapes in a separator value (`--field-*-separator`,
/// `--context-separator`): `\n \r \t \0 \\` and `\xNN`. Anything else after a
/// backslash is kept verbatim (rg's lenient rule). Returns `s` unchanged when it
/// has no backslash (the common case).
pub fn unescape(a: std.mem.Allocator, s: []const u8) []const u8 {
    if (std.mem.findScalar(u8, s, '\\') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '\\' or i + 1 >= s.len) {
            out.append(a, s[i]) catch die("oom\n", .{});
            continue;
        }
        i += 1;
        switch (s[i]) {
            'n' => out.append(a, '\n') catch die("oom\n", .{}),
            'r' => out.append(a, '\r') catch die("oom\n", .{}),
            't' => out.append(a, '\t') catch die("oom\n", .{}),
            '0' => out.append(a, 0) catch die("oom\n", .{}),
            '\\' => out.append(a, '\\') catch die("oom\n", .{}),
            'x' => {
                if (i + 2 < s.len) {
                    const hi = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch die("bad \\x escape\n", .{});
                    out.append(a, hi) catch die("oom\n", .{});
                    i += 2;
                } else die("bad \\x escape\n", .{});
            },
            else => {
                out.append(a, '\\') catch die("oom\n", .{});
                out.append(a, s[i]) catch die("oom\n", .{});
            },
        }
    }
    return out.toOwnedSlice(a) catch die("oom\n", .{});
}

/// Parse a `--max-filesize` value: a decimal with an optional `K`/`M`/`G` (1024-
/// based) suffix, e.g. `50`, `4K`, `1M` (ripgrep's grammar).
pub fn toBytes(s: []const u8) usize {
    if (s.len == 0) die("bad size ''\n", .{});
    const mult: usize = switch (s[s.len - 1]) {
        'K', 'k' => 1024,
        'M', 'm' => 1024 * 1024,
        'G', 'g' => 1024 * 1024 * 1024,
        else => 1,
    };
    const digits = if (mult == 1) s else s[0 .. s.len - 1];
    return toU(digits) * mult;
}
