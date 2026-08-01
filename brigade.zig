//! brigade — the shard-aware unit-test runner, shared by this package and by
//! the sibling packages built on it (`gist`, `relate`) through their existing
//! dependency on `irregex`.
//!
//! It lives here rather than in a build-tooling package of its own because it
//! has exactly one consumer set and they all already depend on this one. A
//! separate package would have bought nothing but a fourth edge in the graph
//! and a repository that has to be published before anyone can clone and test
//! this one.
//!
//! Zig's stock runner walks `builtin.test_functions` start to finish in one
//! process, so a package's whole suite is pinned to a single core no matter how
//! many the machine has. irregex's suite reached ~1000 tests and ~18 minutes of
//! wall clock at `user/real = 0.64` on a 16-core box — the tests were not slow,
//! they were serial.
//!
//! brigade changes only *which* tests a process owns, never how one is run: a
//! process claims the residues `i, i+n, i+2n, …` of `BRIGADE_SHARD=i/n` and
//! executes them with byte-identical per-test semantics (fresh allocator +
//! `Io` instance, leak detection, `error.SkipZigTest`, error-return traces,
//! logged-error counting). Parallelism is therefore *not* implemented here:
//! `addKernel` hangs n independent `Run` steps off one compiled binary and
//! Zig's build runner — which already schedules independent steps across cores,
//! already renders their progress, and already captures each one's output on
//! its own pipe — runs them at once. No threads, no forks, no shared state,
//! and no interleaved stderr, because each shard is simply a different process.
//!
//! Round-robin rather than contiguous blocks: tests are declared in module
//! order, so cost clusters by module (every DFA differential lands together).
//! Striding the residues spreads each cluster across all shards, which is the
//! balance a static split can get without a work queue. `addKernel` then asks
//! for ~2x as many shards as cores, so the build runner's own in-flight limit
//! finishes the job a static split can't: a shard that drew a cheap slice ends
//! and the next one starts, rather than a core idling beside a grinding
//! neighbor.
//!
//! Three name levers narrow a run, all applied *before* sharding so a narrowed
//! run still splits: `BRIGADE_FILTER` (run only these), `BRIGADE_SKIP` (run
//! everything but these — how a `test-quick` tier stands aside a kernel's
//! declared long poles), and `BRIGADE_TIMES` (emit `<ms>\t<name>` per test,
//! which is how you find a long pole in the first place).
//!
//! Sharding is invisible to test authors and needs no test to be thread-safe —
//! but a shard is a *process*, so two tests that collide on a fixed external
//! name (the same `/tmp` fixture path, the same listening socket) can now run
//! at the same time. Kernel fixtures already key those paths per test and per
//! pid. `BRIGADE_SHARD=0/1` (or `-Dtest-shards=1`) restores a single-process
//! run for bisecting a failure or stepping under a debugger.
//!
//! Wired by each package's `build.zig` as a `.simple`-mode `test_runner`, which
//! means the build runner judges a shard by its exit code rather than the
//! `std.zig.Server` protocol — that protocol hands out one test index at a
//! time and awaits its result, so it cannot express a parallel run.
//!
//! **Two output channels, and which one you pick is a correctness question.**
//! The build runner renders any step with non-empty *stderr* through its failure
//! printer — step name, the text, and a `failed command: <argv>` caption — even
//! when the step succeeded. So stderr is not "the diagnostic stream" here; it is
//! the stream that makes a green shard look dead. `note` is stdout, for what a
//! *passing* test proved (verdict counts, censuses, measured shapes), and the
//! build step captures and drops it. `std.debug.print` stays stderr, for what a
//! reader must act on. brigade's own summary has always obeyed this; `note` is
//! how a test body obeys it too.

const builtin = @import("builtin");
const std = @import("std");

const Io = std.Io;
const testing = std.testing;
const runner_io: Io = Io.Threaded.global_single_threaded.io();

pub const std_options: std.Options = .{ .logFn = log };

// `std_options` is resolved by the standard library via
// `@import("root").std_options`, never by name from this file — exactly like
// `main` below, which the OS loader invokes the same way. Pin the wiring here
// so a future refactor can't silently detach the custom `log` sink (and the
// `log_err_count` "a test that logs .err fails" contract with it) without a
// compile error.
comptime {
    if (std_options.logFn != log) @compileError("std_options.logFn must stay wired to brigade's log()");
}

/// Errors logged by the test under execution. A test that logs at `.err` fails
/// even when it returns cleanly — same contract as the stock runner.
var log_err_count: usize = 0;
/// Set by `fuzz` below; reported so a suite can't silently lose its fuzz tests.
var is_fuzz_test: bool = false;

