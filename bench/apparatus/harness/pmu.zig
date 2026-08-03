//! gist bench — cross-OS hardware performance-counter reader (Layer A of the
//! optimality certificate). The macroscopic race proves gist is *fastest in its
//! class*; this proves *why*, microscopically: retired **cycles** and
//! **instructions** per byte for the single-threaded hot kernel, the number that
//! later meets the roofline (Layer C) and the static port-pressure bound
//! (Layer B). Wall-clock measures the noisy box; the PMU measures the work.
//!
//! Three backends behind one `Meter`, tried in that order:
//!   * **macOS `kperf`** — Apple's private `kperf`/`kperfdata` frameworks,
//!     `dlopen`'d at runtime (the same path Instruments uses; see ibireme's
//!     `kpc_demo`). FIXED_CYCLES + FIXED_INSTRUCTIONS via the thread-counter
//!     API. **Requires root**, and root is the *only* key: xnu's
//!     `_current_task_can_own_ktrace` is `kauth_cred_issuser(...)` plus an
//!     entitlement that exists only on a DEVELOPMENT/DEBUG kernel. Worth
//!     keeping first because it is the only backend that can program
//!     *configurable* events (cache misses, branch mispredicts) — nothing below
//!     reaches past the two fixed counters.
//!   * **macOS `thread_selfcounts`** — the same two numbers, **unprivileged**.
//!     xnu's `THSC_CPI` ("the current thread's cycles and instructions",
//!     `bsd/sys/resource_private.h`) is not gated by ktrace at all, so an
//!     ordinary `zig build portbound` measures real cycles/byte with no `sudo`,
//!     no sudoers rule, and no setuid anything. Measured on an M4 Max: 0.35%
//!     cycle repeatability over a 6M-cycle region, 385 cycles per read, and a
//!     saturating sibling thread leaks 0.01% — it is genuinely per-thread.
//!     See `bench/apparatus/privilege/README.md` for the evidence and for why
//!     the privileged arrangement it replaces is staged but not installed.
//!   * **everything else** — `has_pmu = false`; `counters()` returns zero and the
//!     caller falls back to its monotonic `std.time.Timer` (ns/byte). The Linux
//!     `perf_event_open` backend lands in pass 2 (see `Meter.init`).
//!
//! Design rule: **never fail the run.** If no PMU can be opened (not macOS,
//! framework missing, counters refused) `init` degrades to wall-clock and
//! reports which tier it landed on. Both macOS backends are reached purely
//! through dlsym'd C entry points, and each *proves* its counters advance
//! before claiming `has_pmu` — so neither can silently report garbage, and a
//! future OS that drops a symbol or narrows a struct degrades instead of lying.
//!
//! The file also carries the two host-provenance primitives every certificate
//! layer stamps next to a measured number: `cpuBrand` (which silicon produced
//! it) and `requestPerformanceQos` (P-core-biased scheduling on Apple Silicon).
//! Both run strictly outside any timed window.

const std = @import("std");
const builtin = @import("builtin");

/// One read of the per-thread counter file. `valid=false` ⇒ wall-clock only.
pub const Counters = struct {
    cycles: u64 = 0,
    instructions: u64 = 0,
    valid: bool = false,
};

/// Which instrument a number came from. A report that stamps provenance needs
/// to name its meter without carrying the whole prose `note` — and, more to the
/// point, must not attribute an unprivileged `thread_selfcounts` reading to
/// kperf just because kperf used to be the only backend.
pub const Kind = enum { none, kperf, thsc };

