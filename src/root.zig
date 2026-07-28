//! irregex — fast, agent-friendly code locator kernel.
//!
//! The engine half of an agent-native grep: a candidate INDEX that turns a
//! whole-tree scan into a scoped lookup, plus (later tiers) sparse-n-gram
//! selection, ranked + token-compressed output, and fusion with an external
//! code graph + contracts. ripgrep is near-optimal at *unindexed* scan; irregex's
//! win is at scale (don't rescan) and at *intent* (don't already know the
//! symbol) — see `research/dossiers/locator-sota.dossier.toml`.
//!
//! Search, index lifecycle, and result handling are Zig-native and surfaced by
//! the `gist` CLI. The C ABI in `include/irregex.h` exposes ABI/engine-version
//! introspection, allocation-free trigram extraction, AND — since ADR-352
//! rung 3 — an in-process warm search SESSION (`irregex_open`/`irregex_search`/
//! `irregex_close`, implemented in
//! `surface/ffi/session.zig`): a non-Zig host holds a corpus warm in its own
//! process and streams match records over a callback, with no subprocess,
//! socket, `stdout`, or `exit`. Every entry returns a status code instead of
//! `die()`ing, so a bad query can never terminate an embedding host — the
//! property ADR-352 gated the search ABI on. It rides the
//! error-returning shared core (`kernel/match/query/query.zig`) + resident engine, so an
//! in-process answer is byte-identical to the cold `gist --json` stream. Index
//! BUILD lifecycle stays a Zig/CLI surface (a session searches the live tree).
//!
//! Package shape: two engines over a shared floor, grouped by concern and
//! re-exported here (three layers under `src/`):
//!
//!   kernel/   — pure compute, no argv/walk/emit: match · rank · kinship · batch ·
//!               compose · primitives
//!   corpus/   — the body of text + persisted forms: tree/ walk · scope/ · index/
//!               (trigrams · postings · codex · atlas · crest · …)
//!   surface/  — transports + faces: exec/{cold,session} · ffi · face/{gist,relate,irregex}
//!               · cli/ (shared flag/emit vocabulary)

const std = @import("std");

// ── assay: the instrumentation floor (time · count · debug) ──
// The bottom of the package DAG (imports only std): typed monotonic `Span`/
// `Duration` vs wall-clock `Anchor`, the comptime-checked `Tally(Schema)`
// counter set, and the one lens-gated, sink-routed diagnostic channel every
// timing/trace/summary line flows through (so the C-ABI never-write contract
// and warm-query timing are properties of one seam). See src/assay/README.md.
pub const assay = @import("assay/assay.zig");

// How a face terminates: the rg `0`/`1`/`2` exit contract (both precedences)
// and the `fatal` catch that keeps an escaped error off Zig's default handler,
// which would exit 1 — "found nothing" — on a hard fault. See ADR-373.
pub const Outcome = @import("surface/cli/outcome.zig").Outcome;
pub const fatal = @import("surface/cli/outcome.zig").fatal;

// The vocabulary those exits speak: five fault domains declared once (Zig
// merges error names globally, so the merge must be deliberate), the
// declinature enum that keeps a routine tier fallback out of the error channel
// entirely, and the thread-local detail slot the C ABI's last-fault pull reads.
// Vocabulary and payload only — transport stays assay's. See ADR-373 laws 1-3.
pub const fault = @import("fault.zig");

// ── candidate index ──
pub const ngram = @import("corpus/index/trigrams/ngram.zig");
pub const trigram = @import("corpus/index/trigrams/trigram.zig");
pub const persist = @import("corpus/index/trigrams/persist.zig");
pub const codicil = @import("corpus/index/trigrams/codicil.zig");

// ── the crest sieve (math floor + persisted sidecar) ──
// The forced-class-run necessary condition that prunes the trigram index's one
// structural hole — literal-free class-repetition patterns ([0-9a-f]{8}) that
// extract no required substring. Kernel is pure math; the sidecar rides the
// same generation-atomic publish as the trigram pair. Proof: research/crest/.
pub const crest = @import("kernel/primitives/crest.zig");
pub const crest_sidecar = @import("corpus/index/crest/sidecar.zig");

// ── the ward (shared reader/writer discipline) ──
// The concurrency-axis peer of `parallel.zig`: lease guards + the double-checked
// read-mostly `readReconciled` dance the warm session rides instead of
// hand-rolling `std.Io.RwLock` lock/unlock pairs. Pure `std.Io` plumbing.
pub const ward = @import("kernel/primitives/ward.zig");

// ── the fan-out floor (byte-balanced sharding + partial-spawn-safe spawn/join) ──
// The other half of that pair, re-exported for the same reason: the bench harness
// has to reproduce a product lane's EXACT shard geometry to price it honestly, and
// re-deriving `greedyBounds`/`fanOut` in the harness would make the instrument
// disagree with the thing it measures.
pub const parallel = @import("kernel/primitives/parallel.zig");

// ── regex engine ──
// The engine is a sealed deep module: every consumer enters through its one
// entry file, so a second grammar cannot grow beside it. These names re-export
// the stages the C-ABI / library consumers bind, through that same door.
const regex_engine = @import("kernel/match/regex/regex.zig");
pub const regex = regex_engine.program;
pub const regex_dfa = regex_engine.dfa;
/// The engine-neutral match seam (`Matcher`) the presentation layer programs
/// to — re-exported for the bench lab's isolated output-path profiles.
pub const matcher = regex_engine.ladder;

