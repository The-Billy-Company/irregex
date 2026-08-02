//! irregex — fast, agent-friendly code locator kernel.
//!
//! The engine half of an agent-native grep: a candidate INDEX that turns a
//! whole-tree scan into a scoped lookup, plus (later tiers) sparse-n-gram
//! selection, ranked + token-compressed output, and fusion with an external
//! code graph + contracts. Two rivals bound this design, and naming only the
//! first is how the interesting half goes missing. ripgrep is near-optimal at
//! *unindexed* scan, so against it the win is at scale (don't rescan) and at
//! *intent* (don't already know the symbol). csearch and zoekt don't rescan
//! either — against THEM the win is that an index here may only elide reads and
//! never overrule live bytes, so a stale index costs speed rather than
//! correctness (`corpus/fresh/`, which measures where both of them answer a
//! mutated tree wrongly). See `research/gist/PRIOR_ART.md`.
//!
//! Search, index lifecycle, and result handling are Zig-native and surfaced by
//! the `gist` CLI. This package's own C ABI (`include/irgx.h`, shims in
//! `surface/ffi/exports.zig`) is deliberately the SMALL half: a pattern over a
//! buffer the host already holds — compile, `is_match`, `find_all`,
//! `captures` — plus the status/fault substrate every package's ABI returns.
//! No corpus, no session, no index; a host that wants those links `libgist`.
//! Every entry returns a status instead of `die()`ing, so a bad pattern can
//! never terminate an embedding host, and every verb is a shim over the
//! machinery the CLI runs (`kernel/query/query.zig`, the `Caps` arms) — which
//! is what makes an in-process answer the same answer `gist --json` prints.
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

// Who the program riding this engine is: the name it signs a diagnostic with,
// the namespace its knobs live in, where its artifacts go. A binary declares
// `pub const irgx_brand: irregex.Brand = .{ .name = "relate" };` in its root
// module; anything that declares nothing keeps the historical `gist` spellings.
pub const Brand = assay.Brand;

// How a face terminates: the rg `0`/`1`/`2` exit contract (both precedences)
// and the `fatal` catch that keeps an escaped error off Zig's default handler,
// which would exit 1 — "found nothing" — on a hard fault.
pub const Outcome = @import("surface/cli/outcome.zig").Outcome;
pub const fatal = @import("surface/cli/outcome.zig").fatal;

// The vocabulary those exits speak: five fault domains declared once (Zig
// merges error names globally, so the merge must be deliberate), the
// declinature enum that keeps a routine tier fallback out of the error channel
// entirely, and the thread-local detail slot the C ABI's last-fault pull reads.
// Vocabulary and payload only — transport stays assay's.
pub const fault = @import("fault.zig");

// The platform seam: the POSIX-shaped primitives the engine actually calls —
// handle-relative open, read, whole-file map, write, argv, stdin readiness —
// with the Windows fork stated once behind a comptime branch rather than
// sprinkled through the descent. Exported so the CLI's own module root (which
// sits outside this module's path) reaches it through the same door.
pub const portal = @import("portal.zig");

// ── candidate index ──
pub const ngram = @import("corpus/index/trigrams/ngram.zig");
pub const trigram = @import("corpus/index/trigrams/trigram.zig");
pub const persist = @import("corpus/index/trigrams/persist.zig");
pub const sliver = @import("corpus/index/trigrams/sliver.zig");
pub const codicil = @import("corpus/index/trigrams/codicil.zig");

// ── the crest sieve (math floor + persisted sidecar) ──
// The forced-class-run necessary condition that prunes the trigram index's one
// structural hole — literal-free class-repetition patterns ([0-9a-f]{8}) that
// extract no required substring. Kernel is pure math; the sidecar rides the
// same generation-atomic publish as the trigram pair. Proof: research/crest/.
pub const crest = @import("kernel/math/crest.zig");
pub const crest_sidecar = @import("corpus/index/crest/sidecar.zig");

// ── the signet (one durable identity for bytes that outlive the process) ──
// The seal every persisted artifact carries and the digest an embedder needs to
// speak the same integrity language as the index it maps. Hash-table keys and
// the kinship sketch hashes are deliberately NOT this — see the module header.
pub const signet = @import("corpus/index/frame/signet.zig");
pub const home = @import("corpus/index/frame/home.zig");

