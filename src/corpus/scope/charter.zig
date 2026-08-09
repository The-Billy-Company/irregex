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
//!            `.gist/`, so "seed `derived-out`" was per-machine folklore and a
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
//! `key = ["a", "b"]`, `#` comments — and every departure from it is refused with
//! a line number rather than half-applied. It is deliberately NOT ripgrep's
//! "each line is a verbatim argv element", which has no tokenization and so turns
//! an ordinary quoted glob into a silent no-match (ripgrep #927, #932, #2646,
//! #3428 — still being filed). Here a quote is a quote.
//!
//! WHAT A REFUSAL COSTS IS THE CALLER'S, NOT THIS MODULE'S. A face refuses to
//! search at all — the judgement is right, and it stays — but this file is also
//! read from inside an embedding host through the C ABI, where ending the process
//! is a defect no host can catch. So a malformed charter is dropped and its
//! reason left readable (`faulted`), and a CLI ADOPTS the loud exit at startup
//! (`failLoud`, reached by `honorNoConfig`). See `Refusal`.

const std = @import("std");
const assay = @import("../../assay/assay.zig");
const misread = @import("../../kernel/math/misread.zig");
const portal = @import("../../portal.zig");

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

/// The keys a charter may declare — the suggestion set, and the sentence the
/// fault note quotes, kept as one list so they cannot disagree.
pub const keys = [_][]const u8{ "roots", "skip", "types" };