/// The runner's own stdout, at file scope so `note` and `main` share one
/// buffered stream. Two writers on fd 1 with private buffers would interleave
/// by flush order rather than by call order, which is how a census line ends up
/// inside the middle of a summary.
///
/// Opened on first use rather than in the initializer because one platform
/// cannot answer "which handle is stdout" until the process is running: POSIX
/// has the constant 1, Windows reads it out of the PEB, and a container-level
/// initializer must be comptime-known. `sink()` is therefore the only way to
/// reach it — one stream, still, just claimed later.
var stdout_buf: [4096]u8 = undefined;
var stdout: ?Io.File.Writer = null;

fn sink() *Io.Writer {
    @disableInstrumentation();
    if (stdout == null) stdout = Io.File.stdout().writerStreaming(runner_io, &stdout_buf);
    return &stdout.?.interface;
}

/// What a *passing* test says about what it proved — a differential's verdict
/// count, an eligibility census, a table's measured shape.
///
/// Use this instead of `std.debug.print` anywhere a green test narrates. The
/// channel is the whole point: `std.debug.print` writes to **stderr**, and the
/// build runner renders any step with non-empty stderr through its failure
/// printer — stating the step's name, echoing the text, and captioning it
/// `failed command: <argv>` — whether or not the step failed
/// (`build_runner.zig`: *"No matter the result, we want to display
/// error/warning messages"*, and `result_failed_command` is populated for a
/// success too). Six narrating tests therefore made every green quick-tier run
/// print six blocks that read exactly like six crashed shards.
///
/// So the rule brigade already applies to its own summary applies here: stdout
/// is where a healthy run talks, and the build step captures and drops it.
/// stderr stays reserved for what a reader must act on, which keeps FAIL, LEAK,
/// and a panic's trace as the only things that can ever surface from a shard.
/// Run the shard binary directly and this output is on your terminal as before.
///
/// The trade, stated rather than discovered: because the build step drops
/// stdout, a *failing* shard's narration is dropped with it. Failure
/// diagnostics must therefore keep using `std.debug.print` — as every
/// `MISMATCH`/`DIVERGENCE`/`UNSOUND` line in the kernels already does — and the
/// red-summary path prints the one command that replays a shard in full. What
/// belongs here is what a test says when it *passed*.
pub fn note(comptime fmt: []const u8, args: anytype) void {
    @disableInstrumentation();
    sink().print(fmt, args) catch {};
}

/// What a reader must act on: a FAIL, a LEAK, a logged `.err`, a red summary.
/// Goes to stderr — where the build runner *should* surface it — after draining
/// whatever `note` left buffered, so the narration that led up to a failure is
/// still ahead of it rather than behind it on a different stream.
fn alarm(comptime fmt: []const u8, args: anytype) void {
    @disableInstrumentation();
    sink().flush() catch {};
    std.debug.print(fmt, args);
}

/// Which slice of `builtin.test_functions` this process owns, as the residue
/// class `index (mod count)`. The default owns everything, so an unset
/// environment behaves exactly like the stock runner.
const Shard = struct {
    index: usize = 0,
    count: usize = 1,

    /// Parse `"i/n"`. Returns null for anything malformed or out of range so
    /// the caller can fail loudly rather than silently run a wrong subset —
    /// a shard that quietly owns nothing is a green suite that tested nothing.
    fn parse(spec: []const u8) ?Shard {
        const slash = std.mem.indexOfScalar(u8, spec, '/') orelse return null;
        const index = std.fmt.parseUnsigned(usize, spec[0..slash], 10) catch return null;
        const count = std.fmt.parseUnsigned(usize, spec[slash + 1 ..], 10) catch return null;
        if (count == 0 or index >= count) return null;
        return .{ .index = index, .count = count };
    }

    fn owns(shard: Shard, test_index: usize) bool {
        return test_index % shard.count == shard.index;
    }
};

/// Storage for environment values a platform hands over in an encoding brigade
/// cannot borrow (Windows only — see `envValue`). Sized for the four short specs
/// read below; an over-long value is refused rather than truncated, because a
/// silently halved `BRIGADE_SKIP` is a suite that quietly ran the wrong set.
var env_buf: [4096]u8 = undefined;
var env_used: usize = 0;

