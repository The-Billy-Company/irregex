//! gist search core — the compiled, transport-neutral query (ADR-352).
//!
//! One deep module owns "a search intent, compiled". A `(pattern, fixed,
//! ignore_case, mode)` spec — the whole shape the unified search contract admits
//! — lowers into an immutable matcher: a bare literal for the `-F` no-fold fast
//! path (SIMD substring), else gist's linear-time regex engine (a `-F -i` literal
//! is escaped so the engine does the ASCII case fold). From that one compiled
//! form every face draws the two things it needs — the sound TRIGRAM PREFILTER
//! that prunes index candidates, and the per-doc MATCH / line-COUNT decision.
//!
//! Two invariants make this the shared core the CLI, the resident daemon, and
//! (later) the C FFI can all execute through instead of forking the logic:
//!
//!   • Fail-closed, never fatal. Every entry point RETURNS a typed error — a
//!     pattern outside the linear-time syntax is `error.Unsupported`, an
//!     allocation failure is `error.OutOfMemory` — so a bad query can never
//!     `die()`/exit an embedding host (the exact hazard ADR-352 defers the FFI
//!     on). The CLI's cold path keeps its own `die()` shell; this core does not.
//!   • Thread-safe for the parallel walk. A `CompiledQuery` is immutable after
//!     `compile`; the only per-query mutable state — the regex Pike-VM
//!     simulation — is a caller-owned `Scratch`, one per worker, threaded into
//!     the match primitives. N workers share one compiled query with N scratches.
//!
//! Before this module, the warm engine (`session/resident.zig`) and the cold
//! engine (`commands/ripgrep/`) each re-derived the required-literal-vs-alts
//! prefilter and re-implemented literal/regex verification; the two "cannot
//! drift" only because they now compile and match through the same code here.

const std = @import("std");
const simd = @import("../scan/simd.zig");
const Regex = @import("../regex/core.zig").Regex;

/// The three mode shapes the shared core answers: `files` (any line matches),
/// `count` (how many lines match), and `lines` (the default `path:text` match
/// lines — rendered by the warm session through the cold `Emitter` itself, so
/// the presentation cannot drift). Richer cold-only presentations (context,
/// JSON, replace, --only-matching) stay in `commands/ripgrep/` — they consume
/// the same match decision but shape their own output.
pub const Mode = enum(u8) { files = 0, count = 1, lines = 2 };

/// A search intent before compilation. Mirrors the resident classifier's
/// `Request` fields (`session/request.zig`) — the transport-neutral subset of
/// the contract's request options.
pub const Spec = struct {
    /// The search pattern. For a `literal` body it is aliased, not copied — the
    /// caller keeps it alive for the query's lifetime.
    pattern: []const u8,
    mode: Mode = .files,
    /// `-F`: treat the pattern as a fixed string, not a regex.
    fixed: bool = false,
    /// `-i`: case-insensitive (Unicode fold when `unicode`, else ASCII).
    ignore_case: bool = false,
    /// Unicode mode (rg default ON): full case-fold orbits and codepoint
    /// `\w`/`\d`/`\s`/`.`/`\p{…}`/`\b`. The resident fast path never sees an
    /// explicit `--no-unicode`/`(?-u)` (its classifier hands those to the cold
    /// engine), so it always compiles at the rg-parity default.
    unicode: bool = true,
};

pub const CompileError = error{
    /// The pattern is outside gist's linear-time regex syntax (e.g. a construct
    /// only PCRE would accept). The caller answers cold rather than approximating.
    Unsupported,
    OutOfMemory,
};

/// Per-query mutable match scratch — the regex simulation state, or nothing for
/// a literal query. One per thread; never shared. Made by `CompiledQuery.scratch`.
pub const Scratch = union(enum) {
    none,
    sim: Regex.Sim,

    pub fn deinit(self: *Scratch) void {
        switch (self.*) {
            .sim => |*s| s.deinit(),
            .none => {},
        }
    }
};