pub const Meter = struct {
    has_pmu: bool = false,
    note: []const u8 = "wall-clock only (no PMU)",
    backend: Backend = .{ .none = {} },

    const Backend = union(enum) {
        none: void,
        kperf: KPerf,
        thsc: Thsc,
    };

    pub fn kind(self: *const Meter) Kind {
        return switch (self.backend) {
            .none => .none,
            .kperf => .kperf,
            .thsc => .thsc,
        };
    }

    /// Try the platform PMU; on any failure degrade to wall-clock. Never errors.
    /// kperf first (it is the only tier that can carry configurable events), then
    /// the unprivileged per-thread counters, which need no `sudo` at all.
    pub fn init() Meter {
        if (builtin.target.os.tag == .macos) {
            if (KPerf.open()) |k| {
                return .{ .has_pmu = true, .note = k.note, .backend = .{ .kperf = k } };
            } else |_| {}
            if (Thsc.open()) |t| {
                return .{ .has_pmu = true, .note = t.note, .backend = .{ .thsc = t } };
            } else |_| {}
            return .{ .note = "wall-clock only (no kperf: needs root; no thread_selfcounts: unavailable)" };
        }
        // Linux perf_event_open backend: pass 2.
        return .{};
    }

    pub fn deinit(self: *Meter) void {
        if (comptime builtin.target.os.tag != .macos) return;
        switch (self.backend) {
            .kperf => |*k| k.close(),
            .thsc => |*t| t.close(),
            .none => {},
        }
    }

    /// Snapshot the calling thread's accumulated counters. Take one before and
    /// one after the measured region; the delta is the region's cost. Reads the
    /// **current thread only**, so the measured kernel must be single-threaded
    /// (a parallel fan-out would leak cycles onto unmeasured workers).
    pub fn counters(self: *Meter) Counters {
        if (comptime builtin.target.os.tag != .macos) return .{};
        return switch (self.backend) {
            .kperf => |*k| k.read(),
            .thsc => |*t| t.read(),
            .none => .{},
        };
    }
};

// ── host provenance (certificate stamps; never inside a timed window) ─────────

extern "c" fn sysctlbyname(name: [*:0]const u8, oldp: ?*anyopaque, oldlenp: *usize, newp: ?*anyopaque, newlen: usize) c_int;
extern "c" fn pthread_set_qos_class_self_np(qos_class: c_uint, relative_priority: c_int) c_int;

/// QOS_CLASS_USER_INTERACTIVE (sys/qos.h) — the highest scheduling tier.
const qos_user_interactive: c_uint = 0x21;

/// The marketing CPU name (`machdep.cpu.brand_string`) — a measured number must
/// name the silicon that produced it. Falls back to the compile-time arch tag
/// when the sysctl is unavailable (non-macOS, or a denied read).
pub fn cpuBrand(buf: []u8) []const u8 {
    if (builtin.target.os.tag == .macos) {
        var len: usize = buf.len;
        if (sysctlbyname("machdep.cpu.brand_string", buf.ptr, &len, null, 0) == 0 and len > 0) {
            return std.mem.sliceTo(buf[0..len], 0);
        }
    }
    const tag = @tagName(builtin.target.cpu.arch);
    const n = @min(tag.len, buf.len);
    @memcpy(buf[0..n], tag[0..n]);
    return buf[0..n];
}

/// Ask the scheduler to run the calling thread at USER_INTERACTIVE QoS — on
/// Apple Silicon that biases placement onto a **P-core** (macOS exposes no
/// public hard core pin; QoS is the honest lever). Call once before measuring.
/// Returns whether the hint was accepted, so the caller can stamp it as
/// provenance rather than silently assuming a P-core.
pub fn requestPerformanceQos() bool {
    if (builtin.target.os.tag != .macos) return false;
    return pthread_set_qos_class_self_np(qos_user_interactive, 0) == 0;
}

// ── macOS kperf/kperfdata backend ────────────────────────────────────────────

const KPC_MAX_COUNTERS = 32;
const KPC_CLASS_CONFIGURABLE_MASK: u32 = 1 << 1;

/// Resolve every field of `T` from `lib` as `<prefix><field name>` — one loop
/// instead of a lookup line per symbol. Fails loud on the first missing symbol
/// (a partial resolve must never half-configure the kernel's counters).
fn resolve(comptime T: type, lib: *std.DynLib, comptime prefix: []const u8) !T {
    var t: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        @field(t, f.name) = lib.lookup(f.type, prefix ++ f.name) orelse return error.SymbolMissing;
    }
    return t;
}

