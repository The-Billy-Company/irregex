//! One JSON string escaper for every irregex face that writes JSON/NDJSON.
//!
//! `rg --json` (emit/json.zig), the relate/irregex NDJSON verb rows
//! (cli/relate/kinship.zig, re-exported as `jsonStr`), and the gist `--schema`
//! manifest all need the identical operation: append a byte slice as a JSON
//! string literal, surrounding quotes included. They used to carry three
//! near-copies that had quietly diverged — the schema one emitted RAW control
//! bytes (invalid JSON), the relate one lacked the `\b`/`\f` short forms — so
//! this is the single source of truth they now share.
//!
//! The escaping is serde_json's / ripgrep's exact discipline (the strictest
//! master, `rg --json` byte-parity): `"` and `\` backslash-escaped; the five C0
//! short forms `\b \t \n \f \r`; every other control (`< 0x20`) as `\u00XX`;
//! valid multi-byte UTF-8 passes through raw (callers that may hold invalid
//! UTF-8 gate to base64 upstream — see emit/json.jsonData). OOM is fatal, the
//! CLI output contract.

const std = @import("std");
const oom = @import("../argv/args.zig").oom;

/// Append `s` to `out` as a JSON string literal, surrounding quotes included.
/// Argument order matches the relate face's `(buf, gpa, s)` convention so
/// `kinship.jsonStr` re-exports this directly.
pub fn write(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) void {
    out.append(gpa, '"') catch oom();
    for (s) |c| switch (c) {
        '"' => out.appendSlice(gpa, "\\\"") catch oom(),
        '\\' => out.appendSlice(gpa, "\\\\") catch oom(),
        0x08 => out.appendSlice(gpa, "\\b") catch oom(),
        '\t' => out.appendSlice(gpa, "\\t") catch oom(),
        '\n' => out.appendSlice(gpa, "\\n") catch oom(),
        0x0C => out.appendSlice(gpa, "\\f") catch oom(),
        '\r' => out.appendSlice(gpa, "\\r") catch oom(),
        else => if (c < 0x20)
            out.print(gpa, "\\u{x:0>4}", .{c}) catch oom()
        else
            out.append(gpa, c) catch oom(),
    };
    out.append(gpa, '"') catch oom();
}

const t = std.testing;

test "write: quotes, backslashes, and every C0 short form escape correctly" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.allocator);
    write(&buf, t.allocator, "a\"b\\c\n\t\r\x08\x0c");
    try t.expectEqualStrings("\"a\\\"b\\\\c\\n\\t\\r\\b\\f\"", buf.items);
}

test "write: other controls become \\u00XX; UTF-8 passes through raw" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.allocator);
    write(&buf, t.allocator, "\x01\x1f\u{00e9}");
    try t.expectEqualStrings("\"\\u0001\\u001f\u{00e9}\"", buf.items);
}
