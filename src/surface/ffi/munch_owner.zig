//! Private native ownership, not another C surface. An immutable Program is
//! shared; every Worker exclusively owns its permission and winner buffers.
//! The allocator must outlive all workers and support concurrent allocation/free
//! if callers clone or destroy workers concurrently. FFI uses c_allocator.
const std = @import("std");
const rx = @import("../../kernel/regex/regex.zig");
const image = rx.munch_image;

pub const Program = struct {
    allocator: std.mem.Allocator,
    inner: rx.Munch,
    count: usize,
    flags: u32,
    identity: image.Identity,
    worker_layout: WorkerLayout,
    refs: std.atomic.Value(usize),

    fn retain(p: *Program) error{Exhausted}!void {
        var n = p.refs.load(.monotonic);
        while (true) {
            std.debug.assert(n != 0);
            if (n == std.math.maxInt(usize)) return error.Exhausted;
            if (p.refs.cmpxchgWeak(n, n + 1, .monotonic, .monotonic)) |changed| {
                n = changed;
            } else return;
        }
    }

    fn release(p: *Program) void {
        const previous = p.refs.fetchSub(1, .acq_rel);
        std.debug.assert(previous != 0);
        if (previous == 1) {
            const allocator = p.allocator;
            p.inner.deinit();
            allocator.destroy(p);
        }
    }
};

/// The exact requested scratch payload is checked once at Program publication.
/// Later clones use these immutable counts and do not inherit a load budget.
const WorkerLayout = struct {
    allow_words: usize,
    winners: usize,
    bytes: u64,

    fn checked(inner: *const rx.Munch) image.Error!WorkerLayout {
        const words = inner.voices.len;
        const winners = inner.admitted();
        _ = try rx.Munch.checkedLayout(words, @sizeOf(u64), @alignOf(u64));
        _ = try rx.Munch.checkedLayout(winners, @sizeOf(u32), @alignOf(u32));
        const bytes = try image.types.add(@sizeOf(Worker), try image.types.add(
            try image.types.mul(words, @sizeOf(u64)),
            try image.types.mul(winners, @sizeOf(u32)),
        ));
        _ = try image.types.size(bytes);
        return .{ .allow_words = words, .winners = winners, .bytes = bytes };
    }
};

pub const Worker = struct {
    program: *Program,
    allow: rx.Munch.Allow,
    winners: []u32,
    pending: ?image.Encoded = null,

    pub fn clearPending(w: *Worker) void {
        if (w.pending) |held| w.program.allocator.free(held.bytes);
        w.pending = null;
    }

    pub fn machine(w: *const Worker) *const rx.Munch {
        return &w.program.inner;
    }

    pub fn deinit(w: *Worker) void {
        const p = w.program;
        const allocator = p.allocator;
        w.clearPending();
        w.allow.deinit(allocator);
        allocator.free(w.winners);
        allocator.destroy(w);
        p.release();
    }
};

/// Pure preflight before input views, allocation or kernel ordinal casts.
pub fn checkSourceCount(count: usize) error{Oversized}!void {
    var total = try rx.Munch.sourceLayout(count);
    total = std.math.add(usize, total, try rx.Munch.checkedLayout(count, @sizeOf([]const u8), @alignOf([]const u8))) catch return error.Oversized;
    total = std.math.add(usize, total, try rx.Munch.checkedLayout(count, @sizeOf(u64), @alignOf(u64))) catch return error.Oversized;
    total = std.math.add(usize, total, try rx.Munch.checkedLayout(count, @sizeOf(u32), @alignOf(u32))) catch return error.Oversized;
    total = std.math.add(usize, total, @sizeOf(Program)) catch return error.Oversized;
    total = std.math.add(usize, total, @sizeOf(Worker)) catch return error.Oversized;
    _ = std.math.cast(u64, total) orelse return error.Oversized;
}

fn allocateWorker(p: *Program, context: ?*image.Context) image.Error!*Worker {
    const allocator = p.allocator;
    const w = if (context) |ctx| try ctx.create(Worker, .worker) else try allocator.create(Worker);
    errdefer if (context) |ctx| ctx.destroy(w) else allocator.destroy(w);
    const words = if (context) |ctx| try ctx.alloc(u64, p.worker_layout.allow_words, .allow) else try allocator.alloc(u64, p.worker_layout.allow_words);
    errdefer if (context) |ctx| ctx.free(words) else allocator.free(words);
    if (context) |ctx| try ctx.work(try image.types.mul(words.len, 8));
    @memset(words, 0);
    const winners = if (context) |ctx| try ctx.alloc(u32, p.worker_layout.winners, .winners) else try allocator.alloc(u32, p.worker_layout.winners);
    errdefer if (context) |ctx| ctx.free(winners) else allocator.free(winners);
    if (context) |ctx| try ctx.work(@sizeOf(Worker));
    w.* = .{ .program = p, .allow = .{ .words = words }, .winners = winners };
    return w;
}

