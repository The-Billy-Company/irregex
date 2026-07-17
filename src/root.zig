//! gist — fast, agent-friendly code locator kernel.
//!
//! The engine half of an agent-native grep: a candidate INDEX that turns a
//! whole-tree scan into a scoped lookup, plus (later tiers) sparse-n-gram
//! selection, ranked + token-compressed output, and fusion with an external
//! code graph + contracts. ripgrep is near-optimal at *unindexed* scan; gist's
//! win is at scale (don't rescan) and at *intent* (don't already know the
//! symbol) — see `research/dossiers/locator-sota.dossier.toml`.
//!
//! Search, index lifecycle, and result handling are Zig-native and surfaced by
//! the `gist` CLI. The C ABI in `include/gist.h` exposes ABI/engine-version
//! introspection, allocation-free trigram extraction, AND — since ADR-352
//! rung 3 — an in-process warm search SESSION (`gist_open`/`gist_search`/
//! `gist_close`, implemented in `ffi/session.zig`): a non-Zig host holds a
//! corpus warm in its own process and streams match records over a callback,
//! with no subprocess, socket, `stdout`, or `exit`. Every entry returns a
//! status code instead of `die()`ing, so a bad query can never terminate an
//! embedding host — the property ADR-352 gated the search ABI on. It rides the
//! error-returning shared core (`engine/query.zig`) + resident engine, so an
//! in-process answer is byte-identical to the cold `gist --json` stream. Index
//! BUILD lifecycle stays a Zig/CLI surface (a session searches the live tree).
//!
//! Package shape mirrors pkg/kernels/core + principia, grouped into
//! concern-scoped subfolders under `src/` (each re-exported here):
//!
//!   index/    — the trigram candidate index (turn a whole-tree scan into a lookup)
//!   regex/    — the linear-time RE2-style engine (NFA + byte-class DFA + prefilter)
//!   rank/     — RRF result ranking + its language-agnostic byte-level signals
//!   scan/     — byte-level match execution (SIMD substring, data-parallel verify kernel)
//!   corpus/   — in-memory corpus loading, the shared Haystack walk, + the T3 freshness overlay
//!   engine/   — the transport-neutral compiled query: one compile → prefilter → match core (fail-closed, thread-safe) both cold CLI and warm session execute through
//!   session/  — the resident-session transport (ADR-352 rung 2.5): warm engine · UDS codec · classifier · watcher
//!   commands/ — the CLI surfaces built on the engine (scope · status · ripgrep · cli)

const std = @import("std");

// ── candidate index ──
pub const ngram = @import("index/ngram.zig");
pub const trigram = @import("index/trigram.zig");
pub const persist = @import("index/persist.zig");

// ── regex engine ──
pub const regex = @import("regex/core.zig");
pub const regex_syntax = @import("regex/syntax.zig");
pub const regex_analysis = @import("regex/analysis.zig");
pub const regex_compile = @import("regex/compile.zig");
pub const regex_prefilter = @import("regex/prefilter.zig");
pub const regex_dfa = @import("regex/dfa.zig");
pub const regex_captures = @import("regex/captures.zig");
pub const regex_pcre2 = @import("regex/pcre2.zig");
pub const regex_matcher = @import("regex/matcher.zig");

// ── ranking ──
pub const rank = @import("rank/rank.zig");
pub const signals = @import("rank/signals.zig");

// ── byte-level match execution ──
pub const simd = @import("scan/simd.zig");
pub const verify = @import("scan/verify.zig");

// ── corpus + freshness ──
pub const corpus = @import("corpus/corpus.zig");
pub const haystack = @import("corpus/haystack.zig");
pub const bulkstat = @import("corpus/bulkstat.zig");
pub const fresh = @import("corpus/fresh.zig");

// ── the transport-neutral compiled query (the shared search core) ──
// One deep module owns "a search intent, compiled": the fail-closed, thread-safe
// compile → sound-trigram-prefilter → per-doc match/count kernels that BOTH the
// cold CLI (`commands/ripgrep`) and the warm resident session (`session`)
// execute through, so the two engines cannot drift on what matches.
pub const engine = struct {
    pub const query = @import("engine/query.zig");
};

// ── resident search session (ADR-352 rung 2.5): the warm in-memory engine +
// its Unix-socket transport, sharing the kernels above but returning errors
// instead of `die()`ing so a bad request can't take down the daemon. ──
pub const session = struct {
    pub const resident = @import("session/resident.zig");
    pub const mirror = @import("session/mirror.zig");
    pub const render = @import("session/render.zig");
    pub const request = @import("session/request.zig");
    pub const protocol = @import("session/protocol.zig");
    pub const watch = @import("session/watch.zig");
};

// ── in-process C-ABI search session (ADR-352 rung 3) ──
// The warm engine above, exposed to non-Zig hosts as an `open`/`search`/`close`
// callback-streaming C ABI — no subprocess, socket, stdout, or exit. Backs the
// `cffi` Python transport; the `export fn`s below forward into it.
pub const ffi = @import("ffi/session.zig");

