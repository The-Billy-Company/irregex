//! `libirgx` — the C-ABI artifact's root, and nothing else.
//!
//! This file exists to be a *different* root from `src/root.zig`. A Zig
//! `export fn` is emitted by every compilation that reaches it, so if these
//! shims lived in the library module, then `libgist`, `librelate`, and
//! `libblast` — each of which imports that module — would every one of them
//! carry its own copy of `irgx_last_fault`, and a host linking two would get
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
//! Header: `include/irgx.h`, which is the normative statement of these
//! signatures. Bodies: `contract.zig` (substrate) and `pattern.zig` (verbs).

const std = @import("std");
const builtin = @import("builtin");
const irregex = @import("irregex");

const answer = irregex.ffi.answer;
const api = irregex.api;
const contract = irregex.ffi.contract;
/// A sibling in THIS module rather than a member of the library's `ffi` group:
/// it lowers the `api` veneer, which only a consumer of the library may reach.
const corpus = @import("corpus.zig");
const munch = irregex.ffi.munch;
const pattern = irregex.ffi.pattern;
const rows = irregex.ffi.rows;
const slate = irregex.ffi.slate;

/// `std.Io.Threaded`'s vtable makes every method reachable the moment one is
/// instantiated, and `netWriteFile` is `@panic("TODO ...")`-stubbed on every
/// backend — which the MSVC ABI cannot compile: `SelfInfo.Windows.zig`'s
/// `loadNtdllProc` (reached only from `defaultPanic`'s stack walk, and only
/// for `.msvc`) casts `*anyopaque` to a function pointer without the
/// `@alignCast` Zig itself now requires. Upstream bug, not ours — a static or
/// object artifact for ANY `-msvc` target hits this in zig 0.16.0, panic or
/// not. Every other ABI keeps the default, fully symbolicated panic
/// unchanged; only the one target Zig cannot otherwise compile degrades to
/// the message-only handler.
pub const panic = if (builtin.abi == .msvc)
    std.debug.simple_panic
else
    std.debug.FullPanic(std.debug.defaultPanic);

/// The C-ABI compatibility integer for `libirgx` specifically. It started at
/// 1 because this artifact is new: the `2` a host may remember belongs to the
/// session ABI, which is `libgist`'s and versions on its own axis. Bump only
/// for a breaking layout or signature change — an additive symbol keeps it.
///
/// **2** — two changes a v1 consumer would misread rather than reject:
/// `irgx_fault.has_at` became `at_space`, same offset and width but three
/// values where a boolean was, and `irgx_find_all`'s `*written` became the
/// text's true count instead of the window's. (`irgx_group_name` arrived in
/// the same revision and would not have bumped anything.)
export fn irgx_abi_version() u32 {
    return irregex.abi();
}

/// The engine semver, NUL-terminated and static, so a binding can version-gate
/// the shared library it loaded against the version it was generated from.
export fn irgx_version() [*:0]const u8 {
    return irregex.version_string.ptr;
}

/// The vendored PCRE2 the `IRGX_PCRE` flag runs on — reported alongside the
/// engine version because "which regex grammar do I actually have" is two
/// numbers, and a host selecting the PCRE arm is asking about the second one.
export fn irgx_pcre2_version() [*:0]const u8 {
    return irregex.pcre2_version_string;
}

/// A static, NUL-terminated human message for a status code (for logs; the
/// typed code stays the contract). A pure reader: it leaves the fault slot
/// alone, so a host may call it before `irgx_last_fault`.
export fn irgx_status_message(code: i32) [*:0]const u8 {
    return contract.statusMessage(code);
}

/// Detail for the LAST failing call on THIS thread — which fault, about which
/// file, at which byte. Reading does not consume; the answer stays valid until
/// this thread's next work call.
export fn irgx_last_fault(out: ?*contract.FaultDetail) i32 {
    return @intFromEnum(contract.lastFault(out));
}

// ── the regex plane ──────────────────────────────────────────────────────────
// A handle is single-threaded: it owns the scratch its finds run in. Compile
// one per thread rather than sharing one under a lock — the compile is pure,
// and the lock would serialize the only part that was ever parallel.

/// Compile `pattern[0..len]` under `flags` (`IRGX_FIXED` … `IRGX_PCRE`)
/// and write the handle to `*out`. 0 on success; negative on failure, with the
/// reason in `irgx_last_fault`.
export fn irgx_compile(pat: ?[*]const u8, len: usize, flags: u32, out: ?**pattern.Regex) i32 {
    return @intFromEnum(pattern.compile(pat, len, flags, out));
}

