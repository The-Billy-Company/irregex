//! `libirregex` — the C-ABI artifact's root, and nothing else.
//!
//! This file exists to be a *different* root from `src/root.zig`. A Zig
//! `export fn` is emitted by every compilation that reaches it, so if these
//! shims lived in the library module, then `libgist`, `librelate`, and
//! `libblast` — each of which imports that module — would every one of them
//! carry its own copy of `irregex_last_fault`, and a host linking two would get
//! a duplicate-symbol error for a symbol it asked for once. Keeping the
//! `export fn`s in the artifact's root instead means the symbols exist exactly
//! where the `.a`/`.dylib` named after them is, which is the whole premise of
//! four libraries rather than one.
//!
//! What crosses here is two planes: the SUBSTRATE every package's ABI shares
//! (the status vocabulary, the per-thread fault pull, the ABI/engine versions),
//! and this package's OWN verbs — a pattern over a buffer. Neither knows
//! anything about a corpus; that is `libgist`.
//!
//! Header: `include/irregex.h`, which is the normative statement of these
//! signatures. Bodies: `contract.zig` (substrate) and `pattern.zig` (verbs).

const std = @import("std");
const irregex = @import("irregex");

const answer = irregex.ffi.answer;
const api = irregex.api;
const contract = irregex.ffi.contract;
/// A sibling in THIS module rather than a member of the library's `ffi` group:
/// it lowers the `api` veneer, which only a consumer of the library may reach.
const corpus = @import("corpus.zig");
const pattern = irregex.ffi.pattern;
const rows = irregex.ffi.rows;

/// The C-ABI compatibility integer for `libirregex` specifically. It started at
/// 1 because this artifact is new: the `2` a host may remember belongs to the
/// session ABI, which is `libgist`'s and versions on its own axis. Bump only
/// for a breaking layout or signature change — an additive symbol keeps it.
///
/// **2** — two changes a v1 consumer would misread rather than reject:
/// `irregex_fault.has_at` became `at_space`, same offset and width but three
/// values where a boolean was, and `irregex_find_all`'s `*written` became the
/// text's true count instead of the window's. (`irregex_group_name` arrived in
/// the same revision and would not have bumped anything.)
export fn irregex_abi_version() u32 {
    return 2;
}

/// The engine semver, NUL-terminated and static, so a binding can version-gate
/// the shared library it loaded against the version it was generated from.
export fn irregex_version() [*:0]const u8 {
    return irregex.version_string.ptr;
}

/// The vendored PCRE2 the `IRREGEX_PCRE` flag runs on — reported alongside the
/// engine version because "which regex grammar do I actually have" is two
/// numbers, and a host selecting the PCRE arm is asking about the second one.
export fn irregex_pcre2_version() [*:0]const u8 {
    return irregex.pcre2_version_string;
}

/// A static, NUL-terminated human message for a status code (for logs; the
/// typed code stays the contract). A pure reader: it leaves the fault slot
/// alone, so a host may call it before `irregex_last_fault`.
export fn irregex_status_message(code: i32) [*:0]const u8 {
    return contract.statusMessage(code);
}

/// Detail for the LAST failing call on THIS thread — which fault, about which
/// file, at which byte. Reading does not consume; the answer stays valid until
/// this thread's next work call.
export fn irregex_last_fault(out: ?*contract.FaultDetail) i32 {
    return @intFromEnum(contract.lastFault(out));
}

// ── the regex plane ──────────────────────────────────────────────────────────
// A handle is single-threaded: it owns the scratch its finds run in. Compile
// one per thread rather than sharing one under a lock — the compile is pure,
// and the lock would serialize the only part that was ever parallel.

/// Compile `pattern[0..len]` under `flags` (`IRREGEX_FIXED` … `IRREGEX_PCRE`)
/// and write the handle to `*out`. 0 on success; negative on failure, with the
/// reason in `irregex_last_fault`.
export fn irregex_compile(pat: ?[*]const u8, len: usize, flags: u32, out: ?**pattern.Regex) i32 {
    return @intFromEnum(pattern.compile(pat, len, flags, out));
}

/// Release a handle from `irregex_compile`.
export fn irregex_free(re: *pattern.Regex) void {
    pattern.free(re);
}

/// Whether `text[0..len]` holds a match: 1 yes, 0 no, negative on error.
export fn irregex_is_match(re: *pattern.Regex, text: ?[*]const u8, len: usize) i32 {
    return @intFromEnum(pattern.isMatch(re, text, len));
}

/// Write the matches in `text[0..len]` into `out[0..cap]` and their count into
/// `*written`. Returns 1 when the text HAS at least one, 0 when none, negative
/// on error. `cap` is a window over the answer: at most `cap` are written and
/// `*written` reports how many the text HAS, so a short window sizes its retry —
/// and a `cap = 0` count query writes nothing yet still answers 1.
export fn irregex_find_all(re: *pattern.Regex, text: ?[*]const u8, len: usize, out: ?[*]pattern.Span, cap: usize, written: ?*usize) i32 {
    return @intFromEnum(pattern.findAll(re, text, len, out, cap, written));
}

