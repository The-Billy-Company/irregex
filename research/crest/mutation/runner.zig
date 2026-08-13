//! Focused mutation-test runner with a machine-validated evidence protocol.

const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;

const prefix = "CREST_MUTATION_TEST_V1\t";
const assertion_exit = 101;
const panic_exit = 102;
const runner_exit = 103;

var active_test: ?[]const u8 = null;
var test_running = false;

pub const panic = std.debug.FullPanic(panicHandler);

fn emit(status: []const u8, name: []const u8) void {
    std.debug.print(prefix ++ "{s}\t{s}\n", .{ status, name });
}

fn emitDetail(status: []const u8, name: []const u8, detail: []const u8) void {
    std.debug.print(prefix ++ "{s}\t{s}\t{s}\n", .{ status, name, detail });
}

fn runnerFailure(detail: []const u8) noreturn {
    emitDetail("runner_error", active_test orelse "none", detail);
    std.process.exit(runner_exit);
}

fn panicHandler(_: []const u8, _: ?usize) noreturn {
    if (test_running and active_test != null) {
        emit("panicked", active_test.?);
        std.process.exit(panic_exit);
    }
    runnerFailure("panic_outside_test");
}

pub fn main(init: std.process.Init.Minimal) void {
    const tests = builtin.test_functions;
    if (tests.len != 1) runnerFailure("focused_test_count");

    const selected = tests[0];
    active_test = selected.name;
    emit("selected", selected.name);

    testing.environ = init.environ;
    testing.allocator_instance = .{};
    testing.io_instance = .init(testing.allocator, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });

    test_running = true;
    const result = selected.func();
    test_running = false;

    testing.io_instance.deinit();
    const leaks = testing.allocator_instance.detectLeaks();
    testing.allocator_instance.deinitWithoutLeakChecks();
    if (leaks != 0) runnerFailure("memory_leak");

    if (result) |_| {
        emit("passed", selected.name);
        return;
    } else |err| {
        if (err == error.SkipZigTest) runnerFailure("test_skipped");
        emitDetail("failed", selected.name, @errorName(err));
        std.process.exit(assertion_exit);
    }
}
