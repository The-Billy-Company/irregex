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
//! `irregex_close`, implemented in `ffi/session.zig`): a non-Zig host holds a
//! corpus warm in its own process and streams match records over a callback,
//! with no subprocess, socket, `stdout`, or `exit`. Every entry returns a
//! status code instead of `die()`ing, so a bad query can never terminate an
//! embedding host — the property ADR-352 gated the search ABI on. It rides the
//! error-returning shared core (`engine/query.zig`) + resident engine, so an
//! in-process answer is byte-identical to the cold `gist --json` stream. Index
//! BUILD lifecycle stays a Zig/CLI surface (a session searches the live tree).
//!
//! Package shape: two engines over a small shared floor, each re-exported here:
//!
//!   corpus/       — SHARED: in-memory corpus loading + the Haystack walk (both engines ride it)
//!   scope/        — SHARED: path scoping (-g glob matching, -t type table)
//!   primitives/   — SHARED math (ADR-363): patterns (match) · sketch (relate) · loom (weave)
//!   gist/kernel/  — the exact-search engine: index (trigram candidates + T3 freshness),
//!                   regex (linear-time RE2-style NFA + byte-class DFA + prefilter),
//!                   rank (RRF + byte-level signals), scan (SIMD substring + parallel verify),
//!                   engine (the transport-neutral compiled query both cold CLI and warm session execute through)
//!   gist/session/ — the resident-session transport (ADR-352 rung 2.5): warm engine · UDS codec · classifier · watcher
//!   gist/faces/   — the gist product surfaces (cli · ripgrep · status · serve · client · ffi)
//!   hydra/        — the compression-search engine: engine/ verb drivers + cli/ binary shell

const std = @import("std");

// ── candidate index ──
pub const ngram = @import("gist/kernel/index/ngram.zig");
pub const trigram = @import("gist/kernel/index/trigram.zig");
pub const persist = @import("gist/kernel/index/persist.zig");

// ── regex engine ──
// Submodules are imported by their consumers directly; only the core + DFA
// surfaces are re-exported at the root for the C-ABI / library consumers.
pub const regex = @import("gist/kernel/regex/core.zig");
pub const regex_dfa = @import("gist/kernel/regex/dfa.zig");

// ── ranking ──
pub const rank = @import("gist/kernel/rank/rank.zig");
pub const signals = @import("gist/kernel/rank/signals.zig");

// ── byte-level match execution ──
pub const simd = @import("gist/kernel/scan/simd.zig");
pub const verify = @import("gist/kernel/scan/verify.zig");

// ── corpus + freshness ──
pub const corpus = @import("corpus/corpus.zig");
pub const haystack = @import("corpus/haystack.zig");
pub const bulkstat = @import("corpus/bulkstat.zig");
pub const fresh = @import("gist/kernel/index/fresh.zig");

// ── irregex: the irregular-expression primitives (match ∪ relate ∪ weave) ──
// The set-shaped tier over the engine: PatternSet compiles MANY intents with
// exact per-pattern attribution (the match half), Sketch measures compression
// kinship between byte bodies (the relate half — LZ dictionaries, no parsing),
// and loom executes a closed filter/group/sort/limit plan over the attributed
// stream engine-side. Primitives only — faces (CLI verbs, bindings) consume.
pub const irregex = struct {
    pub const patterns = @import("primitives/patterns.zig");
    pub const sketch = @import("primitives/sketch.zig");
    pub const loom = @import("primitives/loom.zig");
};

// ── hydra: the compression-search engine ──
// The asymmetric successor to the symmetric sketch for SEARCH: a persisted
// phrase lexicon prices every LZ78 phrase at its corpus information content
// (−log2(df/N) bits), ranks docs by the bits their dictionary already paid
// toward describing a query (bitsSaved), and refines with the native ΔAb
// conditional parse (crossCost). See src/hydra/engine/lexicon.zig.
pub const hydra = struct {
    pub const lexicon = @import("hydra/engine/lexicon.zig");
    pub const verbs = @import("hydra/engine/verbs.zig");
};

// ── the transport-neutral compiled query (the shared search core) ──
// One deep module owns "a search intent, compiled": the fail-closed, thread-safe
// compile → sound-trigram-prefilter → per-doc match/count kernels that BOTH the
// cold CLI (`commands/ripgrep`) and the warm resident session (`session`)
// execute through, so the two engines cannot drift on what matches.
pub const engine = struct {
    pub const query = @import("gist/kernel/engine/query.zig");
};

