//! signet — the mark that proves which bytes these are.
//!
//! One digest (BLAKE3) and one attachment protocol behind every place irregex
//! needs bytes to stay identifiable AFTER the process that wrote them exits:
//! the seal a persisted artifact carries, the identity of a corpus file's
//! contents, the digest of a format's own schema, and the rollup that folds
//! many of those into one.
//!
//! There used to be three answers to that one question — an FNV-1a u64 trailer
//! on the kinship atlas and the fragment atlas, an XxHash64 trailer on the
//! codex, and nothing at all on the two largest blobs (`index.gist` at ~42 MB,
//! `content.shard` at ~215 MB) — each with its own hand-written write/verify
//! pair to keep in step. A 64-bit non-cryptographic checksum over a
//! hundred-megabyte artifact is a coin flip wearing a proof's clothes: FNV-1a
//! in particular avalanches so poorly that a torn write inside a low-entropy
//! region (a run of zeros, a repeated path prefix) is exactly the case most
//! likely to land back on the recorded digest. One 256-bit digest costs the
//! same page walk and actually means something.
//!
//! DOMAIN SEPARATION. Every entry point mixes a unique NUL-terminated label in
//! front of the payload. Labels contain no NUL, so `label ++ payload` is
//! prefix-free and no payload can impersonate another domain's framing — a
//! schema digest can never be accepted as an artifact seal, whatever the bytes.
//!
//! WHAT DOES NOT BELONG HERE. Two other kinds of hashing live in this tree, and
//! moving them here would be a bug, not a cleanup:
//!
//!   * hash-TABLE keys — `std.hash.Wyhash` in the path→doc lookups and the DFA
//!     state-set maps. A slot index wants speed, is never persisted, and
//!     survives a collision by construction: it re-probes and compares the key.
//!   * the LZ78 phrase and winnowing hashes in `kernel/kinship/`. FNV there is
//!     not a checksum, it IS the sketch — phrase identity feeds bottom-k
//!     selection, so swapping the function moves every distance in the corpus
//!     and silently re-grades every answer relate has ever given.
//!
//! A signet is for bytes that OUTLIVE the process and get compared later.

const std = @import("std");

const Blake3 = std.crypto.hash.Blake3;

/// Bytes in a signet — BLAKE3's native 256-bit digest.
pub const len = Blake3.digest_length;

/// The narrowest set this module can fail with. Zig widens it into the persist
/// domain's `fault.Persist` at every call site that has one, so the primitives
/// floor stays dependency-free without inventing a parallel vocabulary.
pub const Error = error{Corrupt};

/// What a digest is ABOUT. Mixed in ahead of the payload, so two roles can
/// never mint the same mark over the same bytes.
pub const Domain = enum {
    /// A persisted blob's own bytes — the seal at its tail.
    artifact,
    /// A corpus file's contents — the identity to reach for when an mtime lies.
    content,
    /// A format's canonical preimage — what kills a cache when meaning changes.
    schema,
    /// A fold over other signets, in an order the caller declares canonical.
    rollup,

    /// NUL-terminated and NUL-free: that is what makes the framing prefix-free.
    fn label(self: Domain) []const u8 {
        return switch (self) {
            .artifact => "irregex/signet/artifact\x00",
            .content => "irregex/signet/content\x00",
            .schema => "irregex/signet/schema\x00",
            .rollup => "irregex/signet/rollup\x00",
        };
    }
};

pub const Signet = extern struct {
    bytes: [len]u8,

    /// The mark of nothing — an unfilled field. No domain can produce it
    /// (BLAKE3 lands on all-zero with probability 2⁻²⁵⁶), so it is sound as an
    /// "absent" sentinel rather than a value that might collide with a real one.
    pub const absent: Signet = .{ .bytes = @splat(0) };

    /// Plain compare, deliberately not `crypto.timing_safe`: a signet is a
    /// public checksum over public bytes, never a secret, and a constant-time
    /// compare here would only advertise a threat model this artifact lacks.
    pub fn eql(self: Signet, other: Signet) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    /// The leading 64 bits — the compact form for a field that must stay narrow
    /// (a log line, an existing u64 slot). Sound for equality across a
    /// corpus-sized population; never the form to persist as an integrity seal.
    pub fn short(self: Signet) u64 {
        return std.mem.readInt(u64, self.bytes[0..8], .little);
    }

    /// Lowercase hex, allocation-free — what `status` prints and `parse` reads.
    pub fn hex(self: Signet) [len * 2]u8 {
        const digits = "0123456789abcdef";
        var out: [len * 2]u8 = undefined;
        for (self.bytes, 0..) |b, i| {
            out[i * 2] = digits[b >> 4];
            out[i * 2 + 1] = digits[b & 0xf];
        }
        return out;
    }

    /// Round-trip `hex`. Strict on length and on case, so a mark that came back
    /// reshaped by something in between fails closed instead of near-matching.
    pub fn parse(text: []const u8) Error!Signet {
        if (text.len != len * 2) return Error.Corrupt;
        var out: Signet = undefined;
        for (&out.bytes, 0..) |*b, i| {
            b.* = (try nibble(text[i * 2]) << 4) | try nibble(text[i * 2 + 1]);
        }
        return out;
    }

    fn nibble(c: u8) Error!u8 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            else => Error.Corrupt,
        };
    }
};

