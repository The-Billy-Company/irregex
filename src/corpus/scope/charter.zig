//! The tree's charter — `.irregex.toml`, committed, shared, and read alike by
//! every face, the daemon, and both bindings.
//!
//! ripgrep has one configuration file and it holds two unlike things. Half of a
//! `.ripgreprc` is taste (`--max-columns`, `--colors`); the other half —
//! `--glob=!vendor/*`, `--type-add`, the roots you always mean — is not taste at
//! all but a FACT about the repository, equally true for the person, the agent,
//! the daemon, and CI. Conflating them is why that file has to be defended
//! against with `--no-config`: a personal preference can silently change what a
//! shared script matches.
//!
//! This file is the second half, split out and given the property the first half
//! can never have: it is committed. Three corpus facts had no committed home
//! before it, and every one of them was a real divergence between two clones of
//! the same tree —
//!
//!   * roots  lived only in `GIST_ROOTS`, else the whole tree;
//!   * skips  lived in `<GIST_DIR>/skips.list`, which defaults inside gitignored
//!            `.local/`, so "seed `graphify-out`" was per-machine folklore and a
//!            fresh clone searched a different corpus than a seeded one;
//!   * types  had to be re-passed as `--type-add` on every single invocation.
//!
//! What a charter may say is ceilinged at `Reach.corpus` (see the argv catalog):
//! it declares which files exist, never what counts as a match in them. That
//! ceiling is the whole reason a shared file is safe to honor by default — a
//! teammate cannot commit `-i` into the tree and quietly change everyone's
//! results, agents included. Taste stays in the personal, terminal-only
//! preference layer, which is a different file for a different reader.
//!
//! Format is a strict, tiny subset of TOML — top-level `key = "str"` or
//! `key = ["a", "b"]`, `#` comments — and every departure from it fails loud
//! with a line number. It is deliberately NOT ripgrep's "each line is a verbatim
//! argv element", which has no tokenization and so turns an ordinary quoted glob
//! into a silent no-match (ripgrep #927, #932, #2646, #3428 — still being filed).
//! Here a quote is a quote.

const std = @import("std");
const assay = @import("../../assay/assay.zig");

/// The charter's filename, searched for from the working directory upward.
pub const filename = ".irregex.toml";

/// Ceilings. A charter is committed source, so these bound what a hostile or
/// careless commit can do to everyone who clones the tree.
const max_bytes: usize = 64 << 10;
const max_entries: usize = 1024;
const max_climb: usize = 40;

/// What a charter is allowed to declare. Every key is a `Reach.corpus` fact:
/// which files the engine sees, never what matches inside them.
pub const Charter = struct {
    /// Where it was found, relative to the working directory — the string a
    /// provenance report shows, so a reader can open the file that explains
    /// the behavior they are looking at.
    path: []const u8,
    /// Its directory, as a relative prefix (`""` for the working directory,
    /// else `..`, `../..`, …). Roots resolve against this rather than against
    /// the working directory, so `gist` run from a subdirectory searches the
    /// same corpus it does from the tree root — cargo's rule, for cargo's
    /// reason.
    dir: []const u8,
    /// Default corpus roots, already prefixed by `dir`.
    roots: []const []const u8,
    /// Extra directory basenames every walk prunes, beyond the generic
    /// VCS/build/cache baseline.
    skip: []const []const u8,
    /// `name:glob` definitions, exactly as `--type-add` takes them.
    types: []const []const u8,

    pub fn deinit(self: *const Charter, gpa: std.mem.Allocator) void {
        for ([_][]const []const u8{ self.roots, self.skip, self.types }) |list| {
            for (list) |s| gpa.free(s);
            gpa.free(list);
        }
        gpa.free(self.path);
        gpa.free(self.dir);
    }
};

/// Why a charter was rejected. Every one of these is a loud exit rather than a
/// shrug: a corpus declaration that half-parsed would mean searching a corpus
/// nobody described, which is worse than not having the file.
pub const Fault = error{
    UnknownKey,
    DuplicateKey,
    ExpectedEquals,
    ExpectedValue,
    UnterminatedString,
    BadEscape,
    TooManyEntries,
    Oversized,
    EmptyValue,
};

