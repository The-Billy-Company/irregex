//! Signet unit tests — the four properties every persisted seal leans on:
//! that the digest really is BLAKE3, that domains cannot bleed into each other,
//! that a sealed blob detects the corruption shapes a torn write actually makes,
//! and that a rollup is reproducible from a declared order.
//!
//! Expectations are derived from the CONTRACT (the published BLAKE3 vector, the
//! documented `label ++ payload` framing, the labels themselves), never from
//! re-running the module and pinning whatever fell out.

const std = @import("std");
const testing = std.testing;
const signet = @import("signet.zig");

/// The published BLAKE3 test vector for the empty input. Pinning it proves the
/// primitive underneath really is BLAKE3 — if std ever swapped implementations
/// or we reached for the wrong hash, every persisted seal in the tree would
/// change meaning and this is the line that says so.
const blake3_of_empty = "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262";

test "the primitive underneath is BLAKE3" {
    var raw: [signet.len]u8 = undefined;
    std.crypto.hash.Blake3.hash("", &raw, .{});
    const mark = signet.Signet{ .bytes = raw };
    try testing.expectEqualStrings(blake3_of_empty, &mark.hex());
}

test "a domain label is part of the contract, not an implementation detail" {
    // Changing a label silently invalidates every artifact already on disk, so
    // the exact framing is pinned here rather than left to whatever the code
    // happens to do this week.
    const payload = "the quick brown fox";
    var expected: [signet.len]u8 = undefined;
    var h = std.crypto.hash.Blake3.init(.{});
    h.update("irregex/signet/artifact\x00");
    h.update(payload);
    h.final(&expected);
    try testing.expect(signet.of(.artifact, payload).eql(.{ .bytes = expected }));
}

test "domains separate, and a payload cannot forge another domain's framing" {
    const payload = "same bytes, four meanings";
    const marks = [_]signet.Signet{
        signet.of(.artifact, payload),
        signet.of(.content, payload),
        signet.of(.schema, payload),
        signet.of(.rollup, payload),
    };
    for (marks, 0..) |a, i| for (marks[i + 1 ..]) |b| try testing.expect(!a.eql(b));

    // The adverse case the NUL is there for: a payload that OPENS with another
    // domain's label must not hash to that domain's mark over the remainder.
    // Without prefix-free framing these two are the same byte stream.
    const smuggled = "irregex/signet/content\x00" ++ payload;
    try testing.expect(!signet.of(.artifact, smuggled).eql(signet.of(.content, payload)));
}

test "a seal round-trips and the empty body is still a body" {
    const gpa = testing.allocator;
    for ([_][]const u8{ "", "x", "package main\n" }) |payload| {
        var blob: std.ArrayList(u8) = .empty;
        defer blob.deinit(gpa);
        try blob.appendSlice(gpa, payload);
        try signet.sealInto(gpa, &blob);

        try testing.expectEqual(payload.len + signet.len, blob.items.len);
        try testing.expectEqualStrings(payload, try signet.unseal(blob.items));
        try signet.verify(blob.items);
        // The deferred half must agree with the eager one, byte for byte.
        try testing.expectEqualStrings(payload, try signet.body(blob.items));
    }
}