/// A compiled, immutable search intent. Cheap to share across walk workers;
/// `deinit` releases the compiled regex and any escaped-literal buffer.
pub const CompiledQuery = struct {
    mode: Mode,
    /// `-i` was requested — recorded because it makes the trigram required-literal
    /// prefilter an UNsafe proxy for "can match" (the fold changes which bytes
    /// appear), so `prefilter` must decline for a caseless regex.
    caseless: bool,
    body: union(enum) {
        /// `-F` no-fold: verified by `simd.contains`. Aliases `Spec.pattern`.
        literal: []const u8,
        /// The compiled linear-time engine (plain regex, or an escaped `-F -i`).
        regex: Regex,
    },
    /// Owns the escaped-literal buffer for the `-F -i` path (regex over a fixed
    /// string); null otherwise. Freed by `deinit`.
    escaped: ?[]u8 = null,

    /// Lower a spec into a compiled query. `-F` without `-i` becomes a literal
    /// (the SIMD fast path); everything else compiles to the regex engine, with
    /// a fixed `-F -i` string escaped first so the engine, not a raw substring
    /// scan, applies the case fold.
    pub fn compile(gpa: std.mem.Allocator, spec: Spec) CompileError!CompiledQuery {
        if (spec.fixed and !spec.ignore_case)
            return .{ .mode = spec.mode, .caseless = false, .body = .{ .literal = spec.pattern } };

        var escaped: ?[]u8 = null;
        const pat = if (spec.fixed) blk: {
            const e = try escapeLiteral(gpa, spec.pattern);
            escaped = e;
            break :blk e;
        } else spec.pattern;
        errdefer if (escaped) |e| gpa.free(e);

        const re = Regex.compileOpts(gpa, pat, .{ .caseless = spec.ignore_case, .unicode = spec.unicode }) catch
            return CompileError.Unsupported;
        return .{ .mode = spec.mode, .caseless = spec.ignore_case, .body = .{ .regex = re }, .escaped = escaped };
    }

    pub fn deinit(self: *CompiledQuery, gpa: std.mem.Allocator) void {
        switch (self.body) {
            .regex => |*re| re.deinit(),
            .literal => {},
        }
        if (self.escaped) |e| gpa.free(e);
    }

    /// A fresh per-thread match scratch: the regex simulation for a regex body,
    /// or `.none` for a literal (SIMD substring needs no state).
    pub fn scratch(self: *const CompiledQuery, gpa: std.mem.Allocator) CompileError!Scratch {
        return switch (self.body) {
            .literal => .none,
            .regex => |*re| .{ .sim = Regex.Sim.init(gpa, re) catch return CompileError.OutOfMemory },
        };
    }

    /// The sound trigram prefilter literals for pruning index candidates, or
    /// empty when none apply. A caseless query declines (the fold makes a raw
    /// literal an unsafe proxy). A literal body yields the needle itself (≥3
    /// bytes — a trigram needs three); a regex yields its guaranteed required
    /// literal (≥3), else its per-branch alternation cover (`foo|bar` ⇒
    /// {foo,bar}), both of which the index treats as sound supersets. `one`
    /// backs the single-literal return so the callee allocates nothing.
    pub fn prefilter(self: *const CompiledQuery, one: *[1][]const u8) []const []const u8 {
        if (self.caseless) return &.{};
        switch (self.body) {
            .literal => |needle| {
                if (needle.len < 3) return &.{};
                one[0] = needle;
                return one[0..1];
            },
            .regex => |*re| return regexPrefilter(re, one),
        }
    }

    /// Does any line of `bytes` match? (rg `-l` semantics.) Literal → substring
    /// presence; regex → whole-doc match over the caller's `scratch`.
    pub fn docMatches(self: *const CompiledQuery, bytes: []const u8, sc: *Scratch) bool {
        return switch (self.body) {
            .literal => |needle| simd.contains(bytes, needle),
            .regex => |*re| re.docMatch(&sc.sim, bytes),
        };
    }

    /// Count matching LINES in `bytes` (rg `-c` semantics), over rg's line model
    /// (`\n` terminates; no phantom final line).
    pub fn countLines(self: *const CompiledQuery, bytes: []const u8, sc: *Scratch) u64 {
        var n: u64 = 0;
        var rest = bytes;
        while (rest.len > 0) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n');
            const end = nl orelse rest.len;
            const line = rest[0..end];
            const hit = switch (self.body) {
                .literal => |needle| simd.contains(line, needle),
                .regex => |*re| re.lineMatch(&sc.sim, line),
            };
            if (hit) n += 1;
            if (nl == null) break;
            rest = rest[end + 1 ..];
        }
        return n;
    }
};

/// The sound trigram prefilter for a compiled regex, independent of the
/// caseless/mode guards a specific face layers on top: the engine's guaranteed
/// required literal (present in EVERY match) when it is ≥3 bytes, else its
/// per-branch alternation cover (`re.alts`). Shared verbatim by the compiled
/// query above and the cold CLI's `trigramFilter`, so warm and cold cannot drift
/// on which literals are safe to prune by.
pub fn regexPrefilter(re: *const Regex, one: *[1][]const u8) []const []const u8 {
    if (re.required.len >= 3) {
        one[0] = re.required;
        return one[0..1];
    }
    return re.alts;
}

/// Escape a literal into a regex (for the caseless `-F -i` path, where the
/// trigram prefilter is unsafe and the regex engine does the case fold).
/// `pub` because the warm lines renderer (`session/render.zig`) builds its
/// emission `Matcher` from the SAME escaped form the cold `-F` path compiles.
pub fn escapeLiteral(a: std.mem.Allocator, pat: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (pat) |c| {
        switch (c) {
            '.', '^', '$', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '\\' => try out.append(a, '\\'),
            else => {},
        }
        try out.append(a, c);
    }
    return out.toOwnedSlice(a);
}
