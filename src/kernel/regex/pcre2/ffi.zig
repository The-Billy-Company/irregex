//! irregex — the minimal C-ABI surface of the vendored PCRE2 10.47 8-bit
//! library.
//!
//! We bind PCRE2 with explicit `extern` declarations rather than `@cImport`
//! (translate-c) so the Zig side stays self-contained: no PCRE2 include path
//! leaks into the engine module, the surface is exactly the entry points the
//! backend needs, and the symbol contract is reviewable in one screen. The C
//! sources are compiled and linked hermetically by `build.zig` (`pcre2Library`);
//! these decls resolve against that archive at final link.
//!
//! All symbols carry the `_8` suffix PCRE2 mints when `PCRE2_CODE_UNIT_WIDTH=8`
//! — the width the whole byte pipeline speaks. Opaque structs mirror
//! PCRE2's own incomplete types; we only ever hold them behind pointers.

const std = @import("std");

pub const Code = opaque {};
pub const MatchData = opaque {};
pub const GeneralContext = opaque {};
pub const MatchContext = opaque {};
pub const CompileContext = opaque {};
pub const JitStack = opaque {};

/// `PCRE2_SIZE` — every offset/length in the API; `size_t` at width 8.
pub const Size = usize;

// ── compile / match option bits (subset; values from vendored pcre2.h) ──
pub const CASELESS: u32 = 0x00000008;
pub const DOTALL: u32 = 0x00000020;
pub const MULTILINE: u32 = 0x00000400;
pub const UCP: u32 = 0x00020000;
pub const UTF: u32 = 0x00080000;
/// Handle subjects containing invalid UTF-8 gracefully (match valid spans,
/// never error) — the mode ripgrep's `-P` uses so a search over binary/partial
/// text degrades instead of failing. Implies UTF; 10.34+.
pub const MATCH_INVALID_UTF: u32 = 0x04000000;

/// `PCRE2_ANCHORED` — the match must begin at the start offset it was handed,
/// with no forward search for a later start. A match-time bit (also legal at
/// compile time), which is what lets one compiled program serve both an
/// unanchored `find` and an anchored `matchAt`.
pub const ANCHORED: u32 = 0x80000000;

/// Full JIT compilation for complete (non-partial) matching.
pub const JIT_COMPLETE: u32 = 0x00000001;

/// `pcre2_match` returns this (−1) for a clean "subject does not match" — the
/// ONLY negative rc that is not an error. Every rc `< ERROR_NOMATCH` is a real
/// match-time failure (resource limit, bad UTF, internal error) that ripgrep
/// surfaces as exit 2 rather than a silent no-match. Value from `pcre2.h`.
pub const ERROR_NOMATCH: c_int = -1;

/// The three rcs that mean "a ceiling on this match context was reached", as
/// opposed to the pattern simply not being there. They are what lets the arm
/// say WHICH ceiling without keeping a second cell to remember it in: PCRE2
/// already distinguishes them, so the reason is a decode of the return code
/// rather than a fact we have to carry alongside it. Values from `pcre2.h`
/// (`PCRE2_ERROR_DEPTHLIMIT` and the obsolete `RECURSIONLIMIT` are one number).
pub const ERROR_MATCHLIMIT: c_int = -47;
pub const ERROR_DEPTHLIMIT: c_int = -53;
pub const ERROR_HEAPLIMIT: c_int = -63;

/// `PCRE2_INFO_CAPTURECOUNT` — the number of capturing subpatterns, queried via
/// `pcre2_pattern_info` to size a replacement's slot vector (`2*(count+1)`).
pub const INFO_CAPTURECOUNT: u32 = 4;

/// The name-table trio, for the inverse lookup `pcre2_substring_number_from_name`
/// cannot do: number → name. PCRE2 keeps the names as a sorted block of
/// fixed-width entries inside the compiled code, each entry being a big-endian
/// group number followed by a NUL-terminated name, so reading it needs all three
/// facts — how many entries, how wide one is, and where the block starts.
/// Values from `pcre2.h`.
pub const INFO_NAMECOUNT: u32 = 17;
pub const INFO_NAMEENTRYSIZE: u32 = 18;
pub const INFO_NAMETABLE: u32 = 19;