/// Release a handle from `irgx_compile`.
export fn irgx_free(re: *pattern.Regex) void {
    pattern.free(re);
}

/// Whether `text[0..len]` holds a match: 1 yes, 0 no, negative on error.
export fn irgx_is_match(re: *pattern.Regex, text: ?[*]const u8, len: usize) i32 {
    return @intFromEnum(pattern.isMatch(re, text, len));
}

/// Write the matches in `text[0..len]` into `out[0..cap]` and their count into
/// `*written`. Returns 1 when the text HAS at least one, 0 when none, negative
/// on error. `cap` is a window over the answer: at most `cap` are written and
/// `*written` reports how many the text HAS, so a short window sizes its retry —
/// and a `cap = 0` count query writes nothing yet still answers 1.
export fn irgx_find_all(re: *pattern.Regex, text: ?[*]const u8, len: usize, out: ?[*]pattern.Span, cap: usize, written: ?*usize) i32 {
    return @intFromEnum(pattern.findAll(re, text, len, out, cap, written));
}

/// Whether this pattern's engine can honor a live `to` bound: 1 yes, 0 no. A
/// static property of the compiled pattern — ask once, not per search. The
/// linear engine can; PCRE2 cannot, because bounding its subject would also move
/// `$`, `\b` and every lookahead.
export fn irgx_pattern_windows(re: *pattern.Regex) i32 {
    return @intFromEnum(pattern.windows(re));
}

/// `irgx_is_match` over the window `[from, to]` of `text[0..len]`: a match must
/// fit inside the region while every assertion still reads the whole text. 1 yes,
/// 0 no, negative on error. `to == len` is the unbounded case; a live bound on an
/// engine that cannot express one faults with `BoundUnsupported` rather than
/// silently answering about a slice.
export fn irgx_is_match_in(re: *pattern.Regex, text: ?[*]const u8, len: usize, from: usize, to: usize) i32 {
    return @intFromEnum(pattern.isMatchIn(re, text, len, from, to));
}

/// `irgx_find_all` over the window `[from, to]` of `text[0..len]` — same region
/// and assertion contract as `irgx_is_match_in`, and the same `cap`/`*written`
/// contract as `irgx_find_all` (`*written` is the count the WINDOW holds, so a
/// short `cap` sizes its retry).
export fn irgx_find_all_in(re: *pattern.Regex, text: ?[*]const u8, len: usize, from: usize, to: usize, out: ?[*]pattern.Span, cap: usize, written: ?*usize) i32 {
    return @intFromEnum(pattern.findAllIn(re, text, len, from, to, out, cap, written));
}

/// Write the group spans of the leftmost match at or after `from` into
/// `out[0..cap]`; `*written` reports how many groups the PATTERN has (so a
/// short `cap` sizes the retry). `out[0]` is the whole match; a group that did
/// not participate is `{-1, -1}`. 1 on a match, 0 on none, negative on error.
export fn irgx_captures(re: *pattern.Regex, text: ?[*]const u8, len: usize, from: usize, out: ?[*]pattern.Span, cap: usize, written: ?*usize) i32 {
    return @intFromEnum(pattern.captures(re, text, len, from, out, cap, written));
}

/// How many capture groups the pattern declares, excluding the whole match.
export fn irgx_group_count(re: *pattern.Regex, out: ?*u32) i32 {
    return @intFromEnum(pattern.groupCount(re, out));
}

/// The number of the group named `name[0..len]`: 1 with `*out` set when the
/// pattern declares it, 0 when it does not, negative on error.
export fn irgx_group_index(re: *pattern.Regex, name: ?[*]const u8, len: usize, out: ?*u32) i32 {
    return @intFromEnum(pattern.groupIndex(re, name, len, out));
}

/// The name group `index` was declared with: 1 with `*out` pointing at borrowed
/// bytes, 0 when the group is unnamed, negative on error. The inverse of
/// `irgx_group_index`, and the direction a host cannot derive itself without
/// re-parsing the pattern.
export fn irgx_group_name(re: *pattern.Regex, index: u32, out: ?*rows.Text) i32 {
    return @intFromEnum(pattern.groupName(re, index, out));
}