fn metadataFor(inner: *const rx.Munch, patterns: []const []const u8, flags: u32) image.Error!image.Identity {
    var identity = try image.sourceIdentity(null, .{ .slices = patterns }, flags);
    identity.roster = try image.rosterIdentity(null, inner, identity.source);
    return identity;
}

/// Takes ownership of inner on both success and failure. Its original winners
/// remain owned in Program (4*A), separately from each worker's new 4*A buffer.
fn own(allocator: std.mem.Allocator, inner: rx.Munch, count: usize, flags: u32, identity: image.Identity) !*Worker {
    var held = inner;
    errdefer held.deinit();
    try checkSourceCount(count);
    if (held.admitted() > count or held.voices.len > held.admitted()) return error.Oversized;
    const worker_layout = try WorkerLayout.checked(&held);
    const p = try allocator.create(Program);
    errdefer allocator.destroy(p);
    p.* = .{ .allocator = allocator, .inner = held, .count = count, .flags = flags, .identity = identity, .worker_layout = worker_layout, .refs = .init(1) };
    return try allocateWorker(p, null);
}

fn ownSource(allocator: std.mem.Allocator, inner: rx.Munch, patterns: []const []const u8, flags: u32) !*Worker {
    var held = inner;
    const identity = metadataFor(&held, patterns, flags) catch |err| {
        held.deinit();
        return err;
    };
    return own(allocator, held, patterns.len, flags, identity);
}

pub fn build(allocator: std.mem.Allocator, patterns: []const []const u8, opts: rx.Munch.Options, flags: u32) !?*Worker {
    try checkSourceCount(patterns.len);
    // Check text/count arithmetic before the old compiler, but do not borrow an
    // image budget or impose image shape ceilings on source construction.
    var text_bytes: u64 = 0;
    for (patterns) |p| text_bytes = try image.types.add(text_bytes, p.len);
    _ = try image.types.size(text_bytes);
    if (patterns.len == 0) {
        var none: [0]rx.Munch.Voice = .{};
        const inner = try rx.Munch.adopt(allocator, 0, &none, &.{});
        return try ownSource(allocator, inner, patterns, flags);
    }
    const inner = (try rx.Munch.compile(allocator, patterns, opts)) orelse return null;
    return try ownSource(allocator, inner, patterns, flags);
}

/// Consumes decoded ownership on success AND failure. Only stable base
/// allocators survive this call; Context is never retained by a Program.
pub fn fromDecoded(ctx: *image.Context, decoded: image.Decoded) image.Error!*Worker {
    var held = decoded;
    errdefer held.deinit(ctx);
    const worker_layout = try WorkerLayout.checked(&held.inner);
    const p = try ctx.create(Program, .program);
    errdefer ctx.destroy(p);
    try ctx.work(@sizeOf(Program));
    p.* = .{ .allocator = ctx.base, .inner = held.inner, .count = held.identity.count, .flags = held.identity.flags, .identity = held.identity, .worker_layout = worker_layout, .refs = .init(1) };
    return try allocateWorker(p, ctx);
}

/// Internal only: no C export, image decode, compile, or shared-table copy.
/// The source worker must remain live throughout this call; other workers may
/// be independently cloned or destroyed when the allocator permits it.
pub fn cloneWorker(source: *const Worker) !*Worker {
    const p = source.program;
    try p.retain();
    errdefer p.release();
    return try allocateWorker(p, null);
}

const t = std.testing;
const kernel = rx.munch;
const test_options: rx.Munch.Options = .{ .multiline = true, .line_anchors = false };

test "munch-owner: source count and every checked layout reject overflow" {
    try checkSourceCount(0);
    try checkSourceCount(74);
    try t.expectError(error.Oversized, rx.Munch.checkedLayout(std.math.maxInt(usize), 4, 4));
    try t.expectError(error.Oversized, rx.Munch.checkedLayout(std.math.maxInt(usize), 1, 8));
    if (@bitSizeOf(usize) > 32) {
        try t.expectError(error.Oversized, checkSourceCount(@as(usize, std.math.maxInt(u32)) + 1));
        // No image-policy ceiling is imposed on source construction.
        try checkSourceCount(4097);
    }
}