// ── ranking ──
pub const rank = @import("kernel/rank/rank.zig");
pub const signals = @import("kernel/rank/signals.zig");

// ── byte-level match execution ──
pub const simd = @import("kernel/match/scan/simd.zig");
pub const verify = @import("kernel/match/scan/verify.zig");

// ── the presentation layer (rg-shaped output; -n/-v/-o/-c frames) ──
// The `Emitter` that turns one file's matches into ripgrep-shaped bytes, and
// the `Opts` flag record that steers it. Re-exported so the bench lab can
// profile individual output-path functions (line-number formatting, the
// invert selection loop) in isolation.
pub const emit = @import("surface/exec/cold/emit/output.zig");
/// The `rg --json` record-stream encoder — re-exported so the bench lab can
/// profile the per-record hot path (`pathData` cache, `writeUint`, `asciiOnly`)
/// over the real corpus in isolation, the same way it profiles the text
/// Emitter's line-number itoa and invert loop.
pub const emit_json = @import("surface/exec/cold/emit/json.zig");
pub const argv = @import("surface/exec/cold/argv/args.zig");
/// The `-r`/`--replace` capture seam (`Caps`/`Captures`) — re-exported so the
/// bench lab can profile the replacement template expander (`emit.expandInto`)
/// against a naive reference in isolation, the same way it profiles the
/// line-number itoa and the invert loop.
pub const captures = regex_engine.captures;

// ── corpus + freshness ──
pub const corpus = @import("corpus/tree/corpus.zig");
pub const haystack = @import("corpus/tree/haystack.zig");
pub const bulkstat = @import("corpus/tree/bulkstat.zig");
pub const fresh = @import("corpus/index/trigrams/fresh.zig");
pub const atlas = @import("corpus/index/atlas/atlas.zig");
pub const frag = @import("corpus/index/frag/frag.zig");
// ── irregex: the irregular-expression primitives (match ∪ relate ∪ weave) ──
// The set-shaped tier over the engine: PatternSet compiles MANY intents with
// exact per-pattern attribution (the match half), Sketch measures compression
// kinship between byte bodies (the relate half — LZ dictionaries, no parsing),
// loom executes a closed filter/group/sort/limit plan over the attributed
// stream engine-side, and bits is the shared two's-complement identity floor
// (set-bit walks, word-packed bit sets) the other tiers ride instead of
// hand-rolling. Primitives only — faces (CLI verbs, bindings) consume.
pub const irregex = struct {
    pub const bits = @import("kernel/primitives/bits.zig");
    pub const patterns = @import("kernel/batch/patterns.zig");
    pub const sketch = @import("kernel/kinship/metric/sketch.zig");
    pub const silhouette = @import("kernel/kinship/metric/silhouette.zig");
    pub const loom = @import("kernel/batch/loom.zig");
};

// ── compose: the third face's exact-before-statistical kernels (ADR-367) ──
// The pure composition tier the `irregex` binary drives: a compiled PatternSet
// (the match half) narrows the corpus to a typed CandidateSet, and the relate
// half then runs ONLY inside that exact subset. Family can additionally lift
// hits into functions / bounded windows before kinship, so a small
// implementation is not drowned by unrelated file bytes. Provenance closes quote's loop:
// a quoted phrase is re-verified against the source's CURRENT bytes. Pure
// kernels — no I/O, no argv; the `surface/face/irregex` face loads the corpus and renders.
pub const compose = struct {
    pub const candidates = @import("kernel/compose/candidates.zig");
    pub const context = @import("kernel/compose/context.zig");
    pub const family = @import("kernel/compose/family.zig");
    pub const provenance = @import("kernel/compose/provenance.zig");
    pub const regions = @import("kernel/compose/regions.zig");
    pub const lexspan = @import("kernel/compose/lexspan.zig");
    pub const blast = @import("kernel/compose/blast.zig");
};

// ── codex: the compressed self-index (the book that IS its own index) ──
// FM-index over SA-IS + Huffman-shaped wavelet tree + RRR bitvectors: holds a
// corpus at entropy-bound size while answering count(P) in O(|P|) — flat in
// corpus size — plus locate (sampled) and byte-exact restore, all after the
// text, suffix array, and BWT are freed. The Shannon rung under both engines:
// gist gets an exact zero-false-positive tier, mutual a corpus-global
// matching-statistics substrate. See src/corpus/index/codex/README.md for the math.
pub const codex = struct {
    pub const sais = @import("corpus/index/codex/sais.zig");
    pub const rrr = @import("corpus/index/codex/rrr.zig");
    pub const wavelet = @import("corpus/index/codex/wavelet.zig");
    pub const index = @import("corpus/index/codex/codex.zig");
    pub const cento = @import("corpus/index/codex/cento.zig");
    pub const shelf = @import("corpus/index/codex/shelf.zig");
};

// ── relate: the compression-search engine ──
// The asymmetric successor to the symmetric sketch for SEARCH: persisted
// trigram evidence nominates a bounded pool, then the zipper decides with a
// suffix-automaton Ziv–Merhav cross-parse. The live lexicon remains the
// missing-index oracle. See src/kernel/kinship/.
pub const relate = struct {
    pub const lexicon = @import("kernel/kinship/recall/lexicon.zig");
    pub const retrieval = @import("surface/exec/cold/engine/retrieval.zig");
    pub const resident = @import("surface/exec/session/warm/recall.zig");
    pub const zipper = @import("kernel/kinship/recall/zipper.zig");
    pub const repetition = @import("kernel/kinship/cluster/echoes.zig");
    pub const attribute = @import("surface/face/relate/attribute.zig");
};