// ── the slate plane (many patterns, one pass, with attribution) ───────────────
// Everything above is about ONE pattern. These four are about N, and they keep
// which pattern found what — the fact a fused `a|b|c` throws away and N separate
// calls pay N times over. Same flag word, same unit (the whole text), so a
// slate's answer about pattern `i` is `irgx_is_match`'s answer about pattern `i`.

/// Compile `patterns[0..count]` as one slate and write the handle to `*out`.
/// `*refused` receives the index of the offending pattern on a refusal (may be
/// null). 0 on success; `IRGX_STALE` when some pattern needs `IRGX_PCRE`;
/// negative on error.
export fn irgx_slate_compile(patterns: ?[*]const slate.Pattern, count: usize, refused: ?*usize, out: ?**slate.Slate) i32 {
    return @intFromEnum(slate.compile(patterns, count, refused, out));
}

/// Release a handle from `irgx_slate_compile`.
export fn irgx_slate_free(handle: *slate.Slate) void {
    slate.free(handle);
}

/// How many patterns the slate holds — the `cap` at which `irgx_slate_which`
/// can never come up short.
export fn irgx_slate_len(handle: *const slate.Slate) usize {
    return slate.len(handle);
}

/// Does ANY pattern in the slate match `text[0..len]`? 1 yes, 0 no, negative on
/// error. The cheapest question the plane answers: a SIMD literal roll rejects a
/// hopeless text with no engine run at all.
export fn irgx_slate_is_match(handle: *slate.Slate, text: ?[*]const u8, len: usize) i32 {
    return @intFromEnum(slate.isMatch(handle, text, len));
}

/// Every pattern matching `text[0..len]`, as ascending indices into the compile
/// list, written to `out[0..cap]`. `*written` is how many matched whether or not
/// `cap` held them. 1 when at least one did, 0 when none did, negative on error.
export fn irgx_slate_which(handle: *slate.Slate, text: ?[*]const u8, len: usize, out: ?[*]u32, cap: usize, written: ?*usize) i32 {
    return @intFromEnum(slate.which(handle, text, len, out, cap, written));
}

// ── the munch plane (many patterns, anchored, longest wins) ───────────────────
// The slate above answers "which of these occur in this text" — a search. These
// five answer the question a tokenizer has instead: starting at exactly this
// offset, which of them reaches furthest. Same patterns, opposite direction, and
// the reason it is a plane rather than a `next_state` export is that the
// maximal-munch RULE is what crosses, not the automaton's table — a host
// stepping states would be a second opinion about what a pattern means.

/// Compile `patterns[0..count]` as one anchored slate under `flags` (a subset of
/// the pattern plane's: `IRGX_IGNORE_CASE`, `IRGX_NO_UNICODE`, `IRGX_MULTILINE`,
/// `IRGX_DOTALL`). 0 on success; `IRGX_STALE` when nothing at all could be
/// determinized; negative on error. A *partial* refusal is success — read it
/// with `irgx_munch_declined`.
export fn irgx_munch_compile(patterns: ?[*]const munch.Pattern, count: usize, flags: u32, out: ?**munch.Munch) i32 {
    return @intFromEnum(munch.compile(patterns, count, flags, out));
}

/// Release a handle from `irgx_munch_compile`.
export fn irgx_munch_free(handle: *munch.Munch) void {
    munch.free(handle);
}

/// How many patterns the slate can name at once — the `cap` at which
/// `irgx_munch_scan`'s winner buffer can never come up short.
export fn irgx_munch_len(handle: *const munch.Munch) usize {
    return munch.len(handle);
}

/// Every pattern the slate could not take, ascending, into `out[0..cap]`, with
/// `*written` set to how many declined whether or not `cap` held them. 1 when at
/// least one did, 0 when the slate took everything, negative on error.
export fn irgx_munch_declined(handle: *const munch.Munch, out: ?[*]munch.Refusal, cap: usize, written: ?*usize) i32 {
    return @intFromEnum(munch.declined(handle, out, cap, written));
}

