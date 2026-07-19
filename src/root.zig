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
//! `irregex_close`, implemented in `runtime/ffi/session.zig`): a non-Zig host holds a
//! corpus warm in its own process and streams match records over a callback,
//! with no subprocess, socket, `stdout`, or `exit`. Every entry returns a
//! status code instead of `die()`ing, so a bad query can never terminate an
//! embedding host — the property ADR-352 gated the search ABI on. It rides the
//! error-returning shared core (`engine/query.zig`) + resident engine, so an
//! in-process answer is byte-identical to the cold `gist --json` stream. Index
//! BUILD lifecycle stays a Zig/CLI surface (a session searches the live tree).
//!
//! Package shape: two engines over a shared floor, grouped by concern and
//! re-exported here:
//!
//!   math/     — SHARED identity floor: two's-complement bit sets both engines ride
//!   corpus/   — SHARED source substrate: loading + Haystack walk (tree/) and
//!               path selection (-g glob, -t type table) in scope/
//!   index/    — the candidate + self indexes: trigram candidates + T3 freshness
//!               (trigrams/), compact posting codecs (postings/), and the compressed
//!               self-index — SA-IS → BWT → RRR wavelet tree (codex/, entropy-space count/find/restore)
//!   search/   — the two engines' search kernels: exact match (match/ — linear RE2-style
//!               NFA + byte-class DFA + prefilter, SIMD scan, the transport-neutral
//!               compiled query both cold CLI and warm session execute through),
//!               RRF ranking (rank/), compression kinship (similarity/ — sketch · lexicon
//!               · zipper), and the batched set ops (batch/ — patterns · loom)
//!   runtime/  — execution hosts: cold rg-compatible control plane, resident
//!               session (ADR-352 rung 2.5), and in-process C ABI (rung 3)
//!   cli/      — thin product faces: gist and relate

const std = @import("std");

// ── candidate index ──
pub const ngram = @import("index/trigrams/ngram.zig");
pub const trigram = @import("index/trigrams/trigram.zig");
pub const persist = @import("index/trigrams/persist.zig");

// ── the crest sieve (math floor + persisted sidecar) ──
// The forced-class-run necessary condition that prunes the trigram index's one
// structural hole — literal-free class-repetition patterns ([0-9a-f]{8}) that
// extract no required substring. Kernel is pure math; the sidecar rides the
// same generation-atomic publish as the trigram pair. Proof: research/crest/.
pub const crest = @import("math/crest.zig");
pub const crest_sidecar = @import("index/crest/sidecar.zig");

// ── regex engine ──
// Submodules are imported by their consumers directly; only the core + DFA
// surfaces are re-exported at the root for the C-ABI / library consumers.
pub const regex = @import("search/match/regex/linear/core.zig");
pub const regex_dfa = @import("search/match/regex/linear/dfa.zig");

// ── ranking ──
pub const rank = @import("search/rank/rank.zig");
pub const signals = @import("search/rank/signals.zig");

// ── byte-level match execution ──
pub const simd = @import("search/match/scan/simd.zig");
pub const verify = @import("search/match/scan/verify.zig");

// ── corpus + freshness ──
pub const corpus = @import("corpus/tree/corpus.zig");
pub const haystack = @import("corpus/tree/haystack.zig");
pub const bulkstat = @import("corpus/tree/bulkstat.zig");
pub const fresh = @import("index/trigrams/fresh.zig");
pub const atlas = @import("index/atlas/atlas.zig");

// ── irregex: the irregular-expression primitives (match ∪ relate ∪ weave) ──
// The set-shaped tier over the engine: PatternSet compiles MANY intents with
// exact per-pattern attribution (the match half), Sketch measures compression
// kinship between byte bodies (the relate half — LZ dictionaries, no parsing),
// loom executes a closed filter/group/sort/limit plan over the attributed
// stream engine-side, and bits is the shared two's-complement identity floor
// (set-bit walks, word-packed bit sets) the other tiers ride instead of
// hand-rolling. Primitives only — faces (CLI verbs, bindings) consume.
pub const irregex = struct {
    pub const bits = @import("math/bits.zig");
    pub const patterns = @import("search/batch/patterns.zig");
    pub const sketch = @import("search/similarity/sketch.zig");
    pub const loom = @import("search/batch/loom.zig");
};