/// One environment lookup, portable and allocation-free.
///
/// std ships no single `get` on purpose: a POSIX block is WTF-8 bytes already in
/// this process's memory, a Windows block is WTF-16 inside the PEB behind a
/// lock, and the one portable accessor allocates. Every key brigade reads is a
/// compile-time literal, so the fork happens on the key at comptime and the
/// Windows arm transcodes into `env_buf` — a test runner has no business needing
/// a heap to answer "which shard am I".
fn envValue(environ: std.process.Environ, comptime key: []const u8) ?[]const u8 {
    @disableInstrumentation();
    if (comptime builtin.os.tag != .windows) return environ.getPosix(key);
    const wide = environ.getWindows(comptime std.unicode.wtf8ToWtf16LeStringLiteral(key)) orelse return null;
    const need = std.unicode.calcWtf8Len(wide);
    if (need > env_buf.len - env_used) return null;
    const dest = env_buf[env_used..][0..need];
    env_used += need;
    return dest[0..std.unicode.wtf16LeToWtf8(dest, wide)];
}

pub fn main(init: std.process.Init.Minimal) void {
    @disableInstrumentation();

    const shard = if (envValue(init.environ, "BRIGADE_SHARD")) |spec|
        Shard.parse(spec) orelse std.process.fatal(
            "BRIGADE_SHARD must be 'index/count' with 0 <= index < count, found '{s}'",
            .{spec},
        )
    else
        Shard{};

    // `BRIGADE_FILTER` answers the question a 20-minute suite otherwise can't:
    // "does the one test I just touched pass?". `BRIGADE_SKIP` is its inverse,
    // and is how a quick tier stands aside a handful of measured long poles.
    // Both select by name *before* sharding, so a narrowed run still splits
    // across shards and a narrowed single-shard run is the tightest edit loop.
    const filter: ?Patterns = if (envValue(init.environ, "BRIGADE_FILTER")) |s| .{ .spec = s } else null;
    const skip: ?Patterns = if (envValue(init.environ, "BRIGADE_SKIP")) |s| .{ .spec = s } else null;
    // `BRIGADE_TIMES` emits `<ms>\t<name>` per test. Cheap enough to be always
    // measured; printing is opt-in so a green run stays one line.
    const report_times = envValue(init.environ, "BRIGADE_TIMES") != null;

    if (shard.index == 0) if (skip) |s| warnUnusedSkips(s);

    var owned: usize = 0;
    var selected: usize = 0;
    for (builtin.test_functions) |test_fn| {
        if (!selects(filter, skip, test_fn.name)) continue;
        owned += @intFromBool(shard.owns(selected));
        selected += 1;
    }
    // Owning nothing is ordinary — 31 of 32 shards do when a filter picks one
    // test. Selecting nothing is a typo, and it would otherwise report as a
    // green suite that tested exactly zero things. Every shard fails on it, so
    // the build fails no matter which one the runner reaches first.
    if (selected == 0 and filter != null) std.process.fatal(
        "BRIGADE_FILTER='{s}' matched none of the {d} tests",
        .{ filter.?.spec, builtin.test_functions.len },
    );

    var pass: usize = 0;
    var skipped: usize = 0;
    var fail: usize = 0;
    var leak: usize = 0;
    var fuzz_count: usize = 0;

    const root_node = std.Progress.start(runner_io, .{
        .root_name = "brigade",
        .estimated_total_items = owned,
    });
    defer root_node.end();

    const started = Io.Clock.now(.awake, runner_io);

    var position: usize = 0;
    for (builtin.test_functions) |test_fn| {
        if (!selects(filter, skip, test_fn.name)) continue;
        defer position += 1;
        if (!shard.owns(position)) continue;

        // Per-test state, reset exactly as the stock runner resets it: a test
        // that leaks must be attributed to itself, not to whatever ran before.
        testing.allocator_instance = .{};
        testing.io_instance = .init(testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        testing.environ = init.environ;
        testing.log_level = .warn;
        log_err_count = 0;
        is_fuzz_test = false;

        const test_node = root_node.start(test_fn.name, 0);
        const entered = Io.Clock.now(.awake, runner_io);
        const result = test_fn.func();
        const test_ms = entered.durationTo(Io.Clock.now(.awake, runner_io)).toMilliseconds();
        testing.io_instance.deinit();
        const leaked = testing.allocator_instance.deinit() == .leak;
        test_node.end();

        if (report_times) sink().print("{d}\t{s}\n", .{ test_ms, test_fn.name }) catch {};

        if (result) |_| {
            pass += 1;
        } else |err| switch (err) {
            error.SkipZigTest => skipped += 1,
            else => {
                fail += 1;
                alarm("FAIL [{d}/{d}] {s}: {t}\n", .{
                    shard.index, shard.count, test_fn.name, err,
                });
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            },
        }
        if (leaked) {
            leak += 1;
            alarm("LEAK [{d}/{d}] {s}\n", .{ shard.index, shard.count, test_fn.name });
        }
        if (log_err_count != 0) {
            fail += 1;
            alarm("LOGGED {d} error(s) [{d}/{d}] {s}\n", .{
                log_err_count, shard.index, shard.count, test_fn.name,
            });
        }
        fuzz_count += @intFromBool(is_fuzz_test);
    }

    const elapsed_ms = started.durationTo(Io.Clock.now(.awake, runner_io)).toMilliseconds();
    var line: [256]u8 = undefined;
    const summary = std.fmt.bufPrint(
        &line,
        "brigade {d}/{d}: {d} passed, {d} skipped, {d} failed, {d} leaked, {d} fuzz of {d} in {d}ms\n",
        .{ shard.index, shard.count, pass, skipped, fail, leak, fuzz_count, owned, elapsed_ms },
    ) catch |err| {
        alarm("brigade: summary line exceeded the {d}-byte buffer: {t}\n", .{ line.len, err });
        std.process.exit(1);
    };

    // A green shard says so on stdout, which the build step captures and drops;
    // stderr is reserved for what a reader must act on, so sixteen healthy
    // shards stay silent instead of printing sixteen lines the build runner
    // would then echo back under a "failed command" heading. A red shard
    // repeats its summary on stderr, where Zig surfaces it beside the failures.
    // `note` puts a *passing* test's narration on the same green channel, for
    // the same reason — see its doc comment.
    if (fail != 0 or leak != 0) {
        alarm("{s}", .{summary});
        // The build step captures stdout and shows only stderr, so a failing
        // shard's `note` narration is dropped along with its green output. Name
        // the one command that brings it back rather than leaving the reader to
        // rediscover that a FAIL line's test name is already a valid filter.
        alarm(
            "brigade: rerun this shard alone for its full output — BRIGADE_SHARD={d}/{d} BRIGADE_FILTER='<name from a FAIL line above>'\n",
            .{ shard.index, shard.count },
        );
        std.process.exit(1);
    }
    sink().writeAll(summary) catch {};
    sink().flush() catch {};
}

/// A comma-separated substring list, the same match shape as `zig test
/// --test-filter` — so a name copied straight out of a FAIL line is already a
/// valid pattern. Empty entries are ignored, which makes a trailing comma and
/// an exported-but-empty variable both harmless.
const Patterns = struct {
    spec: []const u8,

    fn matches(p: Patterns, name: []const u8) bool {
        var it = std.mem.splitScalar(u8, p.spec, ',');
        while (it.next()) |needle| {
            if (needle.len != 0 and std.mem.indexOf(u8, name, needle) != null) return true;
        }
        return false;
    }
};

fn selects(filter: ?Patterns, skip: ?Patterns, name: []const u8) bool {
    if (filter) |f| if (!f.matches(name)) return false;
    if (skip) |s| if (s.matches(name)) return false;
    return true;
}

/// A skip pattern that matches nothing is name drift: the test it was meant to
/// stand aside was renamed or deleted, and the quick tier silently got slower
/// rather than less safe. Failing that direction is the right one, but it still
/// has to be said out loud, once, by the shard that speaks for the run.
fn warnUnusedSkips(skip: Patterns) void {
    var it = std.mem.splitScalar(u8, skip.spec, ',');
    while (it.next()) |needle| {
        if (needle.len == 0) continue;
        for (builtin.test_functions) |test_fn| {
            if (std.mem.indexOf(u8, test_fn.name, needle) != null) break;
        } else std.debug.print(
            "brigade: BRIGADE_SKIP pattern '{s}' matched no test — stale name, so nothing was stood aside\n",
            .{needle},
        );
    }
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    @disableInstrumentation();
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err)) log_err_count +|= 1;
    if (@intFromEnum(message_level) <= @intFromEnum(testing.log_level)) {
        std.debug.print(
            "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n",
            args,
        );
    }
}

/// `std.testing.fuzz` resolves to `@import("root").fuzz`, so every test runner
/// must supply one or a suite that fuzzes won't compile. Coverage-guided
/// fuzzing needs the `std.zig.Server` protocol brigade deliberately doesn't
/// speak (`zig build fuzz` keeps the stock runner for exactly that reason), so
/// here a fuzz test degrades to what a non-fuzz build already does: replay the
/// declared corpus, plus the empty input as a smoke case.
pub fn fuzz(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), smith: *testing.Smith) anyerror!void,
    options: testing.FuzzInputOptions,
) anyerror!void {
    @disableInstrumentation();
    is_fuzz_test = true;

    for (options.corpus) |input| {
        var smith: testing.Smith = .{ .in = input };
        try testOne(context, &smith);
    }
    var smith: testing.Smith = .{ .in = "" };
    try testOne(context, &smith);
}