// ── the ward (shared reader/writer discipline) ──
// The concurrency-axis peer of `parallel.zig`: lease guards + the double-checked
// read-mostly `readReconciled` dance the warm session rides instead of
// hand-rolling `std.Io.RwLock` lock/unlock pairs. Pure `std.Io` plumbing.
pub const ward = @import("kernel/math/lease.zig");

// ── the fan-out floor (byte-balanced sharding + partial-spawn-safe spawn/join) ──
// The other half of that pair, re-exported for the same reason: the bench harness
// has to reproduce a product lane's EXACT shard geometry to price it honestly, and
// re-deriving `greedyBounds`/`fanOut` in the harness would make the instrument
// disagree with the thing it measures.
pub const parallel = @import("kernel/math/parallel.zig");

// ── regex engine ──
// The engine is a sealed deep module: every consumer enters through its one
// entry file, so a second grammar cannot grow beside it. These names re-export
// the stages the C-ABI / library consumers bind, through that same door.
const regex_engine = @import("kernel/regex/regex.zig");
pub const regex = regex_engine.program;
pub const regex_chorus = regex_engine.chorus;
pub const regex_dfa = regex_engine.dfa;
/// The determinizer that discovers that `Dfa` — re-exported for the automata
/// lane's cost harness (`bench/rungs/automata/`), whose claims are each about
/// one function inside it. A harness that reconstructed subset construction to
/// time it would be timing a copy; this re-runs the shipped one over the NFA the
/// shipped compile already lowered.
pub const regex_determinize = regex_engine.determinize;
/// Which states a finished automaton can be skipped out of — re-exported for the
/// same harness, which prices C4's premise by asking it about EVERY state and then
/// measuring how many of a real document's bytes such a skip would delete. The
/// engine itself asks only about the start state.
pub const regex_dwell = regex_engine.dwell;
/// Collapsing a finished determinization in both dimensions — re-exported for the
/// same harness, which prices C5 by asking what the BYTE road's tables still
/// contain that no suffix can distinguish, and what removing it costs. The
/// symbolic road runs it in production; the byte road's answer is a measurement.
pub const regex_reduce = regex_engine.reduce;
/// The accelerator tier's auction and the measured plane it bids in —
/// re-exported for `bench/rungs/price/`, which re-times every coefficient in
/// isolation and then gates the auction's per-pattern choices against the
/// measured-best machine. Both names, because those are two different claims:
/// one about a number, one about a decision made with it.
pub const regex_rungs = regex_engine.rungs;
pub const regex_price = regex_engine.price;
/// The SP-quotient sieve harvested from a `Dfa` — re-exported for its
/// corpus-scale soundness + speed bench (`bench/rungs/sieve/`).
pub const regex_sieve = regex_engine.sieve;
pub const regex_compose = regex_engine.compose;
/// The Parabix bit-parallel rung, lowered from the AST — re-exported for its
/// corpus-scale throughput + agreement bench (`bench/rungs/parabix/`).
pub const regex_parabix = regex_engine.parabix;
/// The parser's own tree and the analyses that walk it — the baseline arm of
/// the sweep bench, and what a planner reads today.
pub const regex_syntax = regex_engine.syntax;
pub const regex_analysis = regex_engine.analysis;
/// The interned, canonicalized shape and its one-pass fused facts — re-exported
/// for the per-consumer A/B bench (`bench/rungs/sweep/`) that decides, walker by
/// walker, whether the fabric actually beats the recursion it would replace.
pub const regex_ast = regex_engine.ast;
/// The engine-neutral match seam (`Matcher`) the presentation layer programs
/// to — re-exported for the bench lab's isolated output-path profiles.
pub const matcher = regex_engine.ladder;

// ── ranking ──
pub const rank = @import("kernel/rank/rank.zig");
pub const signals = @import("kernel/rank/signals.zig");

// ── byte-level match execution ──
pub const simd = @import("kernel/scan/simd.zig");
pub const anchor = @import("kernel/scan/anchor.zig");
pub const calibrate = @import("kernel/scan/calibrate.zig");
pub const verify = @import("kernel/scan/verify.zig");

