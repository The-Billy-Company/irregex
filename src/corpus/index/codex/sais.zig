//! sais — the suffix array the codex self-index is built on.
//!
//! Suffix array by induced sorting (Nong, Zhang & Chan, *Two Efficient
//! Algorithms for Linear Time Suffix Array Construction*, IEEE ToC 2011): the
//! O(n) construction that keeps the FM-index pipeline linear. The sort itself
//! is libsais — the fastest open SA-IS in the field, pinned and compiled from
//! source under `vendor/libsais/` — and this module is the seam that makes its
//! answer the codex's answer.
//!
//! The seam is one fact wide. libsais sorts the n suffixes of the raw bytes;
//! the codex indexes n+1 symbols, because it lifts each byte to c+1 and appends
//! a unique smallest sentinel 0 so that all 256 byte values — NUL included —
//! are ordinary corpus content. That sentinel is strictly smaller than every
//! lifted byte, so its suffix is unconditionally rank 0 and every other suffix
//! keeps the order libsais already computed:
//!
//!     sa[0]  = text.len          the sentinel suffix, first by construction
//!     sa[1..] = libsais(text)    shifted by exactly one row, never re-sorted
//!
//! No transform, no copy: the tail is handed to libsais as the destination
//! buffer, so the lift the codex reasons about costs one stored word. The
//! identity is checked on every build by `codex_test.zig`'s comparison-sort
//! oracle, and was verified row-for-row against the previous hand-rolled SA-IS
//! over a 200 MB corpus (209,715,201 rows, exact) before that one was retired.
//!
//! libsais is compiled without OpenMP (see `vendor/libsais/README.md`), so this
//! is the serial constructor: 3.3× the hand-rolled implementation it replaced at
//! 200 MB, which drops the sort from 74% of a codex build to 46%. That is not
//! enough to make the shelf default-on — the remaining floor is the wavelet/RRR
//! construction and the serialize, measured in this package's README.

const std = @import("std");
const fault = @import("../../../fault.zig");

/// Largest corpus this constructor can address. libsais indexes suffixes with
/// `int32_t`, so the ceiling is a property of the sort, not of the codex —
/// declared here rather than discovered as a truncated index. It is ~10× the
/// largest corpus the shelf has been built over; a tree that outgrows it wants
/// a sharded shelf, not a wider integer.
pub const max_text_len: usize = std.math.maxInt(i32);

/// libsais 2.10.2, bound with explicit `extern` rather than `@cImport` (the
/// house convention — see `kernel/match/regex/pcre2/ffi.zig`) so no module
/// needs the vendored include path. `SA` must hold `n + fs` entries; `fs` is
/// scratch libsais may borrow past the end, and upstream documents 0 as enough
/// for the plain suffix-array entry. Returns 0, or -1 for rejected arguments
/// and -2 for an internal allocation failure.
///
/// `SA` is `int32_t *` upstream and is bound here as `[*]u32` — the same
/// pointer to the same four-byte cells, declared at the signedness of the
/// values that survive the call. libsais parks negative markers in that buffer
/// mid-sort, but nothing reads it until the call returns and every row it
/// leaves behind is a position in `[0, n)`. Naming the out-parameter unsigned
/// is what lets the codex's `[]u32` be handed over directly, with no reinterpret
/// at the seam and no second array to convert through.
extern fn libsais(T: [*]const u8, SA: [*]u32, n: i32, fs: i32, freq: ?[*]i32) i32;

/// Suffix array of `text` + sentinel: `sa` of length `text.len + 1` over the
/// shifted alphabet (byte c ↦ c+1, sentinel 0), with `sa[0] == text.len`.
/// Caller frees.
///
/// Fails with `Oversized` above `max_text_len` and `OutOfMemory` if either this
/// allocation or libsais's own internal one is refused.
pub fn build(gpa: std.mem.Allocator, text: []const u8) (fault.Resource || error{Oversized})![]u32 {
    if (text.len > max_text_len) return error.Oversized;
    const sa = try gpa.alloc(u32, text.len + 1);
    errdefer gpa.free(sa);
    sa[0] = @intCast(text.len); // the sentinel suffix, smaller than every lifted byte
    if (text.len == 0) return sa; // libsais rejects the empty text's null pointer

    const rc = libsais(text.ptr, sa[1..].ptr, @intCast(text.len), 0, null);
    if (rc != 0) {
        // -2 is libsais's own allocation failure. -1 is argument rejection,
        // which the guards above exclude — assert it loudly where asserts live,
        // and still fail closed in a release build rather than return a
        // half-sorted array.
        std.debug.assert(rc == -2);
        return error.OutOfMemory;
    }
    return sa;
}
