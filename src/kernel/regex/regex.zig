//! irregex's regex engine — the one door in.
//!
//! Everything under `kernel/regex/` is one deep module: a linear-time
//! Thompson NFA over bytes (RE2 / ripgrep philosophy — no backtracking, no
//! catastrophic blowup) fronted by a recursive-descent parser, fed by pinned
//! UCD data, accelerated by a byte-class DFA, and escaped from — only on
//! demand — into the vendored PCRE2 JIT. The seven stages behind this file
//! (`syntax → analysis → compile → linear`, with `unicode`, `pcre2`, `oracle`
//! alongside) are INTERNALS. Callers get this file and nothing else; the seal
//! in `contract/irregex.zone` makes that a build-time law rather than a
//! convention, and `zoning verify` in CI judges it.
//!
//! Why a seal and not just a README: the engine's correctness rests on every
//! consumer sharing ONE notion of what a pattern means. The crest sieve learned
//! that the expensive way — it carried a second, smaller regex parser, and the
//! two grammars disagreed on the zero-width `\<` / `\>` word boundaries, which
//! silently pruned two thirds of the matching corpus. A single entry point is
//! how "there is exactly one grammar" stops being a claim and becomes a
//! property: a second implementation cannot reach the internals it would need
//! to fork, and anything that wants the AST must ask this module for it.
//!
//! Competition for this engine is other ENGINES — ripgrep's Rust `regex`, RE2,
//! PCRE2, Hyperscan — measured in `bench/`. It is never a second parser inside
//! this tree.
//!
//! The interface is deliberately narrow: the compiled handle, the
//! engine-neutral match seam, captures, and the three leaf data namespaces
//! consumers genuinely reach for. Anything absent here is internal on purpose —
//! widen this file (and say why) rather than reaching around it.

// ── The compiled query: parse → analyze → lower → execute, behind one handle ─
pub const program = @import("linear/program/core.zig");
pub const Regex = program.Regex;

// ── The same pipeline for MANY patterns, with every voice still nameable ─────
pub const chorus = @import("linear/program/chorus.zig");
pub const Chorus = chorus.Chorus;

// ── The same slate, anchored, longest-first: the lexer primitive ─────────────
// A chorus asks which patterns appear somewhere in a haystack. A munch asks
// which one reaches furthest starting at an exact offset — maximal munch, the
// rule every tokenizer runs on. It is here rather than in a consumer because
// every part of it is a property of automata and not of any one grammar: the
// grouping that carries a slate past one 64-bit attribution mask, the bisected
// admission that charges an unusable pattern to itself instead of to the slate,
// the per-call `Allow` a state-directed lexer narrows the slate with (which has
// to ride the walk, since a long forbidden match hides every short permitted
// one), and the refusal to answer a word-boundary question from an offset whose
// left context is absent. What is NOT here is the tie-break, because that one
// really does belong to a grammar — so a match names every pattern that tied.
pub const munch = @import("linear/program/munch.zig");
pub const Munch = munch.Munch;

// ── The parsed shape + its lowering — what an INDEX PLANNER reasons over ──────
// A prefilter planner (`kernel/query/cover.zig`) chooses which trigrams an
// index may require by reading the pattern's parsed structure, and it must do so
// under the SAME parse options the engine will lower with: a cover derived under
// different fold / dotall / multiline settings than the matcher uses is unsound,
// because it can require a trigram a real match never contains. Both halves of
// that agreement are therefore part of this interface rather than something a
// planner reaches past the seal to reconstruct.
pub const syntax = @import("syntax/syntax.zig");
pub const lower = @import("linear/program/lower.zig");

// ── The same shape, interned — what an ANALYSIS reasons over ─────────────────
// `syntax` hands back the parser's tree, which is the right thing to lower and
// the wrong thing to interrogate: it shares nothing, so every question walks it
// again, and the pipeline asks about fourteen. `ast` is that tree hash-consed
// into a DAG, canonicalized by the operator identities, and swept once for
// every synthesized fact at the same time. Named here because a planner asking
// "what must this pattern contain / how long can it be / does it need a
// codepoint class" is asking about the language, and this is where the language
// is cheap to ask.
pub const ast = @import("ast/ast.zig");

// ── The recursive analyses over that tree — the incumbent, and the control ────
// Named here for one reason: `ast` claims to replace these, and a claim like
// that is only worth what its proof is. The A/B rung (`bench/rungs/sweep/`)
// races both arms as PRODUCTION code through this one door — a bench that
// reconstructed the walkers itself would be racing a copy and proving nothing.
pub const analysis = @import("analysis/analysis.zig");

// ── The engine-neutral match seam: linear arm or PCRE2 arm, one vocabulary ───
pub const ladder = @import("matcher.zig");
pub const Matcher = ladder.Matcher;
pub const Pcre = ladder.Pcre;

