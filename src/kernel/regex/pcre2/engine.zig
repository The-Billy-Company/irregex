//! irregex — the PCRE2-backed `Pcre` engine behind the frozen `matcher.zig`
//! seam.
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
const mark = @import("../../../mark.zig");
const core = @import("../linear/program/core.zig");
const ffi = @import("ffi.zig");
const literal = @import("literal.zig");
const shadow_mod = @import("shadow.zig");

/// One byte span `[start, end)` — the linear engine's type, so the shared
/// output layer names a single `Span` across both engines.
pub const Span = core.Regex.Span;

/// Compile-time engine knobs mirroring `Regex.Options`. `unicode` selects
/// PCRE2 UTF+UCP semantics (ripgrep's `-P` default); off ⇒ raw bytes / ASCII.
pub const Options = struct { caseless: bool = false, multiline: bool = false, dotall: bool = false, unicode: bool = true, word: bool = false, verbose: bool = false };

/// `-w` for this arm, as rg spells it for its own PCRE2 backend:
/// `(?<!\w)(?:PAT)(?!\w)`. Lookaround is free here, so the boundary becomes part
/// of the language exactly as the linear arm's `\b{start-half}` wrap does — and
/// for the same reason (a vet applied after the span is chosen cannot retry the
/// shorter arm at the same offset).
///
/// The wrapped text is what `pcre2_compile` sees and nothing else: the required
/// literal and the shadow gate keep reading the ORIGINAL pattern, whose language
/// CONTAINS the wrapped one, so both prefilters stay sound while staying blind to
/// a construct they would only have to skip. Returns `pattern` itself when there
/// is nothing to do, so a caller frees only what it did not pass in.
pub fn wordWrapped(allocator: std.mem.Allocator, pattern: []const u8, opts: Options) CompileError![]const u8 {
    if (!opts.word) return pattern;
    return std.fmt.allocPrint(allocator, word_lead ++ "{s})(?!\\w)", .{pattern}) catch CompileError.OutOfMemory;
}

/// What `wordWrapped` puts BEFORE the pattern — named so a compile diagnostic can
/// subtract it and keep pointing at the byte the user typed.
const word_lead = "(?<!\\w)(?:";

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

/// The ceilings a caller may put on one search — `mark.Limits`, re-exported so
/// this arm's callers name it once. `null` is "whatever this engine already
/// does", which here means the four constants above, so an all-null `Limits`
/// builds the exact match context the arm has always built.
///
/// `states` is inert here: this arm builds no automaton, so there is nothing
/// for a state ceiling to bound. Ignoring it rather than refusing it is the
/// type's own rule — a host that defensively sets every field should not be
/// punished for the caution the field exists to permit.
pub const Limits = mark.Limits;

/// Which ceiling a `BudgetExceeded` was about.
///
/// A reason rather than three error names, because a step budget, a recursion
/// depth and a heap ceiling are one fact — the limit this host asked for was
/// hit — and the taxonomy's rule is one member per condition, not one per call
/// site (`contract/engine.toml`, `[fault_domains].resource`). It is the same
/// shape `munch.Because` uses for a refusal: a small enumeration minted at
/// exactly one site and read beside the answer.
///
/// It needs no cell of its own. PCRE2 already distinguishes the three, so the
/// reason is a decode of the return code the arm was latching anyway.
pub const Ceiling = enum {
    /// `Limits.steps` — the backtracking budget ran out.
    steps,
    /// `Limits.depth` — the interpreter hit the frame ceiling.
    depth,
    /// `Limits.heap_bytes` — the frame vector could not grow further.
    heap,

    /// The ceiling `rc` reports, or null when it is any other outcome.
    pub fn of(rc: c_int) ?Ceiling {
        return switch (rc) {
            ffi.ERROR_MATCHLIMIT => .steps,
            ffi.ERROR_DEPTHLIMIT => .depth,
            ffi.ERROR_HEAPLIMIT => .heap,
            else => null,
        };
    }

    /// Did the CALLER name this ceiling, or is it the arm's own default?
    ///
    /// The distinction is what makes a `BudgetExceeded` honest. A default the
    /// caller never asked about tripping is the old fail-closed no-match this
    /// arm has always reported, and calling it "the budget you set" would be a
    /// fault about a request nobody made.
    fn asked(self: Ceiling, limits: Limits) bool {
        return switch (self) {
            .steps => limits.steps != null,
            .depth => limits.depth != null,
            .heap => limits.heap_bytes != null,
        };
    }
};

