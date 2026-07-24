//! gist — corpus-derived byte density, the anchor-selection heuristic of the
//! SIMD substring kernel (the memchr crate's "rare byte" idea, re-derived
//! from OUR corpus instead of English prose).
//!
//! `density[b]` ≈ `min(255, round(P(byte b) * 32768))` measured over ~300 MB
//! of the Billy tree (text files only, binaries excluded; 2026-07-23). The
//! scan kernel anchors its block filter on the needle's two RAREST bytes,
//! and when the rarest is genuinely rare (`<= single_probe_max`) it probes
//! with ONE load per block, touching the second window only inside probe-hit
//! blocks. Density — not rank position — is what decides that dispatch: rank
//! flattens the wild skew (rank 198 of 255 sounds selective; it's `c` at a
//! 77% per-64B-block hit rate), and probing a dense byte turns the block
//! gate into an unpredictable branch that mispredicts the loop into the
//! ground (measured: single-probing a uniform-random buffer halved
//! throughput; probing `Z` at 1.3% block density raised the corpus scan 14%).
//!
//! Only the coarse ORDERING matters; exact counts don't. Regenerate by
//! byte-counting the tree. Drift shifts which anchors are picked — the eql
//! verify keeps correctness independent of this table.
//!
//! Deliberately a table, not a runtime census: anchor choice must cost a few
//! L1 loads per query, and a statically-known density keeps `indexOfPos`
//! allocation- and IO-free.

/// Ceiling on a probe byte's density for the single-load fast path: ~9% of
/// 64-byte blocks hit (`density 48` ≡ P ≈ 0.15%, block-hit ≈ 1-(1-P)^64).
/// Above it the second anchor loads unconditionally — the branch a dense
/// probe would add costs more than the load it saves.
pub const single_probe_max: u8 = 48;

/// Clamped per-byte corpus probability: `min(255, round(P * 32768))`.
pub const density = [256]u8{
    0,   0,   0,   0,   0,   0,   0,   0,   0,   157, 255, 0,   0,   2,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    255, 13,  233, 50,  13,  64,  20,  27,  255, 255, 99,  19,  255, 240, 255, 255,
    255, 230, 198, 151, 143, 116, 149, 100, 126, 97,  255, 89,  49,  128, 67,  17,
    81,  170, 98,  186, 105, 181, 103, 35,  38,  159, 9,   36,  96,  72,  144, 121,
    120, 12,  119, 255, 195, 80,  45,  43,  35,  20,  7,   47,  21,  45,  3,   255,
    38,  255, 255, 255, 255, 255, 255, 255, 255, 255, 66,  108, 255, 255, 255, 255,
    255, 55,  255, 255, 255, 255, 224, 187, 255, 255, 61,  118, 16,  118, 1,   0,
    3,   0,   0,   1,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   1,
    0,   1,   0,   3,   3,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   1,
    0,   0,   0,   1,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   0,   1,   3,   0,   0,   0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   1,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   7,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    0,   0,   5,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   1,
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
};