// ── the presentation layer (rg-shaped output; -n/-v/-o/-c frames) ──
// The `Emitter` that turns one file's matches into ripgrep-shaped bytes, and
// the `Opts` flag record that steers it. Re-exported so the bench lab can
// profile individual output-path functions (line-number formatting, the
// invert selection loop) in isolation.
pub const emit = @import("exec/cold/emit/output.zig");
/// The `rg --json` record-stream encoder — re-exported so the bench lab can
/// profile the per-record hot path (`pathData` cache, `writeUint`, `asciiOnly`)
/// over the real corpus in isolation, the same way it profiles the text
/// Emitter's line-number itoa and invert loop.
pub const emit_json = @import("exec/cold/emit/json.zig");
pub const argv = @import("exec/cold/argv/args.zig");
/// The personal, TTY-gated half of the persisted pair: flag defaults a reader
/// keeps for their own terminal. Its committed sibling is `commands.scope.charter`.
pub const preference = @import("exec/cold/argv/preference.zig");
/// The `-r`/`--replace` capture seam (`Caps`/`Captures`) — re-exported so the
/// bench lab can profile the replacement template expander (`emit.expandInto`)
/// against a naive reference in isolation, the same way it profiles the
/// line-number itoa and the invert loop.
pub const captures = regex_engine.captures;

// ── corpus + freshness ──
pub const corpus = @import("corpus/tree/corpus.zig");
pub const haystack = @import("corpus/tree/haystack.zig");
pub const bulkstat = @import("corpus/tree/bulkstat.zig");
pub const fresh = @import("corpus/fresh/fresh.zig");
// atlas/frag (relate's persisted artifacts) live in the `relate` package.
// ── irregex: the irregular-expression primitives (match ∪ relate ∪ weave) ──
// The set-shaped tier over the engine: PatternSet compiles MANY intents with
// exact per-pattern attribution (the match half), Sketch measures compression
// kinship between byte bodies (the relate half — LZ dictionaries, no parsing),
// loom executes a closed filter/group/sort/limit plan over the attributed
// stream engine-side, and bits is the shared two's-complement identity floor
// (set-bit walks, word-packed bit sets) the other tiers ride instead of
// hand-rolling. Primitives only — faces (CLI verbs, bindings) consume.
pub const irregex = struct {
    pub const bits = @import("kernel/math/bits.zig");
    pub const patterns = @import("kernel/slate/patterns.zig");
    // sketch/silhouette (the relate half) live in the `relate` package.
    pub const loom = @import("kernel/slate/loom.zig");
};

// compose (exact ∩ compression kernels) moved to the `relate`
// package — its context/family halves run kinship inside the exact filter,
// so it lives above this library in the ecosystem DAG.

// ── succinct floors + FM-index + shelf ──
// SA-IS / RRR / wavelet are the math floors; the FM-index composition
// (`kernel/codex`) and its persisted multi-doc shelf sit above them. Both
// used to live in `relate`, which made gist's `codex` verb depend on relate
// for an index tier — a cycle once the relate face also needed gist's
// answer keep. An index tier belongs with the other index tiers.
pub const codex = struct {
    pub const sais = @import("kernel/math/succinct/sais.zig");
    pub const rrr = @import("kernel/math/succinct/rrr.zig");
    pub const wavelet = @import("kernel/math/succinct/wavelet.zig");
    pub const index = @import("kernel/codex/codex.zig");
    pub const shelf = @import("corpus/index/shelf/shelf.zig");
};

// The relate engine (kinship metric/cluster/recall, retrieval, the
// Ziv–Merhav cento over this library's FM-index) is the `relate` package.

// ── the transport-neutral compiled query (the shared search core) ──
// One deep module owns "a search intent, compiled": the fail-closed, thread-safe
// compile → sound-trigram-prefilter → per-doc match/count kernels that BOTH the
// cold CLI (`exec/cold`) and the warm resident session (`exec/session`)
// execute through, so the two engines cannot drift on what matches.
pub const engine = struct {
    pub const query = @import("kernel/query/query.zig");
};