/// The one fault a ceiling produces. Never a declinature: `.stale` promises a
/// slower tier can answer, and there is no slower tier for a caller who asked
/// to be stopped — the remedy is a bigger ceiling, which only the caller can
/// grant. Distinct from `OutOfMemory` (the machine's limit, not the caller's).
pub const BudgetError = error{BudgetExceeded};

/// `value`, narrowed to the width PCRE2 spends it in — never upward.
///
/// A ceiling that granted more than it was asked for would be a ceiling in name
/// only, so the saturation is deliberately one-directional: `steps` arrives as
/// a `u64` and `heap_bytes` as a `usize`, and both are floored into `u32`.
fn narrowed(value: anytype) u32 {
    return @intCast(@min(value, std.math.maxInt(u32)));
}

/// Put `limits` on a fresh match context, leaving every unnamed ceiling at this
/// arm's own default so an all-null `Limits` is the context we always built.
///
/// `heap_bytes` is the one that cannot be forwarded verbatim: PCRE2 counts its
/// heap ceiling in kibibytes. The conversion floors, for the same reason the
/// narrowing does — under a sub-kibibyte request the honest answer is that
/// nothing PCRE2 can allocate fits inside it, and refusing is the fail-closed
/// direction. An unset `heap_bytes` never calls the setter at all, so PCRE2's
/// own default stands untouched.
pub fn applyLimits(mc: *ffi.MatchContext, limits: Limits) void {
    _ = ffi.pcre2_set_match_limit_8(mc, if (limits.steps) |s| narrowed(s) else match_limit);
    _ = ffi.pcre2_set_depth_limit_8(mc, limits.depth orelse depth_limit);
    if (limits.heap_bytes) |b| _ = ffi.pcre2_set_heap_limit_8(mc, narrowed(b / 1024));
}

/// May this compile be JIT'd, given the ceilings it must honor?
///
/// The JIT reads `match_limit` and nothing else — it runs on its own stack, so
/// `pcre2_set_depth_limit` and `pcre2_set_heap_limit` are simply not consulted
/// on that path (`vendor/pcre2/src/pcre2_jit_match_inc.h` forwards `limit_match`
/// alone). A host that asks to be bounded and is silently not bounded has a
/// safety property that only looks like one, so naming either of those two
/// ceilings costs the JIT: the interpreter is always the guaranteed fallback,
/// and a slower search that stops is what was actually requested. A caller that
/// sets only `steps` keeps the JIT, because the JIT honors that one.
pub fn jitHonors(limits: Limits) bool {
    return limits.depth == null and limits.heap_bytes == null;
}

/// No match-time option bits: UTF + UCP + invalid-UTF tolerance are baked into
/// the compiled program (they are `pcre2_compile` options), so every
/// `pcre2_match` call passes 0. Named so the intent is explicit at the call.
pub const match_options: u32 = 0;

/// A valid, aligned pointer for a zero-length subject — PCRE2 reads no bytes at
/// length 0 but wants a non-null pointer. Shared by the match + capture engines.
pub const empty_subject: [*]const u8 = &[_]u8{0};

/// The `pcre2_compile` option bits for `opts` — CASELESS/MULTILINE/DOTALL/
/// EXTENDED plus, under `unicode`, UTF+UCP with invalid-UTF tolerance (rg's
/// `-P` default). One
/// mapping shared by the match program and the capture program so `-P -r` folds,
/// anchors, and Unicode-matches exactly like the search that produced the span.
///
/// `EXTENDED` is PCRE2's `(?x)`: the same six whitespace bytes, the same
/// `#`-to-newline comment, both inert inside a class. Mapping it keeps the flag
/// meaning one thing across both arms, so `verbose=True, pcre=True` is not a
/// silently different pattern from `verbose=True`.
///
/// The one place PCRE2 and Python differ is *inside* a brace bound: PCRE2 reads
/// `a{1, 2}` as `a{1,2}` where `re` reads it as six literal characters. That is
/// PCRE2's own reading and not something this mapping can repair — the linear
/// arm refuses `a{1, 2}` outright (rust-regex's policy for a `{` that opens no
/// valid bound), so no arm here silently agrees with `re` about it.
pub fn compileOptionBits(opts: Options) u32 {
    var bits: u32 = 0;
    if (opts.caseless) bits |= ffi.CASELESS;
    if (opts.multiline) bits |= ffi.MULTILINE;
    if (opts.dotall) bits |= ffi.DOTALL;
    if (opts.verbose) bits |= ffi.EXTENDED;
    if (opts.unicode) bits |= ffi.UTF | ffi.UCP | ffi.MATCH_INVALID_UTF;
    return bits;
}

