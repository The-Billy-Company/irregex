//! gist — the CLI executable entrypoint (the `gist` binary).
//!
//!   gist index                 build the index once, persist it to disk
//!   gist query  <needle>       cold-load the index, verify only candidate files
//!   gist regex  <pattern>      same, verified with the Thompson NFA ((?-u) bytes)
//!   gist rank   <needle>       ranked, token-compressed top-K (definition first)
//!   gist grep   [flags] <pat>  ripgrep-compatible `path:line:text` from the index
//!   gist rg     [flags] <pat> [PATH...]   ripgrep-DEFAULT drop-in over a live tree
//!
//! This is the thin dispatch shell only: every verb's real work lives in the
//! engine + command modules, reached through the `gist` module (`commands.cli`
//! for the cold index drivers, `commands.grep` for the index-backed grep verb,
//! `commands.ripgrep` for the arbitrary-tree drop-in). The bench/verify/certify
//! harness is a *separate* executable (`bench/bench.zig`) — production CLI and
//! benchmark tooling no longer share a binary.

const std = @import("std");
const gist = @import("gist");

const cli = gist.commands.cli; // index / query / regex / rank drivers
const grep = gist.commands.grep; // index-backed `grep` verb
const ripgrep = gist.commands.ripgrep; // ripgrep-default drop-in
const default_roots = gist.corpus.default_roots;

fn usage() void {
    std.debug.print(
        \\gist — fast, agent-friendly code locator
        \\
        \\usage: gist <command> [args]
        \\  index                build + persist the trigram index
        \\  query  <needle>      cold-load + verify candidate files (exact substring)
        \\  regex  <pattern>     same, verified with the Thompson NFA ((?-u) bytes)
        \\  rank   <needle>      ranked top-K (a symbol's definition outranks its uses)
        \\  grep   [flags] <pat> ripgrep-compatible `path:line:text` from the index
        \\  rg     [flags] <pat> [PATH...]   ripgrep-default drop-in over a live tree
        \\
    , .{});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip(); // argv[0]
    const mode = it.next() orelse {
        usage();
        return;
    };

    if (std.mem.eql(u8, mode, "index")) {
        try cli.runIndex(gpa, io, &default_roots);
        return;
    }
    if (std.mem.eql(u8, mode, "query")) {
        const needle = it.next() orelse {
            std.debug.print("usage: gist query <needle>\n", .{});
            return;
        };
        try cli.runQuery(gpa, io, needle);
        return;
    }
    if (std.mem.eql(u8, mode, "regex")) {
        const pattern = it.next() orelse {
            std.debug.print("usage: gist regex <pattern>\n", .{});
            return;
        };
        try cli.runRegex(gpa, io, pattern);
        return;
    }
    if (std.mem.eql(u8, mode, "rank")) {
        const needle = it.next() orelse {
            std.debug.print("usage: gist rank <needle>\n", .{});
            return;
        };
        try cli.runRank(gpa, io, needle);
        return;
    }
    // `grep [flags] <pattern>` — the agent's `rg -n --no-heading`: emit every
    // matching line as `path:line:text`, served from the index. One engine for
    // literal + regex; full flag surface parsed by `grep.parseGrep`.
    if (std.mem.eql(u8, mode, "grep")) {
        var rest: std.ArrayList([]const u8) = .empty;
        defer rest.deinit(gpa);
        while (it.next()) |arg| try rest.append(gpa, arg);
        var parsed = (try grep.parseGrep(gpa, rest.items)) orelse return;
        defer parsed.deinit(gpa);
        try grep.runGrep(gpa, io, parsed.pattern, parsed.opts);
        return;
    }
    // `rg [flags] <pattern> [PATH...]` — the ripgrep-DEFAULT drop-in over an
    // arbitrary directory tree (distinct from `grep`'s monorepo-index contract):
    // rg presentation (filename iff recursive/multi-file, line numbers off unless
    // -n, rg exit codes), the substrate for the ripgrep-suite differential proof.
    if (std.mem.eql(u8, mode, "rg")) {
        var rest: std.ArrayList([]const u8) = .empty;
        defer rest.deinit(gpa);
        while (it.next()) |arg| try rest.append(gpa, arg);
        try ripgrep.run(gpa, io, rest.items);
        return;
    }

    std.debug.print("unknown command: {s}\n\n", .{mode});
    usage();
}
