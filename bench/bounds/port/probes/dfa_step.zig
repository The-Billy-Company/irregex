//! Layer-B port-optimality probe — the byte-class DFA transition loop.
//!
//! A **byte-faithful copy** of `Dfa.docMatch` in
//! `src/kernel/regex/linear/dfa/dfa.zig`'s non-accelerated path. Its inner loop is the serial
//! per-byte recurrence `s = trans_in[s + class[doc[i]]]`. That recurrence is a
//! loop-carried dependency chain: each transition's address depends on the
//! previous state, so the loop is **latency-bound** (a pointer chase), the
//! opposite of the throughput-bound SIMD filter — which is exactly why both
//! need a static bound.
//!
//! The tables are passed as raw pointers (not a `Dfa`) so the object links with
//! zero Billy dependencies, yet `probes_test.zig` builds a REAL `Dfa` via
//! `Regex.compile`, hands its `trans_in`/`trans_fin`/`class` tables and its
//! `match_hi` bound to this probe, and asserts the probe's verdict is
//! bit-identical to `Dfa.docMatch` over random docs — a true differential drift
//! guard.
//!
//! The match test is a COMPARE, not a load: `freeze.zig` renumbers match states
//! to the front of the id space, so the measured region's dependency chain is the
//! transition load alone. It used to carry a second dependent load (`is_match[s]`)
//! into an array that was `ncls`-sparse by construction.
//!
//! The inner transition body is bracketed for llvm-mca (markers INSIDE the loop
//! body — outside, LLVM's loop cloning strands the END marker and llvm-mca
//! rejects the malformed region nesting). One iteration consumes exactly one
//! byte, so cycles/byte == the region's throughput number (bytes/iter = 1).
//! NOTE: `Block RThroughput` is the PORT-pressure ceiling; because the loop is
//! latency-bound, its real floor is the recurrence latency (the dependent-load
//! chain `s`→`add`→`trans_in[..]`), which the certificate reports separately.

const std = @import("std");

/// Byte-for-byte `Dfa.docMatch` (non-accel path), inner transition step
/// bracketed for llvm-mca. All state tables are caller-owned pointers.
pub export fn portcert_dfa_step(
    doc_ptr: [*]const u8,
    doc_len: usize,
    trans_in_ptr: [*]const u32,
    trans_fin_ptr: [*]const u32,
    class_ptr: [*]const u8, // 256 entries: byte → class column
    match_hi: u32, // matching row offsets are exactly `[0, match_hi)`
    start: u32,
    dead: u32,
    anchored: bool,
    empty_match: bool,
) bool {
    const doc = doc_ptr[0..doc_len];
    const trans_in = trans_in_ptr;
    const trans_fin = trans_fin_ptr;
    const class = class_ptr;

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
        var hit_dead = false;
        while (i < n and doc[i] != '\n') {
            asm volatile ("# LLVM-MCA-BEGIN dfa_step" ::: .{ .memory = true });
            prev = s;
            s = trans_in[s + class[doc[i]]];
            i += 1;
            const m = s < match_hi;
            // Read the loop-carried `s` + the match flag at the END marker so the
            // full transition chain materializes inside the measured region. No
            // `.memory` clobber (see simd_contains): the register operands anchor
            // the chain without forcing spurious spills.
            asm volatile ("# LLVM-MCA-END dfa_step"
                :
                : [s] "r" (s),
                  [m] "r" (m),
                : .{});
            if (m) return true;
            if (anchored and s == dead) {
                if (i < n and doc[i] != '\n') hit_dead = true;
                break;
            }
        }
        if (!hit_dead) {
            s = trans_fin[prev + class[doc[i - 1]]];
            if (s < match_hi) return true;
            if (i < n) i += 1;
        } else {
            while (i < n and doc[i] != '\n') i += 1;
            if (i < n) i += 1;
        }
    }
    return false;
}

/// Bytes consumed per transition-loop iteration: exactly 1 (the loop steps
/// `i += 1`). So cycles/byte for this probe == its per-iteration cycle count.
pub export fn portcert_dfa_bytes_per_iter() usize {
    return 1;
}