/// Last compile diagnostic, rendered for the caller after a `BadPattern`. It is
/// process-global scratch (a bad pattern is a fatal CLI event, not a concurrent
/// hot path), so a single buffer is sufficient and avoids threading an error
/// string back through the frozen `CompileError` surface.
threadlocal var last_error_buf: [256]u8 = undefined;
threadlocal var last_error_len: usize = 0;
threadlocal var last_error_offset: usize = 0;

/// The most recent compile diagnostic for this thread ("" if none).
pub fn lastError() []const u8 {
    return last_error_buf[0..last_error_len];
}

/// Sticky match-time error code for the whole run (0 = none). `Sim.find`
/// latches any `pcre2_match` failure that is NOT a clean no-match here —
/// catastrophic backtracking (match/depth limit), a JIT stack overflow, an
/// internal fault. ripgrep aborts the run and exits 2 on exactly these, so the
/// CLI reads this after the search and mirrors that exit rather than reporting
/// the silent no-match `find` returns (fail-closed). A process-global atomic
/// (not thread-local) so the parallel `-P` pipeline's worker threads all latch
/// into one cell the main thread reads after they join — one face process runs
/// exactly one query, so a single global is the whole run's verdict.
var match_error_code: std.atomic.Value(c_int) = .init(0);

/// The latched match-time error for this run (0 = none). Reset with
/// `clearMatchError` at the start of a run.
pub fn matchError() c_int {
    return match_error_code.load(.acquire);
}

/// The caller ceiling this run reached, latched beside the raw error code.
///
/// One cell rather than a decode of `matchError`, because the return code alone
/// cannot tell the two ceilings apart that matter here: PCRE2 spells "your
/// ten-million-step default ran out" and "the thousand steps you asked for ran
/// out" with the same `-47`, and only the first is the old fail-closed
/// no-match. `+1` biased so zero is "none" without a sentinel member — the same
/// reason `AtSpace.none` is 0. Process-global like `match_error_code`, and
/// cleared by the same reset, so the parallel `-P` pipeline's workers latch
/// into one cell the main thread reads after they join.
var budget_ceiling: std.atomic.Value(u32) = .init(0);

/// Which ceiling this run hit, or null if it reached none of the caller's.
pub fn ceilingHit() ?Ceiling {
    const biased = budget_ceiling.load(.acquire);
    return if (biased == 0) null else @enumFromInt(biased - 1);
}

/// `error.BudgetExceeded` iff a ceiling the caller named was reached.
///
/// The arm's own verbs stay fail-closed and answer `null`/`false` — a ceiling
/// hit is not a match, and the frozen `?Span` seam has no room to say more —
/// so this is where the fact becomes a fault a host can `try`. Which ceiling it
/// was rides `ceilingHit` beside it, exactly as a `munch.Because` rides beside
/// a refused ordinal.
///
/// It does **not** install a `fault.Detail` yet, and that is a missing edge
/// rather than a design: `[fault_domains].resource` already declares
/// `BudgetExceeded`, but `fault.Resource` does not name it, and adding it there
/// obliges `contract.Status.ofFault` to grow the prong `[status_codes]` already
/// assigns (the `resource` domain folds onto `out_of_memory`). Both files
/// belong to other lanes. Until they land, the reason is readable here and the
/// C seam cannot see it.
pub fn budgetVerdict() BudgetError!void {
    if (ceilingHit() != null) return error.BudgetExceeded;
}

/// Clear the sticky match-time error (call once before a search begins).
pub fn clearMatchError() void {
    match_error_code.store(0, .release);
    budget_ceiling.store(0, .release);
}