// ── the transport-neutral compiled query (the shared search core) ──
// One deep module owns "a search intent, compiled": the fail-closed, thread-safe
// compile → sound-trigram-prefilter → per-doc match/count kernels that BOTH the
// cold CLI (`surface/exec/cold`) and the warm resident session (`surface/exec/session`)
// execute through, so the two engines cannot drift on what matches.
pub const engine = struct {
    pub const query = @import("kernel/match/query/query.zig");
};

// ── resident search session (ADR-352 rung 2.5): the warm in-memory engine +
// its Unix-socket transport, sharing the kernels above but returning errors
// instead of `die()`ing so a bad request can't take down the daemon. ──
pub const session = struct {
    pub const resident = @import("surface/exec/session/warm/resident.zig");
    pub const corpus = @import("surface/exec/session/warm/corpus.zig");
    pub const render = @import("surface/exec/session/facet/render.zig");
    pub const request = @import("surface/exec/session/answer/request.zig");
    pub const protocol = @import("surface/exec/session/conduit/protocol/protocol.zig");
    pub const watch = @import("surface/exec/session/watch/watch.zig");
};

// ── in-process C-ABI search session (ADR-352 rung 3) ──
// The warm engine above, exposed to non-Zig hosts as an `open`/`search`/`close`
// callback-streaming C ABI — no subprocess, socket, stdout, or exit. Backs the
// `cffi` Python transport; the `export fn`s below forward into it.
pub const ffi = struct {
    pub const contract = @import("surface/ffi/contract.zig");
    pub const session = @import("surface/ffi/session.zig");
    /// The pull-cursor sibling of `session` (ADR-352): open an `Engine`, run a
    /// `search` that materializes a `Cursor`, then `next`/`next_batch` it — with
    /// thread-safe cancellation and per-operation budgets. Additive over the
    /// legacy triad; backs the Go/cgo binding and any callback-averse host.
    pub const cursor = @import("surface/ffi/cursor.zig");
    /// The analytic plane's data contract (ADR-377): the self-describing row
    /// every kinship/retrieval/sweep/composed verb answers with, the five
    /// params families, and the generated schema table all three bindings
    /// decode against.
    pub const rows = @import("surface/ffi/rows.zig");
    /// The analytic plane's dispatch: one entry for seventeen verbs, each
    /// materializing a `Rows` cursor. A verb this build cannot answer
    /// in-process returns `.stale` — the ABI's "answer through the fallback",
    /// so the plane graduates verb by verb without a binding changing.
    pub const analytic = @import("surface/ffi/analytic.zig");
};

/// CLI surfaces built on the engine above. Not part of the C ABI — the `gist`
/// executable (`surface/face/gist/main.zig`) and the bench harness dispatch through
/// these; grouped here so the whole command tree resolves through the module.
pub const commands = struct {
    pub const scope = struct {
        pub const glob = @import("corpus/scope/glob.zig");
        pub const types = @import("corpus/scope/types.zig");
    };
    /// Read-only index introspection (the `status` verb).
    pub const status = @import("surface/face/gist/status/status.zig");
    /// `gist --schema` JSON capability manifest.
    pub const schema = @import("surface/face/gist/schema/schema.zig");
    /// The unified search engine — the certified ripgrep-parity walk-and-emit
    /// control plane (`engine/serial.zig`), its index-backed read-elision +
    /// `--no-index`/`--rank` candidate sources, and the ranked view
    /// (`view/ranked.zig`). Backs the bare `gist <pattern>` shorthand,
    /// `gist rg`, and the rgsuite parity certificate.
    pub const search = @import("surface/exec/cold/engine/serial.zig");
    /// The `index` verb — build + persist the trigram index the engine reads.
    pub const indexer = @import("surface/face/gist/lifecycle/index.zig");
    /// The `codex` verbs — exact existence/count tier over the self-index shelf.
    pub const codex = @import("surface/face/gist/lifecycle/codex.zig");
    /// `gist serve` — the resident daemon that keeps a `session` warm behind a
    /// Unix socket (ADR-352 rung 2.5).
    pub const serve = @import("surface/face/gist/daemon/serve/serve.zig");
    /// `relate patterns` — one walk, N patterns, exact per-pattern attribution.
    pub const relate_attribute = @import("surface/face/relate/attribute.zig");
    /// `relate similar` — the neighbor verb: one probe (path, `path#Lnnn`, or
    /// text), one ranked answer, priced by the probe's own shape.
    pub const relate_probe = @import("surface/face/relate/probe.zig");
    pub const relate_quote = @import("surface/face/relate/quote.zig");
    /// `relate pack` — greedy submodular anti-redundant context packing.
    pub const relate_pack = @import("surface/face/relate/pack.zig");
    /// `relate echoes` — the repetition verb: unit × channel × shape, so pairs,
    /// fork families, function-level clones, and the distinct complement are one
    /// query instead of four verbs.
    pub const relate_repeat = @import("surface/face/relate/repeat.zig");
    /// `relate index`/`status` — the kinship-atlas lifecycle (relate's warm tier).
    pub const relate_lifecycle = @import("surface/face/relate/lifecycle.zig");
    /// The shared kinship plumbing: parallel fingerprinting + the file view.
    pub const relate_kinship = @import("surface/face/relate/kinship.zig");
    /// The unit view: file | function | match, warm or live, optionally narrowed
    /// by the exact engine first (`--matching`).
    pub const relate_units = @import("surface/face/relate/units.zig");
    /// The query option surface every relate kinship verb is configured through.
    pub const relate_options = @import("surface/face/relate/options.zig");
    /// The shared verb-table renderer: one `Face` declaration becomes the help,
    /// the `--schema` manifest, the dispatch, and the unknown-verb line.
    pub const manifest = @import("surface/cli/manifest.zig");
    /// relate's verb table — the single source those four renderings read.
    pub const relate_repertoire = @import("surface/face/relate/repertoire.zig");
    /// The composed face (ADR-367): the `irregex` binary's verb drivers + its
    /// verb table, orchestrating the `compose` kernels over a loaded corpus /
    /// codex shelf. `context` and `family` folded into `relate pack --matching`
    /// and `relate echoes --matching`; what remains is the pair that needs live
    /// bytes rather than a narrowing.
    pub const compose_provenance = @import("surface/face/irregex/provenance.zig");
    /// The composed `blast` verb: a live symbol blast radius for editing agents
    /// (seed → dependents/dependencies → twins/ripple → comments), computed from
    /// current bytes with no precomputed graph.
    pub const compose_blast = @import("surface/face/irregex/blast.zig");
    /// The composed face's verb table.
    pub const compose_repertoire = @import("surface/face/irregex/repertoire.zig");
    /// The CLI's warm fast path — dial the daemon for an eligible query, emit
    /// byte-identically to cold, else fall back (`attempt`).
    pub const client = @import("surface/face/gist/daemon/client/client.zig");
};