// ── The byte-class DFA — the O(1)/byte primary executor ──────────────────────
pub const dfa = @import("linear/dfa/dfa.zig");

// ── The determinizer that discovers it — what a COST harness reasons over ────
// Named for the same reason as the rungs below: the automata lane's claims
// (`research/automata/CLAIM.md`) are each about one function inside this file,
// and a harness that reconstructed the subset construction to time it would be
// timing a copy. The `Regex` handle already carries the lowered NFA (`states`,
// `start`, `anchored`), so re-running THIS determinizer over it is a
// measurement of the shipped one and not of a transcription. Read-only for that
// purpose: production compilation still enters through `lower`.
pub const determinize = @import("linear/dfa/powerset.zig");

// ── Which states a finished automaton can be skipped out of ──────────────────
// A road-independent operation on a built automaton (`linear/automata/`), named
// here for the same cost-harness reason: the engine asks it about the START state
// only, and whether it is worth asking about every state is a question about a
// real document's occupancy, which only a harness can answer. Exposing it is what
// lets that harness price the claim before the claim is built.
pub const dwell = @import("linear/automata/dwell.zig");

// ── Collapsing a finished determinization to the automaton it means ───────────
// The other road-independent operation in `linear/automata/`, named here for the
// cost-harness reason again: the symbolic road runs it because its product is
// visibly redundant, and whether the BYTE road should run it too is a question
// about how much slack subset construction leaves and what closing that slack
// costs against determinization itself. Only a harness can answer that, so the
// harness has to be able to ask.
pub const reduce = @import("linear/automata/reduce.zig");

// ── The accelerator tier itself: the auction, and the plane it bids in ───────
// Named here for the same reason each rung below is. A rung's claim is a claim
// about a NUMBER now, so the harness that re-times those numbers and gates the
// auction's choices against measured-best (`bench/rungs/price/`) has to reach
// the same plane the shipped auction reads — a bench that priced with its own
// copy of the coefficients would be proving the copy.
pub const rungs = @import("linear/ladder/rungs.zig");
pub const price = rungs.price;

// ── The quotient sieve — the two-valued reject rung that fronts the DFA ──────
// Named here because it is built FROM a `Dfa` and answers about one, so a
// consumer holding the DFA is exactly the consumer that can hold its sieve.
// (The bench that proves its soundness against this engine enters here too;
// reaching past the seal for it would be the second-grammar mistake in
// miniature.)
pub const sieve = @import("linear/sieve/sieve.zig");

// ── The composition rung — a DFA re-expressed as NEON transformations ────────
// Named for the same reason as the sieve: it is lowered FROM a `Dfa` and
// answers the same boolean about one, so the consumer holding the DFA is the
// consumer that can hold its composition tables. Its `lanes` submodule is the
// shared 16-wide `TBL`/`pshufb` primitive and depends on nothing in this
// engine, so a sibling may import that file directly without coming through
// here — but anything wanting the RUNG comes through this door.
pub const compose = @import("linear/shuffle/shuffle.zig");

// ── The Parabix rung — bit-parallel marker propagation over transposed bytes ──
// Unlike the sieve and the composition rung this one is lowered from the AST,
// not from a `Dfa`: star-height and class-chain shape are properties of the
// pattern, and a determinized automaton has already forgotten both. It is named
// here for the same reason they are — its corpus-scale bench and its
// differential harness must arm the REAL rung, and reaching past the seal for
// it would be the second-grammar mistake this file exists to prevent. Its
// `Parabix.compileOffer` is that entrance: the one parser, invoked from outside.
pub const parabix = @import("linear/parabix/parabix.zig");

// ── The consumer face: a compiled pattern and everything you ask of it ───────
// `glean/` is the one tier here shaped by the caller rather than the automaton:
// `Pattern` owns its scratch, walks matches through a `Cursor`, reads captures
// as `Groups` instead of a slot vector, and replaces/splits over the same walk.
// Everything it does lowers to a call on the `Matcher` below it, so it adds a
// face and not an engine.
pub const glean = @import("glean/glean.zig");
pub const Pattern = glean.Pattern;

// ── Capture extraction: a separate Pike VM, so the primary engine stays free ─
pub const captures = @import("compile/captures.zig");
pub const Caps = captures.Caps;
pub const Captures = captures.Captures;
pub const OnePass = captures.OnePass;
pub const PcreCaptures = captures.PcreCaptures;

// ── Leaf data the surface shares with the engine so both agree on a "word" ───
pub const word = @import("syntax/word.zig");
pub const unicode = @import("unicode/tables.zig");
pub const decode = @import("unicode/decode.zig");

// ── The opt-in escape hatch for lookaround / backreferences (`-P`) ───────────
pub const pcre2 = @import("pcre2/backend.zig");