/// Latch a `pcre2_match` return code as a fault iff it is worse than a clean
/// no-match (`< ERROR_NOMATCH`) — the match/depth-limit and JIT-stack failures
/// ripgrep exits 2 on — and, when the ceiling it reports is one `limits`
/// actually named, latch which ceiling that was. Shared by the boolean/span
/// `Sim` and the capture engine (and safe across the parallel pipeline's
/// workers) so all paths surface catastrophic input identically.
///
/// The reason is recorded here, at the hit, rather than at whatever surface
/// eventually asks. A search that answered no-match and a search that was
/// stopped are the same `null` to the caller above, so the fact has to be kept
/// while the arm still knows which it was.
///
/// An unnamed ceiling is deliberately left at the first line. Hitting the arm's
/// ten-million step default is the fail-closed no-match this engine has always
/// reported, and dressing it as "the budget you set" would be a fault about a
/// request nobody made — so an all-null `Limits` records exactly what it always
/// did and no more.
pub fn recordFault(limits: Limits, rc: c_int) void {
    if (rc < ffi.ERROR_NOMATCH) match_error_code.store(rc, .release);
    const hit = Ceiling.of(rc) orelse return;
    if (!hit.asked(limits)) return;
    budget_ceiling.store(@intFromEnum(hit) + 1, .release);
}

/// Render the latched match-time error into `buf` (empty when none), for the
/// stderr diagnostic the CLI prints alongside its exit-2.
pub fn matchErrorMessage(buf: []u8) []const u8 {
    const code = match_error_code.load(.acquire);
    if (code == 0) return "";
    return ffi.errorMessage(code, buf);
}

/// Where in the pattern the last compile error was detected. Meaningless
/// without a preceding `BadPattern`, so it is read next to `lastError` or not
/// at all; PCRE2 reports it as a byte index into the pattern it was handed.
pub fn lastErrorOffset() usize {
    return last_error_offset;
}