// ── codex: the compressed self-index (the book that IS its own index) ──
// FM-index over SA-IS + Huffman-shaped wavelet tree + RRR bitvectors: holds a
// corpus at entropy-bound size while answering count(P) in O(|P|) — flat in
// corpus size — plus locate (sampled) and byte-exact restore, all after the
// text, suffix array, and BWT are freed. The Shannon rung under both engines:
// gist gets an exact zero-false-positive tier, mutual a corpus-global
// matching-statistics substrate. See src/index/codex/README.md for the math.
pub const codex = struct {
    pub const sais = @import("index/codex/sais.zig");
    pub const rrr = @import("index/codex/rrr.zig");
    pub const wavelet = @import("index/codex/wavelet.zig");
    pub const index = @import("index/codex/codex.zig");
    pub const cento = @import("index/codex/cento.zig");
    pub const shelf = @import("index/codex/shelf.zig");
};

// ── relate: the compression-search engine ──
// The asymmetric successor to the symmetric sketch for SEARCH, hand-rolled:
// the lexicon prices winnowed fingerprints at their corpus information
// content (−log2(df/N) bits) and nominates candidates by the bits a doc
// already paid toward describing the query; the zipper decides exactly — a
// suffix-automaton Ziv–Merhav cross-parse charging real code lengths (the
// paper's ΔAb with no compressor run). See src/search/similarity/.
pub const relate = struct {
    pub const lexicon = @import("search/similarity/lexicon.zig");
    pub const zipper = @import("search/similarity/zipper.zig");
    pub const verbs = @import("cli/relate/verbs.zig");
};

// ── the transport-neutral compiled query (the shared search core) ──
// One deep module owns "a search intent, compiled": the fail-closed, thread-safe
// compile → sound-trigram-prefilter → per-doc match/count kernels that BOTH the
// cold CLI (`runtime/cold`) and the warm resident session (`runtime/session`)
// execute through, so the two engines cannot drift on what matches.
pub const engine = struct {
    pub const query = @import("search/match/query.zig");
};

// ── resident search session (ADR-352 rung 2.5): the warm in-memory engine +
// its Unix-socket transport, sharing the kernels above but returning errors
// instead of `die()`ing so a bad request can't take down the daemon. ──
pub const session = struct {
    pub const resident = @import("runtime/session/resident.zig");
    pub const corpus = @import("runtime/session/corpus.zig");
    pub const render = @import("runtime/session/render.zig");
    pub const request = @import("runtime/session/request.zig");
    pub const protocol = @import("runtime/session/protocol.zig");
    pub const watch = @import("runtime/session/watch.zig");
};

// ── in-process C-ABI search session (ADR-352 rung 3) ──
// The warm engine above, exposed to non-Zig hosts as an `open`/`search`/`close`
// callback-streaming C ABI — no subprocess, socket, stdout, or exit. Backs the
// `cffi` Python transport; the `export fn`s below forward into it.
pub const ffi = @import("runtime/ffi/session.zig");