test "munch-owner: source first drop and clone of clone retain one machine" {
    const source = (try build(t.allocator, &.{ "a+", "a*" }, test_options, 0)).?;
    var source_live = true;
    defer if (source_live) source.deinit();
    const first = try cloneWorker(source);
    var first_live = true;
    defer if (first_live) first.deinit();
    const second = try cloneWorker(first);
    defer second.deinit();
    try t.expect(source.program == first.program and first.program == second.program);
    try t.expect(source.allow.words.ptr != first.allow.words.ptr);
    try t.expect(first.allow.words.ptr != second.allow.words.ptr);
    try t.expect(source.winners.ptr != first.winners.ptr);
    try t.expect(first.winners.ptr != second.winners.ptr);
    try t.expect(source.machine().winners.ptr != source.winners.ptr);
    try t.expectEqual(@as(usize, 3), source.program.refs.load(.monotonic));
    source.deinit();
    source_live = false;
    first.deinit();
    first_live = false;
    second.allow.admitAll();
    const got = (try second.machine().scanWithScratch("aaa", 0, &second.allow, .longest, null, second.winners)).?;
    try t.expectEqual(@as(usize, 3), got.len);
    try t.expectEqualSlices(u32, &.{ 0, 1 }, got.patterns);
    try t.expectEqual(@as(usize, 1), second.program.refs.load(.monotonic));
}

test "munch-owner: empty slate remains distinct from all declined" {
    const source = (try build(t.allocator, &.{}, test_options, 0)).?;
    defer source.deinit();
    const copy = try cloneWorker(source);
    defer copy.deinit();
    try t.expectEqual(@as(usize, 0), copy.program.count);
    try t.expectEqual(@as(usize, 0), copy.machine().admitted());
    try t.expectEqual(@as(?kernel.Match, null), try copy.machine().scanWithScratch("", 0, null, .longest, null, copy.winners));
    try t.expectEqual(@as(?*Worker, null), try build(t.allocator, &.{"("}, test_options, 0));
}