/// The curated Zig-native hosted API (ADR-352): a small vocabulary of owned
/// handles — `Engine`, `SearchQuery`, `Cursor` (pull `next`/`nextBatch`),
/// `CancelToken`, `RunOptions` — over the same error-returning warm engine the
/// resident daemon and the C-ABI shims ride. What a Zig embedder (and the C ABI
/// + bindings above it) programs to, distinct from the internal tiers above.
pub const api = @import("api.zig");

pub const version_string: [:0]const u8 = "0.3.0"; // x-release-please-version

/// The C-ABI compatibility integer. Started at 1 (introspection + the
/// allocation-free trigram primitive); the rung-3 warm session's match callback
/// (`irregex_match_fn`) gaining an `i32` abort return was a breaking signature
/// change that stepped it to 2 (ADR-352). Bump only for a breaking layout or
/// signature change; additive symbols preserve the version. This is the single
/// C-ABI axis — the semantic contract revision, result schema, corpus/index/atlas
/// formats, and engine semver version independently (see `contract/search_api.toml`).
pub fn abi() u32 {
    return 2;
}

export fn irregex_abi_version() u32 {
    return abi();
}

/// The engine semver (`version_string`), NUL-terminated, static-lifetime. Lets
/// a binding version-gate the shared library / binary it drives against its own
/// packaged version (the unified-search contract's `engine_version`, ADR-352).
export fn irregex_version() [*:0]const u8 {
    return version_string.ptr;
}

/// Extract the distinct, ascending trigrams of `text[0..len]` into
/// `out[0..len]` (caller sizes `out` ≥ `len`). Returns the count written.
/// This deterministic primitive is the C ABI's only data operation; search and
/// index lifecycle remain Zig-native/CLI surfaces.
export fn irregex_trigram_count(text: [*]const u8, len: usize, out: [*]u32) usize {
    if (len < 3) return 0;
    return ngram.extractSortedUnique(text[0..len], out[0..len]);
}

// ── in-process warm search session (ADR-352 rung 3) ──
// Thin C shims over `ffi/session.zig`; the `Status` enum lowers to its `i32`
// tag. `irregex_session` is opaque to C (`ffi.Session` by pointer). These are the
// first ABI symbols that open/query a corpus; their match callback carries an
// `i32` abort return (0 continue / non-zero stop).

/// Open a warm session over `roots[0..nroots]` (NUL-terminated paths); writes
/// the handle to `*out`. Returns 0 on success, negative on failure.
export fn irregex_open(roots: [*]const [*:0]const u8, nroots: usize, out: **ffi.session.Session) i32 {
    return @intFromEnum(ffi.session.open(roots, nroots, out));
}

/// Stream each matching line of `pattern[0..pattern_len]` to `on_match`.
/// Returns 1 if any line matched, 0 if none, negative on error (−1 = the caller
/// should answer cold). `on_match` returns 0 to continue or non-zero to stop the
/// stream early (a bounded / first-match query still returns 1). `flags`: bit0
/// `-F` fixed, bit1 `-i` ignore-case.
export fn irregex_search(s: *ffi.session.Session, pattern: [*]const u8, pattern_len: usize, options: ?*const ffi.contract.SearchOptions, on_match: ffi.contract.MatchFn, ctx: ?*anyopaque) i32 {
    return @intFromEnum(ffi.session.search(s, pattern, pattern_len, options, on_match, ctx));
}

/// Free a session opened by `irregex_open`.
export fn irregex_close(s: *ffi.session.Session) void {
    ffi.session.close(s);
}

// ── the pull-cursor surface (ADR-352) ──
// Additive siblings of the callback triad: a host opens an `irregex_engine`,
// runs `irregex_search_cursor` to materialize an `irregex_cursor`, then walks it
// with `irregex_cursor_next`/`_next_batch` — inverting control for a caller that
// can't yield its stack to a callback. Cancellation is an `irregex_cancel` handle
// any thread may trip. All statuses are the same `Status` tags; nothing here can
// `die()` the host, and none of it bumps `abi()` (purely additive symbols).

