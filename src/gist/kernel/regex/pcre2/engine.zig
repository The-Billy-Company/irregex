//! gist — the PCRE2-backed `Pcre` engine behind the frozen `matcher.zig` seam.
//!
//! One `Pcre` owns an immutable compiled program (`ffi.Code`), optionally
//! JIT-compiled, plus the derived required literal for the trigram prefilter.
//! It is shared read-only across worker threads; all mutable match state lives
//! in the per-thread `Sim`/`SpanSim` scratch (a PCRE2 match-data block, a match
//! context carrying deterministic resource ceilings, and a private JIT stack) —
//! PCRE2 match data must never be shared between threads, so the scratch is the
//! thread-local half of the split. See `README.md` for the vendoring + JIT
//! story and `../matcher.zig` for the union that dispatches to us.

const std = @import("std");
const core = @import("../linear/core.zig");
const ffi = @import("ffi.zig");
const literal = @import("literal.zig");

/// One byte span `[start, end)` — the linear engine's type, so the shared
/// output layer names a single `Span` across both engines.
pub const Span = core.Regex.Span;

/// Compile-time engine knobs mirroring `Regex.Options`. `unicode` selects
/// PCRE2 UTF+UCP semantics (ripgrep's `-P` default); off ⇒ raw bytes / ASCII.
pub const Options = struct {
    caseless: bool = false,
    multiline: bool = false,
    dotall: bool = false,
    unicode: bool = true,
};

/// `Unsupported` = built without / unavailable; `BadPattern` = a compile
/// diagnostic (message in `last_error`); `OutOfMemory` = allocation failure.
pub const CompileError = error{ Unsupported, BadPattern, OutOfMemory };

// ── deterministic ceilings so pathological input errors instead of hanging ──
// A 10 MiB JIT stack matches ripgrep's `-P` parity. The match limit bounds the
// interpreter/JIT step count (catastrophic backtracking trips it in
// milliseconds and surfaces as a clean no-match, never a hang); the depth limit
// bounds interpreter recursion. These mirror PCRE2's own defaults except the
// stack cap, which we make explicit.
pub const jit_stack_max: usize = 10 * 1024 * 1024;
pub const jit_stack_start: usize = 32 * 1024;
pub const match_limit: u32 = 10_000_000;
pub const depth_limit: u32 = 10_000;

/// No match-time option bits: UTF + UCP + invalid-UTF tolerance are baked into
/// the compiled program (they are `pcre2_compile` options), so every
/// `pcre2_match` call passes 0. Named so the intent is explicit at the call.
pub const match_options: u32 = 0;

/// A valid, aligned pointer for a zero-length subject — PCRE2 reads no bytes at
/// length 0 but wants a non-null pointer. Shared by the match + capture engines.
pub const empty_subject: [*]const u8 = &[_]u8{0};

/// The `pcre2_compile` option bits for `opts` — CASELESS/MULTILINE/DOTALL plus,
/// under `unicode`, UTF+UCP with invalid-UTF tolerance (rg's `-P` default). One
/// mapping shared by the match program and the capture program so `-P -r` folds,
/// anchors, and Unicode-matches exactly like the search that produced the span.
pub fn compileOptionBits(opts: Options) u32 {
    var bits: u32 = 0;
    if (opts.caseless) bits |= ffi.CASELESS;
    if (opts.multiline) bits |= ffi.MULTILINE;
    if (opts.dotall) bits |= ffi.DOTALL;
    if (opts.unicode) bits |= ffi.UTF | ffi.UCP | ffi.MATCH_INVALID_UTF;
    return bits;
}

/// Last compile diagnostic, rendered for the caller after a `BadPattern`. It is
/// process-global scratch (a bad pattern is a fatal CLI event, not a concurrent
/// hot path), so a single buffer is sufficient and avoids threading an error
/// string back through the frozen `CompileError` surface.
threadlocal var last_error_buf: [256]u8 = undefined;
threadlocal var last_error_len: usize = 0;

/// The most recent compile diagnostic for this thread ("" if none).
pub fn lastError() []const u8 {
    return last_error_buf[0..last_error_len];
}