test "munch-owner: each owner handoff allocation unwinds the consumed machine" {
    // Compile independently so failures target only the four new handoffs:
    // Program, Worker, Allow and winners. own consumes inner even on error.
    for (0..4) |failure| {
        const inner = (try rx.Munch.compile(t.allocator, &.{"a+"}, test_options)).?;
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = failure });
        const identity = try metadataFor(&inner, &.{"a+"}, 0);
        try t.expectError(error.OutOfMemory, own(failing.allocator(), inner, 1, 0, identity));
        try t.expect(failing.has_induced_failure);
        try t.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "munch-owner: each clone handoff allocation rolls back its retained reference" {
    for (0..3) |failure| {
        var failing = t.FailingAllocator.init(t.allocator, .{});
        const source = (try build(failing.allocator(), &.{"a+"}, test_options, 0)).?;
        const before = kernel.determinizations;
        failing.fail_index = failing.alloc_index + failure;
        try t.expectError(error.OutOfMemory, cloneWorker(source));
        try t.expect(failing.has_induced_failure);
        try t.expectEqual(@as(usize, 1), source.program.refs.load(.monotonic));
        try t.expectEqual(before, kernel.determinizations);
        failing.fail_index = std.math.maxInt(usize);
        source.allow.admitAll();
        const got = (try source.machine().scanWithScratch("aa", 0, &source.allow, .longest, null, source.winners)).?;
        try t.expectEqual(@as(usize, 2), got.len);
        source.deinit();
        try t.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "munch-owner: saturated reference count refuses without allocation or wrap" {
    var failing = t.FailingAllocator.init(t.allocator, .{});
    const source = (try build(failing.allocator(), &.{"a"}, test_options, 0)).?;
    defer source.deinit();
    const before = failing.alloc_index;
    const builds = kernel.determinizations;
    source.program.refs.store(std.math.maxInt(usize), .monotonic);
    defer source.program.refs.store(1, .monotonic);
    try t.expectError(error.Exhausted, cloneWorker(source));
    try t.expectEqual(std.math.maxInt(usize), source.program.refs.load(.monotonic));
    try t.expectEqual(before, failing.alloc_index);
    try t.expectEqual(builds, kernel.determinizations);
}

fn permit(a: *rx.Munch.Allow, machine: *const rx.Munch, ordinals: ?[]const u32) void {
    if (ordinals) |list| {
        a.forbidAll();
        for (list) |ordinal| a.admit(machine, ordinal);
    } else a.admitAll();
}

fn sameMatch(expected: ?kernel.Match, actual: ?kernel.Match) !void {
    try t.expectEqual(expected == null, actual == null);
    if (expected) |value| {
        try t.expectEqual(value.len, actual.?.len);
        try t.expectEqualSlices(u32, value.patterns, actual.?.patterns);
    }
}

fn compareQuestion(baseline: *rx.Munch, baseline_allow: *rx.Munch.Allow, worker: *Worker, text: []const u8, at: usize, ordinals: ?[]const u32, pick: rx.Munch.Pick) !void {
    permit(baseline_allow, baseline, ordinals);
    permit(&worker.allow, worker.machine(), ordinals);
    const expected = switch (pick) {
        .longest => baseline.longestAmong(text, at, baseline_allow),
        .shortest => baseline.shortestAmong(text, at, baseline_allow),
    };
    try sameMatch(expected, try worker.machine().scanWithScratch(text, at, &worker.allow, pick, null, worker.winners));
    var unlimited: usize = std.math.maxInt(usize);
    _ = switch (pick) {
        .longest => try baseline.longestAmongMetered(text, at, baseline_allow, &unlimited),
        .shortest => try baseline.shortestAmongMetered(text, at, baseline_allow, &unlimited),
    };
    const spent = std.math.maxInt(usize) - unlimited;
    const budgets = [_]usize{ 0, 1, spent, spent -| 1 };
    for (budgets) |budget| {
        var original_left = budget;
        var worker_left = budget;
        const original = switch (pick) {
            .longest => baseline.longestAmongMetered(text, at, baseline_allow, &original_left),
            .shortest => baseline.shortestAmongMetered(text, at, baseline_allow, &original_left),
        };
        const actual = worker.machine().scanWithScratch(text, at, &worker.allow, pick, &worker_left, worker.winners);
        if (original) |hit| {
            try sameMatch(hit, try actual);
        } else |err| {
            try t.expectError(err, actual);
        }
        try t.expectEqual(original_left, worker_left);
    }
}

fn compareRoster(patterns: []const []const u8, attributed: bool) !void {
    var baseline = (try rx.Munch.compile(t.allocator, patterns, test_options)).?;
    defer baseline.deinit();
    var baseline_allow = try baseline.allowNone(t.allocator);
    defer baseline_allow.deinit(t.allocator);
    const source = (try build(t.allocator, patterns, test_options, 0)).?;
    defer source.deinit();
    const builds = kernel.determinizations;
    const worker = try cloneWorker(source);
    defer worker.deinit();
    try t.expectEqual(builds, kernel.determinizations);
    var has_attribution = false;
    for (worker.machine().voices) |voice| {
        if (voice.ordinals.len > 1) {
            has_attribution = true;
            try t.expect(voice.dfa.pats.len != 0 and voice.dfa.reach.len != 0);
        } else {
            try t.expectEqual(@as(usize, 0), voice.dfa.pats.len);
            try t.expectEqual(@as(usize, 0), voice.dfa.reach.len);
        }
    }
    try t.expectEqual(attributed, has_attribution);
    const permissions = [_]?[]const u32{ null, &.{}, &.{ 0, 1, 64, 70, 71, 72, 73, 999, 0 } };
    for ([_][]const u8{ "", "a", "aaaa", "z", "\xffa" }) |text| {
        for ([_]usize{ 0, text.len }) |at| {
            for (permissions) |ordinals| {
                for ([_]rx.Munch.Pick{ .longest, .shortest }) |pick| {
                    try compareQuestion(&baseline, &baseline_allow, worker, text, at, ordinals, pick);
                }
            }
        }
    }
    // A clone is an ownership operation, never a delayed determinization.
    try t.expectEqual(builds, kernel.determinizations);
}

test "munch-owner: singleton implicit tables preserve tokens and exact remaining work" {
    try compareRoster(&.{"a*"}, false);
}

test "munch-owner: over 64 attributed ties refusals and permits preserve exact work" {
    var patterns: [74][]const u8 = @splat("a+");
    patterns[70] = "a*";
    patterns[71] = "(";
    patterns[72] = "\\Afoo";
    patterns[73] = "\\bfoo";
    try compareRoster(&patterns, true);
    const worker = (try build(t.allocator, &patterns, test_options, 0)).?;
    defer worker.deinit();
    try t.expectEqualSlices(u32, &.{ 71, 72, 73 }, worker.machine().declined);
    try t.expectEqualSlices(rx.Munch.Because, &.{ .syntax, .buffer_anchor, .word_context }, worker.machine().because);
    worker.allow.admitAll();
    const tie = (try worker.machine().scanWithScratch("aaa", 0, &worker.allow, .longest, null, worker.winners)).?;
    try t.expectEqual(@as(usize, 3), tie.len);
    try t.expectEqual(@as(usize, 71), tie.patterns.len);
    for (tie.patterns, 0..) |ordinal, i| try t.expectEqual(@as(u32, @intCast(i)), ordinal);
    const empty = (try worker.machine().scanWithScratch("aaa", 3, &worker.allow, .longest, null, worker.winners)).?;
    try t.expectEqual(@as(usize, 0), empty.len);
    try t.expectEqualSlices(u32, &.{70}, empty.patterns);
}

const Concurrent = struct {
    source: *const Worker,
    ordinal: u32,
    ok: bool = false,

    fn run(job: *Concurrent) void {
        const before = kernel.determinizations;
        for (0..32) |_| {
            const worker = cloneWorker(job.source) catch return;
            defer worker.deinit();
            const nested = cloneWorker(worker) catch return;
            defer nested.deinit();
            nested.allow.admit(nested.machine(), job.ordinal);
            const got = (nested.machine().scanWithScratch("aaa", 0, &nested.allow, .longest, null, nested.winners) catch return) orelse return;
            if (got.len != 3 or got.patterns.len != 1 or got.patterns[0] != job.ordinal) return;
        }
        job.ok = kernel.determinizations == before;
    }
};

test "munch-owner: concurrent clones have independent scratch and no determinization" {
    // c_allocator is thread-safe and outlives every worker; an arbitrary arena
    // allocator does not acquire that property just because tables are shared.
    const source = (try build(std.heap.c_allocator, &.{ "a+", "a*" }, test_options, 0)).?;
    defer source.deinit();
    const before = kernel.determinizations;
    var jobs = [_]Concurrent{
        .{ .source = source, .ordinal = 0 }, .{ .source = source, .ordinal = 1 },
        .{ .source = source, .ordinal = 0 }, .{ .source = source, .ordinal = 1 },
    };
    var threads: [jobs.len]std.Thread = undefined;
    var started: usize = 0;
    errdefer for (threads[0..started]) |thread| thread.join();
    for (&jobs, &threads) |*job, *thread| {
        thread.* = try std.Thread.spawn(.{}, Concurrent.run, .{job});
        started += 1;
    }
    for (threads) |thread| thread.join();
    started = 0;
    try t.expectEqual(@as(usize, 1), source.program.refs.load(.monotonic));
    try t.expectEqual(before, kernel.determinizations);
    for (jobs) |job| try t.expect(job.ok);
}

const image_data = @import("../../kernel/regex/linear/program/munch_image_vectors.zig");

fn imageFixture(name: []const u8) *const image_data.Fixture {
    for (&image_data.fixtures) |*f| if (std.mem.eql(u8, f.name, name)) return f;
    unreachable;
}

fn loadOwned(ctx: *image.Context, f: *const image_data.Fixture) image.Error!*Worker {
    const decoded = try image.load(ctx, .{ .slices = f.patterns }, f.expected_flags, f.bytes);
    return fromDecoded(ctx, decoded);
}

fn freeLoaded(ctx: *image.Context, worker: *Worker) void {
    const owned = ctx.live;
    worker.deinit();
    ctx.released(owned);
}

test "munch-image: every loaded publication allocation unwinds the whole machine" {
    const f = imageFixture("attributed-two");
    var successful = t.FailingAllocator.init(t.allocator, .{});
    var measured = image.Budget.trial();
    var measure_ctx = try image.Context.init(successful.allocator(), image.Limits.trial(), &measured, 0);
    image.types.counters = .{};
    const first = try loadOwned(&measure_ctx, f);
    const allocations = successful.alloc_index;
    try t.expectEqual(@as(u64, 1), image.types.counters.requests[@intFromEnum(image.types.Site.program)]);
    try t.expectEqual(@as(u64, 1), image.types.counters.requests[@intFromEnum(image.types.Site.worker)]);
    try t.expectEqual(@as(u64, 1), image.types.counters.requests[@intFromEnum(image.types.Site.allow)]);
    // One retained kernel winner buffer and one worker buffer are both billed.
    try t.expectEqual(@as(u64, 2), image.types.counters.requests[@intFromEnum(image.types.Site.winners)]);
    try t.expectEqual(@as(u64, @sizeOf(Worker) + 8 + 8), first.program.worker_layout.bytes);
    try t.expect(first.program.allocator.ptr == successful.allocator().ptr);
    const builds = kernel.determinizations;
    const calls_before_clone = successful.alloc_index;
    const bytes_before_clone = successful.allocated_bytes;
    const clone = try cloneWorker(first);
    try t.expectEqual(@as(usize, 3), successful.alloc_index - calls_before_clone);
    try t.expectEqual(first.program.worker_layout.bytes, @as(u64, successful.allocated_bytes - bytes_before_clone));
    try t.expect(clone.pending == null);
    try t.expectEqual(first.program.worker_layout.allow_words, clone.allow.words.len);
    try t.expectEqual(first.program.worker_layout.winners, clone.winners.len);
    clone.deinit();
    try t.expectEqual(builds, kernel.determinizations);
    freeLoaded(&measure_ctx, first);
    try t.expectEqual(@as(u64, 0), measure_ctx.live);
    try t.expectEqual(successful.allocated_bytes, successful.freed_bytes);
    for (0..allocations) |failure| {
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = failure });
        var budget = image.Budget.trial();
        var ctx = try image.Context.init(failing.allocator(), image.Limits.trial(), &budget, 0);
        try t.expectError(error.OutOfMemory, loadOwned(&ctx, f));
        try t.expect(failing.has_induced_failure);
        try t.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        try t.expectEqual(@as(u64, 0), ctx.live);
        try t.expect(budget.allocation_left < image.Budget.trial().allocation_left);
    }
}