// ── discovery ────────────────────────────────────────────────────────────────

/// The charter governing the working directory, or `null` when the tree has
/// none. Resolved once per process and cached; the result is borrowed for the
/// process lifetime, exactly as the env-var knobs beside it are.
///
/// A parse fault exits (2) here rather than propagating: every caller asks this
/// question in the middle of setting up a search, and "your committed corpus
/// declaration is malformed" is not a condition any of them can act on.
pub fn governing() ?*const Charter {
    if (state.done) return state.charter;
    state.done = true;
    if (suppressedNow()) return null;

    const gpa = std.heap.page_allocator; // process-lifetime; never freed
    state.charter = discover(gpa) catch |e| {
        assay.diag("gist: {s}: {s}\n", .{ state.faulted_path, faultNote(e) });
        assay.diag("gist: note: --no-config ignores it for this run\n", .{});
        std.process.exit(2);
    };
    return state.charter;
}

/// Ignore both persisted layers for this run. `--no-config` calls this from a
/// pre-scan of raw argv, before any layer has been consulted — the ordering
/// ripgrep also needs, since the flag has to be honored before the file that
/// might contain flags is read. Must precede the first `governing()`; after
/// that the cache has already published an answer.
pub fn suppress() void {
    suppressed = true;
}

/// Is either persisted layer suppressed right now? Both the charter and the
/// preferences ask this, so the flag and its env twin are answered in one place
/// and cannot come apart.
pub fn suppressedNow() bool {
    return suppressed or assay.envFlag("GIST_NO_CONFIG");
}

/// Answer `--no-config` from RAW argv — every face's first act, before any verb
/// dispatch. It has to run here rather than in the grammar because a flag whose
/// job is to suppress a file cannot be learned from that file, and the charter
/// is consulted by root resolution long before flags are parsed. A `--`
/// separator ends the scan: past it, the token is a pattern.
pub fn honorNoConfig(argv: @FieldType(@FieldType(std.process.Init, "minimal"), "args")) void {
    var scan = std.process.Args.Iterator.init(argv);
    while (scan.next()) |a| {
        if (std.mem.eql(u8, a, "--")) return;
        if (consumed(a)) return suppress();
    }
}

/// The token `honorNoConfig` already answered. Verbs with a closed argument set
/// (`status`, `index`, `codex`) skip it while collecting, so a flag that is
/// legal everywhere does not have to be understood by every verb it precedes.
pub fn consumed(tok: []const u8) bool {
    return std.mem.eql(u8, tok, "--no-config");
}

var suppressed: bool = false;
var state: struct {
    done: bool = false,
    charter: ?*const Charter = null,
    faulted_path: []const u8 = filename,
} = .{};

fn faultNote(e: anyerror) []const u8 {
    return switch (e) {
        Fault.UnknownKey => "unknown key (the charter declares roots, skip, types)",
        Fault.DuplicateKey => "the same key is declared twice",
        Fault.ExpectedEquals => "expected `=` after a key",
        Fault.ExpectedValue => "expected a string or a list of strings",
        Fault.UnterminatedString => "unterminated string",
        Fault.BadEscape => "unsupported escape (only \\\" and \\\\ are recognized)",
        Fault.TooManyEntries => "too many entries",
        Fault.Oversized => "file is too large to be a corpus declaration",
        Fault.EmptyValue => "empty string (a corpus fact cannot be blank)",
        error.OutOfMemory => "out of memory reading it",
        else => "unreadable",
    };
}