/// Open a warm engine over `roots[0..nroots]`; writes the handle to `*out`.
export fn irregex_engine_open(roots: ?[*]const [*:0]const u8, nroots: usize, out: ?**api.Engine) i32 {
    return @intFromEnum(ffi.cursor.engineOpen(roots, nroots, out));
}

/// Free an engine opened by `irregex_engine_open`.
export fn irregex_engine_close(eng: *api.Engine) void {
    ffi.cursor.engineClose(eng);
}

/// Allocate a fresh (unset) cancellation token; writes it to `*out`.
export fn irregex_cancel_new(out: ?**api.CancelToken) i32 {
    return @intFromEnum(ffi.cursor.cancelNew(out));
}

/// Request cancellation of any in-flight search using this token (thread-safe).
export fn irregex_cancel_request(token: *api.CancelToken) void {
    ffi.cursor.cancelRequest(token);
}

/// Free a token from `irregex_cancel_new` (after searches using it complete).
export fn irregex_cancel_free(token: *api.CancelToken) void {
    ffi.cursor.cancelFree(token);
}

/// Run one search and materialize a pull cursor; writes it to `*out`. Returns 0
/// on success, 1 unused here, negative on failure (−1 = stale → answer cold).
export fn irregex_search_cursor(eng: *api.Engine, request: ?*const ffi.contract.SearchRequest, out: ?**ffi.cursor.Cursor) i32 {
    return @intFromEnum(ffi.cursor.searchCursor(eng, request, out));
}

/// Fill `*out` with the next record. Returns 1 (record written), 0 (end of
/// stream), or negative on error. The view borrows cursor/scratch memory.
export fn irregex_cursor_next(cursor: *ffi.cursor.Cursor, out: ?*ffi.contract.Match) i32 {
    return @intFromEnum(ffi.cursor.cursorNext(cursor, out));
}

/// Fill up to `cap` records into `out[0..cap]`; writes the count to `*written`.
/// Returns 1 (≥1 written), 0 (end), or negative on error.
export fn irregex_cursor_next_batch(cursor: *ffi.cursor.Cursor, out: ?[*]ffi.contract.Match, cap: usize, written: ?*usize) i32 {
    return @intFromEnum(ffi.cursor.cursorNextBatch(cursor, out, cap, written));
}

/// Whether any file matched (cold's exit-code boolean): 1 matched, 0 none.
export fn irregex_cursor_matched(cursor: *ffi.cursor.Cursor) i32 {
    return ffi.cursor.cursorMatched(cursor);
}

/// Free a cursor from `irregex_search_cursor`.
export fn irregex_cursor_close(cursor: *ffi.cursor.Cursor) void {
    ffi.cursor.cursorClose(cursor);
}

// ── the analytic plane (ADR-377) ──
// Past the exact engine: compression kinship, retrieval, the multi-pattern
// sweep, and the composed verbs, all reached through ONE dispatch returning one
// self-describing row type. Seventeen verbs, eight symbols — a verb is a `u32`
// op plus one of five params families, so the next verb adds no C surface.
// Purely additive, so `irregex_abi_version` stays 2; the plane's own
// compatibility axis is `irregex_schema_digest`.

/// Run analytic verb `op` with its declared params family and materialize a row
/// cursor into `*out`. Returns 0 on success, or negative — where −1 (stale)
/// means this tier declines and the caller should answer through the CLI
/// fallback, NOT that the query failed.
export fn irregex_analytic_run(eng: *api.Engine, op: u32, params: ?*const ffi.rows.Params, cancel: ?*api.CancelToken, out: ?**ffi.analytic.Rows) i32 {
    return @intFromEnum(ffi.analytic.run(eng, op, params, cancel, out));
}

/// Fill `*out` with the next row. Returns 1 (a row was written), 0 (end), or
/// negative. Rows borrow the cursor arena and stay valid until `_close`.
export fn irregex_rows_next(cursor: *ffi.analytic.Rows, out: ?*ffi.rows.Row) i32 {
    return @intFromEnum(ffi.analytic.next(cursor, out));
}

/// Fill up to `cap` rows into `out[0..cap]`; writes the count to `*written`.
/// The one crossing a batching binding amortizes N rows over.
export fn irregex_rows_next_batch(cursor: *ffi.analytic.Rows, out: ?[*]ffi.rows.Row, cap: usize, written: ?*usize) i32 {
    return @intFromEnum(ffi.analytic.nextBatch(cursor, out, cap, written));
}

/// Answer-level facts no row carries — which tier answered, the freshness fold,
/// and `foreign` (query fingerprints this corpus has never seen).
export fn irregex_rows_stats(cursor: *ffi.analytic.Rows, out: ?*ffi.rows.Stats) i32 {
    return @intFromEnum(ffi.analytic.stats(cursor, out));
}

/// Free a cursor from `irregex_analytic_run` (and everything its rows borrow).
export fn irregex_rows_close(cursor: *ffi.analytic.Rows) void {
    ffi.analytic.close(cursor);
}

/// A stable, static, NUL-terminated digest of the WHOLE row-schema table. A
/// binding compares it to the digest its decoder was generated from, so a stale
/// shared library is a loud startup failure, not a mis-decoded row.
export fn irregex_schema_digest() [*:0]const u8 {
    return ffi.rows.digest();
}