/// CLI surfaces built on the engine above. Not part of the C ABI — the `gist`
/// executable (`commands/cli/main.zig`) and the bench harness dispatch through
/// these; grouped here so the whole command tree resolves through the module.
pub const commands = struct {
    pub const scope = struct {
        pub const glob = @import("commands/scope/glob.zig");
        pub const types = @import("commands/scope/types.zig");
    };
    /// Read-only index introspection (the `status` verb).
    pub const status = @import("commands/status/status.zig");
    /// `gist --schema` JSON capability manifest.
    pub const schema = @import("commands/cli/schema.zig");
    /// The unified search engine — the certified ripgrep-parity walk-and-emit
    /// pipeline (`run`), its index-backed read-elision + `--no-index`/`--rank`
    /// candidate sources, and the ranked view (`rank`). Backs the bare
    /// `gist <pattern>` shorthand, `gist rg`, and the rgsuite parity certificate.
    pub const ripgrep = @import("commands/ripgrep/run.zig");
    /// The `index` verb — build + persist the trigram index the engine reads.
    pub const indexer = @import("commands/ripgrep/index.zig");
    /// `gist serve` — the resident daemon that keeps a `session` warm behind a
    /// Unix socket (ADR-352 rung 2.5).
    pub const serve = @import("commands/serve/serve.zig");
    /// The CLI's warm fast path — dial the daemon for an eligible query, emit
    /// byte-identically to cold, else fall back (`attempt`).
    pub const client = @import("commands/client/client.zig");
};

pub const version_string: [:0]const u8 = "0.1.0"; // x-release-please-version

/// Bump on any BREAK to the C ABI. Additive symbols (e.g. `gist_version`) do
/// not bump it — a consumer compiled against an older header keeps working.
/// v2: the rung-3 match callback (`gist_match_fn`) gained an `i32` abort return
/// (0 continue / non-zero stop), a signature change, so the ABI stepped 1 → 2.
pub fn abi() u32 {
    return 2;
}

export fn gist_abi_version() u32 {
    return abi();
}

/// The engine semver (`version_string`), NUL-terminated, static-lifetime. Lets
/// a binding version-gate the shared library / binary it drives against its own
/// packaged version (the unified-search contract's `engine_version`, ADR-352).
export fn gist_version() [*:0]const u8 {
    return version_string.ptr;
}

/// Extract the distinct, ascending trigrams of `text[0..len]` into
/// `out[0..len]` (caller sizes `out` ≥ `len`). Returns the count written.
/// This deterministic primitive is the C ABI's only data operation; search and
/// index lifecycle remain Zig-native/CLI surfaces.
export fn gist_trigram_count(text: [*]const u8, len: usize, out: [*]u32) usize {
    if (len < 3) return 0;
    return ngram.extractSortedUnique(text[0..len], out[0..len]);
}

// ── in-process warm search session (ADR-352 rung 3) ──
// Thin C shims over `ffi/session.zig`; the `Status` enum lowers to its `i32`
// tag. `gist_session` is opaque to C (`ffi.Session` by pointer). These are the
// first ABI symbols that open/query a corpus; their match callback carries an
// `i32` abort return (0 continue / non-zero stop), the signature refinement
// that took `gist_abi_version` to 2.

/// Open a warm session over `roots[0..nroots]` (NUL-terminated paths); writes
/// the handle to `*out`. Returns 0 on success, negative on failure.
export fn gist_open(roots: [*]const [*:0]const u8, nroots: usize, out: **ffi.Session) i32 {
    return @intFromEnum(ffi.open(roots, nroots, out));
}

/// Stream each matching line of `pattern[0..pattern_len]` to `on_match`.
/// Returns 1 if any line matched, 0 if none, negative on error (−1 = the caller
/// should answer cold). `on_match` returns 0 to continue or non-zero to stop the
/// stream early (a bounded / first-match query still returns 1). `flags`: bit0
/// `-F` fixed, bit1 `-i` ignore-case.
export fn gist_search(s: *ffi.Session, pattern: [*]const u8, pattern_len: usize, flags: u32, on_match: ffi.MatchFn, ctx: ?*anyopaque) i32 {
    return @intFromEnum(ffi.search(s, pattern, pattern_len, flags, on_match, ctx));
}

/// Free a session opened by `gist_open`.
export fn gist_close(s: *ffi.Session) void {
    ffi.close(s);
}

