//! irregex's regex engine — the one door in.
//!
//! Everything under `kernel/match/regex/` is one deep module: a linear-time
//! Thompson NFA over bytes (RE2 / ripgrep philosophy — no backtracking, no
//! catastrophic blowup) fronted by a recursive-descent parser, fed by pinned
//! UCD data, accelerated by a byte-class DFA, and escaped from — only on
//! demand — into the vendored PCRE2 JIT. The seven stages behind this file
//! (`syntax → analysis → compile → linear`, with `unicode`, `pcre2`, `oracle`
//! alongside) are INTERNALS. Callers get this file and nothing else; the seal
//! in `contract/irregex.ward` makes that a build-time law rather than a
//! convention, and `make lint-zig-arch` judges it.
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

// ── The engine-neutral match seam: linear arm or PCRE2 arm, one vocabulary ───
pub const ladder = @import("linear/ladder/matcher.zig");
pub const Matcher = ladder.Matcher;
pub const Pcre = ladder.Pcre;

// ── The byte-class DFA — the O(1)/byte primary executor ──────────────────────
pub const dfa = @import("linear/dfa/dfa.zig");

// ── Capture extraction: a separate Pike VM, so the primary engine stays free ─
pub const captures = @import("compile/captures.zig");
pub const Caps = captures.Caps;
pub const Captures = captures.Captures;
pub const PcreCaptures = captures.PcreCaptures;

// ── Leaf data the surface shares with the engine so both agree on a "word" ───
pub const word = @import("syntax/word.zig");
pub const unicode = @import("unicode/tables.zig");
pub const decode = @import("unicode/decode.zig");

// ── The opt-in escape hatch for lookaround / backreferences (`-P`) ───────────
pub const pcre2 = @import("pcre2/backend.zig");
