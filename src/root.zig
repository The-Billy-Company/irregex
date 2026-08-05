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

// ── what an answer is made of ──
// The other vocabulary, and the one a consumer holds: a byte range, the pattern
// that produced it, and the two together. Hoisted to the root as TYPES rather
// than a namespace because they are the nouns every tier's signature is written
// in — the span engine, the class-run kernel, the hosted API and the C ABI each
// declared their own until this file existed, so a span crossing between two of
// them was a copy the compiler could not distinguish from a conversion.
pub const mark = @import("mark.zig");
pub const Span = mark.Span;
pub const Match = mark.Match;
pub const PatternID = mark.PatternID;
/// What to search vs what to read while searching — the separation that lets a
/// bounded search keep `$`, `\b` and every look-around answering about the whole
/// text instead of about a slice's edges.
pub const Window = mark.Window;
/// Whether an answer decides or merely nominates. The package's central
/// promise as a type: an index, a sieve or a prefilter may eliminate work and
/// may never overrule bytes, which is why a stale artifact here costs speed
/// rather than correctness.
pub const Authority = mark.Authority;

// The platform seam: the POSIX-shaped primitives the engine actually calls —
// handle-relative open, read, whole-file map, write, argv, stdin readiness —
// with the Windows fork stated once behind a comptime branch rather than
// sprinkled through the descent. Exported so the CLI's own module root (which
// sits outside this module's path) reaches it through the same door.
pub const portal = @import("portal.zig");

// ── the product-free floor ──
// Arithmetic and structure that does not know a pattern exists: bit identities,
// the glob matcher, edit distance and its did-you-mean, union-find, hash mixing,
// the sharding geometry every parallel lane divides work by, reader/writer
// leases, the hash-consed DAG, the crest sieve calculus, and the succinct
// sublayer. Half of it is what a reader would otherwise write themselves, which
// is why it is named rather than left behind whichever consumer got there first
// — the glob matcher spent its life addressed as `commands.scope.glob`.
pub const math = @import("kernel/math/math.zig");

// ── the persisted artifacts over a corpus ──
// Grouped by what each one ELIMINATES, which is the only useful way to read
// them: trigrams rule out files that cannot match, the crest sieve rules out
// files a LITERAL-FREE pattern cannot match (the trigram index's one structural
// hole — `[0-9a-f]{8}` extracts no required substring), and the frame/signet
// floor is the byte discipline all of them are sealed with.
pub const index = struct {
    pub const ngram = @import("corpus/index/trigrams/ngram.zig");
    pub const trigram = @import("corpus/index/trigrams/trigram.zig");
    pub const persist = @import("corpus/index/trigrams/persist.zig");
    pub const sliver = @import("corpus/index/trigrams/sliver.zig");
    pub const codicil = @import("corpus/index/trigrams/codicil.zig");
    /// The sieve's persisted half — the kernel is `math.crest`. Rides the same
    /// generation-atomic publish as the trigram pair. Proof: `research/crest/`.
    pub const crest = @import("corpus/index/crest/sidecar.zig");
    /// The seal every artifact carries, and the digest an embedder needs to
    /// speak the same integrity language as the index it maps. Deliberately NOT
    /// hash-table keys or sketch hashes — see the module header.
    pub const signet = @import("corpus/index/frame/signet.zig");
    /// Where artifacts live, and how a foreign tree's are recognized as inert.
    pub const home = @import("corpus/index/frame/home.zig");
};

// ── the regex engine ──
// One name, because the engine is already one deep module and its own entry
// file is already the grouping: `regex.syntax` and `regex.ast` are the parsed
// shape; `regex.dfa`, `regex.determinize`, `regex.dwell`, `regex.reduce`,
// `regex.sieve` and `regex.parabix` are the automata road, with `regex.rungs`
// and `regex.price` the auction that picks along it; `regex.captures` and
// `regex.ladder` are the match seam; `regex.chorus` and `regex.munch` are the
// two faces of a slate.
//
// Seventeen `regex_*` names used to flatten that file into this one. The
// flattening added no capability, cost every reader the question of whether the
// two groupings agreed, and — since most were minted so one bench could reach
// one stage — made the package's public surface a function of its own test
// harness. The seal (`contract/irregex.zone`) is what makes a single door
// load-bearing rather than merely tidy: nothing enters this engine except
// through it, so a second grammar cannot grow beside the first.
pub const regex = @import("kernel/regex/regex.zig");