test {
    // `refAllDecls` pulls each `pub` tier re-export above into `zig build test`,
    // but each tier's tests live in a sibling `*_test.zig` (shape cap), which is
    // NOT re-exported — so every test file is wired in explicitly here.
    std.testing.refAllDecls(@This());
    // engine tiers
    _ = @import("index/ngram_test.zig"); // n-gram extraction strategy primitives
    _ = @import("index/varint_test.zig"); // LEB128 varint codec (compact posting bodies)
    _ = @import("index/trigram_test.zig"); // T0 candidate index: query + serialize + build
    _ = @import("index/trigram_load_test.zig"); // T0 loader adversarial suite: malformed blobs fail closed
    _ = @import("index/persist_test.zig"); // T0 persisted index/path-table integrity (doc-id OOB guard)
    _ = @import("index/trigram_fuzz.zig"); // T0 loader long fuzz (seeds + mutations; GIST_FUZZ_ITERS)
    _ = @import("rank/rank_test.zig"); // T4 RRF fusion ranking
    _ = @import("rank/signals_test.zig"); // cross-language def-detection + generated-file signals
    _ = @import("rank/mirror.zig"); // cached-source mirror classification + exact canonical duplicate
    _ = @import("scan/simd_test.zig"); // SIMD `contains` differential fuzz vs std
    _ = @import("corpus/fresh_test.zig"); // T3 freshness `widen` set-algebra
    _ = @import("engine/query_test.zig"); // shared compiled-query: compile/prefilter/match vs oracle
    _ = @import("session/request_test.zig"); // resident request eligibility classifier
    _ = @import("session/mirror.zig"); // faithful corpus ingest: BOM/UTF-16 decode, whole-body NUL, no cap
    _ = @import("session/render.zig"); // warm lines renderer: cold-Emitter byte parity
    _ = @import("session/resident_test.zig"); // resident session: parity vs cold, overlay, RYW, deletion
    _ = @import("session/protocol_test.zig"); // UDS frame codec round-trip + adversarial
    _ = @import("session/watch_test.zig"); // freshness watcher: dirty/clean seqlock barrier
    _ = @import("session/freshness_test.zig"); // barrier hardening: differential vs on-disk oracle, concurrency, overflow/bound
    _ = @import("corpus/haystack_test.zig"); // shared walk: isSkipDir + joinPath hot-path decisions
    _ = @import("corpus/bulkstat_test.zig"); // getattrlistbulk ≡ stat-walk differential
    _ = @import("regex/syntax_test.zig"); // T2 syntax: ByteSet + recursive-descent parser
    _ = @import("regex/analysis_test.zig"); // T2 analysis: required-literal + cover + anchored
    _ = @import("regex/core_test.zig"); // T2 engine: parser + Pike VM + prefilters
    _ = @import("regex/matcher.zig"); // engine-neutral match seam: linear-arm forwarding
    _ = @import("regex/pcre2.zig"); // PCRE2 `-P` backend: engine + literal co-located tests
    _ = @import("regex/pcre2_test.zig"); // PCRE2 adversarial: lookaround/backref/limit/JIT parity
    _ = @import("regex/adversarial_test.zig"); // independent-oracle differential + prefilter brute force
    _ = @import("regex/dfa_test.zig"); // byte-class DFA unit + differential fuzz
    _ = @import("regex/powerset_test.zig"); // determinizer structural invariants
    _ = @import("regex/unicode/utf8seq.zig"); // scalar-range → UTF-8 byte-range decomposition
    _ = @import("regex/unicode/decode.zig"); // UTF-8 codepoint decode (fwd/last) for \b
    _ = @import("regex/unicode/tables.zig"); // Unicode data API: Perl/\p classes, fold orbits
    // command surfaces (tests + driver bodies, so `zig build test` type-checks all)
    _ = @import("commands/scope/glob_test.zig"); // glob matcher + type/glob/root path scope
    _ = @import("commands/status/status.zig"); // read-only index introspection
    _ = @import("commands/cli/schema.zig"); // `--schema` manifest
    _ = @import("commands/ripgrep/run.zig"); // the unified engine (rgsuite parity drop-in)
    _ = @import("commands/ripgrep/ingest.zig"); // -z/--pre/-E content transforms (decompress/preprocess/transcode)
    _ = @import("commands/ripgrep/encoding.zig"); // -E WHATWG legacy-code-page decoders (single-byte + CJK multi-byte)
    _ = @import("commands/ripgrep/multiline.zig"); // -U whole-buffer match model (Emitter.buffer + --json)
    _ = @import("commands/ripgrep/rank.zig"); // `--rank` definition-first ranked view
    _ = @import("commands/ripgrep/index.zig"); // the `index` verb: build + persist
    _ = @import("commands/serve/serve.zig"); // the resident daemon driver body
    _ = @import("commands/client/client.zig"); // the warm CLI fast-path client body
    _ = @import("commands/client/spawn.zig"); // best-effort detached daemon auto-spawn
    _ = @import("commands/client/client_test.zig"); // wedged-daemon → cold deadline (no hang)
    _ = @import("commands/serve/serve_test.zig"); // end-to-end daemon lifecycle + client round-trip
}