// ── resident search session: the warm in-memory engine +
// its Unix-socket transport, sharing the kernels above but returning errors
// instead of `die()`ing so a bad request can't take down the daemon. ──
pub const session = struct {
    pub const resident = @import("exec/session/warm/resident.zig");
    pub const corpus = @import("exec/session/warm/mirror.zig");
    pub const render = @import("exec/session/facet/render.zig");
    pub const request = @import("exec/session/answer/request.zig");
    // conduit's UDS frame protocol lives in `gist` with the daemon proper.
    pub const watch = @import("exec/session/watch/watch.zig");
};

// The in-process C-ABI session (surface/ffi) and its export shims live in
// the `gist` package, which owns the session-shaped ABI. This library's
// C ABI is the future match-shaped surface.

/// CLI surfaces built on the engine above. Not part of the C ABI — the `gist`
/// executable (`surface/face/gist/main.zig`) and the bench harness dispatch through
/// these; grouped here so the whole command tree resolves through the module.
pub const commands = struct {
    pub const scope = struct {
        pub const glob = @import("kernel/math/glob.zig");
        pub const filter = @import("corpus/scope/filter.zig");
        pub const types = @import("corpus/scope/types.zig");
        /// The corpus partition (`code`/`docs`/`data`) behind `--docs`/`--code`.
        pub const genus = @import("corpus/scope/genus.zig");
        /// The committed tree declaration (`.irregex.toml`) every face honors.
        pub const charter = @import("corpus/scope/charter.zig");
        /// How either persisted configuration file reports being misread.
        pub const misread = @import("kernel/math/misread.zig");
    };
    /// The unified search engine — the certified ripgrep-parity walk-and-emit
    /// control plane (`engine/serial.zig`). Backs the rgsuite parity certificate.
    pub const search = @import("exec/cold/engine/serial.zig");
    // Every verb/face driver (gist · relate · blast binaries), the daemon,
    // and the warm client moved to their product packages.
};

/// The curated Zig-native hosted API: a small vocabulary of owned
/// handles — `Engine`, `SearchQuery`, `Cursor` (pull `next`/`nextBatch`),
/// `CancelToken`, `RunOptions` — over the same error-returning warm engine the
/// resident daemon and the C-ABI shims ride. What a Zig embedder (and the C ABI
/// + bindings above it) programs to, distinct from the internal tiers above.
pub const api = @import("surface/api.zig");

/// The C-ABI substrate the whole ecosystem shares: the status enum and its
/// three dispositions, the one fault translation, the per-incident fault pull,
/// the pattern-semantics flag bits, and the self-describing row protocol.
///
/// `librelate`, `libgist`, and `libblast` each link this library and return
/// these types, so a host that links two of them reads one vocabulary rather
/// than two spellings of "declined". A product's own ABI exports only its
/// verbs on top of this.
pub const ffi = struct {
    pub const contract = @import("surface/ffi/contract.zig");
    pub const rows = @import("surface/ffi/rows.zig");
    /// This library's OWN plane on that substrate: a pattern and a buffer, with
    /// no corpus behind them — compile, `is_match`, `find_all`, `captures`. The
    /// `export fn` shims that lower it to C live in `surface/ffi/exports.zig`,
    /// which is the root of the `libirgx` artifact rather than of this
    /// module, so a host linking two of the ecosystem's libraries gets one
    /// definition of each symbol.
    pub const pattern = @import("surface/ffi/pattern.zig");
    /// The other half every package's ABI shares: a materialized run of rows
    /// plus the position a host reads it from. Each library exports its own
    /// `…_run` and returns THIS, so three questions cost one cursor protocol.
    pub const answer = @import("surface/ffi/answer.zig");
};