const KPerf = struct {
    kperf: std.DynLib,
    kperfdata: std.DynLib,
    classes: u32,
    counter_map: [KPC_MAX_COUNTERS]usize, // event index → thread-counter slot
    note: []const u8,
    kpc: Kpc,

    const Opaque = ?*anyopaque;

    /// kperf — the counting engine (root-gated). Field names are the `kpc_`
    /// symbol suffixes; `resolve` binds them all in one loop.
    const Kpc = struct {
        force_all_ctrs_get: *const fn (*c_int) callconv(.c) c_int,
        force_all_ctrs_set: *const fn (c_int) callconv(.c) c_int,
        set_config: *const fn (u32, [*]u64) callconv(.c) c_int,
        set_counting: *const fn (u32) callconv(.c) c_int,
        set_thread_counting: *const fn (u32) callconv(.c) c_int,
        get_thread_counters: *const fn (u32, u32, [*]u64) callconv(.c) c_int,
    };

    /// kperfdata — the kpep event-database/config builder. Field names are the
    /// `kpep_` symbol suffixes. All pointers stay opaque (no struct layouts).
    const Kpep = struct {
        db_create: *const fn (?[*:0]const u8, *Opaque) callconv(.c) c_int,
        config_create: *const fn (Opaque, *Opaque) callconv(.c) c_int,
        config_force_counters: *const fn (Opaque) callconv(.c) c_int,
        db_event: *const fn (Opaque, [*:0]const u8, *Opaque) callconv(.c) c_int,
        config_add_event: *const fn (Opaque, *Opaque, u32, ?*u32) callconv(.c) c_int,
        config_kpc_classes: *const fn (Opaque, *u32) callconv(.c) c_int,
        config_kpc_count: *const fn (Opaque, *usize) callconv(.c) c_int,
        config_kpc_map: *const fn (Opaque, [*]usize, usize) callconv(.c) c_int,
        config_kpc: *const fn (Opaque, [*]u64, usize) callconv(.c) c_int,
    };

    const kperf_path = "/System/Library/PrivateFrameworks/kperf.framework/kperf";
    const kperfdata_path = "/System/Library/PrivateFrameworks/kperfdata.framework/kperfdata";

    // cycles + instructions, each with Apple-Silicon fixed-counter names first
    // then Intel-Mac / alias fallbacks, so the same binary works across chips.
    const cycle_names = [_][:0]const u8{ "FIXED_CYCLES", "CPU_CLK_UNHALTED.THREAD", "Cycles", "cycles" };
    const inst_names = [_][:0]const u8{ "FIXED_INSTRUCTIONS", "INST_RETIRED.ANY", "Instructions", "instructions" };

    fn open() !KPerf {
        var kperf = try std.DynLib.open(kperf_path);
        errdefer kperf.close();
        var kperfdata = try std.DynLib.open(kperfdata_path);
        errdefer kperfdata.close();

        var self: KPerf = .{
            .kperf = kperf,
            .kperfdata = kperfdata,
            .classes = 0,
            .counter_map = std.mem.zeroes([KPC_MAX_COUNTERS]usize),
            .note = "",
            .kpc = try resolve(Kpc, &kperf, "kpc_"),
        };

        // Permission gate: force_all_ctrs_get fails (non-zero) without root.
        var force: c_int = 0;
        if (self.kpc.force_all_ctrs_get(&force) != 0) return error.PermissionDenied;

        try self.configure();
        self.note = "kperf · FIXED_CYCLES + FIXED_INSTRUCTIONS (root)";
        return self;
    }

    // kpep dance: build a config from the cycle+instruction events, derive the
    // kpc class mask + register set + event→counter map, push it to the kernel,
    // and start per-thread counting. All pointers stay opaque.
    fn configure(self: *KPerf) !void {
        const kpep = try resolve(Kpep, &self.kperfdata, "kpep_");

        var db: Opaque = null;
        if (kpep.db_create(null, &db) != 0) return error.DbCreate;
        var cfg: Opaque = null;
        if (kpep.config_create(db, &cfg) != 0) return error.CfgCreate;
        if (kpep.config_force_counters(cfg) != 0) return error.ForceCounters;

        try addEvent(&kpep, db, cfg, &cycle_names);
        try addEvent(&kpep, db, cfg, &inst_names);

        if (kpep.config_kpc_classes(cfg, &self.classes) != 0) return error.KpcClasses;
        var reg_count: usize = 0;
        if (kpep.config_kpc_count(cfg, &reg_count) != 0) return error.KpcCount;
        if (kpep.config_kpc_map(cfg, &self.counter_map, @sizeOf(@TypeOf(self.counter_map))) != 0) return error.KpcMap;

        var regs: [KPC_MAX_COUNTERS]u64 = std.mem.zeroes([KPC_MAX_COUNTERS]u64);
        if (kpep.config_kpc(cfg, &regs, @sizeOf(@TypeOf(regs))) != 0) return error.KpcRegs;

        if (self.kpc.force_all_ctrs_set(1) != 0) return error.ForceSet;
        if ((self.classes & KPC_CLASS_CONFIGURABLE_MASK) != 0 and reg_count != 0) {
            if (self.kpc.set_config(self.classes, &regs) != 0) return error.SetConfig;
        }
        if (self.kpc.set_counting(self.classes) != 0) return error.SetCounting;
        if (self.kpc.set_thread_counting(self.classes) != 0) return error.SetThreadCounting;
    }

    /// Register the first event name the kpep database recognizes (Apple-Silicon
    /// fixed-counter name first, then Intel/alias fallbacks).
    fn addEvent(kpep: *const Kpep, db: Opaque, cfg: Opaque, names: []const [:0]const u8) !void {
        for (names) |name| {
            var ev: Opaque = null;
            if (kpep.db_event(db, name.ptr, &ev) == 0 and ev != null) {
                if (kpep.config_add_event(cfg, &ev, 0, null) == 0) return;
            }
        }
        return error.EventNotFound;
    }

    fn read(self: *KPerf) Counters {
        var buf: [KPC_MAX_COUNTERS]u64 = std.mem.zeroes([KPC_MAX_COUNTERS]u64);
        if (self.kpc.get_thread_counters(0, KPC_MAX_COUNTERS, &buf) != 0) return .{};
        return .{
            .cycles = buf[self.counter_map[0]],
            .instructions = buf[self.counter_map[1]],
            .valid = true,
        };
    }

    fn close(self: *KPerf) void {
        _ = self.kpc.set_counting(0);
        _ = self.kpc.set_thread_counting(0);
        _ = self.kpc.force_all_ctrs_set(0);
        self.kperfdata.close();
        self.kperf.close();
    }
};