test "munch-image: full loaded owner allocation and initialization work have exact boundaries" {
    const f = imageFixture("attributed-two");
    var measured = image.Budget.trial();
    var measure_ctx = try image.Context.init(t.allocator, image.Limits.trial(), &measured, 0);
    const first = try loadOwned(&measure_ctx, f);
    const allocation = image.Budget.trial().allocation_left - measured.allocation_left;
    const work = image.Budget.trial().work_left - measured.work_left;
    freeLoaded(&measure_ctx, first);
    var exact = image.Budget.trial();
    exact.allocation_left = allocation;
    exact.work_left = work;
    var exact_ctx = try image.Context.init(t.allocator, image.Limits.trial(), &exact, 0);
    const second = try loadOwned(&exact_ctx, f);
    freeLoaded(&exact_ctx, second);
    try t.expectEqual(@as(u64, 0), exact.allocation_left);
    try t.expectEqual(@as(u64, 0), exact.work_left);
    for ([_]bool{ false, true }) |allocation_short| {
        var short = image.Budget.trial();
        if (allocation_short) short.allocation_left = allocation - 1 else short.work_left = work - 1;
        var short_ctx = try image.Context.init(t.allocator, image.Limits.trial(), &short, 0);
        try t.expectError(error.BudgetExceeded, loadOwned(&short_ctx, f));
        try t.expectEqual(@as(u64, 0), short_ctx.live);
    }
}

