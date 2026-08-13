//! `libirgx` — the C-ABI artifact's root, and nothing else.
//!
//! This file exists to be a *different* root from `src/root.zig`. A Zig
//! `export fn` is emitted by every compilation that reaches it, so if these
//! shims lived in the library module, then each product face's library — every
//! one of which imports that module — would carry its own copy of
//! `irgx_last_fault`, and a host linking two would get
//! a duplicate-symbol error for a symbol it asked for once. Keeping the
//! `export fn`s in the artifact's root instead means the symbols exist exactly
//! where the `.a`/`.dylib` named after them is, which is the whole premise of
//! four libraries rather than one.
//!
//! What crosses here is three planes: the SUBSTRATE every package's ABI shares
//! (the status vocabulary, the per-thread fault pull, the ABI/engine versions),
//! this package's OWN verbs — a pattern over a buffer — and the warm CORPUS
//! planes the siblings all reach for. What stays out is the resident session and
//! the analytic producers (each face's own `…_run`), which belong to the
//! library named after each.
//!
//! Header: `include/irgx.h`, which is the normative statement of these
//! signatures. Bodies: `contract.zig` (substrate), `pattern.zig` (verbs), and
//! the per-plane siblings beside them (`corpus` · `tree` · `walk` · `sieve` ·
//! `codex` · `lines` · `literals` · `needles` · `munch` · `slate` · `rows`).

const std = @import("std");
const builtin = @import("builtin");
const irregex = @import("irregex");

const answer = irregex.ffi.answer;
const api = irregex.api;
const codex = irregex.ffi.codex;
const contract = irregex.ffi.contract;
/// A sibling in THIS module rather than a member of the library's `ffi` group:
/// it lowers the `api` veneer, which only a consumer of the library may reach.
const corpus = @import("corpus.zig");
const lines = irregex.ffi.lines;
const literals = irregex.ffi.literals;
const munch = irregex.ffi.munch;
const needles = irregex.ffi.needles;
const pattern = irregex.ffi.pattern;
const rows = irregex.ffi.rows;
const sieve = irregex.ffi.sieve;
const slate = irregex.ffi.slate;
const tree = irregex.ffi.tree;
const walk = irregex.ffi.walk;

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
/// session ABI, which is the face package's and versions on its own axis. Bump only
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

