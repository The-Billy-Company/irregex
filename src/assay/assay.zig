//! assay — the package's instrumentation floor: timing, counters, diagnostics.
//!
//! An *assay* is a precise measurement of composition. This module is the single
//! import (`const assay = @import(".../assay/assay.zig")`) every call site that
//! times, counts, or reports reaches for, so those three concerns share one
//! deliberately-shaped vocabulary instead of ~90 hand-rolled `std.debug.print`
//! sites, ~25 open-coded `nowNs`/`ms` pairs, and several near-duplicate tally
//! structs. It sits at the bottom of the package DAG (imports only `std`), so
//! `kernel/`, `corpus/`, and `surface/` all consume it without inversion.
//!
//! Three axes, three sibling files, re-exported here:
//!   * time  → `span.zig`     — `Span`/`Duration` (monotonic) vs `Anchor` (wall),
//!                              made non-interchangeable at the type level.
//!   * count → `tally.zig`    — `Tally(Schema)`, one comptime-checked counter set.
//!   * debug → `channel.zig`  — the env vocabulary, the lens gate, and the
//!                              thread-local sink every diagnostic routes through.
//!
//! `Run` (below) is the ergonomic layer over the channel for the ~15 verb
//! summary lines: it opens a `Span` and emits one line that is byte-identical to
//! the former `debug.print` in text mode, or a single NDJSON record in `--json`
//! mode — so an agent parsing `gist --json` gets machine-readable timing and
//! counts on stderr instead of English prose.

const std = @import("std");

// ── time ──
const span_mod = @import("span.zig");
pub const Span = span_mod.Span;
pub const Duration = span_mod.Duration;
pub const Anchor = span_mod.Anchor;
pub const anchor = span_mod.anchor;

// ── count ──
pub const Tally = @import("tally.zig").Tally;

// ── debug ──
const channel = @import("channel.zig");
pub const Lens = channel.Lens;
pub const Sink = channel.Sink;
pub const Policy = channel.Policy;
pub const install = channel.install;
pub const scope = channel.scope;
pub const lit = channel.lit;
pub const diag = channel.diag;
pub const trace = channel.trace;
pub const envSpan = channel.envSpan;
pub const envFalsy = channel.envFalsy;
pub const envUsize = channel.envUsize;
pub const envFlag = channel.envFlag;

/// One diagnostic summary line, bound to a `Span` (opened at construction) and
/// the verb's `--json` flag. `emit` renders it as text (byte-identical to the
/// former `std.debug.print`) or as one NDJSON record, routed through the channel
/// sink. `elapsed` returns the typed `Duration` the caller formats inline.
pub const Run = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    span: Span,
    json: bool,

    /// Open a run and start its clock.
    pub fn open(gpa: std.mem.Allocator, io: std.Io, json: bool) Run {
        return .{ .gpa = gpa, .io = io, .span = Span.open(io), .json = json };
    }

    /// Elapsed since `open` — the monotonic `Duration` for the timing clause.
    pub fn elapsed(self: Run) Duration {
        return self.span.read(self.io);
    }

    /// The `Duration` since the last lap (or `open`), then restart the clock —
    /// for verbs whose summary reports a phase split (e.g. `index … · query …`).
    pub fn lap(self: *Run) Duration {
        return self.span.lap(self.io);
    }

    /// Emit the summary. Text mode prints `text_fmt`/`text_args` verbatim; NDJSON
    /// mode (a `--json` run, or `GIST_TRACE_FORMAT=json`) emits one record from
    /// `json_fields` — each entry `.{ "key", kind, value }` with kind `"s"`
    /// (escaped string), `"s?"` (escaped string or null), or a `std.fmt` spec
    /// like `"d"`/`"d:.1"`. The caller passes the same numbers to both arms, so
    /// the two renderings carry identical information.
    pub fn emit(self: Run, comptime text_fmt: []const u8, text_args: anytype, json_fields: anytype) void {
        summary(self.gpa, self.json, text_fmt, text_args, json_fields);
    }
};