/// **A compiled pattern, and everything you ask of it** — `isMatch`, `find`,
/// `matches` (a cursor with the zero-width advance already right), `groups`,
/// `replace`, `split`. It owns its own scratch, so no signature here mentions a
/// Pike VM's thread list, and it compiles the capture arm only if someone asks
/// for a group.
///
/// This is the one type most callers need, which is why it is the one hoisted.
/// `regex.Regex` — the compiled program the walk planner interrogates — is the
/// engine's own face on the same pattern and stays behind the engine door with
/// the machinery that reads it; a `Pattern` hands it back through `engineOf`
/// for an index or a planner that genuinely wants it.
pub const Pattern = regex.Pattern;

/// The anchored, longest-first face of a slate: maximal munch, the rule every
/// lexer runs on. A chorus asks which patterns occur SOMEWHERE; a munch asks
/// which reaches furthest starting exactly HERE. Hoisted for the same reason
/// `Pattern` is — a tokenizer built on this engine is a consumer of the package,
/// not of one of its internals.
pub const Munch = regex.Munch;

/// Many patterns in one pass with exact per-pattern attribution.
pub const Chorus = regex.Chorus;

// ── ranking ──
pub const rank = @import("kernel/rank/rank.zig");
pub const signals = @import("kernel/rank/signals.zig");

// ── the byte tier: candidates without an automaton ──
// One needle to the rare-byte-pair memmem, a handful to Teddy, a large set to
// sparse Aho–Corasick, a dense class to the class-run scan — and `LiteralSet`
// dispatching across that whole range so a caller need not know which answered.
// Every result carries an `Authority`: `.exact` decides, `.candidate` only
// nominates. Four of these ten files were reachable here and six were not,
// which is a strange way to ship an Aho–Corasick.
pub const scan = @import("kernel/scan/scan.zig");

// ── many patterns in one walk ──
// `PatternSet` compiles a slate and keeps which pattern found what; the dragnet
// and the trawl are the two engines under it, chosen on width, so per-byte cost
// stops growing with N; `loom` shapes the attributed rows engine-side instead of
// leaving every consumer to re-implement filter/group/sort/limit over rendered
// text. Its two ordered faces, `Chorus` and `Munch`, are automaton
// constructions and live in the engine, hoisted above beside `Regex`.
pub const slate = @import("kernel/slate/slate.zig");

// ── the presentation layer (rg-shaped output; -n/-v/-o/-c frames) ──
// The `Emitter` that turns one file's matches into ripgrep-shaped bytes, the
// `Opts` record that steers it, and the `rg --json` record-stream encoder.
// Named for anyone building a grep rather than consuming one — which is the
// only audience for it, and a real one.
pub const emit = struct {
    pub const output = @import("exec/cold/emit/output.zig");
    pub const json = @import("exec/cold/emit/json.zig");
};

// ── the flag surface ──
// What a face parses, and the two persisted files that answer before argv does:
// the committed tree charter (`scope.charter`) and the machine-local,
// TTY-gated preference file, which is structurally invisible to a pipe and
// therefore to every agent.
pub const argv = @import("exec/cold/argv/args.zig");
pub const preference = @import("exec/cold/argv/preference.zig");

// ── corpus + freshness ──
pub const corpus = @import("corpus/tree/corpus.zig");
pub const haystack = @import("corpus/tree/haystack.zig");
pub const bulkstat = @import("corpus/tree/bulkstat.zig");
pub const fresh = @import("corpus/fresh/fresh.zig");

/// Path eligibility: which files are in the corpus at all, and why. The
/// committed `.irregex.toml` charter, gitignore precedence, the path filter,
/// the type registry, and the `code`/`docs`/`data` partition behind
/// `--docs`/`--code`. Previously reachable only as `commands.scope.*`, which
/// addressed a library tier by the name of the CLI that happened to call it.
pub const scope = struct {
    pub const filter = @import("corpus/scope/filter.zig");
    pub const types = @import("corpus/scope/types.zig");
    pub const genus = @import("corpus/scope/genus.zig");
    pub const charter = @import("corpus/scope/charter.zig");
};

// atlas/frag (relate's persisted artifacts) live in the `relate` package.
// compose (exact ∩ compression kernels) moved to the `relate` package — its
// context/family halves run kinship inside the exact filter, so it lives above
// this library in the ecosystem DAG.

