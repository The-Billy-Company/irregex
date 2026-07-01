//! gist — fast, agent-friendly code locator kernel (Zig, C-ABI).
//!
//! The engine half of an agent-native grep: a candidate INDEX that turns a
//! whole-tree scan into a scoped lookup, plus (later tiers) sparse-n-gram
//! selection, ranked + token-compressed output, and fusion with an external
//! code graph + contracts. ripgrep is near-optimal at *unindexed* scan; gist's
//! win is at scale (don't rescan) and at *intent* (don't already know the
//! symbol) — see `research/dossiers/locator-sota.dossier.toml`.
//!
//! Package shape mirrors pkg/kernels/core + principia, grouped into
//! concern-scoped subfolders under `src/` (each re-exported here) and surfaced
//! through a FLAT C ABI (no namespaces in C/cffi/cgo) pinned in `include/gist.h`:
//!
//!   index/    — the trigram candidate index (turn a whole-tree scan into a lookup)
//!   regex/    — the linear-time RE2-style engine (NFA + byte-class DFA + prefilter)
//!   rank/     — RRF result ranking + its language-agnostic byte-level signals
//!   scan/     — byte-level match execution (SIMD substring, parallel verify, live sweep)
//!   corpus/   — in-memory corpus loading + the T3 freshness overlay
//!   commands/ — the CLI surfaces built on the engine (scope · grep · ripgrep · cli)

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

// ── ranking ──
pub const rank = @import("rank/rank.zig");
pub const signals = @import("rank/signals.zig");

// ── byte-level match execution ──
pub const simd = @import("scan/simd.zig");
pub const verify = @import("scan/verify.zig");
pub const sweep = @import("scan/sweep.zig");

// ── corpus + freshness ──
pub const corpus = @import("corpus/corpus.zig");
pub const fresh = @import("corpus/fresh.zig");

/// CLI surfaces built on the engine above. Not part of the C ABI — the `gist`
/// executable (`commands/cli/main.zig`) and the bench harness dispatch through
/// these; grouped here so the whole command tree resolves through the module.
pub const commands = struct {
    pub const scope = struct {
        pub const glob = @import("commands/scope/glob.zig");
        pub const types = @import("commands/scope/types.zig");
    };
    pub const grep = @import("commands/grep/emit.zig");
    pub const ripgrep = @import("commands/ripgrep/run.zig");
    pub const cli = @import("commands/cli/drivers.zig");
};

pub const version_string: [:0]const u8 = "0.1.0"; // x-release-please-version

/// Bump on any C-ABI break so bindings can refuse a mismatched shared lib.
pub fn abi() u32 {
    return 1;
}

export fn gist_abi_version() u32 {
    return abi();
}

/// Extract the distinct, ascending trigrams of `text[0..len]` into
/// `out[0..len]` (caller sizes `out` ≥ `len`). Returns the count written.
/// A deterministic, allocation-free primitive — the cross-language parity
/// oracle the bindings assert against.
export fn gist_trigram_count(text: [*]const u8, len: usize, out: [*]u32) usize {
    if (len < 3) return 0;
    return ngram.extractSortedUnique(text[0..len], out[0..len]);
}

test {
    // `refAllDecls` pulls each `pub` tier re-export above into `zig build test`,
    // but each tier's tests live in a sibling `*_test.zig` (shape cap), which is
    // NOT re-exported — so every test file is wired in explicitly here.
    std.testing.refAllDecls(@This());
    // engine tiers
    _ = @import("index/ngram_test.zig"); // n-gram extraction strategy primitives
    _ = @import("index/trigram_test.zig"); // T0 candidate index: query + serialize + build
    _ = @import("rank/rank_test.zig"); // T4 RRF fusion ranking
    _ = @import("rank/signals_test.zig"); // cross-language def-detection + generated-file signals
    _ = @import("scan/simd_test.zig"); // SIMD `contains` differential fuzz vs std
    _ = @import("corpus/fresh_test.zig"); // T3 freshness `widen` set-algebra
    _ = @import("regex/syntax_test.zig"); // T2 syntax: ByteSet + recursive-descent parser
    _ = @import("regex/analysis_test.zig"); // T2 analysis: required-literal + cover + anchored
    _ = @import("regex/core_test.zig"); // T2 engine: parser + Pike VM + prefilters
    _ = @import("regex/adversarial_test.zig"); // independent-oracle differential + prefilter brute force
    _ = @import("regex/dfa_test.zig"); // byte-class DFA unit + differential fuzz
    _ = @import("regex/powerset_test.zig"); // determinizer structural invariants
    // command surfaces (tests + driver bodies, so `zig build test` type-checks all)
    _ = @import("commands/scope/glob_test.zig"); // glob matcher + type/glob/root path scope
    _ = @import("commands/grep/args_test.zig"); // rg-compatible argv parser (bundling, no-ops, roots)
    _ = @import("commands/grep/emit.zig");
    _ = @import("commands/ripgrep/run.zig");
    _ = @import("commands/cli/drivers.zig");
}