/// Walk from the working directory upward for a charter, stopping at the first
/// one found — or at a repository boundary, so a tree without its own charter
/// never silently inherits a parent directory's. Relative prefixes throughout,
/// which keeps the walk free of `getcwd` and makes the roots it yields directly
/// usable as walk arguments.
fn discover(gpa: std.mem.Allocator) !?*const Charter {
    if (assay.envSpan("GIST_CHARTER")) |explicit| {
        state.faulted_path = explicit;
        const src = slurp(gpa, explicit) catch return null;
        defer gpa.free(src);
        return try place(gpa, explicit, "", src);
    }

    var buf: [max_climb * 3 + 32]u8 = undefined;
    var up: usize = 0;
    while (up <= max_climb) : (up += 1) {
        const dir = prefix(buf[0 .. max_climb * 3], up);
        const path = std.fmt.bufPrint(buf[max_climb * 3 ..], "{s}{s}", .{ dir, filename }) catch return null;
        if (slurp(gpa, path)) |src| {
            defer gpa.free(src);
            state.faulted_path = path;
            return try place(gpa, path, dir, src);
        } else |_| {}
        // A repo boundary with no charter in it is an answer: stop, rather than
        // adopt whatever a parent directory outside the tree happens to say.
        if (exists(buf[max_climb * 3 ..], dir, ".git")) return null;
    }
    return null;
}

/// `""`, `"../"`, `"../../"`, … — `up` levels of relative ascent.
fn prefix(buf: []u8, up: usize) []const u8 {
    for (0..up) |i| @memcpy(buf[i * 3 ..][0..3], "../");
    return buf[0 .. up * 3];
}

/// Is `<dir><name>` there? Probed by opening rather than by `access`, so a
/// `.git` FILE (a worktree or submodule pointer) counts as a boundary exactly
/// like a `.git` directory does — both are the edge of a checkout.
fn exists(buf: []u8, dir: []const u8, name: []const u8) bool {
    const path = std.fmt.bufPrint(buf, "{s}{s}", .{ dir, name }) catch return false;
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return false;
    _ = std.posix.system.close(fd);
    return true;
}

/// Read a whole persisted-configuration file, refusing one too large to be one.
/// Shared with the preferences reader: both layers are opened before any `Io`
/// exists (root resolution and argv assembly both precede it), and both would
/// rather report `Oversized` than allocate against a pointed-at video file.
pub fn slurp(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.posix.system.close(fd);
    // Grown rather than stat-sized: one fewer syscall, and the cap is enforced
    // against bytes actually read, so a file that grows under us cannot slip a
    // larger buffer past the ceiling.
    var buf = try gpa.alloc(u8, 4096);
    errdefer gpa.free(buf);
    var read: usize = 0;
    while (true) {
        if (read == buf.len) {
            if (buf.len >= max_bytes) return Fault.Oversized;
            buf = try gpa.realloc(buf, @min(buf.len * 2, max_bytes));
        }
        const n = try std.posix.read(fd, buf[read..]);
        if (n == 0) break;
        read += n;
    }
    return gpa.realloc(buf, read);
}

fn place(gpa: std.mem.Allocator, path: []const u8, dir: []const u8, src: []const u8) !*const Charter {
    const owned = try gpa.create(Charter);
    errdefer gpa.destroy(owned);
    owned.* = try parse(gpa, path, dir, src);
    return owned;
}

// ── parsing ──────────────────────────────────────────────────────────────────

/// Parse a charter's bytes. Returns errors rather than exiting so the format is
/// testable; `governing` is the single place that turns a fault into an exit.
pub fn parse(gpa: std.mem.Allocator, path: []const u8, dir: []const u8, src: []const u8) !Charter {
    var roots: ?[][]const u8 = null;
    var skip: ?[][]const u8 = null;
    var types: ?[][]const u8 = null;
    errdefer for ([_]?[][]const u8{ roots, skip, types }) |maybe| if (maybe) |list| {
        for (list) |s| gpa.free(s);
        gpa.free(list);
    };

    var p: Cursor = .{ .src = src };
    while (p.key()) |name| {
        try p.equals();
        const slot: *?[][]const u8 =
            if (std.mem.eql(u8, name, "roots")) &roots //
            else if (std.mem.eql(u8, name, "skip")) &skip //
            else if (std.mem.eql(u8, name, "types")) &types //
            else return Fault.UnknownKey;
        if (slot.* != null) return Fault.DuplicateKey;
        slot.* = try p.values(gpa);
    }
    try p.fault();

    // Roots are the one key whose meaning depends on where the charter sits;
    // fold the prefix in once here so no consumer has to remember to.
    if (dir.len > 0) if (roots) |list| {
        for (list) |*r| {
            const joined = try std.fmt.allocPrint(gpa, "{s}{s}", .{ dir, r.* });
            gpa.free(r.*);
            r.* = joined;
        }
    };

    return .{
        .path = try gpa.dupe(u8, path),
        .dir = try gpa.dupe(u8, dir),
        .roots = roots orelse &.{},
        .skip = skip orelse &.{},
        .types = types orelse &.{},
    };
}