// ── resident search session (ADR-352 rung 2.5): the warm in-memory engine +
// its Unix-socket transport, sharing the kernels above but returning errors
// instead of `die()`ing so a bad request can't take down the daemon. ──
pub const session = struct {
    pub const resident = @import("gist/session/resident.zig");
    pub const mirror = @import("gist/session/mirror.zig");
    pub const render = @import("gist/session/render.zig");
    pub const request = @import("gist/session/request.zig");
    pub const protocol = @import("gist/session/protocol.zig");
    pub const watch = @import("gist/session/watch.zig");
};

// ── in-process C-ABI search session (ADR-352 rung 3) ──
// The warm engine above, exposed to non-Zig hosts as an `open`/`search`/`close`
// callback-streaming C ABI — no subprocess, socket, stdout, or exit. Backs the
// `cffi` Python transport; the `export fn`s below forward into it.
pub const ffi = @import("gist/faces/ffi/session.zig");

/// CLI surfaces built on the engine above. Not part of the C ABI — the `gist`
/// executable (`commands/cli/main.zig`) and the bench harness dispatch through
/// these; grouped here so the whole command tree resolves through the module.
pub const commands = struct {
    pub const scope = struct {
        pub const glob = @import("scope/glob.zig");
        pub const types = @import("scope/types.zig");
    };
    /// Read-only index introspection (the `status` verb).
    pub const status = @import("gist/faces/status/status.zig");
    /// `gist --schema` JSON capability manifest.
    pub const schema = @import("gist/faces/cli/schema.zig");
    /// The unified search engine — the certified ripgrep-parity walk-and-emit
    /// pipeline (`run`), its index-backed read-elision + `--no-index`/`--rank`
    /// candidate sources, and the ranked view (`rank`). Backs the bare
    /// `gist <pattern>` shorthand, `gist rg`, and the rgsuite parity certificate.
    pub const ripgrep = @import("gist/faces/ripgrep/run.zig");
    /// The `index` verb — build + persist the trigram index the engine reads.
    pub const indexer = @import("gist/faces/ripgrep/index.zig");
    /// `gist serve` — the resident daemon that keeps a `session` warm behind a
    /// Unix socket (ADR-352 rung 2.5).
    pub const serve = @import("gist/faces/serve/serve.zig");
    /// The hydra verbs — `similar`/`dups`/`patterns` over `src/primitives/`.
    pub const irregex = @import("hydra/engine/verbs.zig");
    /// `hydra --schema` JSON capability manifest (the hydra binary's).
    pub const hydra_schema = @import("hydra/cli/schema.zig");
    /// The CLI's warm fast path — dial the daemon for an eligible query, emit
    /// byte-identically to cold, else fall back (`attempt`).
    pub const client = @import("gist/faces/client/client.zig");
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
    _ = @import("gist/kernel/index/ngram_test.zig"); // n-gram extraction strategy primitives
    _ = @import("gist/kernel/index/varint_test.zig"); // LEB128 varint codec (compact posting bodies)
    _ = @import("gist/kernel/index/trigram_test.zig"); // T0 candidate index: query + serialize + build
    _ = @import("gist/kernel/index/trigram_load_test.zig"); // T0 loader adversarial suite: malformed blobs fail closed
    _ = @import("gist/kernel/index/persist_test.zig"); // T0 persisted index/path-table integrity (doc-id OOB guard)
    _ = @import("gist/kernel/index/trigram_fuzz.zig"); // T0 loader long fuzz (seeds + mutations; GIST_FUZZ_ITERS)
    _ = @import("gist/kernel/rank/rank_test.zig"); // T4 RRF fusion ranking
    _ = @import("gist/kernel/rank/signals_test.zig"); // cross-language def-detection + generated-file signals
    _ = @import("gist/kernel/rank/mirror.zig"); // cached-source mirror classification + exact canonical duplicate
    _ = @import("gist/kernel/scan/simd_test.zig"); // SIMD `contains` differential fuzz vs std
    _ = @import("gist/kernel/index/fresh_test.zig"); // T3 freshness `widen` set-algebra
    _ = @import("gist/kernel/engine/query_test.zig"); // shared compiled-query: compile/prefilter/match vs oracle
    _ = @import("primitives/sketch_test.zig"); // relate half: kinship metric semantics + clustering gate
    _ = @import("hydra/engine/lexicon.zig"); // hydra: the query-conditioned coding-gain ranker
    _ = @import("hydra/engine/lexicon_test.zig"); // hydra: retrieval proof (short-query recall, ΔAb sidedness, zero-bit boilerplate)
    _ = @import("primitives/patterns_test.zig"); // match half: set ≡ N single-pattern oracles (gate off/on)
    _ = @import("primitives/loom_test.zig"); // weave: closed op set — total, deterministic, hand-tallied
    _ = @import("gist/session/request_test.zig"); // resident request eligibility classifier
    _ = @import("gist/session/mirror.zig"); // faithful corpus ingest: BOM/UTF-16 decode, whole-body NUL, no cap
    _ = @import("gist/session/render.zig"); // warm lines renderer: cold-Emitter byte parity
    _ = @import("gist/session/resident_test.zig"); // resident session: parity vs cold, overlay, RYW, deletion
    _ = @import("gist/session/protocol_test.zig"); // UDS frame codec round-trip + adversarial
    _ = @import("gist/session/watch_test.zig"); // freshness watcher: dirty/clean seqlock barrier
    _ = @import("gist/session/freshness_test.zig"); // barrier hardening: differential vs on-disk oracle, concurrency, overflow/bound
    _ = @import("gist/session/dirty.zig"); // exact dirty-path log: dedupe, bound→doubt, exact promise
    _ = @import("gist/session/delta.zig"); // O(changed) resolver: path classes, fold aliasing helpers
    _ = @import("gist/session/scoped_test.zig"); // scoped reconcile adversarial: vs full-walk ground truth
    _ = @import("corpus/haystack_test.zig"); // shared walk: isSkipDir + joinPath hot-path decisions
    _ = @import("corpus/bulkstat_test.zig"); // getattrlistbulk ≡ stat-walk differential
    _ = @import("gist/kernel/regex/syntax_test.zig"); // T2 syntax: ByteSet + recursive-descent parser
    _ = @import("gist/kernel/regex/analysis_test.zig"); // T2 analysis: required-literal + cover + anchored
    _ = @import("gist/kernel/regex/core_test.zig"); // T2 engine: parser + Pike VM + prefilters
    _ = @import("gist/kernel/regex/matcher.zig"); // engine-neutral match seam: linear-arm forwarding
    _ = @import("gist/kernel/regex/pcre2.zig"); // PCRE2 `-P` backend: engine + literal co-located tests
    _ = @import("gist/kernel/regex/pcre2_test.zig"); // PCRE2 adversarial: lookaround/backref/limit/JIT parity
    _ = @import("gist/kernel/regex/adversarial_test.zig"); // independent-oracle differential + prefilter brute force
    _ = @import("gist/kernel/regex/dfa_test.zig"); // byte-class DFA unit + differential fuzz
    _ = @import("gist/kernel/regex/powerset_test.zig"); // determinizer structural invariants
    _ = @import("gist/kernel/regex/unicode/utf8seq.zig"); // scalar-range → UTF-8 byte-range decomposition
    _ = @import("gist/kernel/regex/unicode/decode.zig"); // UTF-8 codepoint decode (fwd/last) for \b
    _ = @import("gist/kernel/regex/unicode/tables.zig"); // Unicode data API: Perl/\p classes, fold orbits
    // command surfaces (tests + driver bodies, so `zig build test` type-checks all)
    _ = @import("scope/glob_test.zig"); // glob matcher + type/glob/root path scope
    _ = @import("gist/faces/status/status.zig"); // read-only index introspection
    _ = @import("gist/faces/cli/schema.zig"); // `--schema` manifest
    _ = @import("hydra/cli/schema.zig"); // hydra's `--schema` manifest
    _ = @import("gist/faces/ripgrep/run.zig"); // the unified engine (rgsuite parity drop-in)
    _ = @import("gist/faces/ripgrep/ingest.zig"); // -z/--pre/-E content transforms (decompress/preprocess/transcode)
    _ = @import("gist/faces/ripgrep/encoding.zig"); // -E WHATWG legacy-code-page decoders (single-byte + CJK multi-byte)
    _ = @import("gist/faces/ripgrep/multiline.zig"); // -U whole-buffer match model (Emitter.buffer + --json)
    _ = @import("gist/faces/ripgrep/rank.zig"); // `--rank` definition-first ranked view
    _ = @import("gist/faces/ripgrep/index.zig"); // the `index` verb: build + persist
    _ = @import("gist/faces/serve/serve.zig"); // the resident daemon driver body
    _ = @import("gist/faces/client/client.zig"); // the warm CLI fast-path client body
    _ = @import("gist/faces/client/spawn.zig"); // best-effort detached daemon auto-spawn
    _ = @import("gist/faces/client/client_test.zig"); // wedged-daemon → cold deadline (no hang)
    _ = @import("gist/faces/serve/serve_test.zig"); // end-to-end daemon lifecycle + client round-trip
}