/// Why a charter was rejected. Every one of these is a refusal rather than a
/// shrug: a corpus declaration that half-parsed would mean searching a corpus
/// nobody described, which is worse than not having the file. What a refusal
/// *costs* is the caller's to decide — see `Refusal`.
// File-private parse vocabulary (the fault-channel taxonomy): these names never leave this module
// as a public error set — callers read one back through `faulted()`, tests assert
// via global `error.X`.
const Fault = error{
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

// ── refusal: who decides what a malformed charter costs ──────────────────────

/// What a malformed charter costs the caller who asked for it.
///
/// The judgement itself is not in dispute — a corpus nobody described is worse
/// than no file — but the *remedy* differs by who is asking, and only one of the
/// two askers may be assumed. `governing` is called from the middle of corpus
/// setup: root resolution (`corpus.resolveRoots`), the walk's skip overlay
/// (`haystack.extra_skips`), the type-def pass (`argv.grammar`). Every one of
/// those also runs inside an embedding host, behind the C ABI, where
/// `process.exit(2)` is a defect with no catch — the same reason `ignore.zig`
/// returns `Oom` rather than exiting, stated at its own `Oom` alias.
///
/// So the default is `fault`: the charter is dropped, the reason stays readable
/// through `faulted()`, and the walk proceeds on the tree's undeclared defaults.
/// A CLI's remedy is the opposite one and it is correct for a CLI — refuse to
/// search rather than search the wrong tree — so a face ADOPTS `exit` at
/// startup, where the process it would end is its own.
pub const Refusal = enum {
    /// Drop the charter and leave the reason in `faulted()`. A library may not
    /// choose anything else.
    fault,
    /// Say why on the diagnostic channel and end the process with status 2.
    exit,
};

/// The posture in force. Library-safe until a face states otherwise, so the
/// never-terminate-the-host property holds by construction rather than by every
/// future caller remembering to ask for it.
var refusal: Refusal = .fault;

/// Adopt the CLI's fail-loud posture: the next search that asks for a malformed
/// charter reports it and exits 2. `honorNoConfig` calls this, so every face
/// that scans raw argv gets it without asking; a face that does not scan argv
/// calls it directly.
///
/// Deliberately NOT a validation — it arms the posture and reads nothing. Eager
/// validation here would kill `gist config check`, whose entire job is to
/// REPORT a malformed charter and which runs after this call, in the same
/// process, in every face. That is also why `governing` applies the posture
/// lazily instead: `config` reaches the file through `inspect`/`faulted`, which
/// have no posture at all.
pub fn failLoud() void {
    refusal = .exit;
}

/// The posture in force — what a malformed charter would cost right now.
pub fn refusalNow() Refusal {
    return refusal;
}

/// A posture held for the duration of a scope, with whatever was in force
/// before put back on the way out. Same shape and same reason as
/// `haystack.stateSkipOverlay`: a caller that must not terminate — the C seam,
/// a test — states its own and restores the ambient one, rather than trusting
/// that nothing upstream armed the other.
pub const StatedRefusal = struct {
    ambient: Refusal,

    pub fn release(self: StatedRefusal) void {
        refusal = self.ambient;
    }
};

pub fn stateRefusal(r: Refusal) StatedRefusal {
    const ambient = refusal;
    refusal = r;
    return .{ .ambient = ambient };
}

// ── discovery ────────────────────────────────────────────────────────────────

/// The charter governing the working directory, or `null` when the tree has
/// none. Resolved once per process and cached; the result is borrowed for the
/// process lifetime, exactly as the env-var knobs beside it are.
///
/// `null` is also the answer for a charter that would not parse, and the fault
/// behind it is readable through `faulted()` rather than thrown — this returns
/// an optional, not an error union, because its three callers ask the question
/// while assembling a walk and none of them can act on the reason. Under the
/// `exit` posture a face has adopted, a fault is instead reported and ends the
/// process here; see `Refusal` for why that decision is the caller's.
pub fn governing() ?*const Charter {
    if (suppressedNow()) return null;
    const c = inspect();
    if (state.fault) |e| if (refusal == .exit) {
        report(e);
        std.process.exit(2);
    };
    return c;
}

/// What the file SAYS — for a caller whose job is to report on the
/// configuration rather than to search under it. Two ways this differs from
/// `governing`, both for the same reason:
///
///   * a parse fault is recorded rather than fatal, so `gist config check` can
///     say "the charter is malformed *and* here is the state of your
///     preferences" instead of dying on the first of the two;
///   * suppression is not consulted, because `--no-config` is a fact about
///     *this run's search*, not about the file. A reader whose shell exports
///     `GIST_NO_CONFIG` still needs `gist config` and `gist status` to describe
///     what is on disk — a configuration you cannot interrogate is the actual
///     defect in ripgrep's version of this feature, and refusing to answer
///     precisely when something is overriding you reproduces it.
pub fn inspect() ?*const Charter {
    if (state.done) return state.charter;
    state.done = true;

    const gpa = std.heap.page_allocator; // process-lifetime; never freed
    state.charter = discover(gpa) catch |e| {
        state.fault = e;
        return null;
    };
    return state.charter;
}

/// Say why the charter could not be used, located and with a guess where one is
/// worth making. Split from the exit so `gist config check` can print the same
/// sentence for a file it is only inspecting — and so the `exit` posture is a
/// two-line policy over this rather than a second copy of the wording.
///
/// Writes to the diagnostic channel, so it belongs to a caller that HAS one: the
/// library path never reaches it (`governing` under `Refusal.fault` returns
/// without reporting), which is what keeps an embedding host's streams clean.
pub fn report(e: anyerror) void {
    var loc: [24]u8 = undefined;
    assay.diag(assay.tag ++ "{s}{s}: {s}\n", .{ state.faulted_path, misread.at(&loc, state.diag), faultNote(e) });
    if (didYouMean(e, state.diag.token)) |k| {
        assay.diag(assay.tag ++ "try `{s} = [...]` — `{s}` is not a charter key\n", .{ k, state.diag.token });
    }
    assay.diag(assay.tag ++ "note: --no-config ignores it for this run\n", .{});
}

/// The key worth suggesting for a fault, or null when there is none.
///
/// Which faults are ABOUT a name is part of this answer, not the caller's to
/// remember: only `UnknownKey` is, and an unterminated string that happens to
/// have a legal key as its most recent token would otherwise be answered with
/// "try `skip` — `skip` is not a charter key". One function, so the run's exit
/// path and `gist config check` cannot come apart on it.
pub fn didYouMean(e: anyerror, token: []const u8) ?[]const u8 {
    if (e != Fault.UnknownKey) return null;
    return misread.nearest(token, &keys);
}

/// The fault that kept the charter from loading, if any. This is how a caller
/// learns WHY `governing` handed back nothing: the reason does not ride the
/// return type (see `governing`), so it is pulled from here — the same
/// ask-afterwards grammar `irgx_last_fault` uses at the C seam, which is the one
/// consumer that then has to name a domain member for it.
pub fn faulted() ?struct { path: []const u8, err: anyerror, at: misread.Diagnostic } {
    _ = inspect();
    const e = state.fault orelse return null;
    return .{ .path = state.faulted_path, .err = e, .at = state.diag };
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
    return suppressed or assay.knobFlag("NO_CONFIG");
}

/// Answer `--no-config` from RAW argv — every face's first act, before any verb
/// dispatch. It has to run here rather than in the grammar because a flag whose
/// job is to suppress a file cannot be learned from that file, and the charter
/// is consulted by root resolution long before flags are parsed. A `--`
/// separator ends the scan: past it, the token is a pattern.
/// `gpa` is needed only because Windows argv arrives as one unsplit command line
/// (see `portal.argsIterator`); on POSIX it is untouched. A platform that cannot
/// even enumerate its own arguments has nothing to suppress, so a failure here
/// leaves the charter honored rather than silently disabling it.
///
/// It also ADOPTS the fail-loud posture (`failLoud`), which is why this is the
/// right seam for it rather than a second call every face would have to
/// remember: having an argv at all is the fact that distinguishes a face from a
/// library, and this is the one function that takes one before anything is
/// searched. A face with no argv scan states the posture itself.
pub fn honorNoConfig(gpa: std.mem.Allocator, argv: std.process.Args) void {
    failLoud();
    var scan = portal.argsIterator(argv, gpa) catch return;
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
    fault: ?anyerror = null,
    diag: misread.Diagnostic = .{},
    /// `discover` builds candidate paths in a stack buffer, so the one we keep
    /// to name in a fault has to be copied out of it — `faulted()` may be read
    /// long after that frame is gone.
    path_bytes: [max_climb * 3 + 32]u8 = undefined,
    /// Likewise for the faulting token, which the parser slices out of the
    /// file's bytes — freed before anyone reads the diagnostic.
    token_bytes: [128]u8 = undefined,
} = .{};

fn rememberPath(path: []const u8) void {
    const n = @min(path.len, state.path_bytes.len);
    @memcpy(state.path_bytes[0..n], path[0..n]);
    state.faulted_path = state.path_bytes[0..n];
}

pub fn faultNote(e: anyerror) []const u8 {
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
    if (assay.knob("CHARTER")) |explicit| {
        rememberPath(explicit);
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
            rememberPath(path);
            return try place(gpa, state.faulted_path, dir, src);
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
    const fd = portal.openFile(portal.cwd(), path) catch return false;
    portal.close(fd);
    return true;
}

/// Read a whole persisted-configuration file, refusing one too large to be one.
/// Shared with the preferences reader: both layers are opened before any `Io`
/// exists (root resolution and argv assembly both precede it), and both would
/// rather report `Oversized` than allocate against a pointed-at video file.
pub fn slurp(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const fd = try portal.openFile(portal.cwd(), path);
    defer portal.close(fd);
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
        const n = try portal.read(fd, buf[read..]);
        if (n == 0) break;
        read += n;
    }
    return gpa.realloc(buf, read);
}

fn place(gpa: std.mem.Allocator, path: []const u8, dir: []const u8, src: []const u8) !*const Charter {
    const owned = try gpa.create(Charter);
    errdefer gpa.destroy(owned);
    owned.* = parse(gpa, path, dir, src, &state.diag) catch |e| {
        state.diag.token = misread.keepToken(&state.token_bytes, state.diag.token);
        return e;
    };
    return owned;
}

// ── parsing ──────────────────────────────────────────────────────────────────

/// Parse a charter's bytes. Returns errors rather than exiting so the format is
/// testable; `governing` is the single place that turns a fault into an exit.
pub fn parse(gpa: std.mem.Allocator, path: []const u8, dir: []const u8, src: []const u8, diag: ?*misread.Diagnostic) !Charter {
    var roots: ?[][]const u8 = null;
    var skip: ?[][]const u8 = null;
    var types: ?[][]const u8 = null;
    errdefer for ([_]?[][]const u8{ roots, skip, types }) |maybe| if (maybe) |list| {
        for (list) |s| gpa.free(s);
        gpa.free(list);
    };

    var p: Cursor = .{ .src = src };
    // Every early return below is a fault, so the diagnostic is published on
    // the way out rather than at each of the seven `return`s.
    errdefer if (diag) |d| {
        d.* = .{ .line = p.lineNow(), .token = p.token };
    };

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
    /// The last thing read that a fault could be *about* — quoted back to the
    /// reader and fed to `nearest`. Tracked rather than reconstructed because
    /// by the time a value fails, `i` has moved past the key that names it.
    token: []const u8 = "",

    fn fault(self: *Cursor) !void {
        if (self.err) |e| return e;
    }

    /// 1-based line of the cursor, counted on demand. A charter is a handful of
    /// lines read once per process, and paying for the count only when
    /// something is already going wrong keeps the happy path a pure scan.
    fn lineNow(self: *const Cursor) usize {
        const upto = @min(self.i, self.src.len);
        return 1 + std.mem.count(u8, self.src[0..upto], "\n");
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
        self.token = self.src[start..self.i];
        return self.token;
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