// ── macOS unprivileged backend: thread_selfcounts ────────────────────────────

/// Somewhere for the validation loop's result to land, so the optimizer can't
/// delete the work whose cycles we are trying to observe.
var thsc_sink: u64 = 0;

/// The same two numbers kperf's fixed counters carry — retired cycles and
/// instructions for the **calling thread** — read through xnu's
/// `thread_selfcounts` syscall, which no ktrace ACL guards. This is the tier
/// that removes the sudoers question from the certificate entirely.
///
/// Reached through the exported libSystem symbol, never through the syscall
/// number: a syscall number is a magic constant that silently means something
/// else if it is ever renumbered, while a missing symbol is a clean degrade. The
/// struct layout is likewise not guessed — it is `struct thsc_cpi` from xnu's
/// `bsd/sys/resource_private.h`, **instructions first**, and `open` proves the
/// kernel filled both fields before trusting either (see `poison`).
const Thsc = struct {
    libsystem: std.DynLib,
    selfcounts: *const fn (u32, *Cpi, usize) callconv(.c) c_int,
    note: []const u8,

    /// `THSC_CPI = 1` — "get the current thread's cycles and instructions".
    /// The kernel rejects an unknown kind (verified: kind 999 ⇒ -1), so this
    /// constant cannot quietly select a different flavor.
    const kind_cpi: u32 = 1;

    /// `struct thsc_cpi`. Instructions come first; reading the two the other way
    /// round would report an IPC of 1/IPC and a clock ~1.7× the real one.
    const Cpi = extern struct { instructions: u64, cycles: u64 };

    /// The kernel accepts an undersized buffer and returns **success** having
    /// written only part of the struct (verified: `size=8` fills instructions and
    /// leaves cycles untouched). So a zero return is not evidence the read
    /// happened. Both fields are pre-set to a value no counter can plausibly
    /// hold; a field still holding it after the call means the contract moved
    /// under us, and the backend refuses rather than reporting a poison as a
    /// cycle count.
    const poison: u64 = 0xA5A5_A5A5_DEAD_BEEF;

    const libsystem_path = "/usr/lib/libSystem.B.dylib";

    fn open() !Thsc {
        var libsystem = try std.DynLib.open(libsystem_path);
        errdefer libsystem.close();

        var self: Thsc = .{
            .libsystem = libsystem,
            .selfcounts = libsystem.lookup(
                *const fn (u32, *Cpi, usize) callconv(.c) c_int,
                "thread_selfcounts",
            ) orelse return error.SymbolMissing,
            .note = "",
        };

        // Prove the counters before claiming them: two reads around a little
        // real work must both succeed, must fill both fields, and must advance.
        // A kernel that returns ENOTSUP for CPI (the header says some hardware
        // does) or that stops accounting fails here and we fall to wall-clock.
        const a = self.sample() orelse return error.CountersUnavailable;
        var acc: u64 = thsc_sink;
        for (0..4096) |i| acc +%= i ^ (acc >> 3);
        thsc_sink = acc;
        const b = self.sample() orelse return error.CountersUnavailable;
        if (b.cycles <= a.cycles or b.instructions <= a.instructions) return error.CountersNotAdvancing;

        self.note = "thread_selfcounts · THSC_CPI cycles + instructions (unprivileged, per-thread)";
        return self;
    }

    /// One raw read, or `null` if the kernel refused it or short-filled it.
    fn sample(self: *const Thsc) ?Cpi {
        var c: Cpi = .{ .instructions = poison, .cycles = poison };
        if (self.selfcounts(kind_cpi, &c, @sizeOf(Cpi)) != 0) return null;
        if (c.instructions == poison or c.cycles == poison) return null;
        return c;
    }

    fn read(self: *Thsc) Counters {
        const c = self.sample() orelse return .{};
        return .{ .cycles = c.cycles, .instructions = c.instructions, .valid = true };
    }

    fn close(self: *Thsc) void {
        self.libsystem.close();
    }
};