/// CLI surfaces built on the engine above. Not part of the C ABI — the `gist`
/// executable (`cli/gist/main.zig`) and the bench harness dispatch through
/// these; grouped here so the whole command tree resolves through the module.
pub const commands = struct {
    pub const scope = struct {
        pub const glob = @import("corpus/scope/glob.zig");
        pub const types = @import("corpus/scope/types.zig");
    };
    /// Read-only index introspection (the `status` verb).
    pub const status = @import("cli/gist/status/status.zig");
    /// `gist --schema` JSON capability manifest.
    pub const schema = @import("cli/gist/schema/schema.zig");
    /// The unified search engine — the certified ripgrep-parity walk-and-emit
    /// control plane (`engine/serial.zig`), its index-backed read-elision +
    /// `--no-index`/`--rank` candidate sources, and the ranked view
    /// (`engine/ranked.zig`). Backs the bare `gist <pattern>` shorthand,
    /// `gist rg`, and the rgsuite parity certificate.
    pub const search = @import("runtime/cold/engine/serial.zig");
    /// The `index` verb — build + persist the trigram index the engine reads.
    pub const indexer = @import("cli/gist/lifecycle/index.zig");
    /// The `codex` verbs — exact existence/count tier over the self-index shelf.
    pub const codex = @import("cli/gist/lifecycle/codex.zig");
    /// `gist serve` — the resident daemon that keeps a `session` warm behind a
    /// Unix socket (ADR-352 rung 2.5).
    pub const serve = @import("cli/gist/daemon/serve/serve.zig");
    /// The relate verbs — `similar`/`dups`/`patterns` over `src/search/`.
    pub const irregex = @import("cli/relate/verbs.zig");
    /// `relate search` — two-stage compression retrieval (lexicon → zipper).
    pub const relate_search = @import("cli/relate/search.zig");
    pub const relate_quote = @import("cli/relate/quote.zig");
    /// `relate pack` — greedy submodular anti-redundant context packing.
    pub const relate_pack = @import("cli/relate/pack.zig");
    /// `relate clusters` — fork families over the verified dup graph.
    pub const relate_family = @import("cli/relate/family.zig");
    /// `relate index`/`status` — the kinship-atlas lifecycle (relate's warm tier).
    pub const relate_lifecycle = @import("cli/relate/lifecycle.zig");
    /// The shared kinship plumbing: view resolver (atlas ∪ live) + pair machinery.
    pub const relate_kinship = @import("cli/relate/kinship.zig");
    /// `relate --schema` JSON capability manifest (the relate binary's).
    pub const relate_schema = @import("cli/relate/schema.zig");
    /// The CLI's warm fast path — dial the daemon for an eligible query, emit
    /// byte-identically to cold, else fall back (`attempt`).
    pub const client = @import("cli/gist/daemon/client/client.zig");
};

pub const version_string: [:0]const u8 = "0.1.0"; // x-release-please-version

/// Bump on any BREAK to the C ABI. Additive symbols (e.g. `irregex_version`) do
/// not bump it — a consumer compiled against an older header keeps working.
/// v2: the rung-3 match callback (`irregex_match_fn`) gained an `i32` abort return
/// (0 continue / non-zero stop), a signature change, so the ABI stepped 1 → 2.
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
// `i32` abort return (0 continue / non-zero stop), the signature refinement
// that took `irregex_abi_version` to 2.

/// Open a warm session over `roots[0..nroots]` (NUL-terminated paths); writes
/// the handle to `*out`. Returns 0 on success, negative on failure.
export fn irregex_open(roots: [*]const [*:0]const u8, nroots: usize, out: **ffi.Session) i32 {
    return @intFromEnum(ffi.open(roots, nroots, out));
}

/// Stream each matching line of `pattern[0..pattern_len]` to `on_match`.
/// Returns 1 if any line matched, 0 if none, negative on error (−1 = the caller
/// should answer cold). `on_match` returns 0 to continue or non-zero to stop the
/// stream early (a bounded / first-match query still returns 1). `flags`: bit0
/// `-F` fixed, bit1 `-i` ignore-case.
export fn irregex_search(s: *ffi.Session, pattern: [*]const u8, pattern_len: usize, flags: u32, on_match: ffi.MatchFn, ctx: ?*anyopaque) i32 {
    return @intFromEnum(ffi.search(s, pattern, pattern_len, flags, on_match, ctx));
}

/// Free a session opened by `irregex_open`.
export fn irregex_close(s: *ffi.Session) void {
    ffi.close(s);
}