/// Whether this pattern can report EARLIEST-mode spans: 1 yes, 0 no. A static
/// property of the compiled pattern, like `irgx_pattern_windows` — ask once, not
/// per search.
///
/// Answering 0 is a refusal, not a slower path: a span request under
/// `IRGX_MODE_EARLIEST` then faults with `Unsupported` rather than quietly
/// returning the leftmost-first match under an earliest label. PCRE2 declines
/// (no inspectable program), and so does any assertion-bearing pattern, whose
/// determinized states depend on the gap they were entered at — which a walk
/// starting mid-buffer cannot reconstruct. The mode is inert on the boolean
/// verbs either way, since existence does not depend on which match is reported,
/// so a host only needs this before asking for spans.
export fn irgx_pattern_earliest(re: *pattern.Regex) i32 {
    return @intFromEnum(pattern.earliest(re));
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
// The thing every analytic producer is HANDED. Each face's own `…_run` takes an
// open engine, and an engine can only be read by the copy of the engine code
// that made it — so unlike the verbs, the opener cannot be one
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
// producer — its face-named `…_run` — and every one of them hands back a cursor
// walked by THESE symbols, so a host asking three packages three questions still
// learns one way to read an answer.

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

// ── lines ────────────────────────────────────────────────────────────────────
// The line grid every grep-shaped host rebuilds by hand, and the one place the
// off-by-one lives. A span is a byte offset; a user reads rows.

/// How many lines `text[0..len]` holds. An unterminated tail counts as a line,
/// because a host printing `n` rows must print that one too.
export fn irgx_lines_count(text: ?[*]const u8, len: usize, out: ?*u64) i32 {
    return @intFromEnum(lines.count(text, len, out));
}

/// The band of lines around byte `at`: up to `before` rows preceding it, the row
/// holding it, and up to `after` following. `*center` receives the band-relative
/// index of the row holding `at`, which is the number a caret needs and cannot
/// derive from `*written` alone (a band clipped at the text's start has fewer
/// preceding rows than asked for). `at == len` is legal and lands on the tail.
export fn irgx_lines_context(
    text: ?[*]const u8,
    len: usize,
    at: usize,
    before: usize,
    after: usize,
    out: ?[*]lines.Line,
    cap: usize,
    written: ?*usize,
    center: ?*usize,
) i32 {
    return @intFromEnum(lines.context(text, len, at, before, after, out, cap, written, center));
}

/// The whole grid, one `irgx_line` per row. Each row carries `content_end` and
/// `term_end` separately, so a host can render without the terminator and slice
/// with it, and never has to guess whether the file ended in `\n` or `\r\n`.
export fn irgx_lines_split(text: ?[*]const u8, len: usize, out: ?[*]lines.Line, cap: usize, written: ?*usize) i32 {
    return @intFromEnum(lines.split(text, len, out, cap, written));
}

// ── literals + the Unicode tables ───────────────────────────────────────────
// What a pattern PROMISES about the bytes any match must contain — the input an
// indexer needs to build a prefilter — plus the tables the engine decides with,
// so a host is not left reimplementing case folding against a different Unicode
// version than the one matching it.

/// Extract what `re` promises about its matches. The handle borrows nothing from
/// `re` after this returns, so the two are freed independently.
export fn irgx_literals_open(re: ?*pattern.Regex, out: ?**literals.Literals) i32 {
    return @intFromEnum(literals.open(re, out));
}

/// Release a handle from `irgx_literals_open`.
export fn irgx_literals_free(lits: *literals.Literals) void {
    literals.free(lits);
}

/// The facts about the extraction as a whole: which sets are populated, how each
/// is graded, and the pattern's structural signature. Read this BEFORE a set —
/// it is what says whether the set you are about to read is a guarantee or a
/// guess, and a prefilter built on the wrong one drops real matches.
export fn irgx_literals_promise(lits: *const literals.Literals, out: ?*literals.Promise) i32 {
    return @intFromEnum(literals.promise(lits, out));
}

/// One set of literals by `place` (prefix / suffix / required / …), with its
/// grade written to `*verdict`. The `irgx_text` rows borrow the handle's arena
/// and die with `irgx_literals_free`; copy anything outliving it.
export fn irgx_literals_set(
    lits: *const literals.Literals,
    place: u32,
    verdict: ?*u32,
    out: ?[*]rows.Text,
    cap: usize,
    written: ?*usize,
) i32 {
    return @intFromEnum(literals.set(lits, place, verdict, out, cap, written));
}

/// Every codepoint that case-folds together with `cp`, including `cp` itself —
/// the orbit, not a pair, because `k`, `K` and KELVIN SIGN are one class. This
/// is the table `-i` folds with, so a host building its own index folds
/// identically instead of approximately.
export fn irgx_fold_orbit(cp: u32, out: ?[*]u32, cap: usize, written: ?*usize) i32 {
    return @intFromEnum(literals.foldOrbit(cp, out, cap, written));
}

/// The inclusive codepoint ranges of the Unicode property `name[0..len]`
/// (`Letter`, `Greek`, `Nd`, …), ascending and non-overlapping. An unknown name
/// faults with `BadPattern` rather than answering empty, because an empty class
/// and a misspelled one must not look alike.
export fn irgx_property_ranges(
    name: ?[*]const u8,
    len: usize,
    out: ?[*]literals.Range,
    cap: usize,
    written: ?*usize,
) i32 {
    return @intFromEnum(literals.propertyRanges(name, len, out, cap, written));
}

/// Whether `cp` is in the property `name[0..len]`: 1 yes, 0 no, negative for an
/// unknown property. The membership test without materializing the ranges.
export fn irgx_property_has(name: ?[*]const u8, len: usize, cp: u32) i32 {
    return @intFromEnum(literals.propertyHas(name, len, cp));
}

/// The Unicode version these tables were generated from, static and
/// NUL-terminated. A host whose own tables disagree is a host whose prefilter
/// and this engine disagree about what a letter is.
export fn irgx_unicode_version(out: ?*rows.Text) i32 {
    return @intFromEnum(literals.unicodeVersion(out));
}

// ── needles ──────────────────────────────────────────────────────────────────
// Many literals, one pass, with attribution. The question a regex alternation
// answers slowly and a wordlist scanner answers quickly.

/// Compile `list[0..count]` into one multi-literal scanner. `*refused` receives
/// how many needles the machine declined to seat, so a partial set is visible
/// rather than silently smaller than what was handed in.
export fn irgx_needles_compile(
    list: ?[*]const needles.Needle,
    count: usize,
    flags: u32,
    refused: ?*usize,
    out: ?**needles.Needles,
) i32 {
    return @intFromEnum(needles.compile(list, count, flags, refused, out));
}

/// Release a handle from `irgx_needles_compile`.
export fn irgx_needles_free(handle: *needles.Needles) void {
    needles.free(handle);
}

/// How many needles the set holds — the exact `cap` `irgx_needles_which` never
/// needs to retry at.
export fn irgx_needles_len(handle: *const needles.Needles) usize {
    return needles.len(handle);
}

/// What this set is and which machine answers about it. A pure reader: it starts
/// no work, so it cannot disturb the fault a previous call left for the host.
export fn irgx_needles_describe(handle: *const needles.Needles, out: ?*needles.Shape) i32 {
    return @intFromEnum(needles.describe(handle, out));
}

/// Whether any needle occurs in `text[0..len]`: 1 yes, 0 no, negative on error.
/// The cheapest question — it stops at the first hit and attributes nothing.
export fn irgx_needles_is_match(handle: *needles.Needles, text: ?[*]const u8, len: usize) i32 {
    return @intFromEnum(needles.isMatch(handle, text, len));
}

/// WHICH needles occur in `text[0..len]`, as ascending indices into the compiled
/// list — presence per needle, not one row per occurrence. Size `cap` from
/// `irgx_needles_len` and this never retries.
export fn irgx_needles_which(handle: *needles.Needles, text: ?[*]const u8, len: usize, out: ?[*]u32, cap: usize, written: ?*usize) i32 {
    return @intFromEnum(needles.which(handle, text, len, out, cap, written));
}

/// Every occurrence, each carrying its needle index and its span — the
/// attributed walk. `*written` is the count the TEXT holds, so a short `cap`
/// sizes its retry rather than truncating silently.
export fn irgx_needles_find_all(handle: *needles.Needles, text: ?[*]const u8, len: usize, out: ?[*]needles.Occurrence, cap: usize, written: ?*usize) i32 {
    return @intFromEnum(needles.findAll(handle, text, len, out, cap, written));
}

// ── tree: searching a tree rather than a buffer the host already holds ──

/// Run one search over the engine's corpus and hand back a cursor to pull from.
/// A handle comes back on `.ok` TOO — including `.ok` with no records — so the
/// host owes `irgx_matches_close` on every non-negative return.
export fn irgx_tree_search(engine: *api.Engine, req: ?*const tree.Request, out: ?**api.Cursor) i32 {
    return @intFromEnum(tree.search(engine, req, out));
}

/// Pull one record. `.match` for a record, `.ok` for a drained stream (`out`
/// untouched) — the one-record spelling of `irgx_matches_next_batch`.
export fn irgx_matches_next(cursor: *api.Cursor, out: ?*tree.Match) i32 {
    return @intFromEnum(tree.next(cursor, out));
}

/// Pull up to `cap` records in one crossing and write how many landed. That
/// count is what this call CONSUMED, never a total that exists.
export fn irgx_matches_next_batch(cursor: *api.Cursor, out: ?[*]tree.Match, cap: usize, written: ?*usize) i32 {
    return @intFromEnum(tree.nextBatch(cursor, out, cap, written));
}

/// How many records the stream holds, without advancing it — the total the
/// batch verb's `*written` deliberately cannot answer.
export fn irgx_matches_count(cursor: *const api.Cursor) usize {
    return tree.count(cursor);
}

/// Release the cursor and every byte its records borrowed.
export fn irgx_matches_close(cursor: *api.Cursor) void {
    tree.close(cursor);
}

// ── walk: which files a search is even allowed to read ──

/// The ceilings this build enforces on a walk, so a host can size its request
/// against the truth rather than against a constant it copied.
export fn irgx_walk_limits(out: ?*walk.Limits) i32 {
    return @intFromEnum(walk.limits(out));
}

/// Materialize the eligible set for `spec` — gitignore precedence, type
/// registry, hidden and binary policy, all of it — into a walk to iterate.
export fn irgx_walk_open(spec: ?*const walk.Spec, out: ?**walk.Walk) i32 {
    return @intFromEnum(walk.open(spec, out));
}

/// How many entries the walk holds. A read of materialized state, so it hands
/// back the number rather than a status to unwrap.
export fn irgx_walk_count(w: *const walk.Walk) usize {
    return walk.count(w);
}

/// How many directories the walk could not read but was told to tolerate — the
/// number that separates "nothing matched" from "we never looked there".
export fn irgx_walk_gapped(w: *const walk.Walk) u32 {
    return walk.gapped(w);
}

/// Pull one eligible entry; `.ok` once the walk is drained.
export fn irgx_walk_next(w: *walk.Walk, out: ?*walk.Entry) i32 {
    return @intFromEnum(walk.next(w, out));
}

/// Pull up to `cap` entries in one crossing, writing how many landed.
export fn irgx_walk_next_batch(w: *walk.Walk, out: ?[*]walk.Entry, cap: usize, written: ?*usize) i32 {
    return @intFromEnum(walk.nextBatch(w, out, cap, written));
}

/// Restart iteration from the first entry. The set was already materialized, so
/// this re-reads nothing from the filesystem.
export fn irgx_walk_rewind(w: *walk.Walk) void {
    walk.rewind(w);
}

/// Whether this exact path is in the eligible set — the membership question,
/// asked without iterating to find out.
export fn irgx_walk_holds(w: *const walk.Walk, path: ?[*]const u8, path_len: usize) i32 {
    return @intFromEnum(walk.holds(w, path, path_len));
}

/// Release the walk and every byte it lent out.
export fn irgx_walk_close(w: *walk.Walk) void {
    walk.close(w);
}

/// Whether `bytes[0..len]` reads as binary under the same window the corpus
/// walk itself applies — the predicate, decoupled from the walk.
export fn irgx_walk_binary(bytes: ?[*]const u8, len: usize) i32 {
    return @intFromEnum(walk.binary(bytes, len));
}

/// What a path is FOR — code, docs or data — the total, disjoint partition the
/// `--docs`/`--code`/`--data` corpus split is built on.
export fn irgx_walk_genus(path: ?[*]const u8, len: usize, out: ?*walk.Genus) i32 {
    return @intFromEnum(walk.genusOf(path, len, out));
}

// ── sieve: narrowing before reading, so most files are never opened ──

/// Open the persisted narrowing artifacts in `dir` — the trigram index and the
/// crest sieve. A foreign tree's artifacts open inert rather than wrong.
export fn irgx_sieve_open(dir: ?[*]const u8, dir_len: usize, out: ?**sieve.Sieve) i32 {
    return @intFromEnum(sieve.open(dir, dir_len, out));
}

/// Release the sieve and every byte it lent out.
export fn irgx_sieve_close(s: *sieve.Sieve) void {
    sieve.close(s);
}

/// What this artifact set actually contains — document, path and posting
/// counts, and which of the two narrowing tiers are present at all.
export fn irgx_sieve_describe(s: *const sieve.Sieve, out: ?*sieve.Facts) i32 {
    return @intFromEnum(sieve.facts(s, out));
}

/// The path a document id names. Bytes borrowed from the sieve, valid until
/// `irgx_sieve_close`.
export fn irgx_sieve_doc_path(s: *const sieve.Sieve, doc: u32, out: ?*rows.Text) i32 {
    return @intFromEnum(sieve.docPath(s, doc, out));
}

/// The i-th root the artifacts were built over — how a host recognizes an index
/// built for a different tree.
export fn irgx_sieve_root(s: *const sieve.Sieve, i: u32, out: ?*rows.Text) i32 {
    return @intFromEnum(sieve.root(s, i, out));
}

/// The documents that could contain this literal, as ascending ids. A SUPERSET:
/// the sieve rules files out, it never rules one in.
export fn irgx_sieve_literal(s: *sieve.Sieve, needle: ?[*]const u8, len: usize, out: ?[*]u32, cap: usize, written: ?*usize) i32 {
    return @intFromEnum(sieve.literal(s, needle, len, out, cap, written));
}

/// The same question for a union of literals — the union computed inside the
/// index rather than by N crossings the host merges itself.
export fn irgx_sieve_alternation(s: *sieve.Sieve, needles_ptr: ?[*]const rows.Text, n: usize, out: ?[*]u32, cap: usize, written: ?*usize) i32 {
    return @intFromEnum(sieve.alternation(s, needles_ptr, n, out, cap, written));
}

/// The documents a compiled pattern's whole narrowing calculus admits — the
/// superset to read, in id order.
export fn irgx_sieve_candidates(s: *sieve.Sieve, w: *const sieve.Winnow, out: ?[*]u32, cap: usize, written: ?*usize) i32 {
    return @intFromEnum(sieve.candidates(s, w, out, cap, written));
}

/// The candidates, ordered by what is cheapest to read rather than by id — the
/// same set, sequenced for the machine that has to open the files.
export fn irgx_sieve_reading_list(s: *sieve.Sieve, w: *const sieve.Winnow, out: ?[*]u32, cap: usize, written: ?*usize) i32 {
    return @intFromEnum(sieve.readingList(s, w, out, cap, written));
}

/// Whether the artifacts still describe the tree, and the wall-clock anchor the
/// answer is measured against.
export fn irgx_sieve_freshness(s: *const sieve.Sieve, out: ?*sieve.Freshness) i32 {
    return @intFromEnum(sieve.freshness(s, out));
}

/// HOW MANY documents changed since the anchor — the magnitude `freshness`
/// reduces to a state, for a host deciding whether a rebuild is worth it.
export fn irgx_sieve_stale_count(s: *const sieve.Sieve, out: ?*usize) i32 {
    return @intFromEnum(sieve.staleCount(s, out));
}

/// Derive a pattern's narrowing plan once, to spend across many sieve queries.
export fn irgx_winnow_of(re: ?*pattern.Regex, out: ?**sieve.Winnow) i32 {
    return @intFromEnum(sieve.winnowOf(re, out));
}

/// Release the plan.
export fn irgx_winnow_free(w: *sieve.Winnow) void {
    sieve.winnowFree(w);
}

/// What the plan is made of — clauses, atoms, literals — and whether it can
/// narrow at all. `idle` is the honest answer that this pattern rules nothing out.
export fn irgx_winnow_describe(w: *const sieve.Winnow, out: ?*sieve.WinnowFacts) i32 {
    return @intFromEnum(sieve.winnowFacts(w, out));
}

// ── codex: the self-index — count, locate and restore without the text ──

/// The longest text this build can index, so a host refuses before it allocates.
export fn irgx_codex_max_text_len() usize {
    return codex.maxTextLen();
}

/// Build a self-index over `text[0..len]`. The result answers about the text
/// without keeping it, which is the whole point of the structure.
export fn irgx_codex_build(text: ?[*]const u8, len: usize, opts: ?*const codex.Options, out: ?**codex.Codex) i32 {
    return @intFromEnum(codex.build(text, len, opts, out));
}

/// Load a previously `irgx_codex_save`d index. A blob this build cannot read
/// fails closed rather than opening as a best-effort prefix.
export fn irgx_codex_load(bytes: ?[*]const u8, len: usize, out: ?**codex.Codex) i32 {
    return @intFromEnum(codex.load(bytes, len, out));
}

/// Release the index.
export fn irgx_codex_free(cx: *codex.Codex) void {
    codex.free(cx);
}

/// The length of the text the index stands for — asked of the index, since the
/// text itself need not exist any more.
export fn irgx_codex_len(cx: *const codex.Codex) usize {
    return codex.length(cx);
}

/// What the index cost and what it can still do — sample rate, and the byte
/// budget each layer holds.
export fn irgx_codex_measure(cx: *const codex.Codex, out: ?*codex.Stats) i32 {
    return @intFromEnum(codex.measure(cx, out));
}

/// How many times `pattern` occurs, in time proportional to the PATTERN — the
/// occurrences are never enumerated to count them.
export fn irgx_codex_count(cx: *const codex.Codex, pattern_ptr: ?[*]const u8, len: usize, out: ?*usize) i32 {
    return @intFromEnum(codex.count(cx, pattern_ptr, len, out));
}

/// WHERE it occurs, as text offsets. `.stale` when the index was built without
/// the locate layer — a declinature, not an empty answer.
export fn irgx_codex_locate(cx: *const codex.Codex, pattern_ptr: ?[*]const u8, len: usize, out: ?[*]usize, cap: usize, written: ?*usize) i32 {
    return @intFromEnum(codex.locate(cx, pattern_ptr, len, out, cap, written));
}

/// The text offset one index row stands for — the single-row spelling of
/// `irgx_codex_locate`, for a host walking rows it already has.
export fn irgx_codex_position(cx: *const codex.Codex, row: usize, out: ?*usize) i32 {
    return @intFromEnum(codex.position(cx, row, out));
}

/// The whole row range: the interval before any character has narrowed it.
export fn irgx_codex_rows_whole(cx: *const codex.Codex, out: ?*codex.Rows) i32 {
    return @intFromEnum(codex.rowsWhole(cx, out));
}

/// Narrow a row range by one byte, extending the pattern leftward — the
/// backward-search step, exposed so a host can drive its own search.
export fn irgx_codex_rows_extend(cx: *const codex.Codex, rows_io: ?*codex.Rows, byte: u8) i32 {
    return @intFromEnum(codex.rowsExtend(cx, rows_io, byte));
}

/// Reconstruct the text from `at` onward — the index is the text, so nothing
/// else needed to be kept.
export fn irgx_codex_extract(cx: *codex.Codex, at: usize, out: ?[*]u8, cap: usize, written: ?*usize) i32 {
    return @intFromEnum(codex.extract(cx, at, out, cap, written));
}

/// Serialize the index. `*written` is the size the index NEEDS, so a short
/// `cap` sizes its retry rather than truncating silently.
export fn irgx_codex_save(cx: *codex.Codex, out: ?[*]u8, cap: usize, written: ?*usize) i32 {
    return @intFromEnum(codex.save(cx, out, cap, written));
}

test {
    // The shims are one-liners over tested bodies; what a test here can still
    // catch is a signature that stopped compiling as C-callable.
    std.testing.refAllDecls(@This());
}