/// Render a PCRE2 compile error code into the thread-local diagnostic buffer
/// (read back via `lastError` after a `BadPattern`). `at` is PCRE2's own
/// `erroroffset`, which the C seam forwards so a host gets "where" and not only
/// "what" — the CLI prints the message alone and ignores it.
pub fn recordErrorAt(code: c_int, at: usize) void {
    last_error_offset = at;
    recordError(code);
}

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
    /// The ceilings every `Sim` built from this program runs under. They ride
    /// the compiled program rather than each match call because that is where
    /// the C ABI already puts them (`irgx_options` is a compile-time struct),
    /// and because the scratch is built from the program — so a worker cannot
    /// end up bounded differently from the query it belongs to. All-null is
    /// the arm's own defaults, unchanged.
    limits: Limits = .{},
    /// The linear-time over-approximation gate (`shadow.zig`): a compiled
    /// linear `Regex` whose language provably CONTAINS this pattern's, so a
    /// haystack it rejects cannot match and PCRE2 never scans it — the
    /// O(1)/byte DFA absorbs the worst-case-exponential inputs backtracking
    /// chokes on. Null when no over-approximation is provable (PCRE2 runs raw,
    /// exactly the old behavior) or when the shadow is nullable (a gate that
    /// admits everything is pure overhead). Immutable, shared like `code`.
    shadow: ?core.Regex = null,

    /// Compile `pattern` into a PCRE2 program, JIT-compiling when the platform
    /// supports it. Declines with `BadPattern` (diagnostic in `lastError`) for
    /// an invalid pattern, `OutOfMemory` on allocation failure.
    pub fn compileOpts(allocator: std.mem.Allocator, pattern: []const u8, opts: Options) CompileError!Pcre {
        return compileMode(allocator, pattern, opts, true, .{});
    }

    /// `compileOpts` under caller ceilings — the entry a host that cannot
    /// afford this arm's defaults compiles through. Every field of `limits`
    /// left null keeps the default, so this is `compileOpts` for `.{}` and the
    /// two are one program with one behavior rather than two code paths.
    pub fn compileLimited(allocator: std.mem.Allocator, pattern: []const u8, opts: Options, limits: Limits) CompileError!Pcre {
        return compileMode(allocator, pattern, opts, true, limits);
    }

    pub fn deinit(self: *Pcre) void {
        ffi.pcre2_code_free_8(self.code);
        if (self.required.len > 0) self.allocator.free(self.required);
        for (self.alts) |s| self.allocator.free(s);
        if (self.alts.len > 0) self.allocator.free(self.alts);
        if (self.shadow) |*sh| sh.deinit();
        self.* = undefined;
    }

    /// Per-thread PCRE2 match scratch (the `Regex.Sim` twin): a match-data block,
    /// a match context with the resource ceilings, and (when JIT'd) a private
    /// 10 MiB JIT stack. One per worker; never shared — this is the thread-local
    /// half of the engine. The allocator satisfies the `matcher.zig` seam only;
    /// PCRE2 owns its own allocations.
    pub const Sim = struct {
        md: *ffi.MatchData,
        mc: *ffi.MatchContext,
        jit_stack: ?*ffi.JitStack,
        /// Pike scratch for the shadow gate's rare no-DFA fallback (a powerset
        /// blow-up). Present iff `re.shadow` is — the gates below unwrap it.
        shadow: ?core.Regex.Sim,
        /// The ceilings this scratch was built under, copied from the program
        /// it belongs to. Held rather than re-read because `find` needs to know
        /// whether the ceiling PCRE2 just reported is one the caller named, and
        /// the return code cannot say.
        limits: Limits,

        pub fn init(allocator: std.mem.Allocator, re: *const Pcre) CompileError!Sim {
            const md = ffi.pcre2_match_data_create_from_pattern_8(re.code, null) orelse
                return CompileError.OutOfMemory;
            errdefer ffi.pcre2_match_data_free_8(md);
            const mc = ffi.pcre2_match_context_create_8(null) orelse
                return CompileError.OutOfMemory;
            errdefer ffi.pcre2_match_context_free_8(mc);
            applyLimits(mc, re.limits);

            var jit_stack: ?*ffi.JitStack = null;
            errdefer if (jit_stack) |js| ffi.pcre2_jit_stack_free_8(js);
            if (re.jit) {
                jit_stack = ffi.pcre2_jit_stack_create_8(jit_stack_start, jit_stack_max, null);
                if (jit_stack) |js| ffi.pcre2_jit_stack_assign_8(mc, null, js);
            }
            const sh_sim: ?core.Regex.Sim = if (re.shadow) |*sh|
                core.Regex.Sim.init(allocator, sh) catch return CompileError.OutOfMemory
            else
                null;
            return .{ .md = md, .mc = mc, .jit_stack = jit_stack, .shadow = sh_sim, .limits = re.limits };
        }
        pub fn deinit(self: *Sim) void {
            if (self.shadow) |*s| s.deinit();
            if (self.jit_stack) |js| ffi.pcre2_jit_stack_free_8(js);
            ffi.pcre2_match_context_free_8(self.mc);
            ffi.pcre2_match_data_free_8(self.md);
            self.* = undefined;
        }
        /// Leftmost match in `hay[from..]`, or null (no match OR a resource
        /// limit — fail-closed: never report a match we could not verify).
        fn find(self: *Sim, re: *const Pcre, hay: []const u8, from: usize) ?Span {
            if (from > hay.len) return null;
            const subject: [*]const u8 = if (hay.len == 0) empty_subject else hay.ptr;
            const rc = ffi.pcre2_match_8(re.code, subject, hay.len, from, match_options, self.md, self.mc);
            if (rc < 0) {
                // A clean no-match is `ERROR_NOMATCH`; anything more negative is a
                // resource limit or fault ripgrep exits 2 on — latch it (last one
                // wins; any error is enough to force the exit-2 the CLI mirrors),
                // and, when the caller named the ceiling that stopped us, record
                // the `BudgetExceeded` incident it can read back afterwards.
                recordFault(self.limits, rc);
                return null;
            }
            const ov = ffi.pcre2_get_ovector_pointer_8(self.md);
            return .{ .start = ov[0], .end = ov[1] };
        }
    };

    /// Per-query span-extraction scratch (the `Regex.SpanSim` twin) — the same
    /// PCRE2 scratch serves both grains, so it is one type.
    pub const SpanSim = Sim;

    /// The shadow gate: false iff the linear over-approximation PROVES no PCRE
    /// match exists in `hay` (language containment — see `shadow.zig`). The
    /// shadow is assertion-free by construction, so its boolean is
    /// substring-complete over any haystack (line or whole buffer alike) and
    /// almost always answers from the O(1)/byte DFA. True when no shadow.
    inline fn admits(self: *const Pcre, sim: anytype, hay: []const u8) bool {
        if (self.shadow) |*sh| return sh.lineMatch(&sim.shadow.?, hay);
        return true;
    }

    /// Does the pattern match any substring of `line`? (Per-line boolean path.)
    pub fn lineMatch(self: *const Pcre, sim: *Sim, line: []const u8) bool {
        if (!self.admits(sim, line)) return false;
        return sim.find(self, line, 0) != null;
    }

    /// Does any line of `doc` match? rg `-l` line model: `\n` terminates a line
    /// (no phantom empty final line for a trailing newline); content after the
    /// last `\n` is a line. Mirrors `Regex.docMatch` so `^`/`$` anchor per line.
    /// Each line passes the shadow gate before PCRE2 sees it — a pathological
    /// line (one 120 KB base64 run) costs one DFA pass, never backtracking.
    pub fn docMatch(self: *const Pcre, sim: *Sim, doc: []const u8) bool {
        var i: usize = 0;
        while (i < doc.len) {
            const end = std.mem.indexOfScalarPos(u8, doc, i, '\n') orelse doc.len;
            const line = doc[i..end];
            if (self.admits(sim, line) and sim.find(self, line, 0) != null) return true;
            i = end + 1;
        }
        return false;
    }

    /// Does the pattern match any substring of the WHOLE buffer under multiline
    /// semantics? Compiled with `PCRE2_MULTILINE`, one unanchored search over
    /// the buffer already realizes rg's `-U` model. The multiline twin of
    /// `docMatch`; empty buffer never matches (rg's line model).
    pub fn bufMatch(self: *const Pcre, sim: *Sim, buf: []const u8) bool {
        if (buf.len == 0) return false;
        if (!self.admits(sim, buf)) return false;
        return sim.find(self, buf, 0) != null;
    }

    /// Leftmost match of the pattern within `hay[from..]` as a byte span, or
    /// null. `hay` is a line in the per-line default, the buffer under `-U`.
    /// The shadow gates only the FIRST probe of a haystack (`from == 0`): a
    /// zero-match haystack is exactly the backtracking worst case, while a
    /// later probe means a match already landed and the haystack is hot — and
    /// re-gating every step of a span walk would be quadratic.
    pub fn matchSpan(self: *const Pcre, sim: *SpanSim, hay: []const u8, from: usize) ?Span {
        if (from == 0 and !self.admits(sim, hay)) return null;
        return sim.find(self, hay, from);
    }
};