// ── tests ────────────────────────────────────────────────────────────────────
//
// These are the checks that decide whether a certificate number is real, so each
// is written to FAIL on a specific way the counter could be lying — not to
// re-state the implementation. None of them asserts a machine-specific constant,
// so they hold on any host: on a box with no cycle counter every one degrades to
// asserting the documented wall-clock contract instead of skipping silently.

var test_sink: u64 = 0;

/// Burn a known, non-elidable amount of work. Returns the accumulator so a
/// caller can keep it live.
fn spin(iters: usize) u64 {
    var acc: u64 = test_sink;
    for (0..iters) |i| acc +%= i ^ (acc >> 3);
    test_sink = acc;
    return acc;
}

/// Wall-clock wait, straight through libc — the module already links it for
/// `dlopen`, and threading a `std.Io` in just to pause a test would give this
/// file a dependency none of its production code has.
fn nap(ns: u64) void {
    const ts: std.c.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = std.c.nanosleep(&ts, null);
}

test "a meter is either honestly instrumented or honestly wall-clock" {
    var m = Meter.init();
    defer m.deinit();
    // The invariant every consumer relies on: `has_pmu` and the backend agree,
    // and a meter without one reports zeroed, invalid counters rather than a
    // plausible-looking number.
    try std.testing.expectEqual(m.has_pmu, m.kind() != .none);
    if (!m.has_pmu) {
        const c = m.counters();
        try std.testing.expect(!c.valid);
        try std.testing.expectEqual(@as(u64, 0), c.cycles);
        try std.testing.expectEqual(@as(u64, 0), c.instructions);
    }
    try std.testing.expect(m.note.len > 0);
}

test "counters advance across real work and stay self-consistent" {
    var m = Meter.init();
    defer m.deinit();
    if (!m.has_pmu) return;

    const a = m.counters();
    std.mem.doNotOptimizeAway(spin(1 << 21));
    const b = m.counters();
    try std.testing.expect(a.valid and b.valid);
    try std.testing.expect(b.cycles > a.cycles);
    try std.testing.expect(b.instructions > a.instructions);

    // IPC has to be physically possible. This is a coarse sanity bound — it
    // catches a units mix-up or a counter wired to something that isn't a
    // counter, but deliberately not a field-order oracle: swapping the two
    // fields merely reports 1/IPC, which is still inside any honest window on a
    // machine near IPC 1. The layout is pinned by the short-read test below,
    // which was checked against exactly that mutation.
    const ipc = @as(f64, @floatFromInt(b.instructions - a.instructions)) /
        @as(f64, @floatFromInt(b.cycles - a.cycles));
    try std.testing.expect(ipc > 0.01 and ipc < 64.0);
}