test {
    // `refAllDecls` pulls each `pub` tier re-export above into `zig build test`,
    // but each tier's tests live in a sibling `*_test.zig` (shape cap), which is
    // NOT re-exported — so every test file is wired in explicitly here.
    std.testing.refAllDecls(@This());
    // engine tiers
    _ = @import("index/trigrams/ngram_test.zig"); // n-gram extraction strategy primitives
    _ = @import("index/postings/varint_test.zig"); // LEB128 varint codec (compact posting bodies)
    _ = @import("index/trigrams/trigram_test.zig"); // T0 candidate index: query + serialize + build
    _ = @import("index/trigrams/trigram_load_test.zig"); // T0 loader adversarial suite: malformed blobs fail closed
    _ = @import("index/trigrams/persist_test.zig"); // T0 persisted index/path-table integrity (doc-id OOB guard)
    _ = @import("index/trigrams/trigram_fuzz.zig"); // T0 loader long fuzz (seeds + mutations; GIST_FUZZ_ITERS)
    _ = @import("search/rank/rank_test.zig"); // T4 RRF fusion ranking
    _ = @import("search/rank/signals_test.zig"); // cross-language def-detection + generated-file signals
    _ = @import("search/rank/mirror.zig"); // cached-source mirror classification + exact canonical duplicate
    _ = @import("search/match/scan/simd_test.zig"); // SIMD `contains` differential fuzz vs std
    _ = @import("index/trigrams/fresh_test.zig"); // T3 freshness `widen` set-algebra
    _ = @import("search/match/query_test.zig"); // shared compiled-query: compile/prefilter/match vs oracle
    _ = @import("math/bits_test.zig"); // shared two's-complement bit identities vs bool-slice oracle
    _ = @import("math/crest_test.zig"); // crest sieve: forced-run calculus vs hand-computed ĝ + sieve decision
    _ = @import("index/crest/sidecar_test.zig"); // crest sidecar codec: round-trip + fail-closed adversarial
    _ = @import("search/similarity/sketch_test.zig"); // relate half: kinship metric semantics + clustering gate
    _ = @import("search/similarity/lexicon.zig"); // mutual: corpus-priced fingerprint recall index
    _ = @import("search/similarity/zipper.zig"); // mutual: suffix-automaton Ziv–Merhav cross-parse (exact ΔAb)
    _ = @import("search/similarity/lexicon_test.zig"); // mutual: retrieval proof (short-query recall, ΔAb sidedness, zero-bit boilerplate)
    _ = @import("index/atlas/atlas.zig"); // relate warm tier: persisted kinship atlas (save/parse/fold)
    _ = @import("index/atlas/atlas_test.zig"); // atlas round-trip, fail-closed parse, freshness-fold semantics
    _ = @import("index/codex/codex_test.zig"); // codex: SA-IS/RRR/wavelet/index differential vs naive oracles
    _ = @import("search/batch/patterns_test.zig"); // match half: set ≡ N single-pattern oracles (gate off/on)
    _ = @import("search/batch/loom_test.zig"); // weave: closed op set — total, deterministic, hand-tallied
    _ = @import("runtime/session/request_test.zig"); // resident request eligibility classifier
    _ = @import("runtime/session/corpus.zig"); // faithful corpus ingest: BOM/UTF-16 decode, whole-body NUL, no cap
    _ = @import("runtime/session/render.zig"); // warm lines renderer: cold-Emitter byte parity
    _ = @import("runtime/session/resident_test.zig"); // resident session: parity vs cold, overlay, RYW, deletion
    _ = @import("runtime/session/protocol_test.zig"); // UDS frame codec round-trip + adversarial
    _ = @import("runtime/session/watch_test.zig"); // freshness watcher: dirty/clean seqlock barrier
    _ = @import("runtime/session/freshness_test.zig"); // barrier hardening: differential vs on-disk oracle, concurrency, overflow/bound
    _ = @import("runtime/session/dirty.zig"); // exact dirty-path log: dedupe, bound→doubt, exact promise
    _ = @import("runtime/session/delta.zig"); // O(changed) resolver: path classes, fold aliasing helpers
    _ = @import("runtime/session/scoped_test.zig"); // scoped reconcile adversarial: vs full-walk ground truth
    _ = @import("corpus/tree/haystack_test.zig"); // shared walk: isSkipDir + joinPath hot-path decisions
    _ = @import("corpus/tree/bulkstat_test.zig"); // getattrlistbulk ≡ stat-walk differential
    _ = @import("search/match/regex/syntax/syntax_test.zig"); // T2 syntax: ByteSet + recursive-descent parser
    _ = @import("search/match/regex/analysis/analysis_test.zig"); // T2 analysis: required-literal + cover + anchored
    _ = @import("search/match/regex/linear/core_test.zig"); // T2 engine: parser + Pike VM + prefilters
    _ = @import("search/match/regex/linear/matcher.zig"); // engine-neutral match seam: linear-arm forwarding
    _ = @import("search/match/regex/pcre2/backend.zig"); // PCRE2 `-P` backend: engine + literal co-located tests
    _ = @import("search/match/regex/pcre2/backend_test.zig"); // PCRE2 adversarial: lookaround/backref/limit/JIT parity
    _ = @import("search/match/regex/oracle/adversarial_test.zig"); // independent-oracle differential + prefilter brute force
    _ = @import("search/match/regex/linear/dfa_test.zig"); // byte-class DFA unit + differential fuzz
    _ = @import("search/match/regex/linear/powerset_test.zig"); // determinizer structural invariants
    _ = @import("search/match/regex/unicode/utf8seq.zig"); // scalar-range → UTF-8 byte-range decomposition
    _ = @import("search/match/regex/unicode/decode.zig"); // UTF-8 codepoint decode (fwd/last) for \b
    _ = @import("search/match/regex/unicode/tables.zig"); // Unicode data API: Perl/\p classes, fold orbits
    // command surfaces (tests + driver bodies, so `zig build test` type-checks all)
    _ = @import("corpus/scope/glob_test.zig"); // glob matcher + type/glob/root path scope
    _ = @import("cli/gist/status/status.zig"); // read-only index introspection
    _ = @import("cli/gist/schema/schema.zig"); // `--schema` manifest
    _ = @import("cli/relate/schema.zig"); // relate's `--schema` manifest
    _ = @import("cli/relate/kinship.zig"); // relate shared plumbing: view resolver + verified-pair machinery
    _ = @import("cli/relate/pack.zig"); // `relate pack` driver body (greedy coverage semantics tested here)
    _ = @import("cli/relate/family.zig"); // `relate clusters` driver body (union-find fork families)
    _ = @import("cli/relate/lifecycle.zig"); // `relate index`/`status` driver bodies
    _ = @import("runtime/cold/engine/serial.zig"); // the unified engine (rgsuite parity drop-in)
    _ = @import("runtime/cold/engine/parallel.zig"); // the fused work-stealing parallel walk/read/emit pass
    _ = @import("runtime/cold/read/ingest.zig"); // -z/--pre/-E content transforms (decompress/preprocess/transcode)
    _ = @import("runtime/cold/read/encoding.zig"); // -E WHATWG legacy-code-page decoders (single-byte + CJK multi-byte)
    _ = @import("runtime/cold/emit/multiline.zig"); // -U whole-buffer match model (Emitter.buffer + --json)
    _ = @import("runtime/cold/emit/hints.zig"); // no-match stderr guidance: shape analysis + exact render bytes
    _ = @import("runtime/cold/engine/ranked.zig"); // `--rank` definition-first ranked view
    _ = @import("cli/gist/lifecycle/index.zig"); // the `index` verb: build + persist
    _ = @import("cli/gist/daemon/serve/serve.zig"); // the resident daemon driver body
    _ = @import("cli/gist/daemon/client/client.zig"); // the warm CLI fast-path client body
    _ = @import("cli/gist/daemon/client/spawn.zig"); // best-effort detached daemon auto-spawn
    _ = @import("cli/gist/daemon/client/client_test.zig"); // wedged-daemon → cold deadline (no hang)
    _ = @import("cli/gist/daemon/serve/serve_test.zig"); // end-to-end daemon lifecycle + client round-trip
}