/// The span-free emit primitive `Run.emit` delegates to: render one summary as
/// `text_fmt`/`text_args` (text mode, byte-identical to the former
/// `std.debug.print`) or as one NDJSON record from `json_fields`, routed through
/// the channel sink. For verbs that own bespoke multi-span timing (e.g. the
/// ranked engine's separate cold-load and rank spans) and so can't be bound to a
/// single `Run` clock — everyone else reaches for `Run`.
pub fn summary(gpa: std.mem.Allocator, json: bool, comptime text_fmt: []const u8, text_args: anytype, json_fields: anytype) void {
    if (!channel.jsonFormat(json)) return channel.diag(text_fmt, text_args);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    jsonRecord(&buf, gpa, json_fields);
    channel.diag("{s}", .{buf.items});
}

/// Build one NDJSON diagnostic record `{"k":v,…}\n` from a comptime field spec.
/// Assay owns this small escaper for its own stderr diagnostic stream, distinct
/// from `surface/cli/emit.zig`'s result-row emitter (stdout) — the two serve
/// different streams and keeping assay dependency-free (std only) preserves the
/// package DAG. Best-effort: an OOM drops the record rather than crashing a
/// diagnostic.
fn jsonRecord(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, fields: anytype) void {
    inline for (fields, 0..) |f, i| {
        buf.appendSlice(gpa, (if (i == 0) "{\"" else ",\"") ++ f[0] ++ "\":") catch return;
        if (comptime std.mem.eql(u8, f[1], "s")) {
            appendJsonString(buf, gpa, f[2]);
        } else if (comptime std.mem.eql(u8, f[1], "s?")) {
            if (f[2]) |v| appendJsonString(buf, gpa, v) else buf.appendSlice(gpa, "null") catch return;
        } else {
            buf.print(gpa, "{" ++ f[1] ++ "}", .{f[2]}) catch return;
        }
    }
    buf.appendSlice(gpa, "}\n") catch return;
}

/// Append `s` as a JSON string literal (quotes included), escaping the seven
/// characters JSON requires plus C0 controls as `\u00XX`.
fn appendJsonString(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) void {
    buf.append(gpa, '"') catch return;
    for (s) |c| switch (c) {
        '"' => buf.appendSlice(gpa, "\\\"") catch return,
        '\\' => buf.appendSlice(gpa, "\\\\") catch return,
        '\n' => buf.appendSlice(gpa, "\\n") catch return,
        '\r' => buf.appendSlice(gpa, "\\r") catch return,
        '\t' => buf.appendSlice(gpa, "\\t") catch return,
        0x08 => buf.appendSlice(gpa, "\\b") catch return,
        0x0c => buf.appendSlice(gpa, "\\f") catch return,
        else => if (c < 0x20)
            buf.print(gpa, "\\u{x:0>4}", .{c}) catch return
        else
            buf.append(gpa, c) catch return,
    };
    buf.append(gpa, '"') catch return;
}

test {
    _ = @import("span.zig");
    _ = @import("tally.zig");
    _ = @import("channel.zig");
}

test "Run.emit text mode is byte-identical to a debug.print line" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const sc = scope(.{ .buffer = .{ .list = &buf, .gpa = gpa } });
    defer sc.end();

    // io/span are unread in text mode; construct directly to avoid opening a
    // span against an undefined clock.
    const run = Run{ .gpa = gpa, .io = undefined, .span = .{ .start = 0 }, .json = false };
    run.emit("similar: {d} sketches · {s}\n", .{ 12, "atlas" }, .{
        .{ "sketches", "d", @as(usize, 12) },
        .{ "source", "s", "atlas" },
    });
    try std.testing.expectEqualStrings("similar: 12 sketches · atlas\n", buf.items);
}

test "Run.emit json mode escapes and frames a record" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const sc = scope(.{ .buffer = .{ .list = &buf, .gpa = gpa } });
    defer sc.end();

    const run = Run{ .gpa = gpa, .io = undefined, .span = .{ .start = 0 }, .json = true };
    run.emit("ignored text\n", .{}, .{
        .{ "verb", "s", "quo\"te" },
        .{ "n", "d", @as(usize, 3) },
    });
    try std.testing.expectEqualStrings("{\"verb\":\"quo\\\"te\",\"n\":3}\n", buf.items);
}
