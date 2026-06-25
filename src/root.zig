//! gist — fast, agent-friendly code locator kernel (Zig, C-ABI).
//!
//! The engine half of an agent-native grep: a candidate INDEX that turns a
//! whole-tree scan into a scoped lookup, plus (later tiers) sparse-n-gram
//! selection, ranked + token-compressed output, and fusion with an external
//! code graph + contracts. ripgrep is near-optimal at *unindexed* scan; gist's
//! win is at scale (don't rescan) and at *intent* (don't already know the
//! symbol) — see `research/dossiers/locator-sota.dossier.toml`.
//!
//! Package shape mirrors pkg/kernels/core + principia: each tier is a sibling
//! file under `src/`, re-exported here, and surfaced through a FLAT C ABI
//! (no namespaces in C/cffi/cgo) pinned in `include/gist.h`.

const std = @import("std");

pub const ngram = @import("ngram.zig");
pub const trigram = @import("trigram.zig");
pub const regex = @import("regex/core.zig");
pub const regex_syntax = @import("regex/syntax.zig");
pub const regex_dfa = @import("regex/dfa.zig");
pub const rank = @import("rank.zig");

pub const version_string: [:0]const u8 = "0.1.0";

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
    _ = @import("ngram_test.zig"); // n-gram extraction strategy primitives
    _ = @import("trigram_test.zig"); // T0 candidate index: query + serialize + build
    _ = @import("rank_test.zig"); // T4 RRF fusion ranking
    _ = @import("regex/core_test.zig"); // T2 engine: parser + Pike VM + prefilters
    _ = @import("regex/dfa_test.zig"); // byte-class DFA unit + differential fuzz
    _ = @import("regex/powerset_test.zig"); // determinizer structural invariants
}