test "a seal catches the corruption shapes a torn write actually makes" {
    const gpa = testing.allocator;
    // Low-entropy, highly repetitive: the region where a weak checksum is most
    // likely to land back on its own recorded value, and the shape a truncated
    // or half-flushed artifact really has.
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(gpa);
    for (0..64) |_| try blob.appendSlice(gpa, "src/corpus/index/frame/x\x00\x00\x00\x00");
    const body_len = blob.items.len;
    try signet.sealInto(gpa, &blob);
    try signet.verify(blob.items);

    // One flipped bit anywhere in the body.
    for ([_]usize{ 0, 1, body_len / 2, body_len - 1 }) |i| {
        blob.items[i] ^= 0x01;
        try testing.expectError(error.Corrupt, signet.unseal(blob.items));
        blob.items[i] ^= 0x01;
    }

    // A tampered seal is corruption too — the seal is not exempt from itself.
    blob.items[body_len] ^= 0x80;
    try testing.expectError(error.Corrupt, signet.unseal(blob.items));
    blob.items[body_len] ^= 0x80;

    // Truncation must fail rather than silently re-reading the last 32 body
    // bytes as a seal, which is exactly what a length-blind reader would do.
    try testing.expectError(error.Corrupt, signet.unseal(blob.items[0 .. blob.items.len - 1]));

    // Shorter than a seal is not "an empty body", it is a corrupt blob.
    try testing.expectError(error.Corrupt, signet.unseal(blob.items[0..signet.len -| 1]));
    try testing.expectError(error.Corrupt, signet.body(""));
    try testing.expectError(error.Corrupt, signet.declared("short"));
}

test "sealAt matches sealInto for a format that fills by offset" {
    const gpa = testing.allocator;
    const payload = "GISTIDX\x01directory and body";

    var appended: std.ArrayList(u8) = .empty;
    defer appended.deinit(gpa);
    try appended.appendSlice(gpa, payload);
    try signet.sealInto(gpa, &appended);

    const buf = try gpa.alloc(u8, payload.len + signet.len);
    defer gpa.free(buf);
    @memcpy(buf[0..payload.len], payload);
    signet.sealAt(buf, payload.len);

    try testing.expectEqualSlices(u8, appended.items, buf);
}

test "a rollup is reproducible from a declared order, and order is load-bearing" {
    const marks = [_]signet.Signet{
        signet.of(.content, "doc 0"),
        signet.of(.content, "doc 1"),
        signet.of(.content, "doc 2"),
    };

    var forward = signet.Scribe.init(.rollup);
    for (marks) |m| forward.push(m);

    var again = signet.Scribe.init(.rollup);
    for (marks) |m| again.push(m);
    try testing.expect(forward.finish().eql(again.finish()));

    // Doc-id order is the canonical order; a walk that shuffled two entries
    // produced a different corpus, and the mark has to say so.
    var swapped = signet.Scribe.init(.rollup);
    for ([_]usize{ 1, 0, 2 }) |i| swapped.push(marks[i]);
    try testing.expect(!forward.finish().eql(swapped.finish()));

    // A rollup is not the digest of the concatenated marks in another domain.
    var flat = signet.Scribe.init(.content);
    for (marks) |m| flat.push(m);
    try testing.expect(!forward.finish().eql(flat.finish()));
}

test "hex round-trips and rejects anything reshaped in transit" {
    const mark = signet.of(.schema, "format-version/u16le\x00\x02\x00");
    const text = mark.hex();
    try testing.expect((try signet.Signet.parse(&text)).eql(mark));

    var upper = text;
    for (&upper) |*c| c.* = std.ascii.toUpper(c.*);
    // Only one spelling is canonical; a case-folded mark is a mark that passed
    // through something that did not treat it as opaque bytes.
    if (!std.mem.eql(u8, &upper, &text)) try testing.expectError(error.Corrupt, signet.Signet.parse(&upper));

    try testing.expectError(error.Corrupt, signet.Signet.parse(text[0 .. text.len - 1]));
    try testing.expectError(error.Corrupt, signet.Signet.parse(""));
    var bad = text;
    bad[7] = 'z';
    try testing.expectError(error.Corrupt, signet.Signet.parse(&bad));
}

test "short is the leading 64 bits, and absent is unreachable" {
    const mark = signet.of(.content, "a corpus file");
    try testing.expectEqual(std.mem.readInt(u64, mark.bytes[0..8], .little), mark.short());
    // `absent` is a sentinel precisely because no domain can mint it.
    for ([_][]const u8{ "", "x", "a corpus file" }) |b|
        try testing.expect(!signet.of(.content, b).eql(signet.Signet.absent));
}