/// The longest (`IRGX_MUNCH_LONGEST`) or shortest (`IRGX_MUNCH_SHORTEST`) match
/// beginning at exactly `at`, among the patterns `allow[0..nallow]` permits (null
/// permits every one), writing the winning length and count to `*tok` and the
/// winning pattern ids to `out[0..cap]`. 1 when something accepted, 0 when
/// nothing starts here, negative on error.
export fn irgx_munch_scan(
    handle: *munch.Munch,
    text: ?[*]const u8,
    len: usize,
    at: usize,
    allow: ?[*]const u32,
    nallow: usize,
    pick: u32,
    tok: ?*munch.Token,
    out: ?[*]u32,
    cap: usize,
) i32 {
    return @intFromEnum(munch.scan(handle, text, len, at, allow, nallow, pick, tok, out, cap));
}

// ── the shared warm corpus ───────────────────────────────────────────────────
// The thing every analytic producer is HANDED. `gist_run`, `relate_run`, and
// `blast_run` all take an open engine, and an engine can only be read by the copy
// of the engine code that made it — so unlike the verbs, the opener cannot be one
// symbol per library. It is here for the same reason the cursor below is.

/// Stand a warm corpus up over `roots[0..nroots]` (NUL-terminated paths) and write
/// the handle to `*out`. `nroots == 0` walks the CWD. 0 on success; negative on
/// failure, with the reason in `irgx_last_fault`.
export fn irgx_engine_open(roots: ?[*]const [*:0]const u8, nroots: usize, out: ?**api.Engine) i32 {
    return @intFromEnum(corpus.open(roots, nroots, out));
}

/// Release a corpus from `irgx_engine_open`, and everything it holds warm.
/// Every cursor drawn from it must be closed first.
export fn irgx_engine_close(engine: *api.Engine) void {
    corpus.close(engine);
}

/// Allocate a fresh (unset) cancellation token; writes it to `*out`.
export fn irgx_cancel_new(out: ?**api.CancelToken) i32 {
    return @intFromEnum(corpus.cancelNew(out));
}

/// Trip a token, cancelling every in-flight query using it. The one entry here a
/// host may call from another thread while a query is running.
export fn irgx_cancel_request(token: *api.CancelToken) void {
    corpus.cancelRequest(token);
}

/// Free a token from `irgx_cancel_new`, after every query using it returned.
export fn irgx_cancel_free(token: *api.CancelToken) void {
    corpus.cancelFree(token);
}

// ── the shared row cursor ────────────────────────────────────────────────────
// The walking half of the analytic protocol. Each library exports its own
// producer — `gist_run`, `relate_run`, `blast_run` — and every one of them
// hands back a cursor walked by THESE symbols, so a host asking three packages
// three questions still learns one way to read an answer.

/// Write the next row into `*out`. 1 when one was written, 0 at the end,
/// negative on error. Rows borrow the cursor's arena until `irgx_rows_close`.
export fn irgx_rows_next(cursor: *answer.Answer, out: ?*rows.Row) i32 {
    return @intFromEnum(answer.next(cursor, out));
}

/// Fill up to `cap` rows into `out[0..cap]`, writing the count to `*written`.
/// The crossing a batching binding amortizes N rows over.
export fn irgx_rows_next_batch(cursor: *answer.Answer, out: ?[*]rows.Row, cap: usize, written: ?*usize) i32 {
    return @intFromEnum(answer.nextBatch(cursor, out, cap, written));
}

/// Answer-level facts no row carries — which tier answered, the freshness
/// fold, and `foreign` (query fingerprints this corpus has never seen).
export fn irgx_rows_stats(cursor: *answer.Answer, out: ?*rows.Stats) i32 {
    return @intFromEnum(answer.stats(cursor, out));
}

/// Free a cursor, and with it everything its rows borrow.
export fn irgx_rows_close(cursor: *answer.Answer) void {
    answer.close(cursor);
}

/// A stable, static, NUL-terminated digest of the WHOLE row-schema table. A
/// binding compares it to the digest its decoder was generated from, so a
/// stale shared library is a loud startup failure, not a mis-decoded row.
export fn irgx_schema_digest() [*:0]const u8 {
    return rows.digest();
}

/// How many row schemas this build declares (ids are 1..count).
export fn irgx_schema_count() u32 {
    return rows.schemaCount();
}

/// Fill `*out` with schema `id`. Its names, tags, and field arrays are static
/// and outlive every call.
export fn irgx_schema_get(id: u32, out: ?*rows.Schema) i32 {
    return @intFromEnum(rows.schemaGet(id, out));
}

test {
    // The shims are one-liners over tested bodies; what a test here can still
    // catch is a signature that stopped compiling as C-callable.
    std.testing.refAllDecls(@This());
}