// ── the product seam ──
// What the sibling product packages (`relate` · `gist` · `blast`) reach that
// is not part of the curated vocabulary above. The ecosystem's own internals,
// re-exported through one door because the products and the library are tuned
// together and version together — an outside embedder should prefer the
// curated tiers, and nothing here is semver-stable. Grouped by tier, named by
// file, so a product import reads like the path it replaced.
pub const inner = struct {
    pub const corpus = struct {
        pub const journal = @import("corpus/fresh/journal.zig");
        pub const shard = @import("corpus/index/content/shard.zig");
        pub const treemap = @import("corpus/index/phantom/treemap.zig");
        pub const frame = @import("corpus/index/frame/frame.zig");
        pub const encoding = @import("corpus/read/encoding.zig");
        pub const inode = @import("corpus/read/inode.zig");
        pub const slurp = @import("corpus/read/slurp.zig");
        pub const paths = @import("corpus/scope/paths.zig");
        pub const ignore = @import("corpus/tree/ignore.zig");
        pub const loadpar = @import("corpus/tree/loadpar.zig");
    };
    pub const cold = struct {
        pub const catalog = @import("exec/cold/argv/catalog.zig");
        pub const intent = @import("exec/cold/argv/intent.zig");
        pub const elide = @import("exec/cold/quarry/elide.zig");
        pub const walk = @import("exec/cold/quarry/walk.zig");
    };
    pub const session = struct {
        pub const keep = @import("exec/session/answer/keep.zig");
        pub const shm = @import("exec/session/conduit/shm.zig");
        pub const truth = @import("exec/session/warm/truth.zig");
        pub const annals = @import("exec/session/reconcile/annals.zig");
        pub const dirty = @import("exec/session/reconcile/dirty.zig");
        pub const seqlock = @import("exec/session/reconcile/seqlock.zig");
    };
    pub const math = struct {
        pub const forest = @import("kernel/math/forest.zig");
        pub const mix = @import("kernel/math/mix.zig");
    };
    pub const cli = struct {
        pub const outcome = @import("surface/cli/outcome.zig");
        pub const beacon = @import("surface/cli/beacon.zig");
        pub const emit = @import("surface/cli/emit.zig");
        pub const guide = @import("surface/cli/guide.zig");
        pub const jsonstr = @import("surface/cli/jsonstr.zig");
    };
    /// The shared comment/code/string span lexer (regions + comment-scope +
    /// blast all read it; pure, std-only).
    pub const lexspan = @import("kernel/anatomy/lexspan.zig");
};

pub const version_string: [:0]const u8 = "1.0.0"; // x-release-please-version

/// The C-ABI compatibility integer, and the provenance stamp every measurement
/// harness prints in its banner — which is why it is declared here rather than
/// only on the export shim: a bench binary links the module, not the library.
/// `contract/engine.toml`'s `abi_version` is the contract for this number, and
/// `irgx_abi_version()` returns it rather than restating it, so the two can
/// never disagree. Bump only for a breaking layout or signature change; an
/// additive symbol keeps it.
pub fn abi() u32 {
    return 2;
}

/// The vendored PCRE2 the `-P` backend links (`kernel/regex/pcre2/ffi.zig`),
/// reported by `gist rg --pcre2-version` in ripgrep's own phrasing. Declared
/// beside the engine semver rather than inside the FFI shim so the answer a
/// caller reads and the library actually linked have one name between them.
pub const pcre2_version_string = "10.47";

// The session export shims and the analytic-plane exports belong to the `gist`
// package; what lives here is the substrate underneath all of them (`ffi`).

