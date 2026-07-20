//! Shared CLI vocabulary — NDJSON / text row emission.
//!
//! Every face's `--json` arm escapes strings and frames rows the same way, so
//! the shapes live here rather than per verb. `jsonStr` is the single escaper
//! (re-exported from the cold emit floor) so all faces escape identically;
//! `jsonRow` frames one object from a comptime field spec and `emitRow` routes
//! text vs JSON off one `json` bool.

const std = @import("std");
const cli_args = @import("../exec/cold/argv/args.zig");

const oom = cli_args.oom;

/// Append `s` JSON-string-escaped (quotes included) — the one escaper every
/// face shares (arg order matches these `(buf, gpa, s)` callers).
pub const jsonStr = @import("../exec/cold/emit/jsonstr.zig").write;

/// One NDJSON result row from a comptime field spec — the shared emitter
/// behind every verb's `--json` arm. Each entry is `.{ "key", kind, value }`
/// with kind `"s"` (escaped string), `"s?"` (escaped string or `null`), or a
/// `std.fmt` spec like `"d:.4"` applied verbatim.
pub fn jsonRow(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, fields: anytype) void {
    inline for (fields, 0..) |f, i| {
        buf.appendSlice(gpa, (if (i == 0) "{\"" else ",\"") ++ f[0] ++ "\":") catch oom();
        if (comptime std.mem.eql(u8, f[1], "s")) {
            jsonStr(buf, gpa, f[2]);
        } else if (comptime std.mem.eql(u8, f[1], "s?")) {
            if (f[2]) |v| jsonStr(buf, gpa, v) else buf.appendSlice(gpa, "null") catch oom();
        } else {
            buf.print(gpa, "{" ++ f[1] ++ "}", .{f[2]}) catch oom();
        }
    }
    buf.appendSlice(gpa, "}\n") catch oom();
}

/// One result row: `--json` routes through `jsonRow`, text prints `tfmt`.
pub fn emitRow(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, json: bool, jfields: anytype, comptime tfmt: []const u8, targs: anytype) void {
    if (json) jsonRow(buf, gpa, jfields) else buf.print(gpa, tfmt, targs) catch oom();
}