// ── the FM-index and its persisted shelf ──
// The FM-index composition (`kernel/codex`) and the multi-doc shelf above it.
// Both used to live in `relate`, which made gist's `codex` verb depend on
// relate for an index tier — a cycle once the relate face also needed gist's
// answer keep. An index tier belongs with the other index tiers.
//
// The floors it is BUILT from — SA-IS, RRR, the wavelet tree — are not here.
// They were, and it made the same three files reachable at two addresses
// (`codex.sais` and `math.succinct.sais` are one file), which is the precise
// shape of drift this pass exists to remove: two doors onto one thing let two
// readers form two mental models of where it lives, and neither is wrong. They
// are arithmetic over bitvectors that does not know an FM-index exists, so they
// belong to the product-free floor and are reached at `math.succinct.*`. What
// remains under this door is what is genuinely the codex.
pub const codex = struct {
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
    /// The certified ripgrep-parity walk-and-emit control plane the whole cold
    /// pipeline runs through, and what the rgsuite parity certificate is a
    /// statement about. The warm session re-enters this same per-file path
    /// rather than keeping a second opinion about what a hit is.
    pub const search = @import("exec/cold/engine/serial.zig");
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

// `commands` retired here. It was a CLI-shaped alias namespace over library
// tiers — `commands.scope.glob` was the math floor's glob matcher and
// `commands.search` was the cold engine — so it named six modules after the
// executable that happened to reach them first. The modules did not move (the
// walk, the charter and the filter are load-bearing inside this library); the
// address did: `math.glob`, `math.misread`, `scope.*`, `engine.search`.

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
    /// The same plane asked about N patterns at once, with attribution: which of
    /// them match this text, in one pass rather than N. Its unit is the whole
    /// text, exactly as `pattern`'s is, so the two never disagree about whether
    /// a pattern matches a string.
    pub const slate = @import("surface/ffi/slate.zig");
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

/// The engine semver, read from `build.zig.zon`'s `.version` — the single
/// place this package's version is written. `build.zig` lifts it into this
/// module as a build option, so a release bumps one line and this constant,
/// `irgx_version()`, and every `--version` banner follow with nothing to keep
/// in step by hand.
pub const version_string: [:0]const u8 = @import("build_options").version;

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

// No retired spellings live here. Every name 1.0.0 exported that this file no
// longer does is declared in `contract/exports.toml`'s `[removed]`, with the
// address that replaced it, and `quality/surface/check.py` fails a removal that
// was never declared — the arm exists because this pass dropped nineteen of
// them and the only thing that noticed was a downstream bench failing to
// compile, one name per build.
//
// Carrying them as aliases was the other option, and what they WERE is what
// rejected it: `regex_dfa`, `emit_json` and their kin flattened a grouping the
// engine already had, most of them minted so one bench could reach one stage.
// An alias block would have re-created precisely the surface this pass removed,
// and re-created it at the root, where a reader meets it first. A major version
// is the mechanism for that trade, so this is one.

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
    _ = @import("surface/ffi/slate.zig"); // the many-patterns plane: parity with the pattern plane, pattern copying, per-pattern refusal
    _ = @import("kernel/anatomy/lexspan.zig"); // the shared comment/code/string lexer: `inner` is one level deep, so its tests need naming here
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
    _ = @import("kernel/scan/lanes_test.zig"); // the shuffle primitive: host instruction vs the portable arm no CI host compiles
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
    _ = @import("kernel/regex/syntax/directive.zig"); // T2 syntax: the leading `(?flags)` head, read as options
    _ = @import("kernel/regex/analysis/analysis_test.zig"); // T2 analysis: required-literal + cover + anchored
    _ = @import("kernel/regex/analysis/swell_test.zig"); // crest sieve, query half: forced-crest ĝ vs hand-computed + Sieve Theorem vs the matcher
    _ = @import("kernel/regex/linear/program/core_test.zig"); // T2 engine: parser + Pike VM + prefilters
    _ = @import("kernel/regex/linear/program/chorus_test.zig"); // T2 engine: attributing union — tiers + differential vs N engines
    _ = @import("kernel/regex/linear/program/munch_test.zig"); // T2 engine: anchored longest-match slate — bisected admission + differential vs N engines
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
    _ = @import("kernel/regex/glean/glean_test.zig"); // the consumer face: zero-width advance, bounded windows, pooled scratch, absent groups
    _ = @import("kernel/query/zero_width_test.zig"); // the two empty-match rules, each pinned to its own outside bar (Python re vs ripgrep)
    _ = @import("kernel/query/word_rule_test.zig"); // the -w rule, pinned across query's walk and glean's cursor, on both backends
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
    _ = @import("mark_test.zig"); // the answer vocabulary: half-open spans, zero width, pattern ids
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