/// Sticky match-time error code for the whole run (0 = none). `Scratch.find`
/// latches any `pcre2_match` failure that is NOT a clean no-match here —
/// catastrophic backtracking (match/depth limit), a JIT stack overflow, an
/// internal fault. ripgrep aborts the run and exits 2 on exactly these, so the
/// CLI reads this after the search and mirrors that exit rather than reporting
/// the silent no-match `find` returns (fail-closed). A process-global atomic
/// (not thread-local) so the parallel `-P` pipeline's worker threads all latch
/// into one cell the main thread reads after they join — one gist process runs
/// exactly one query, so a single global is the whole run's verdict.
var match_error_code: std.atomic.Value(c_int) = .init(0);

/// The latched match-time error for this run (0 = none). Reset with
/// `clearMatchError` at the start of a run.
pub fn matchError() c_int {
    return match_error_code.load(.acquire);
}

/// Clear the sticky match-time error (call once before a search begins).
pub fn clearMatchError() void {
    match_error_code.store(0, .release);
}

/// Latch a `pcre2_match` return code as a fault iff it is worse than a clean
/// no-match (`< ERROR_NOMATCH`) — the match/depth-limit and JIT-stack failures
/// ripgrep exits 2 on. Shared by the boolean/span `Scratch` and the capture
/// engine (and safe across the parallel pipeline's workers) so all paths
/// surface catastrophic input identically.
pub fn recordMatchFault(rc: c_int) void {
    if (rc < ffi.ERROR_NOMATCH) match_error_code.store(rc, .release);
}

/// Render the latched match-time error into `buf` (empty when none), for the
/// stderr diagnostic the CLI prints alongside its exit-2.
pub fn matchErrorMessage(buf: []u8) []const u8 {
    const code = match_error_code.load(.acquire);
    if (code == 0) return "";
    return ffi.errorMessage(code, buf);
}

/// Render a PCRE2 compile error code into the thread-local diagnostic buffer
/// (read back via `lastError` after a `BadPattern`).
pub fn recordError(code: c_int) void {
    const msg = ffi.errorMessage(code, &last_error_buf);
    // `errorMessage` wrote into the buffer (or returned a static fallback).
    last_error_len = if (msg.ptr == &last_error_buf) msg.len else blk: {
        const n = @min(msg.len, last_error_buf.len);
        @memcpy(last_error_buf[0..n], msg[0..n]);
        break :blk n;
    };
}