/// The compile core with an explicit JIT toggle. `Pcre.compileOpts` passes
/// `enable_jit = true` (JIT when the target supports it, interpreter otherwise);
/// tests pass `false` to force the interpreter path and prove the two engines
/// agree byte-for-byte. The interpreter is always the guaranteed fallback, so a
/// `false` here is exactly the platform-has-no-JIT case. Kept a module-level
/// helper (not a `Pcre` method) so the frozen `Pcre` surface stays byte-stable.
///
/// `limits` may also withdraw the JIT on its own — see `jitHonors`. A ceiling
/// the fast path would not read is not a ceiling.
pub fn compileMode(allocator: std.mem.Allocator, pattern: []const u8, opts: Options, enable_jit: bool, limits: Limits) CompileError!Pcre {
    const compile_options = compileOptionBits(opts);

    const src = try wordWrapped(allocator, pattern, opts);
    defer if (src.ptr != pattern.ptr) allocator.free(src);

    var errorcode: c_int = 0;
    var erroroffset: ffi.Size = 0;
    const code = ffi.pcre2_compile_8(src.ptr, src.len, compile_options, &errorcode, &erroroffset, null) orelse {
        // PCRE2 located the defect in the text IT was handed; the caller draws its
        // caret against the pattern the user typed, so discount the `-w` lead.
        recordErrorAt(errorcode, erroroffset -| (if (src.ptr == pattern.ptr) 0 else word_lead.len));
        return CompileError.BadPattern;
    };
    errdefer ffi.pcre2_code_free_8(code);

    // Best-effort JIT; the interpreter is always the guaranteed fallback.
    const jit = enable_jit and jitHonors(limits) and ffi.pcre2_jit_compile_8(code, ffi.JIT_COMPLETE) == 0;

    // Both prefilters below read the PATTERN TEXT, and verbose changes what that
    // text says: `literal.required` would report `"a b"` as required by `a b`,
    // which no match of it contains, and the shadow rewriter would read a `(` or
    // `[` inside a `#` comment as structure. A prefilter that is not an
    // over-approximation does not slow a search down, it loses matches — the one
    // failure mode nothing downstream can notice — so under verbose both decline
    // and PCRE2 runs raw. (The linear arm keeps every prefilter, because it
    // derives them from the single verbose-aware `lower.parse` rather than from
    // the bytes.)
    var req = if (opts.verbose) try allocator.alloc(u8, 0) else try literal.required(allocator, pattern, opts.caseless);
    errdefer allocator.free(req);

    // The shadow gate + prefilter upgrade — best-effort at every step: any
    // bail leaves this Pcre exactly as it was (raw PCRE2, textual literal).
    var shadow: ?core.Regex = try buildShadow(allocator, pattern, opts);
    errdefer if (shadow) |*sh| sh.deinit();
    var alts: []const []const u8 = &.{};
    if (shadow) |*sh| {
        // L(pcre) ⊆ L(shadow), so any literal every SHADOW match requires is
        // required by every PCRE match too — adopt whichever is longer, and
        // the shadow's alternation cover when the single literal is too short.
        // (The pure-literal EQUIVALENCE set does not transfer: containment is
        // one-directional.) This hands `-P` the trigram index it never had.
        if (sh.required.len > req.len) {
            allocator.free(req);
            req = try allocator.dupe(u8, sh.required);
        }
        if (sh.alts.len > 0) {
            const dst = try allocator.alloc([]const u8, sh.alts.len);
            var n: usize = 0;
            errdefer {
                for (dst[0..n]) |s| allocator.free(s);
                allocator.free(dst);
            }
            for (sh.alts) |s| {
                dst[n] = try allocator.dupe(u8, s);
                n += 1;
            }
            alts = dst;
        }
    }

    return .{
        .required = req,
        .alts = alts,
        .nullable = computeNullable(code, pattern),
        .multiline = opts.multiline,
        .allocator = allocator,
        .code = code,
        .jit = jit,
        .shadow = shadow,
        .limits = limits,
    };
}