test {
    // `refAllDecls` pulls each `pub` tier re-export above into `zig build test`,
    // but each tier's tests live in a sibling `*_test.zig` (shape cap), which is
    // NOT re-exported — so every test file is wired in explicitly here.
    std.testing.refAllDecls(@This());
    // `refAllDecls` is one level deep: it references the `ffi` struct without
    // analyzing the files behind it, so those tests need naming outright.
    _ = @import("surface/ffi/contract.zig"); // the shared status/fault substrate every package's ABI returns
    _ = @import("surface/ffi/rows.zig"); // the self-describing row protocol the analytic ABIs share
    _ = @import("surface/ffi/answer.zig"); // the shared row cursor: one walk, batching from the same position, fail-closed arguments
    _ = @import("surface/ffi/pattern.zig"); // the regex-over-text plane: argument guards, the lazy capture arm, -F/-w/smart-case at the seam
    _ = @import("assay/assay.zig"); // instrumentation floor: Span/Duration/Anchor, Tally(Schema), the diagnostic channel
    _ = @import("surface/api_test.zig"); // hosted API facade: Engine/Cursor/CancelToken over a live warm tree
    // engine tiers
    _ = @import("corpus/index/trigrams/ngram_test.zig"); // n-gram extraction strategy primitives
    _ = @import("corpus/index/postings/varint_test.zig"); // LEB128 varint codec (compact posting bodies)
    _ = @import("corpus/index/trigrams/trigram_test.zig"); // T0 candidate index: query + serialize + build
    _ = @import("corpus/index/trigrams/kiln_test.zig"); // block builder vs the format oracle: bounded-memory build emits the same bytes
    _ = @import("corpus/index/trigrams/trigram_load_test.zig"); // T0 loader adversarial suite: malformed blobs fail closed
    _ = @import("corpus/index/trigrams/persist_test.zig"); // T0 persisted corpus/index/path-table integrity (doc-id OOB guard)
    _ = @import("corpus/index/trigrams/sliver_test.zig"); // sub-trigram tier: the Sliver Theorem + the rescue-set premise
    _ = @import("corpus/index/trigrams/codicil_test.zig"); // incremental codicil: round-trip, fail-closed decode, layered-query parity
    _ = @import("corpus/index/trigrams/lapse_test.zig"); // generation retention: each publish fence asserted alone
    _ = @import("corpus/index/trigrams/trigram_fuzz.zig"); // T0 loader long fuzz (seeds + mutations; GIST_FUZZ_ITERS)
    _ = @import("corpus/index/frame/frame_test.zig"); // shared artifact-load protocol: tree binding + future-anchor refusal, no leak on reject
    _ = @import("corpus/index/phantom/treemap_test.zig"); // phantom tree.map layout: round-trip, root resolve, torn blobs fail closed
    _ = @import("corpus/index/content/shard.zig"); // content shard: body round-trip, freshness gate, torn blobs fail closed
    _ = @import("kernel/codex/codex_test.zig"); // SA-IS/RRR/wavelet/FM-index differential vs naive oracles
    _ = @import("corpus/index/shelf/shelf_test.zig"); // count/tally vs per-doc oracles through save/load, fail-closed framing
    _ = @import("kernel/rank/rank_test.zig"); // T4 RRF fusion ranking
    _ = @import("kernel/rank/signals_test.zig"); // cross-language def-detection + generated-file signals
    _ = @import("kernel/rank/replica.zig"); // cached-source mirror classification + exact canonical duplicate
    _ = @import("kernel/scan/simd_test.zig"); // SIMD `contains` differential fuzz vs std
    _ = @import("kernel/scan/calibrate_test.zig"); // per-buffer anchor calibration: planted oracle + stratification contrast
    _ = @import("kernel/scan/anchor_test.zig"); // anchor tie-break + table-range regression guards, and plan-seam equivalence
    _ = @import("kernel/scan/classrun_test.zig"); // SIMD class-run kernel vs scalar oracle (both backends)
    _ = @import("corpus/fresh/fresh_test.zig"); // T3 freshness `widen` set-algebra
    _ = @import("kernel/query/query_test.zig"); // shared compiled-query: compile/prefilter/match vs oracle
    _ = @import("kernel/math/bits_test.zig"); // shared two's-complement bit identities vs bool-slice oracle
    _ = @import("kernel/math/dag_test.zig"); // hash-consed DAG substrate: identity, topological order, sweeps vs recursion
    _ = @import("kernel/regex/ast/ast_test.zig"); // interned AST: re-association safety, fused facts vs today's recursive walkers
    _ = @import("kernel/math/crest_test.zig"); // crest sieve, document half: ρ(d) scan + dominance decision + sidecar schema
    _ = @import("kernel/math/parallel.zig"); // shared byte-balanced sharding + partial-spawn-safe fan-out
    _ = @import("corpus/index/frame/signet_test.zig"); // BLAKE3 identity: domain separation, seal round-trip, torn-write detection
    _ = @import("kernel/math/lease_test.zig"); // reader/writer lease guards + double-checked readReconciled dance
    _ = @import("corpus/index/crest/sidecar_test.zig"); // crest sidecar codec: round-trip + fail-closed adversarial
    _ = @import("kernel/slate/patterns_test.zig"); // match half: set ≡ N single-pattern oracles (gate off/on)
    _ = @import("kernel/slate/trawl_test.zig"); // wide-slate tier: Aho–Corasick vs substring oracle; striped ≡ serial
    _ = @import("kernel/slate/loom_test.zig"); // weave: closed op set — total, deterministic, hand-tallied
    _ = @import("exec/session/answer/request_test.zig"); // resident request eligibility classifier
    _ = @import("exec/session/warm/mirror.zig"); // faithful corpus ingest: BOM/UTF-16 decode, whole-body NUL, no cap
    _ = @import("exec/session/facet/render.zig"); // warm lines renderer: cold-Emitter byte parity
    _ = @import("exec/session/warm/resident_test.zig"); // resident session: parity vs cold, overlay, RYW, deletion
    _ = @import("exec/session/conduit/shm.zig"); // portable anonymous shm buffer: fd round-trip, zero-len unsupported
    _ = @import("exec/session/watch/watch_test.zig"); // freshness watcher: dirty/clean seqlock barrier + the promise EVERY exact backend makes, over real mutations
    _ = @import("exec/session/watch/kqueue_test.zig"); // macOS-only: the ignore-selected watch set, and a vnode it cannot open
    _ = @import("exec/session/watch/notify_test.zig"); // Windows-only: recursive-subscription cost, buffer overflow, plain record class
    _ = @import("exec/session/reconcile/reconcile_test.zig"); // barrier hardening: differential vs on-disk oracle, concurrency, overflow/bound
    _ = @import("exec/session/reconcile/vouch_test.zig"); // epoch vouch on the real backend (macOS+Linux): liveness, same-epoch⇒same-bytes, surrender
    _ = @import("exec/session/reconcile/dirty.zig"); // exact dirty-path log: dedupe, bound→doubt, exact promise
    _ = @import("exec/session/reconcile/delta.zig"); // O(changed) resolver: path classes, fold aliasing helpers
    _ = @import("exec/session/reconcile/annals.zig"); // delivery ledger: which changed (since) + whether any did (epoch)
    _ = @import("exec/session/answer/keep.zig"); // answer keep: epoch match, exit-code fidelity, LRU + oversize refusal
    _ = @import("exec/session/warm/scoped_test.zig"); // scoped reconcile adversarial: vs full-walk ground truth
    _ = @import("corpus/tree/haystack_test.zig"); // shared walk: isSkipDir + joinPath hot-path decisions
    _ = @import("corpus/tree/bulkstat_test.zig"); // getattrlistbulk ≡ stat-walk differential
    _ = @import("corpus/tree/loadpar.zig"); // fused parallel walk+read: byte-identical membership vs serial oracle
    _ = @import("corpus/tree/drain.zig"); // stdout cadence: line boundaries, block ramp, order under a refused sink
    _ = @import("kernel/regex/syntax/syntax_test.zig"); // T2 syntax: ByteSet + recursive-descent parser
    _ = @import("kernel/regex/analysis/analysis_test.zig"); // T2 analysis: required-literal + cover + anchored
    _ = @import("kernel/regex/analysis/swell_test.zig"); // crest sieve, query half: forced-crest ĝ vs hand-computed + Sieve Theorem vs the matcher
    _ = @import("kernel/regex/linear/program/core_test.zig"); // T2 engine: parser + Pike VM + prefilters
    _ = @import("kernel/regex/linear/program/chorus_test.zig"); // T2 engine: attributing union — tiers + differential vs N engines
    _ = @import("kernel/regex/matcher.zig"); // engine-neutral match seam: linear-arm forwarding
    _ = @import("kernel/regex/pcre2/backend.zig"); // PCRE2 `-P` backend: engine + literal co-located tests
    _ = @import("kernel/regex/pcre2/backend_test.zig"); // PCRE2 adversarial: lookaround/backref/limit/JIT parity
    _ = @import("kernel/regex/oracle/adversarial_test.zig"); // independent-oracle differential + prefilter brute force
    _ = @import("kernel/regex/compile/onepass_test.zig"); // one-pass capture arm: slot-exact vs the Pike VM + fail-closed refusal
    _ = @import("kernel/regex/linear/dfa/dfa_test.zig"); // byte-class DFA unit + differential fuzz
    _ = @import("kernel/regex/linear/dfa/powerset_test.zig"); // determinizer structural invariants
    _ = @import("kernel/regex/linear/caliper/caliper_test.zig"); // two-jaw span measurement: differential fuzz vs the Pike span oracle
    _ = @import("kernel/regex/linear/symbolic/symbolic_test.zig"); // predicate alphabet: ≡ Pike AND ≡ byte powerset, malformed UTF-8 included
    _ = @import("kernel/regex/linear/sieve/sieve_test.zig"); // SP-quotient sieve: superset soundness vs Pike, kernel ≡ oracle, worthless abort
    _ = @import("kernel/regex/linear/shuffle/shuffle_test.zig"); // transformation composition: kernel ≡ scalar fold, fail-closed gates, line + doc differential vs Pike
    _ = @import("kernel/regex/linear/parabix/parabix_test.zig"); // Parabix bit-parallel rung: transpose + class circuits vs their definitions, fail-closed gate, line + doc differential vs Pike
    _ = @import("kernel/regex/linear/ladder/rungs_test.zig"); // the auction, through a real compile: what a PATTERN is bid
    _ = @import("kernel/regex/unicode/utf8seq.zig"); // scalar-range → UTF-8 byte-range decomposition
    _ = @import("kernel/regex/unicode/decode.zig"); // UTF-8 codepoint decode (fwd/last) for \b
    _ = @import("kernel/regex/unicode/tables.zig"); // Unicode data API: Perl/\p classes, fold orbits
    // command surfaces (tests + driver bodies, so `zig build test` type-checks all)
    _ = @import("kernel/math/glob_test.zig"); // the pure glob matcher
    _ = @import("corpus/scope/filter_test.zig"); // type/glob/root path scope
    _ = @import("corpus/scope/genus_test.zig"); // the code/docs/data partition: totality, disjointness, precedence
    _ = @import("corpus/scope/charter_test.zig"); // the committed tree declaration's grammar
    _ = @import("kernel/math/misread.zig"); // located faults + did-you-mean, shared by both persisted layers
    _ = @import("exec/cold/argv/preference_test.zig"); // personal preferences: tokenizing + reach admission
    _ = @import("exec/cold/engine/serial.zig"); // the unified engine (rgsuite parity drop-in)
    _ = @import("exec/cold/quarry/elide.zig"); // the indexed→live read-elision oracle both cold engines admit
    _ = @import("exec/cold/engine/swarm/swarm.zig"); // the fused work-stealing walk: eligibility + run lifecycle
    _ = @import("exec/cold/engine/swarm/crew.zig"); // worker state, pool topology, the ordered --sort replay
    _ = @import("exec/cold/read/ingest.zig"); // -z/--pre/-E content transforms (decompress/preprocess/transcode)
    _ = @import("corpus/read/encoding.zig"); // -E WHATWG legacy-code-page decoders (single-byte + CJK multi-byte)
    _ = @import("exec/cold/emit/render.zig"); // one file's result: the --files-without-match verdict both engines fold
    _ = @import("exec/cold/emit/multiline.zig"); // -U whole-buffer match model (Emitter.buffer + --json)
    _ = @import("exec/cold/emit/output/multibuf_test.zig"); // -U whole-buffer emit: the ripgrep-captured parity table
    _ = @import("exec/cold/emit/hints.zig"); // no-match stderr guidance: shape analysis + exact render bytes
    _ = @import("exec/cold/emit/color.zig"); // --colors specs → the run's four SGR prefixes
    _ = @import("surface/cli/beacon_test.zig"); // OSC-8 hyperlinks: rg's format grammar, the terminal probe, the framed bytes
    _ = @import("surface/cli/guide.zig"); // the stderr guidance grammar both faces speak
    _ = Outcome; // the rg exit-code contract, incl. the -q short-circuit precedence
    _ = @import("surface/cli/outcome.zig");
    _ = @import("fault.zig"); // the fault/declinature vocabulary + the detail slot
    _ = @import("surface/cli/jsonstr.zig"); // the one JSON string escaper every JSON/NDJSON face shares
    _ = @import("exec/cold/view/ranked.zig"); // `--rank` definition-first ranked view

    // The daemon's two end-to-end suites stand or fall with its transport: both
    // build a real `AF_UNIX` socketpair and poll it, which is the one thing a
    // platform without `portal.resident_sessions` has no version of. Gated at the
    // aggregator rather than skipped inside, because `socketpair`/`pollfd` are not
    // merely absent on Windows — they are untyped, so *analyzing* the file is the
    // error, and a runtime `SkipZigTest` never gets the chance to run. They return
    // with the transport (rung 2) instead of needing a rewrite.
    if (comptime portal.resident_sessions) {}
}