/// How many row schemas this build declares (ids are 1..count).
export fn irregex_schema_count() u32 {
    return ffi.rows.schemaCount();
}

/// Fill `*out` with schema `id`. The names, tags, and field arrays are static
/// and outlive every call.
export fn irregex_schema_get(id: u32, out: ?*ffi.rows.Schema) i32 {
    return @intFromEnum(ffi.rows.schemaGet(id, out));
}

/// A stable, static, NUL-terminated human message for a status code (for logs;
/// the typed code stays the contract).
export fn irregex_status_message(code: i32) [*:0]const u8 {
    return ffi.cursor.statusMessage(code);
}

/// Detail for the LAST failing call on THIS thread — which fault member, and
/// where. Additive: a new symbol changes no existing layout or signature, so
/// `irregex_abi_version` stays 2. Reading does not consume, and a declinature
/// never lands here (ADR-373).
export fn irregex_last_fault(out: ?*ffi.contract.FaultDetail) i32 {
    return @intFromEnum(ffi.contract.lastFault(out));
}

test {
    // `refAllDecls` pulls each `pub` tier re-export above into `zig build test`,
    // but each tier's tests live in a sibling `*_test.zig` (shape cap), which is
    // NOT re-exported — so every test file is wired in explicitly here.
    std.testing.refAllDecls(@This());
    _ = @import("assay/assay.zig"); // instrumentation floor: Span/Duration/Anchor, Tally(Schema), the diagnostic channel
    _ = @import("api_test.zig"); // hosted API facade: Engine/Cursor/CancelToken over a live warm tree
    // engine tiers
    _ = @import("corpus/index/trigrams/ngram_test.zig"); // n-gram extraction strategy primitives
    _ = @import("corpus/index/postings/varint_test.zig"); // LEB128 varint codec (compact posting bodies)
    _ = @import("corpus/index/trigrams/trigram_test.zig"); // T0 candidate index: query + serialize + build
    _ = @import("corpus/index/trigrams/trigram_load_test.zig"); // T0 loader adversarial suite: malformed blobs fail closed
    _ = @import("corpus/index/trigrams/persist_test.zig"); // T0 persisted corpus/index/path-table integrity (doc-id OOB guard)
    _ = @import("corpus/index/trigrams/codicil_test.zig"); // incremental codicil: round-trip, fail-closed decode, layered-query parity
    _ = @import("corpus/index/trigrams/trigram_fuzz.zig"); // T0 loader long fuzz (seeds + mutations; GIST_FUZZ_ITERS)
    _ = @import("corpus/index/frame/frame_test.zig"); // shared artifact-load protocol: tree binding + future-anchor refusal, no leak on reject
    _ = @import("corpus/index/phantom/treemap_test.zig"); // phantom tree.map layout: round-trip, root resolve, torn blobs fail closed
    _ = @import("corpus/index/content/shard.zig"); // content shard: body round-trip, freshness gate, torn blobs fail closed
    _ = @import("kernel/rank/rank_test.zig"); // T4 RRF fusion ranking
    _ = @import("kernel/rank/signals_test.zig"); // cross-language def-detection + generated-file signals
    _ = @import("kernel/rank/mirror.zig"); // cached-source mirror classification + exact canonical duplicate
    _ = @import("kernel/match/scan/simd_test.zig"); // SIMD `contains` differential fuzz vs std
    _ = @import("kernel/match/scan/classrun_test.zig"); // SIMD class-run kernel vs scalar oracle (both backends)
    _ = @import("corpus/index/trigrams/fresh_test.zig"); // T3 freshness `widen` set-algebra
    _ = @import("kernel/match/query/query_test.zig"); // shared compiled-query: compile/prefilter/match vs oracle
    _ = @import("kernel/primitives/bits_test.zig"); // shared two's-complement bit identities vs bool-slice oracle
    _ = @import("kernel/primitives/crest_test.zig"); // crest sieve, document half: ρ(d) scan + dominance decision + sidecar schema
    _ = @import("kernel/primitives/parallel.zig"); // shared byte-balanced sharding + partial-spawn-safe fan-out
    _ = @import("kernel/primitives/ward_test.zig"); // reader/writer lease guards + double-checked readReconciled dance
    _ = @import("corpus/index/crest/sidecar_test.zig"); // crest sidecar codec: round-trip + fail-closed adversarial
    _ = @import("kernel/kinship/metric/sketch_test.zig"); // relate half: kinship metric semantics + clustering gate
    _ = @import("kernel/kinship/metric/sketch_oracle_test.zig"); // relate half: external oracles — exact bottom-k, set-Jaccard, deflate NCD rank
    _ = @import("kernel/kinship/metric/silhouette_test.zig"); // structure channel: normalization invariance + winnow guarantee
    _ = @import("kernel/kinship/recall/lexicon.zig"); // mutual: corpus-priced fingerprint recall index
    _ = @import("kernel/kinship/recall/zipper.zig"); // mutual: suffix-automaton Ziv–Merhav cross-parse (exact ΔAb)
    _ = @import("kernel/kinship/recall/lexicon_test.zig"); // mutual: retrieval proof (short-query recall, ΔAb sidedness, zero-bit boilerplate)
    _ = @import("kernel/kinship/cluster/pairs.zig"); // relate pair machinery: seed-bucket candidates + exact verify
    _ = @import("kernel/kinship/cluster/families.zig"); // relate fork families: union-find over the verified dup graph
    _ = @import("kernel/kinship/metric/channel.zig"); // the one channel vocabulary + its measured grade bands
    _ = @import("kernel/kinship/cluster/echoes.zig"); // repetition kernel: unit × channel × shape (pairs/families/distinct)
    _ = @import("kernel/kinship/recall/coverage.zig"); // relate pack core: greedy submodular max-coverage
    _ = @import("surface/exec/session/warm/recall.zig"); // relate resident retrieval session: warm index + cached anchor overlay + watcher conformance
    _ = @import("kernel/compose/candidates.zig"); // compose: exact PatternSet → typed CandidateSet (≡ N single-pattern runs)
    _ = @import("kernel/compose/candidates_test.zig"); // compose: CandidateSet ≡ substring set-algebra (any/all masks, 64-cap, error paths)
    _ = @import("kernel/compose/context.zig"); // compose: coverage packing inside the exact filter
    _ = @import("kernel/compose/family.zig"); // compose: fork families / echoes inside the exact filter
    _ = @import("kernel/compose/provenance.zig"); // compose: quote attribution re-verified against current bytes
    _ = @import("kernel/compose/regions.zig"); // compose: exact-hit functions / match windows as comparison units
    _ = @import("kernel/compose/lexspan.zig"); // compose: shared comment/code/string span lexer (regions + comment-scope + blast)
    _ = @import("kernel/compose/blast.zig"); // compose: live symbol blast radius (seed → tiers → comments)
    _ = @import("corpus/index/atlas/atlas.zig"); // relate warm tier: persisted kinship atlas (save/parse/fold)
    _ = @import("corpus/index/atlas/atlas_test.zig"); // atlas round-trip, fail-closed parse, freshness-fold semantics
    _ = @import("corpus/index/frag/frag.zig"); // concept warm tier: persisted fragment silhouettes (save/parse/fold)
    _ = @import("corpus/index/frag/frag_test.zig"); // frag round-trip, fail-closed parse, freshness-fold + deletion gate
    _ = @import("corpus/index/codex/codex_test.zig"); // codex: SA-IS/RRR/wavelet/index differential vs naive oracles
    _ = @import("kernel/batch/patterns_test.zig"); // match half: set ≡ N single-pattern oracles (gate off/on)
    _ = @import("kernel/batch/loom_test.zig"); // weave: closed op set — total, deterministic, hand-tallied
    _ = @import("surface/exec/session/answer/request_test.zig"); // resident request eligibility classifier
    _ = @import("surface/exec/session/warm/corpus.zig"); // faithful corpus ingest: BOM/UTF-16 decode, whole-body NUL, no cap
    _ = @import("surface/exec/session/facet/render.zig"); // warm lines renderer: cold-Emitter byte parity
    _ = @import("surface/exec/session/warm/resident_test.zig"); // resident session: parity vs cold, overlay, RYW, deletion
    _ = @import("surface/exec/session/conduit/protocol/protocol_test.zig"); // UDS frame codec round-trip + adversarial
    _ = @import("surface/exec/session/conduit/shm.zig"); // portable anonymous shm buffer: fd round-trip, zero-len unsupported
    _ = @import("surface/exec/session/watch/watch_test.zig"); // freshness watcher: dirty/clean seqlock barrier
    _ = @import("surface/exec/session/watch/kqueue_test.zig"); // macOS kqueue barrier: real mutations → scoped reconcile (ADR-372)
    _ = @import("surface/exec/session/freshness/freshness_test.zig"); // barrier hardening: differential vs on-disk oracle, concurrency, overflow/bound
    _ = @import("surface/exec/session/freshness/dirty.zig"); // exact dirty-path log: dedupe, bound→doubt, exact promise
    _ = @import("surface/exec/session/freshness/delta.zig"); // O(changed) resolver: path classes, fold aliasing helpers
    _ = @import("surface/exec/session/freshness/annals.zig"); // delivery ledger: which changed (since) + whether any did (epoch)
    _ = @import("surface/exec/session/answer/keep.zig"); // answer keep: epoch match, exit-code fidelity, LRU + oversize refusal
    _ = @import("surface/exec/session/warm/scoped_test.zig"); // scoped reconcile adversarial: vs full-walk ground truth
    _ = @import("corpus/tree/haystack_test.zig"); // shared walk: isSkipDir + joinPath hot-path decisions
    _ = @import("corpus/tree/bulkstat_test.zig"); // getattrlistbulk ≡ stat-walk differential
    _ = @import("corpus/tree/loadpar.zig"); // fused parallel walk+read: byte-identical membership vs serial oracle
    _ = @import("kernel/match/regex/syntax/syntax_test.zig"); // T2 syntax: ByteSet + recursive-descent parser
    _ = @import("kernel/match/regex/analysis/analysis_test.zig"); // T2 analysis: required-literal + cover + anchored
    _ = @import("kernel/match/regex/analysis/swell_test.zig"); // crest sieve, query half: forced-crest ĝ vs hand-computed + Sieve Theorem vs the matcher
    _ = @import("kernel/match/regex/linear/program/core_test.zig"); // T2 engine: parser + Pike VM + prefilters
    _ = @import("kernel/match/regex/linear/ladder/matcher.zig"); // engine-neutral match seam: linear-arm forwarding
    _ = @import("kernel/match/regex/pcre2/backend.zig"); // PCRE2 `-P` backend: engine + literal co-located tests
    _ = @import("kernel/match/regex/pcre2/backend_test.zig"); // PCRE2 adversarial: lookaround/backref/limit/JIT parity
    _ = @import("kernel/match/regex/oracle/adversarial_test.zig"); // independent-oracle differential + prefilter brute force
    _ = @import("kernel/match/regex/linear/dfa/dfa_test.zig"); // byte-class DFA unit + differential fuzz
    _ = @import("kernel/match/regex/linear/dfa/powerset_test.zig"); // determinizer structural invariants
    _ = @import("kernel/match/regex/unicode/utf8seq.zig"); // scalar-range → UTF-8 byte-range decomposition
    _ = @import("kernel/match/regex/unicode/decode.zig"); // UTF-8 codepoint decode (fwd/last) for \b
    _ = @import("kernel/match/regex/unicode/tables.zig"); // Unicode data API: Perl/\p classes, fold orbits
    // command surfaces (tests + driver bodies, so `zig build test` type-checks all)
    _ = @import("corpus/scope/glob_test.zig"); // glob matcher + type/glob/root path scope
    _ = @import("surface/face/gist/status/status.zig"); // read-only index introspection
    _ = @import("surface/face/gist/schema/schema.zig"); // `--schema` manifest
    _ = @import("surface/face/relate/repertoire.zig"); // relate's verb table (schema validity + both registers)
    _ = @import("surface/face/relate/kinship.zig"); // relate shared plumbing: view resolver + verified-pair machinery
    _ = @import("surface/face/relate/units.zig"); // the unit view: file|function|match × warm/live × exact narrowing
    _ = @import("surface/face/relate/options.zig"); // the one query option surface (flag loop + unit-scaled floors)
    _ = @import("surface/face/relate/probe.zig"); // the neighbor verb: probe classification, self-exclusion, both polarities
    _ = @import("surface/face/relate/repeat.zig"); // the repetition verb: unit × channel × shape rendering
    _ = @import("surface/face/relate/attribute.zig"); // `relate patterns` driver body (one walk, N patterns)
    _ = @import("surface/face/relate/pack.zig"); // `relate pack` driver body (greedy coverage semantics tested here)
    _ = @import("surface/face/relate/lifecycle.zig"); // `relate index`/`status` driver bodies
    _ = @import("surface/face/irregex/provenance.zig"); // composed `provenance` driver body
    _ = @import("surface/face/irregex/blast.zig"); // composed `blast` driver body (budget accountant + render)
    _ = @import("surface/face/irregex/repertoire.zig"); // the composed face's verb table (scope-required invariant)
    _ = @import("surface/face/irregex/shared.zig"); // composed CLI shared plumbing
    _ = @import("surface/exec/cold/engine/serial.zig"); // the unified engine (rgsuite parity drop-in)
    _ = @import("surface/exec/cold/quarry/elide.zig"); // the indexed→live read-elision oracle both cold engines admit
    _ = @import("surface/exec/cold/engine/swarm/swarm.zig"); // the fused work-stealing walk: eligibility + run lifecycle
    _ = @import("surface/exec/cold/engine/swarm/crew.zig"); // worker state, pool topology, the ordered --sort replay
    _ = @import("surface/exec/cold/read/ingest.zig"); // -z/--pre/-E content transforms (decompress/preprocess/transcode)
    _ = @import("surface/exec/cold/read/encoding.zig"); // -E WHATWG legacy-code-page decoders (single-byte + CJK multi-byte)
    _ = @import("surface/exec/cold/emit/multiline.zig"); // -U whole-buffer match model (Emitter.buffer + --json)
    _ = @import("surface/exec/cold/emit/output/multibuf_test.zig"); // -U whole-buffer emit: the ripgrep-captured parity table
    _ = @import("surface/exec/cold/emit/hints.zig"); // no-match stderr guidance: shape analysis + exact render bytes
    _ = @import("surface/cli/manifest.zig"); // the verb-table renderer (help, schema, dispatch, verb list)
    _ = @import("surface/cli/guide.zig"); // the stderr guidance grammar both faces speak
    _ = @import("surface/cli/grade.zig"); // kinship channels, calibrated grades, the weak-result verdict
    _ = Outcome; // the rg exit-code contract, incl. the -q short-circuit precedence
    _ = @import("surface/cli/outcome.zig");
    _ = @import("fault.zig"); // the fault/declinature vocabulary + the detail slot
    _ = @import("surface/ffi/rows.zig"); // analytic plane: C layout parity, schema table integrity, the row builder
    _ = @import("surface/ffi/analytic.zig"); // analytic plane: dispatch fails closed, the cursor walks/batches/reports
    _ = @import("surface/exec/cold/emit/jsonstr.zig"); // the one JSON string escaper every JSON/NDJSON face shares
    _ = @import("surface/exec/cold/view/ranked.zig"); // `--rank` definition-first ranked view
    _ = @import("surface/face/gist/lifecycle/index.zig"); // the `index` verb: build + persist
    _ = @import("surface/face/gist/daemon/serve/serve.zig"); // the resident daemon driver body
    _ = @import("surface/face/gist/daemon/client/client.zig"); // the warm CLI fast-path client body
    _ = @import("surface/face/gist/daemon/client/spawn.zig"); // best-effort detached daemon auto-spawn
    _ = @import("surface/face/gist/daemon/client/client_test.zig"); // wedged-daemon → cold deadline (no hang)
    _ = @import("surface/face/gist/daemon/serve/serve_test.zig"); // end-to-end daemon lifecycle + client round-trip
}