/// `PCRE2_UNSET` — the ovector sentinel for a group that did not participate in
/// the match (`SIZE_MAX`). Mapped to this package's `-1` "unset slot"
/// convention.
pub const UNSET: Size = std.math.maxInt(Size);

// ── compile / free ──
pub extern fn pcre2_compile_8(
    pattern: [*]const u8,
    length: Size,
    options: u32,
    errorcode: *c_int,
    erroroffset: *Size,
    ccontext: ?*CompileContext,
) ?*Code;
pub extern fn pcre2_code_free_8(code: ?*Code) void;
pub extern fn pcre2_get_error_message_8(errorcode: c_int, buffer: [*]u8, bufflen: Size) c_int;

/// Query compiled-pattern metadata (`what` = an `INFO_*` selector); `where`
/// points at the typed output slot. Used for `INFO_CAPTURECOUNT`.
pub extern fn pcre2_pattern_info_8(code: *const Code, what: u32, where: ?*anyopaque) c_int;

/// Resolve a `(?P<name>…)` / `(?<name>…)` group name to its number (≥1), or a
/// negative error when the name is unknown/duplicated — for `${name}` replace.
pub extern fn pcre2_substring_number_from_name_8(code: *const Code, name: [*:0]const u8) c_int;

// ── per-thread match scratch ──
pub extern fn pcre2_match_data_create_from_pattern_8(code: *const Code, gcontext: ?*GeneralContext) ?*MatchData;
pub extern fn pcre2_match_data_free_8(match_data: ?*MatchData) void;
pub extern fn pcre2_get_ovector_pointer_8(match_data: *MatchData) [*]Size;

// ── matching ──
pub extern fn pcre2_match_8(
    code: *const Code,
    subject: [*]const u8,
    length: Size,
    startoffset: Size,
    options: u32,
    match_data: *MatchData,
    mcontext: ?*MatchContext,
) c_int;

// ── deterministic resource ceilings (per-thread match context) ──
pub extern fn pcre2_match_context_create_8(gcontext: ?*GeneralContext) ?*MatchContext;
pub extern fn pcre2_match_context_free_8(mcontext: ?*MatchContext) void;
pub extern fn pcre2_set_match_limit_8(mcontext: *MatchContext, value: u32) c_int;
pub extern fn pcre2_set_depth_limit_8(mcontext: *MatchContext, value: u32) c_int;

/// The heap a single match may hold, **counted in kibibytes** — PCRE2's own
/// unit, and the reason the caller-facing `heap_bytes` cannot be forwarded
/// verbatim. Unset by this arm until a caller names one, so a context nobody
/// bounded keeps PCRE2's own default exactly as it always has. Honored by the
/// interpreter only; the JIT runs on its own stack and never reads it.
pub extern fn pcre2_set_heap_limit_8(mcontext: *MatchContext, value: u32) c_int;

// ── JIT: compile + per-thread executable stack ──
pub extern fn pcre2_jit_compile_8(code: *Code, options: u32) c_int;
pub extern fn pcre2_jit_stack_create_8(startsize: Size, maxsize: Size, gcontext: ?*GeneralContext) ?*JitStack;
pub extern fn pcre2_jit_stack_free_8(jit_stack: ?*JitStack) void;
pub extern fn pcre2_jit_stack_assign_8(mcontext: *MatchContext, callback: ?*const anyopaque, callback_data: ?*anyopaque) void;

/// Render a PCRE2 error code into `buf`, returning the message slice. Used to
/// surface a human-readable compile diagnostic through `CompileError`.
pub fn errorMessage(code: c_int, buf: []u8) []const u8 {
    const n = pcre2_get_error_message_8(code, buf.ptr, buf.len);
    return if (n > 0) buf[0..@intCast(n)] else "unknown PCRE2 error";
}