/// A scanner over the charter's bytes. Small enough to read in one sitting,
/// which is the point: a corpus declaration whose grammar needs a parser
/// generator is a corpus declaration nobody will audit.
const Cursor = struct {
    src: []const u8,
    i: usize = 0,
    err: ?anyerror = null,

    fn fault(self: *Cursor) !void {
        if (self.err) |e| return e;
    }

    fn skipDead(self: *Cursor) void {
        while (self.i < self.src.len) : (self.i += 1) switch (self.src[self.i]) {
            ' ', '\t', '\r', '\n', ',' => {},
            '#' => while (self.i < self.src.len and self.src[self.i] != '\n') : (self.i += 1) {},
            else => return,
        };
    }

    /// The next bare key, or null at end of input (or once faulted).
    fn key(self: *Cursor) ?[]const u8 {
        if (self.err != null) return null;
        self.skipDead();
        const start = self.i;
        while (self.i < self.src.len) : (self.i += 1) switch (self.src[self.i]) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => {},
            else => break,
        };
        if (self.i == start) {
            if (self.i < self.src.len) self.err = Fault.ExpectedValue;
            return null;
        }
        return self.src[start..self.i];
    }

    fn equals(self: *Cursor) !void {
        self.skipDead();
        if (self.i >= self.src.len or self.src[self.i] != '=') return Fault.ExpectedEquals;
        self.i += 1;
    }

    /// A bare string, or a `[…]` list of them — one shape, since every charter
    /// key is a set and a lone string is just a set of one.
    fn values(self: *Cursor, gpa: std.mem.Allocator) ![][]const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |s| gpa.free(s);
            out.deinit(gpa);
        }
        self.skipDead();
        if (self.i < self.src.len and self.src[self.i] == '[') {
            self.i += 1;
            while (true) {
                self.skipDead();
                if (self.i < self.src.len and self.src[self.i] == ']') {
                    self.i += 1;
                    break;
                }
                if (self.i >= self.src.len) return Fault.ExpectedValue;
                if (out.items.len >= max_entries) return Fault.TooManyEntries;
                try out.append(gpa, try self.string(gpa));
            }
        } else {
            try out.append(gpa, try self.string(gpa));
        }
        return out.toOwnedSlice(gpa);
    }

    fn string(self: *Cursor, gpa: std.mem.Allocator) ![]const u8 {
        if (self.i >= self.src.len or self.src[self.i] != '"') return Fault.ExpectedValue;
        self.i += 1;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        while (self.i < self.src.len) : (self.i += 1) switch (self.src[self.i]) {
            '"' => {
                self.i += 1;
                if (out.items.len == 0) return Fault.EmptyValue;
                return out.toOwnedSlice(gpa);
            },
            '\n' => return Fault.UnterminatedString,
            '\\' => {
                self.i += 1;
                if (self.i >= self.src.len) return Fault.UnterminatedString;
                switch (self.src[self.i]) {
                    '"', '\\' => try out.append(gpa, self.src[self.i]),
                    else => return Fault.BadEscape,
                }
            },
            else => |c| try out.append(gpa, c),
        };
        return Fault.UnterminatedString;
    }
};