/// A compiled PCRE2 program + its trigram-prefilter literal. Immutable after
/// `compileOpts`; shared across threads (per-thread `Sim`/`SpanSim` hold the
/// only mutable state).
pub const Pcre = struct {
    /// Longest literal present in every match ("" if none) — the sound trigram
    /// prefilter. Never over-claims (see `literal.zig`).
    required: []u8 = &.{},
    /// Alternation cover set. Left empty by this backend (conservative): the
    /// required literal alone is a sound prefilter, and an unsound cover set
    /// would let the index elide a real match.
    alts: []const []const u8 = &.{},
    /// Can the pattern match zero-width? Governs the `-o` empty-match rule.
    nullable: bool = false,
    /// Whole-buffer (`-U`) semantics: `^`/`$` at line boundaries, match may
    /// cross `\n`.
    multiline: bool = false,
    allocator: std.mem.Allocator = undefined,
    /// The compiled program (shared, read-only during matching).
    code: *ffi.Code = undefined,
    /// True iff `pcre2_jit_compile` succeeded; false ⇒ interpreter fallback.
    jit: bool = false,

    /// Compile `pattern` into a PCRE2 program, JIT-compiling when the platform
    /// supports it. Declines with `BadPattern` (diagnostic in `lastError`) for
    /// an invalid pattern, `OutOfMemory` on allocation failure.
    pub fn compileOpts(allocator: std.mem.Allocator, pattern: []const u8, opts: Options) CompileError!Pcre {
        return compileMode(allocator, pattern, opts, true);
    }

    pub fn deinit(self: *Pcre) void {
        ffi.pcre2_code_free_8(self.code);
        if (self.required.len > 0) self.allocator.free(self.required);
        self.* = undefined;
    }

    /// Per-thread PCRE2 match scratch: a match-data block, a match context with
    /// the resource ceilings, and (when JIT'd) a private 10 MiB JIT stack. One
    /// per worker; never shared — this is the thread-local half of the engine.
    const Scratch = struct {
        md: *ffi.MatchData,
        mc: *ffi.MatchContext,
        jit_stack: ?*ffi.JitStack,

        fn init(re: *const Pcre) CompileError!Scratch {
            const md = ffi.pcre2_match_data_create_from_pattern_8(re.code, null) orelse
                return CompileError.OutOfMemory;
            errdefer ffi.pcre2_match_data_free_8(md);
            const mc = ffi.pcre2_match_context_create_8(null) orelse
                return CompileError.OutOfMemory;
            errdefer ffi.pcre2_match_context_free_8(mc);
            _ = ffi.pcre2_set_match_limit_8(mc, match_limit);
            _ = ffi.pcre2_set_depth_limit_8(mc, depth_limit);

            var jit_stack: ?*ffi.JitStack = null;
            if (re.jit) {
                jit_stack = ffi.pcre2_jit_stack_create_8(jit_stack_start, jit_stack_max, null);
                if (jit_stack) |js| ffi.pcre2_jit_stack_assign_8(mc, null, js);
            }
            return .{ .md = md, .mc = mc, .jit_stack = jit_stack };
        }
        fn deinit(self: *Scratch) void {
            if (self.jit_stack) |js| ffi.pcre2_jit_stack_free_8(js);
            ffi.pcre2_match_context_free_8(self.mc);
            ffi.pcre2_match_data_free_8(self.md);
            self.* = undefined;
        }
        /// Leftmost match in `hay[from..]`, or null (no match OR a resource
        /// limit — fail-closed: never report a match we could not verify).
        fn find(self: *Scratch, re: *const Pcre, hay: []const u8, from: usize) ?Span {
            if (from > hay.len) return null;
            const subject: [*]const u8 = if (hay.len == 0) empty_subject else hay.ptr;
            const rc = ffi.pcre2_match_8(re.code, subject, hay.len, from, match_options, self.md, self.mc);
            if (rc < 0) {
                // A clean no-match is `ERROR_NOMATCH`; anything more negative is a
                // resource limit or fault ripgrep exits 2 on — latch it (last one
                // wins; any error is enough to force the exit-2 the CLI mirrors).
                recordMatchFault(rc);
                return null;
            }
            const ov = ffi.pcre2_get_ovector_pointer_8(self.md);
            return .{ .start = ov[0], .end = ov[1] };
        }
    };

    /// Per-query boolean-match scratch (the `Regex.Sim` twin).
    pub const Sim = struct {
        scratch: Scratch,
        pub fn init(allocator: std.mem.Allocator, re: *const Pcre) CompileError!Sim {
            _ = allocator; // PCRE2 owns its own allocations
            return .{ .scratch = try Scratch.init(re) };
        }
        pub fn deinit(self: *Sim) void {
            self.scratch.deinit();
        }
    };

    /// Per-query span-extraction scratch (the `Regex.SpanSim` twin).
    pub const SpanSim = struct {
        scratch: Scratch,
        pub fn init(allocator: std.mem.Allocator, re: *const Pcre) CompileError!SpanSim {
            _ = allocator;
            return .{ .scratch = try Scratch.init(re) };
        }
        pub fn deinit(self: *SpanSim) void {
            self.scratch.deinit();
        }
    };

    /// Does the pattern match any substring of `line`? (Per-line boolean path.)
    pub fn lineMatch(self: *const Pcre, sim: *Sim, line: []const u8) bool {
        return sim.scratch.find(self, line, 0) != null;
    }

    /// Does any line of `doc` match? rg `-l` line model: `\n` terminates a line
    /// (no phantom empty final line for a trailing newline); content after the
    /// last `\n` is a line. Mirrors `Regex.docMatch` so `^`/`$` anchor per line.
    pub fn docMatch(self: *const Pcre, sim: *Sim, doc: []const u8) bool {
        if (doc.len == 0) return false;
        var rest = doc;
        while (rest.len > 0) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n');
            const end = nl orelse rest.len;
            if (sim.scratch.find(self, rest[0..end], 0) != null) return true;
            if (nl == null) break;
            rest = rest[end + 1 ..];
        }
        return false;
    }

    /// Does the pattern match any substring of the WHOLE buffer under multiline
    /// semantics? Compiled with `PCRE2_MULTILINE`, one unanchored search over
    /// the buffer already realizes rg's `-U` model. The multiline twin of
    /// `docMatch`; empty buffer never matches (rg's line model).
    pub fn bufMatch(self: *const Pcre, sim: *Sim, buf: []const u8) bool {
        if (buf.len == 0) return false;
        return sim.scratch.find(self, buf, 0) != null;
    }

    /// Leftmost match of the pattern within `hay[from..]` as a byte span, or
    /// null. `hay` is a line in the per-line default, the buffer under `-U`.
    pub fn matchSpan(self: *const Pcre, sim: *SpanSim, hay: []const u8, from: usize) ?Span {
        return sim.scratch.find(self, hay, from);
    }
};