fn compareImageRoster(patterns: []const []const u8) !void {
    const source = (try build(t.allocator, patterns, test_options, 0)).?;
    defer source.deinit();
    const builds = kernel.determinizations;
    var save_budget = image.Budget.trial();
    var save_ctx = try image.Context.init(t.allocator, image.Limits.trial(), &save_budget, 0);
    const encoded = try image.save(&save_ctx, source.machine(), source.program.identity);
    defer save_ctx.free(encoded.bytes);
    var load_budget = image.Budget.trial();
    var load_ctx = try image.Context.init(t.allocator, image.Limits.trial(), &load_budget, 0);
    const decoded = try image.load(&load_ctx, .{ .slices = patterns }, 0, encoded.bytes);
    const worker = try fromDecoded(&load_ctx, decoded);
    defer freeLoaded(&load_ctx, worker);
    try t.expectEqualSlices(u32, source.machine().declined, worker.machine().declined);
    try t.expectEqualSlices(rx.Munch.Because, source.machine().because, worker.machine().because);
    try t.expectEqualSlices(u8, &source.program.identity.source, &worker.program.identity.source);
    try t.expectEqualSlices(u8, &source.program.identity.roster, &worker.program.identity.roster);
    try t.expectEqual(source.machine().voices.len, worker.machine().voices.len);
    for (source.machine().voices, worker.machine().voices) |old, loaded| {
        try t.expectEqualSlices(u32, old.ordinals, loaded.ordinals);
        try t.expectEqualSlices(u64, old.dfa.pats, loaded.dfa.pats);
        try t.expectEqualSlices(u64, old.dfa.reach, loaded.dfa.reach);
    }
    const permissions = [_]?[]const u32{ null, &.{}, &.{ 0, 1, 64, 70, 71, 72, 73, 999, 0 } };
    for ([_][]const u8{ "", "a", "aaaa", "z", "\xffa" }) |text| {
        for ([_]usize{ 0, text.len }) |at| {
            for (permissions) |ordinals| {
                for ([_]rx.Munch.Pick{ .longest, .shortest }) |pick| {
                    try compareQuestion(&source.program.inner, &source.allow, worker, text, at, ordinals, pick);
                }
            }
        }
    }
    const copy = try cloneWorker(worker);
    defer copy.deinit();
    try t.expectEqual(builds, kernel.determinizations);
}

