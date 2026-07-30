//! Layer-B port-optimality probe — the byte-INDEXED DFA transition loop.
//!
//! The sibling of `dfa_step.zig`, and the pair is the point. Both walk the same
//! automaton over the same document and return the same boolean; they differ in
//! exactly one instruction, because they index different layouts of the same
//! tables:
//!
//!   * `dfa_step`   — `s = trans_in[s + class[doc[i]]]`, the **classed** tables.
//!     Three loads per byte, and two of them are dependent: the document byte
//!     feeds `class[..]`, whose result feeds the address of `trans_in[..]`.
//!   * this probe    — `s = trans_in[s + doc[i]]`, the **byte-indexed mirror**
//!     (`Dfa.Wide`). The class column is folded into the row at freeze time, so
//!     the byte indexes a 256-wide row directly. Two loads per byte, and the
//!     recurrence's dependent chain is one link shorter.
//!
//! `Dfa.docMatch` steps the mirror whenever the automaton has one, so this is
//! the recurrence the shipped document walk actually runs; `dfa_step` bounds the
//! classed recurrence every other DFA consumer still runs. Layer B needs both:
//! removing a link from a loop-carried dependency chain is precisely the kind of
//! change whose payoff a latency bound predicts and a throughput bound cannot.
//!
//! Neither probe is the shipped walk's *whole* body — `docMatch` bursts four
//! lines in lockstep to overlap four independent copies of this chain. That is a
//! deliberate scope choice: Layer B bounds the recurrence, and the recurrence is
//! what the mirror changed. The lane count's effect is a measured throughput
//! question, answered by `bench/rungs/automata -- burst`.
//!
//! Tables arrive as raw pointers (not a `Dfa`) so the object links with zero
//! Billy dependencies, yet `probes_test.zig` builds a REAL `Dfa` via
//! `Regex.compile`, hands over its `wide` mirror's tables and bound, and asserts
//! this probe's verdict is bit-identical to `Dfa.docMatch` — a true differential
//! drift guard rather than an oracle.
//!
//! The inner transition body is bracketed for llvm-mca (markers INSIDE the loop
//! body — outside, LLVM's loop cloning strands the END marker and llvm-mca
//! rejects the malformed region nesting). One iteration consumes exactly one
//! byte, so cycles/byte == the region's throughput number (bytes/iter = 1).
//! NOTE: `Block RThroughput` is the PORT-pressure ceiling; because the loop is
//! latency-bound, its real floor is the recurrence latency (the dependent-load
//! chain `s`→`add`→`trans_in[..]`), which the certificate reports separately.

const std = @import("std");

/// Row stride of the byte-indexed mirror — the whole byte alphabet, unclassed.
/// Mirrors `Dfa.Wide.stride`; asserted equal in `probes_test.zig`.
pub const stride = 256;

/// `Dfa.docMatch` over a `Dfa.Wide` mirror, inner transition step bracketed for
/// llvm-mca. All state tables are caller-owned pointers. `match_hi` and `start`
/// are the MIRROR's (premultiplied by `stride`, not by `ncls`) — the one place
/// the two layouts' offsets are not interchangeable.
pub export fn portcert_dfa_mirror(
    doc_ptr: [*]const u8,
    doc_len: usize,
    trans_in_ptr: [*]const u32,
    trans_fin_ptr: [*]const u32,
    match_hi: u32, // matching row offsets are exactly `[0, match_hi)`
    start: u32,
    empty_match: bool,
) bool {
    const doc = doc_ptr[0..doc_len];
    const trans_in = trans_in_ptr;
    const trans_fin = trans_fin_ptr;

    const n = doc.len;
    var i: usize = 0;
    while (i < n) {
        if (doc[i] == '\n') {
            if (empty_match) return true;
            i += 1;
            continue;
        }
        var s = start;
        if (s < match_hi) return true;
        var prev = s;
        while (i < n and doc[i] != '\n') {
            asm volatile ("# LLVM-MCA-BEGIN dfa_mirror" ::: .{ .memory = true });
            prev = s;
            s = trans_in[s + doc[i]];
            i += 1;
            const m = s < match_hi;
            // Read the loop-carried `s` + the match flag at the END marker so the
            // full transition chain materializes inside the measured region. No
            // `.memory` clobber (see simd_contains): the register operands anchor
            // the chain without forcing spurious spills.
            asm volatile ("# LLVM-MCA-END dfa_mirror"
                :
                : [s] "r" (s),
                  [m] "r" (m),
                : .{});
            if (m) return true;
        }
        s = trans_fin[prev + doc[i - 1]];
        if (s < match_hi) return true;
        if (i < n) i += 1;
    }
    return false;
}

/// Bytes consumed per transition-loop iteration: exactly 1 (the loop steps
/// `i += 1`). So cycles/byte for this probe == its per-iteration cycle count.
pub export fn portcert_dfa_mirror_bytes_per_iter() usize {
    return 1;
}