/// The compile core with an explicit JIT toggle. `Pcre.compileOpts` passes
/// `enable_jit = true` (JIT when the target supports it, interpreter otherwise);
/// tests pass `false` to force the interpreter path and prove the two engines
/// agree byte-for-byte. The interpreter is always the guaranteed fallback, so a
/// `false` here is exactly the platform-has-no-JIT case. Kept a module-level
/// helper (not a `Pcre` method) so the frozen `Pcre` surface stays byte-stable.
pub fn compileMode(allocator: std.mem.Allocator, pattern: []const u8, opts: Options, enable_jit: bool) CompileError!Pcre {
    const compile_options = compileOptionBits(opts);

    var errorcode: c_int = 0;
    var erroroffset: ffi.Size = 0;
    const code = ffi.pcre2_compile_8(
        pattern.ptr,
        pattern.len,
        compile_options,
        &errorcode,
        &erroroffset,
        null,
    ) orelse {
        recordError(errorcode);
        return CompileError.BadPattern;
    };
    errdefer ffi.pcre2_code_free_8(code);

    // Best-effort JIT; the interpreter is always the guaranteed fallback.
    const jit = enable_jit and ffi.pcre2_jit_compile_8(code, ffi.JIT_COMPLETE) == 0;

    const req = try literal.required(allocator, pattern, opts.caseless);
    errdefer allocator.free(req);

    return .{
        .required = req,
        .nullable = computeNullable(code, pattern),
        .multiline = opts.multiline,
        .allocator = allocator,
        .code = code,
        .jit = jit,
    };
}

/// Whether the pattern can match zero-width. Biased toward `true`: the emitter
/// consults this only on an actual zero-width span, and over-reporting is inert
/// while under-reporting drops rg-visible empty matches. So we take it as true
/// when the pattern matches the empty subject (`a*`, `x?`, `^$`) OR textually
/// carries a zero-width assertion that can match empty on non-empty input
/// (lookaround, `\b`/`\B`), which the empty-subject probe alone misses.
fn computeNullable(code: *ffi.Code, pattern: []const u8) bool {
    const md = ffi.pcre2_match_data_create_from_pattern_8(code, null) orelse return true;
    defer ffi.pcre2_match_data_free_8(md);
    if (ffi.pcre2_match_8(code, empty_subject, 0, 0, match_options, md, null) >= 0) return true;
    return containsZeroWidthAssertion(pattern);
}

/// True if `pattern` textually contains a lookaround or word-boundary assertion
/// — constructs that can match zero-width on non-empty input. Over-inclusive by
/// design (a false positive here is harmless per `computeNullable`).
fn containsZeroWidthAssertion(pattern: []const u8) bool {
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '\\' and i + 1 < pattern.len) {
            if (pattern[i + 1] == 'b' or pattern[i + 1] == 'B') return true;
            i += 1; // skip the escaped byte
        } else if (pattern[i] == '(' and i + 2 < pattern.len and pattern[i + 1] == '?') {
            switch (pattern[i + 2]) {
                '=', '!', '<' => return true, // (?= (?! (?<= (?<!
                else => {},
            }
        }
    }
    return false;
}
