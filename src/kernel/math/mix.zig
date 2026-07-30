//! Hash mixing — the bit-spreading floor under kinship sketches, recall
//! lexicons, and slice-keyed hash maps. Generic sequence math with zero
//! kinship semantics: FNV-1a's constants, the splitmix64 finalizer that
//! spreads an FNV accumulator to bottom-k uniformity, and `SliceCtx`, the
//! HashMap context `std` lacks for slice keys.

const std = @import("std");

pub const fnv_offset: u64 = 0xcbf29ce484222325;
pub const fnv_prime: u64 = 0x100000001b3;

/// splitmix64 finalizer — spreads the FNV accumulator so bottom-k selection
/// sees uniform keys (FNV alone clusters short phrases in the low bits).
pub inline fn finalize(x: u64) u64 {
    var z = x +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

/// Wyhash HashMap context over `[]const T` keys. `std.AutoHashMap` rejects
/// slice keys, so seven automata engines once hand-rolled this identical
/// struct; the generic states the std gap exactly once.
pub fn SliceCtx(comptime T: type) type {
    return struct {
        pub fn hash(_: @This(), k: []const T) u64 {
            return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(k));
        }
        pub fn eql(_: @This(), a: []const T, b: []const T) bool {
            return std.mem.eql(T, a, b);
        }
    };
}