test "munch-image: source singleton and over 64 attributed partial refusals roundtrip exact scans and work" {
    try compareImageRoster(&.{"a*"});
    var patterns: [74][]const u8 = @splat("a+");
    patterns[70] = "a*";
    patterns[71] = "(";
    patterns[72] = "\\Afoo";
    patterns[73] = "\\bfoo";
    try compareImageRoster(&patterns);
}

test "munch-image: source encoding whole budgets and every allocation failure preserve the source" {
    const source = (try build(t.allocator, &.{ "a+", "a*", "(" }, test_options, 0)).?;
    defer source.deinit();
    const builds = kernel.determinizations;
    var successful = t.FailingAllocator.init(t.allocator, .{});
    var measured = image.Budget.trial();
    var measure_ctx = try image.Context.init(successful.allocator(), image.Limits.trial(), &measured, 0);
    const encoded = try image.save(&measure_ctx, source.machine(), source.program.identity);
    const allocations = successful.alloc_index;
    const allocation = image.Budget.trial().allocation_left - measured.allocation_left;
    const work = image.Budget.trial().work_left - measured.work_left;
    measure_ctx.free(encoded.bytes);
    try t.expectEqual(successful.allocated_bytes, successful.freed_bytes);
    var exact = image.Budget.trial();
    exact.allocation_left = allocation;
    exact.work_left = work;
    var exact_ctx = try image.Context.init(t.allocator, image.Limits.trial(), &exact, 0);
    const second = try image.save(&exact_ctx, source.machine(), source.program.identity);
    exact_ctx.free(second.bytes);
    try t.expectEqual(@as(u64, 0), exact.allocation_left);
    try t.expectEqual(@as(u64, 0), exact.work_left);
    for ([_]bool{ false, true }) |allocation_short| {
        var short = image.Budget.trial();
        if (allocation_short) short.allocation_left = allocation - 1 else short.work_left = work - 1;
        var short_ctx = try image.Context.init(t.allocator, image.Limits.trial(), &short, 0);
        try t.expectError(error.BudgetExceeded, image.save(&short_ctx, source.machine(), source.program.identity));
        try t.expectEqual(@as(u64, 0), short_ctx.live);
    }
    for (0..allocations) |failure| {
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = failure });
        var budget = image.Budget.trial();
        var ctx = try image.Context.init(failing.allocator(), image.Limits.trial(), &budget, 0);
        try t.expectError(error.OutOfMemory, image.save(&ctx, source.machine(), source.program.identity));
        try t.expect(failing.has_induced_failure);
        try t.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        try t.expectEqual(@as(u64, 0), ctx.live);
    }
    try t.expect(source.pending == null);
    source.allow.admitAll();
    const got = (try source.machine().scanWithScratch("aaa", 0, &source.allow, .longest, null, source.winners)).?;
    try t.expectEqual(@as(usize, 3), got.len);
    try t.expectEqualSlices(u32, &.{ 0, 1 }, got.patterns);
    try t.expectEqual(builds, kernel.determinizations);
}