/// Write the group spans of the leftmost match at or after `from` into
/// `out[0..cap]`; `*written` reports how many groups the PATTERN has (so a
/// short `cap` sizes the retry). `out[0]` is the whole match; a group that did
/// not participate is `{-1, -1}`. 1 on a match, 0 on none, negative on error.
export fn irregex_captures(re: *pattern.Regex, text: ?[*]const u8, len: usize, from: usize, out: ?[*]pattern.Span, cap: usize, written: ?*usize) i32 {
    return @intFromEnum(pattern.captures(re, text, len, from, out, cap, written));
}

/// How many capture groups the pattern declares, excluding the whole match.
export fn irregex_group_count(re: *pattern.Regex, out: ?*u32) i32 {
    return @intFromEnum(pattern.groupCount(re, out));
}

/// The number of the group named `name[0..len]`: 1 with `*out` set when the
/// pattern declares it, 0 when it does not, negative on error.
export fn irregex_group_index(re: *pattern.Regex, name: ?[*]const u8, len: usize, out: ?*u32) i32 {
    return @intFromEnum(pattern.groupIndex(re, name, len, out));
}

/// The name group `index` was declared with: 1 with `*out` pointing at borrowed
/// bytes, 0 when the group is unnamed, negative on error. The inverse of
/// `irregex_group_index`, and the direction a host cannot derive itself without
/// re-parsing the pattern.
export fn irregex_group_name(re: *pattern.Regex, index: u32, out: ?*rows.Text) i32 {
    return @intFromEnum(pattern.groupName(re, index, out));
}

// ── the shared warm corpus ───────────────────────────────────────────────────
// The thing every analytic producer is HANDED. `gist_run`, `relate_run`, and
// `blast_run` all take an open engine, and an engine can only be read by the copy
// of the engine code that made it — so unlike the verbs, the opener cannot be one
// symbol per library. It is here for the same reason the cursor below is.

/// Stand a warm corpus up over `roots[0..nroots]` (NUL-terminated paths) and write
/// the handle to `*out`. `nroots == 0` walks the CWD. 0 on success; negative on
/// failure, with the reason in `irregex_last_fault`.
export fn irregex_engine_open(roots: ?[*]const [*:0]const u8, nroots: usize, out: ?**api.Engine) i32 {
    return @intFromEnum(corpus.open(roots, nroots, out));
}

/// Release a corpus from `irregex_engine_open`, and everything it holds warm.
/// Every cursor drawn from it must be closed first.
export fn irregex_engine_close(engine: *api.Engine) void {
    corpus.close(engine);
}

/// Allocate a fresh (unset) cancellation token; writes it to `*out`.
export fn irregex_cancel_new(out: ?**api.CancelToken) i32 {
    return @intFromEnum(corpus.cancelNew(out));
}

/// Trip a token, cancelling every in-flight query using it. The one entry here a
/// host may call from another thread while a query is running.
export fn irregex_cancel_request(token: *api.CancelToken) void {
    corpus.cancelRequest(token);
}

/// Free a token from `irregex_cancel_new`, after every query using it returned.
export fn irregex_cancel_free(token: *api.CancelToken) void {
    corpus.cancelFree(token);
}

// ── the shared row cursor ────────────────────────────────────────────────────
// The walking half of the analytic protocol. Each library exports its own
// producer — `gist_run`, `relate_run`, `blast_run` — and every one of them
// hands back a cursor walked by THESE symbols, so a host asking three packages
// three questions still learns one way to read an answer.

/// Write the next row into `*out`. 1 when one was written, 0 at the end,
/// negative on error. Rows borrow the cursor's arena until `irregex_rows_close`.
export fn irregex_rows_next(cursor: *answer.Answer, out: ?*rows.Row) i32 {
    return @intFromEnum(answer.next(cursor, out));
}

/// Fill up to `cap` rows into `out[0..cap]`, writing the count to `*written`.
/// The crossing a batching binding amortizes N rows over.
export fn irregex_rows_next_batch(cursor: *answer.Answer, out: ?[*]rows.Row, cap: usize, written: ?*usize) i32 {
    return @intFromEnum(answer.nextBatch(cursor, out, cap, written));
}

/// Answer-level facts no row carries — which tier answered, the freshness
/// fold, and `foreign` (query fingerprints this corpus has never seen).
export fn irregex_rows_stats(cursor: *answer.Answer, out: ?*rows.Stats) i32 {
    return @intFromEnum(answer.stats(cursor, out));
}

/// Free a cursor, and with it everything its rows borrow.
export fn irregex_rows_close(cursor: *answer.Answer) void {
    answer.close(cursor);
}

/// A stable, static, NUL-terminated digest of the WHOLE row-schema table. A
/// binding compares it to the digest its decoder was generated from, so a
/// stale shared library is a loud startup failure, not a mis-decoded row.
export fn irregex_schema_digest() [*:0]const u8 {
    return rows.digest();
}

/// How many row schemas this build declares (ids are 1..count).
export fn irregex_schema_count() u32 {
    return rows.schemaCount();
}

/// Fill `*out` with schema `id`. Its names, tags, and field arrays are static
/// and outlive every call.
export fn irregex_schema_get(id: u32, out: ?*rows.Schema) i32 {
    return @intFromEnum(rows.schemaGet(id, out));
}

test {
    // The shims are one-liners over tested bodies; what a test here can still
    // catch is a signature that stopped compiling as C-callable.
    std.testing.refAllDecls(@This());
}