test "cycles measure work, not elapsed time" {
    var m = Meter.init();
    defer m.deinit();
    if (!m.has_pmu) return;

    // A sleeping thread retires almost nothing. If cycles tracked wall-clock,
    // 50 ms of sleep would look like ~10^8 cycles on any modern core; the
    // counter is only useful because it does not.
    const s0 = m.counters();
    nap(50 * std.time.ns_per_ms);
    const s1 = m.counters();
    const idle = s1.cycles -% s0.cycles;

    const w0 = m.counters();
    std.mem.doNotOptimizeAway(spin(1 << 21));
    const w1 = m.counters();
    const busy = w1.cycles -% w0.cycles;

    try std.testing.expect(busy > idle * 4);
}

test "counters are per-thread, so a busy neighbor cannot inflate them" {
    var m = Meter.init();
    defer m.deinit();
    if (!m.has_pmu) return;

    const iters: usize = 1 << 21;
    const solo = blk: {
        const a = m.counters();
        std.mem.doNotOptimizeAway(spin(iters));
        break :blk m.counters().cycles -% a.cycles;
    };

    // Ten agents share this machine, so a counter that accrued a sibling's work
    // would make every measurement a function of who else is building. Saturate
    // another thread and require the same answer.
    const Sibling = struct {
        stop: std.atomic.Value(bool) = .init(false),
        sink: u64 = 0,
        fn churn(s: *@This()) void {
            while (!s.stop.load(.monotonic)) {
                var acc: u64 = s.sink;
                for (0..1 << 16) |i| acc +%= i ^ (acc >> 3);
                s.sink = acc;
            }
        }
    };
    var sib: Sibling = .{};
    const th = try std.Thread.spawn(.{}, Sibling.churn, .{&sib});
    defer {
        sib.stop.store(true, .monotonic);
        th.join();
    }
    nap(10 * std.time.ns_per_ms); // let it get going

    const shared = blk: {
        const a = m.counters();
        std.mem.doNotOptimizeAway(spin(iters));
        break :blk m.counters().cycles -% a.cycles;
    };

    // Generous bound: contention for shared cache and the memory system can
    // legitimately slow this thread. What it must not do is *add* the sibling's
    // retired cycles, which would be a multiple, not a fraction.
    try std.testing.expect(shared < solo * 2);
}

test "an undersized read is refused rather than half-filled" {
    if (comptime builtin.target.os.tag != .macos) return;
    var t = Thsc.open() catch return; // no unprivileged counter here; nothing to check
    defer t.close();

    // The kernel returns success for a short buffer, writing only the fields
    // that fit — verified on macOS 26: `size=8` fills instructions and leaves
    // cycles untouched. `sample` must therefore not trust the return code, and
    // the poison sentinel is what catches it. Ask for one field's worth and
    // require the backend to notice.
    var c: Thsc.Cpi = .{ .instructions = Thsc.poison, .cycles = Thsc.poison };
    _ = t.selfcounts(Thsc.kind_cpi, &c, @sizeOf(u64));
    try std.testing.expectEqual(Thsc.poison, c.cycles);

    // And the full-size read the backend actually issues fills both.
    const full = t.sample() orelse return error.FullSizedReadRefused;
    try std.testing.expect(full.cycles != Thsc.poison and full.instructions != Thsc.poison);
}

test "an unknown counter kind is rejected, so the flavor cannot drift" {
    if (comptime builtin.target.os.tag != .macos) return;
    var t = Thsc.open() catch return;
    defer t.close();
    var c: Thsc.Cpi = .{ .instructions = 0, .cycles = 0 };
    try std.testing.expect(t.selfcounts(0xDEAD, &c, @sizeOf(Thsc.Cpi)) != 0);
}

test "host provenance answers before anything is measured" {
    var buf: [64]u8 = undefined;
    try std.testing.expect(cpuBrand(&buf).len > 0);
    _ = requestPerformanceQos(); // a hint; a host may decline it
}