/// Compile the linear over-approximation gate for `pattern`, or null when none
/// is provable / useful. Every failure short of OOM is a silent decline —
/// PCRE2 then runs raw, exactly the pre-shadow behavior (fail-open by design).
fn buildShadow(allocator: std.mem.Allocator, pattern: []const u8, opts: Options) error{OutOfMemory}!?core.Regex {
    // See `compileMode`: the rewriter reads the bytes as structure, and under
    // verbose a `(` inside a `#` comment is not structure. A shadow that is not
    // a superset gates real matches out, so this declines rather than guesses.
    if (opts.verbose) return null;
    const text = switch (try shadow_mod.overapprox(allocator, pattern)) {
        .got => |t| t,
        // The rewriter found no containment proof; PCRE2 runs raw.
        .declined => return null,
    };
    defer allocator.free(text);
    // Mirror the PCRE2 compile knobs so the two languages align (fold, `.`-vs-
    // `\n`, Unicode classes). `line_anchors` is irrelevant: the shadow is
    // assertion-free by construction.
    //
    // `multiline` is the exception, and it is pinned rather than mirrored. It
    // does not name a language here — the shadow has no anchors for it to move
    // — it names the GRAIN the gate scans at, and `admits` is handed a whole
    // buffer by `matchSpan` and a line by `docMatch` alike. Mirrored, a shadow
    // built for line grain answered a buffer question, and a pattern whose
    // language needs a terminator was gated out of a buffer that plainly holds
    // one: `irgx_find_all(re, "x\ny")` for `\n` found nothing under PCRE while
    // the linear arm and every general-purpose regex library found (1,2).
    // Pinned true, the gate scans whatever it is given, and it can only ever
    // admit MORE - which is the safe direction for an over-approximation.
    var sh = core.Regex.compileOpts(allocator, text, .{
        .caseless = opts.caseless,
        .multiline = true,
        .dotall = opts.dotall,
        .unicode = opts.unicode,
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        // A rewrite the linear engine still declines (e.g. an exotic class) —
        // the bail path, not an error.
        else => return null,
    };
    // A nullable shadow admits every haystack — a gate that never gates. Its
    // literals are worthless too (a nullable pattern requires no bytes).
    if (sh.nullable or sh.eol_empty) {
        sh.deinit();
        return null;
    }
    return sh;
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
            // (?= (?! (?<= (?<!
            if (std.mem.indexOfScalar(u8, "=!<", pattern[i + 2]) != null) return true;
        }
    }
    return false;
}