/// The mark of `bytes` in `domain` — the one-shot form.
pub fn of(domain: Domain, bytes: []const u8) Signet {
    var scribe = Scribe.init(domain);
    scribe.update(bytes);
    return scribe.finish();
}

/// A signet built in pieces: for a payload assembled incrementally, and the
/// only way to fold signets into a `.rollup`.
pub const Scribe = struct {
    state: Blake3,

    pub fn init(domain: Domain) Scribe {
        var state = Blake3.init(.{});
        state.update(domain.label());
        return .{ .state = state };
    }

    pub fn update(self: *Scribe, bytes: []const u8) void {
        self.state.update(bytes);
    }

    /// Fold one signet in. Order is significant and the caller owns it — the
    /// corpus rollup walks doc-id order, which `paths.list` already fixes, so
    /// the same tree yields the same mark without anyone sorting anything.
    pub fn push(self: *Scribe, mark: Signet) void {
        self.state.update(&mark.bytes);
    }

    pub fn finish(self: *const Scribe) Signet {
        var out: Signet = undefined;
        self.state.final(&out.bytes);
        return out;
    }
};

// ── the seal: how a signet attaches to a persisted blob ──
//
// A sealed blob is `body ++ signet`, and the seal covers every preceding byte —
// magic, version, header, payload alike. A format gets its whole corruption
// story from two calls, and a new artifact never has to re-derive where the
// checksum lives or what it is supposed to reach.

/// Append the seal over everything written so far.
pub fn sealInto(gpa: std.mem.Allocator, out: *std.ArrayList(u8)) std.mem.Allocator.Error!void {
    const mark = of(.artifact, out.items);
    try out.appendSlice(gpa, &mark.bytes);
}

/// Write the seal over `written` into the `len` bytes that follow it — the
/// fixed-buffer twin of `sealInto`, for a format that sizes its blob up front
/// and fills it by offset instead of appending.
pub fn sealAt(buf: []u8, written: usize) void {
    const mark = of(.artifact, buf[0..written]);
    @memcpy(buf[written..][0..len], &mark.bytes);
}

/// The body of a sealed blob, PROVEN intact. The eager form — reach for it
/// whenever the loader was going to touch every byte anyway.
pub fn unseal(bytes: []const u8) Error![]const u8 {
    const payload = try body(bytes);
    if (!of(.artifact, payload).eql(try declared(bytes))) return Error.Corrupt;
    return payload;
}

/// The body a sealed blob CLAIMS, without paying to verify it.
///
/// This is the deferred half, and the reason sealing is two functions instead
/// of one. `index.gist` and `content.shard` are MAPPED, not read: the entire
/// value of that tier is that a query faults in the handful of pages it touches
/// and never the other quarter-gigabyte. Digesting the blob at load would spend
/// the whole saving to re-prove what the layout validators, the tree binding,
/// and the freshness gate already fail closed on. So a mapped artifact takes
/// its body here and offers `verify` for the moment someone actually asks.
pub fn body(bytes: []const u8) Error![]const u8 {
    if (bytes.len < len) return Error.Corrupt;
    return bytes[0 .. bytes.len - len];
}

/// The seal a blob declares, whether or not it earns it.
pub fn declared(bytes: []const u8) Error!Signet {
    if (bytes.len < len) return Error.Corrupt;
    var out: Signet = undefined;
    @memcpy(&out.bytes, bytes[bytes.len - len ..]);
    return out;
}

/// Prove a sealed blob intact — the half `body` deferred.
pub fn verify(bytes: []const u8) Error!void {
    _ = try unseal(bytes);
}
