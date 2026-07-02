//! gist — the CLI executable entrypoint (the `gist` binary).
//!
//! Three real verbs — what gist DOES, not which competitor's argv it apes:
//!
//!   gist index                        build + persist the trigram index
//!   gist status                       read-only: is an index ready, how fresh, how big
//!   gist search <pattern> [PATH...]    the one search verb (shape is a flag)
//!
//! Plus three top-level introspection flags (convention, like `--help`, so the
//! verb list stays at three): `--help`, `--version`, `--schema` (a JSON
//! capability manifest for agents/codegen). The `search` shape is chosen by flag
//! — `--show lines|files|count|ranked`, `--rank`, `--json` — not a different verb,
//! collapsing the old `query`/`regex`/`rank`/`grep` quartet into one.
//!
//! This is the thin dispatch shell only: every verb's real work lives in the
//! engine + command modules, reached through the `gist` module (`commands.search`
//! for index+search, `commands.status` for introspection, `commands.schema` for
//! the manifest). The internal `rg` differential-parity drop-in stays reachable
//! for the rgsuite harness but is DELIBERATELY undocumented — it is harness
//! plumbing, not a public verb. The bench/verify/certify harness is a separate
//! executable (`bench/bench.zig`).

const std = @import("std");
const gist = @import("gist");

const search = gist.commands.search; // index + the one `search` verb
const status = gist.commands.status; // read-only index introspection
const schema = gist.commands.schema; // `--schema` JSON manifest
const ripgrep = gist.commands.ripgrep; // internal rgsuite parity drop-in (undocumented)
const default_roots = gist.corpus.default_roots;

fn usage() void {
    std.debug.print(
        \\gist — fast, agent-friendly code locator
        \\
        \\usage: gist <command> [args]
        \\  index                        build + persist the trigram index
        \\  status                       is an index ready, how fresh, how big
        \\  search <pattern> [PATH...]   find matches (shape via --show/--rank/--json)
        \\
        \\  gist search --help           the full search flag surface (native + legacy)
        \\  gist --schema                a JSON capability manifest for agents
        \\  gist --version
        \\
    , .{});
}

fn searchHelp() void {
    std.debug.print(
        \\usage: gist search <pattern> [PATH...] [flags]
        \\
        \\  --show <ranked|lines|files|count>   output shape (default: lines)
        \\  --rank [=N]                         shorthand for --show ranked (top N, default 20)
        \\  --lang <name>   --glob <pattern>    scope by language / path glob
        \\  --word  --fixed  --ignore-case  --smart-case  --invert
        \\  --before N  --after N  --context N
        \\  --limit N  --spans  --replace <template>  --only-matching
        \\  --live                              skip the index, scan the tree fresh
        \\  --json                              structured output instead of path:line:text
        \\  --pattern <pat>   --files   --      explicit pattern / list files / end of flags
        \\
        \\Legacy / ripgrep-compatible aliases (accepted, not the primary spelling):
        \\  -l -c -v -i -w -F -o -n -N -S -m -e -t -g -r -A -B -C
        \\  --files-with-matches --count --count-matches --invert-match --word-regexp ...
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

    // Top-level introspection flags (convention, not verbs).
    if (std.mem.eql(u8, mode, "--help") or std.mem.eql(u8, mode, "-h")) {
        usage();
        return;
    }
    if (std.mem.eql(u8, mode, "--version") or std.mem.eql(u8, mode, "-V")) {
        std.debug.print("gist {s}\n", .{gist.version_string});
        return;
    }
    if (std.mem.eql(u8, mode, "--schema")) {
        schema.emit();
        return;
    }

    if (std.mem.eql(u8, mode, "index")) {
        try search.runIndex(gpa, io, &default_roots);
        return;
    }
    if (std.mem.eql(u8, mode, "status")) {
        try status.run(gpa, io);
        return;
    }
    // `search <pattern> [PATH...] [flags]` — the one search verb. Shape (lines /
    // files / count / ranked), freshness (--live), and structure (--json) are all
    // flags; `search.runSearch` parses them (native Set B + legacy Set A) and
    // dispatches to the fastest correct engine.
    if (std.mem.eql(u8, mode, "search")) {
        var rest: std.ArrayList([]const u8) = .empty;
        defer rest.deinit(gpa);
        while (it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                searchHelp();
                return;
            }
            try rest.append(gpa, arg);
        }
        try search.runSearch(gpa, io, rest.items);
        return;
    }
    // `rg [flags] <pattern> [PATH...]` — the INTERNAL ripgrep-default drop-in that
    // backs the rgsuite differential-parity certificate (441 mined `rg`-argv
    // replays). Reachable so `bench/rgsuite/run.py` keeps working, but omitted
    // from `usage()`/`--schema`: it is harness plumbing, not a public gist verb.
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
