//! irregex bench — cross-OS hardware performance-counter reader (Layer A of the
//! optimality certificate). The macroscopic race proves the shipped CLI is
//! *fastest in its class*; this proves *why*, microscopically: retired **cycles**
//! and **instructions** per byte for the single-threaded hot kernel, the number that
//! later meets the roofline (Layer C) and the static port-pressure bound
//! (Layer B). Wall-clock measures the noisy box; the PMU measures the work.
//!
//! Five backends behind one `Meter`, each tried on the one OS that has it:
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
//!   * **Linux `perf_event_open`** — `PERF_COUNT_HW_CPU_CYCLES` and
//!     `PERF_COUNT_HW_INSTRUCTIONS` as one **group**, read in a single
//!     `read()`. Unprivileged: `exclude_kernel` is what carries it past
//!     `kernel.perf_event_paranoid = 2`, the hardened default most
//!     distributions and container images ship. This is where most regex work
//!     actually runs, so without it the best-measured numbers in the repo were
//!     unmeasurable on the platform that cares about them.
//!   * **Windows `QueryThreadCycleTime`** — per-thread cycles, unprivileged, no
//!     driver. **Cycles only**: Windows has no unprivileged retired-instruction
//!     counter, so this tier reports `counts_instructions = false` rather than
//!     manufacturing an IPC out of a wall clock.
//!   * **everything else** — `has_pmu = false`; `counters()` returns zero and the
//!     caller falls back to its monotonic `std.time.Timer` (ns/byte).
//!
//! Design rule: **never fail the run.** If no PMU can be opened (framework
//! missing, paranoid ceiling too high, no PMU behind the hypervisor) `init`
//! degrades to wall-clock and reports which tier it landed on — and the note
//! names the wall it hit, because "one `sysctl` away from a real number" and
//! "this box has no counters" are different situations for whoever reads the
//! certificate. Every backend *proves* its counters advance before claiming
//! `has_pmu`, so none can silently report garbage, and a future OS that drops a
//! symbol, narrows a struct, or opens an event that never increments degrades
//! instead of lying.
//!
//! The file also carries the two host-provenance primitives every certificate
//! layer stamps next to a measured number: `cpuBrand` (which silicon produced
//! it) and `requestPerformanceQos` (as hot a thread as an unprivileged process
//! may ask for, which is a different lever per OS: QoS class on macOS, thread
//! priority on Windows, and a pin onto the fastest core class on Linux).
//! Both run strictly outside any timed window.

const std = @import("std");
const builtin = @import("builtin");

/// One read of the per-thread counter file. `valid=false` ⇒ wall-clock only.
///
/// The two flags are separate claims, and the split is not decoration: Windows
/// can honestly report cycles and has no unprivileged instruction counter at
/// all. `valid` means **the cycle count is a measurement**; `counts_instructions`
/// additionally means the instruction count is. A consumer that reads `valid`
/// and then divides gets an IPC of zero on such a host, which is why every
/// derived-from-instructions column has to test the second flag.
pub const Counters = struct {
    cycles: u64 = 0,
    instructions: u64 = 0,
    /// The cycle count is real.
    valid: bool = false,
    /// …and so is the instruction count. A backend that cannot count
    /// instructions leaves this false and `instructions` at zero rather than
    /// filling the field with something that merely has the right units.
    counts_instructions: bool = false,
};

/// Which instrument a number came from. A report that stamps provenance needs
/// to name its meter without carrying the whole prose `note` — and, more to the
/// point, must not attribute an unprivileged `thread_selfcounts` reading to
/// kperf just because kperf used to be the only backend.
pub const Kind = enum { none, kperf, thsc, perf, qtct };

pub const Meter = struct {
    has_pmu: bool = false,
    /// Whether this meter counts retired instructions too. Published on the
    /// meter rather than only on a `Counters` so a report can decide whether it
    /// has an IPC column to print **before** it measures anything — a table
    /// that discovers the gap after the first read has already chosen a header.
    has_instructions: bool = false,
    note: []const u8 = "wall-clock only (no PMU)",
    backend: Backend = .{ .none = {} },

    const Backend = union(enum) {
        none: void,
        kperf: KPerf,
        thsc: Thsc,
        perf: Perf,
        qtct: Qtct,
    };

    pub fn kind(self: *const Meter) Kind {
        return switch (self.backend) {
            .none => .none,
            .kperf => .kperf,
            .thsc => .thsc,
            .perf => .perf,
            .qtct => .qtct,
        };
    }

    /// Try the platform PMU; on any failure degrade to wall-clock. Never errors.
    /// One ordered try-list per OS: on macOS kperf first (it is the only tier
    /// that can carry configurable events), then the unprivileged per-thread
    /// counters, which need no `sudo` at all. Linux and Windows each have
    /// exactly one unprivileged tier, so their list is one entry long and the
    /// interesting part is the note the failure leaves behind.
    pub fn init() Meter {
        switch (comptime builtin.target.os.tag) {
            .macos => {
                if (KPerf.open()) |k| {
                    return .{ .has_pmu = true, .has_instructions = true, .note = k.note, .backend = .{ .kperf = k } };
                } else |_| {}
                if (Thsc.open()) |t| {
                    return .{ .has_pmu = true, .has_instructions = true, .note = t.note, .backend = .{ .thsc = t } };
                } else |_| {}
                return .{ .note = "wall-clock only (no kperf: needs root; no thread_selfcounts: unavailable)" };
            },
            .linux => {
                if (Perf.open()) |p| {
                    return .{ .has_pmu = true, .has_instructions = true, .note = p.note, .backend = .{ .perf = p } };
                } else |err| return .{ .note = Perf.explain(err) };
            },
            .windows => {
                if (Qtct.open()) |q| {
                    return .{ .has_pmu = true, .note = q.note, .backend = .{ .qtct = q } };
                } else |_| {}
                return .{ .note = "wall-clock only (QueryThreadCycleTime unavailable or not advancing)" };
            },
            else => return .{},
        }
    }

    pub fn deinit(self: *Meter) void {
        switch (self.backend) {
            .kperf => |*k| k.close(),
            .thsc => |*t| t.close(),
            .perf => |*p| p.close(),
            .qtct => |*q| q.close(),
            .none => {},
        }
    }

    /// Snapshot the calling thread's accumulated counters. Take one before and
    /// one after the measured region; the delta is the region's cost. Reads the
    /// **current thread only**, so the measured kernel must be single-threaded
    /// (a parallel fan-out would leak cycles onto unmeasured workers).
    pub fn counters(self: *Meter) Counters {
        return switch (self.backend) {
            .kperf => |*k| k.read(),
            .thsc => |*t| t.read(),
            .perf => |*p| p.read(),
            .qtct => |*q| q.read(),
            .none => .{},
        };
    }
};

// ── host provenance (certificate stamps; never inside a timed window) ─────────

extern "c" fn sysctlbyname(name: [*:0]const u8, oldp: ?*anyopaque, oldlenp: *usize, newp: ?*anyopaque, newlen: usize) c_int;
extern "c" fn pthread_set_qos_class_self_np(qos_class: c_uint, relative_priority: c_int) c_int;

/// QOS_CLASS_USER_INTERACTIVE (sys/qos.h) — the highest scheduling tier.
const qos_user_interactive: c_uint = 0x21;

/// `THREAD_PRIORITY_HIGHEST` (winbase.h) — the top of the *within-class* band,
/// which is as far as an unprivileged process gets without raising the whole
/// process's priority class.
const thread_priority_highest: c_int = 2;

/// The marketing CPU name — a measured number must name the silicon that
/// produced it. Four sources, narrowest first: macOS's
/// `machdep.cpu.brand_string`, the x86 brand string out of the silicon itself,
/// the board/SoC name Linux publishes for the arches that have no such
/// instruction, and finally the compile-time arch tag, which always answers.
/// Never fails and never writes past `buf`.
pub fn cpuBrand(buf: []u8) []const u8 {
    if (builtin.target.os.tag == .macos) {
        var len: usize = buf.len;
        if (sysctlbyname("machdep.cpu.brand_string", buf.ptr, &len, null, 0) == 0 and len > 0) {
            return std.mem.sliceTo(buf[0..len], 0);
        }
    }
    // Any OS on x86-64: CPUID is above the kernel, so this one arm serves Linux
    // and Windows both, and needs neither a `/proc` parse nor a registry read.
    if (comptime builtin.target.cpu.arch == .x86_64 and builtin.cpu.has(.x86, .cx8)) {
        if (cpuidBrand(buf)) |brand| return brand;
    }
    if (builtin.target.os.tag == .linux) {
        // aarch64 has no brand-string instruction, so the name lives in a file.
        // Ordered by how specific the answer is: the SoC's own machine name, the
        // device tree's board model, then whatever `/proc/cpuinfo` admits to —
        // `model name` on the kernels that emit it, and the MIDR part id as the
        // last thing that still identifies a core rather than an architecture.
        if (fileLine(buf, "/sys/devices/soc0/machine")) |name| return name;
        if (fileLine(buf, "/sys/firmware/devicetree/base/model")) |name| return name;
        if (procField(buf, "model name")) |name| return name;
        if (procField(buf, "CPU part")) |name| return name;
    }
    const tag = @tagName(builtin.target.cpu.arch);
    const n = @min(tag.len, buf.len);
    @memcpy(buf[0..n], tag[0..n]);
    return buf[0..n];
}

/// Ask the scheduler to run the calling thread as hot as an unprivileged
/// process may ask. Call once before measuring. Returns whether the hint was
/// accepted, so the caller can stamp it as provenance rather than silently
/// assuming a fast core — and the lever differs per OS:
///
///   * **macOS** — USER_INTERACTIVE QoS, which on Apple Silicon biases
///     placement onto a **P-core**; macOS exposes no public hard core pin, so
///     QoS is the honest lever.
///   * **Windows** — `THREAD_PRIORITY_HIGHEST`, which buys less preemption
///     rather than a core class. Windows offers no unprivileged
///     heterogeneous-core placement request either.
///   * **Linux** — `sched_setaffinity(2)` onto the fastest core class, when the
///     host has more than one. Priority is still not available (`nice(2)` and
///     `setpriority(2)` can only *lower* without `CAP_SYS_NICE`, and
///     `sched_setscheduler(SCHED_FIFO)` wants the same capability), but core
///     placement is, and on a hybrid part it is the lever that matters.
///
///     This returned false, on the reasoning that affinity meant pinning to a
///     CPU we would have to *guess* was a performance core. The premise was
///     wrong: the kernel publishes the answer in `cpufreq/cpuinfo_max_freq`, so
///     the class is READ, never guessed — and the cost of not asking is not the
///     one report line the old note weighed. On the i5-13500 this package mints
///     x86 coefficients on, P-cores top out at 4.8 GHz and E-cores at 3.5, both
///     confirmed against the chain in `assay.Cadence`. A clock sampled on one
///     class and coefficients timed on the other differ by 1.37× with nothing in
///     the output saying so, which is a wrong number rather than a missing one.
///
///     Still fail-closed, and still an honest claim: false when sysfs cannot be
///     read, when every available CPU is the same speed (nothing to arrange), or
///     when the pin is refused. True means this thread is now confined to the
///     fastest class the host offers.
pub fn requestPerformanceQos() bool {
    if (builtin.target.os.tag == .macos) return pthread_set_qos_class_self_np(qos_user_interactive, 0) == 0;
    if (builtin.target.os.tag == .windows) {
        return SetThreadPriority(std.os.windows.GetCurrentThread(), thread_priority_highest).toBool();
    }
    if (builtin.target.os.tag == .linux) return pinToFastestCores();
    return false;
}

/// Confine this thread to the CPUs whose advertised ceiling is the highest of
/// those it may currently run on. Returns false unless that set is a strict
/// subset of where it could already go — a machine with one core class has no
/// performance class, and reporting that we "arranged" something there would be
/// the same overclaim the Linux arm used to avoid by doing nothing.
fn pinToFastestCores() bool {
    var current: std.os.linux.cpu_set_t = undefined;
    if (std.os.linux.sched_getaffinity(0, @sizeOf(std.os.linux.cpu_set_t), &current) != 0) return false;

    const word_bits = @bitSizeOf(usize);
    const slots = @typeInfo(std.os.linux.cpu_set_t).array.len * word_bits;

    var top: u64 = 0;
    var fastest = std.mem.zeroes(std.os.linux.cpu_set_t);
    var eligible: usize = 0;
    var chosen: usize = 0;
    for (0..slots) |cpu| {
        if (current[cpu / word_bits] & (@as(usize, 1) << @intCast(cpu % word_bits)) == 0) continue;
        eligible += 1;
        // An unreadable ceiling is not a slow core, it is an unknown one, and a
        // host without cpufreq at all reports none — which lands every CPU at
        // zero, leaves the set unnarrowed, and returns false below.
        const ceiling = cpuMaxKhz(cpu) orelse continue;
        if (ceiling > top) {
            top = ceiling;
            fastest = std.mem.zeroes(std.os.linux.cpu_set_t);
            chosen = 0;
        }
        if (ceiling == top) {
            fastest[cpu / word_bits] |= @as(usize, 1) << @intCast(cpu % word_bits);
            chosen += 1;
        }
    }

    if (chosen == 0 or chosen == eligible) return false;
    std.os.linux.sched_setaffinity(0, &fastest) catch return false;
    return true;
}

/// One CPU's advertised ceiling in kHz, or null when the host does not publish
/// one. Read from sysfs because that is where Linux states the P/E split; the
/// file is a short decimal integer and a newline.
fn cpuMaxKhz(cpu: usize) ?u64 {
    var path: [64]u8 = undefined;
    const name = std.fmt.bufPrint(
        &path,
        "/sys/devices/system/cpu/cpu{d}/cpufreq/cpuinfo_max_freq",
        .{cpu},
    ) catch return null;
    const fd = std.os.linux.open(@ptrCast(name.ptr), .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(fd)) < 0) return null;
    defer _ = std.os.linux.close(@intCast(fd));
    var buf: [32]u8 = undefined;
    const n = std.os.linux.read(@intCast(fd), &buf, buf.len);
    if (@as(isize, @bitCast(n)) <= 0) return null;
    return std.fmt.parseInt(u64, std.mem.trim(u8, buf[0..n], " \n\r\t"), 10) catch null;
}

/// The x86 brand string from CPUID leaves 0x8000_0002–0x8000_0004: 48 ASCII
/// bytes, NUL-padded and usually left-padded with spaces. The same marketing
/// name macOS hands back from its sysctl, which is what makes one arm here
/// enough for both other OSes.
///
/// Assembles into a fixed local and copies the trimmed result, so a caller with
/// a 16-byte buffer gets a truncated name rather than a stack smash.
fn cpuidBrand(buf: []u8) ?[]const u8 {
    if (cpuid(0x8000_0000, 0).eax < 0x8000_0004) return null;
    var brand: [48]u8 = undefined;
    inline for (0..3) |i| {
        const leaf = cpuid(0x8000_0002 + @as(u32, i), 0);
        const words = [_]u32{ leaf.eax, leaf.ebx, leaf.ecx, leaf.edx };
        @memcpy(brand[i * 16 ..][0..16], std.mem.asBytes(&words));
    }
    const name = std.mem.trim(u8, std.mem.sliceTo(&brand, 0), " ");
    if (name.len == 0) return null;
    const n = @min(name.len, buf.len);
    @memcpy(buf[0..n], name[0..n]);
    return buf[0..n];
}

const CpuidLeaf = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };

/// One CPUID leaf. A leaf helper that states its own precondition instead of
/// carrying a fallback, because there is no answer to give without the
/// instruction.
///
/// The guard is a **feature** predicate, not an architecture switch, because
/// LLVM does not look inside an `asm` template — an arm chosen by architecture
/// emits its instruction whatever floor the target declared, which is how a
/// baseline-tagged artifact ends up faulting (`quality/ratchets/isa-floor`).
/// CPUID itself has no LLVM feature bit: it is mandatory on every core x86-64
/// targets, so nothing optional exists to name. `cx8` (CMPXCHG8B) is the
/// narrowest bit that does exist — it arrived with the Pentium, the generation
/// that introduced CPUID, and it sits in the x86-64 baseline. So this can only
/// ever refuse a pre-Pentium 32-bit target, never wrongly emit.
fn cpuid(leaf_id: u32, subid: u32) CpuidLeaf {
    if (comptime !builtin.cpu.has(.x86, .cx8)) {
        @compileError("CPUID needs a Pentium-or-later x86; guard the call site on builtin.cpu.has(.x86, .cx8)");
    }
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf_id),
          [sub] "{ecx}" (subid),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

/// One `key : value` line out of `/proc/cpuinfo`. Only the first block is read:
/// every core repeats these fields, and the answer is a host property.
fn procField(buf: []u8, comptime key: []const u8) ?[]const u8 {
    var scratch: [4096]u8 = undefined;
    const text = readSome(&scratch, "/proc/cpuinfo") orelse return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..colon], " \t"), key)) continue;
        return copyTrimmed(buf, line[colon + 1 ..]);
    }
    return null;
}

/// A whole small sysfs attribute or device-tree property as one name. Trims both
/// the trailing newline sysfs adds and the NUL a device-tree string carries,
/// rather than guessing which of the two this path was.
fn fileLine(buf: []u8, comptime path: [:0]const u8) ?[]const u8 {
    var scratch: [256]u8 = undefined;
    const text = readSome(&scratch, path) orelse return null;
    return copyTrimmed(buf, std.mem.sliceTo(text, 0));
}

fn copyTrimmed(buf: []u8, raw: []const u8) ?[]const u8 {
    const name = std.mem.trim(u8, raw, " \t\r\n");
    if (name.len == 0) return null;
    const n = @min(name.len, buf.len);
    @memcpy(buf[0..n], name[0..n]);
    return buf[0..n];
}

/// Up to `buf.len` bytes of a file, straight through the raw syscalls: no
/// allocator and no `std.Io`, matching the rest of this module and keeping a
/// provenance stamp incapable of failing the run. Deliberately one partial
/// read — procfs and sysfs both report `st_size = 0`, so a size-then-read
/// helper would read nothing at all here.
fn readSome(buf: []u8, comptime path: [:0]const u8) ?[]const u8 {
    const linux = std.os.linux;
    const opened = linux.open(path.ptr, .{ .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    const got = linux.read(fd, buf.ptr, buf.len);
    if (linux.errno(got) != .SUCCESS or got == 0) return null;
    return buf[0..got];
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
            .counts_instructions = true,
        };
    }

    // `Meter.deinit` switches over every union prong, so this is analyzed even
    // on a target that could never have opened it — and `std.DynLib` has no
    // Windows arm at all (its `InnerType` there is a `@compileError` stub), so
    // an unguarded teardown makes the whole meter unbuildable for Windows. Each
    // backend therefore states its own OS precondition rather than relying on
    // one guard in the caller.
    fn close(self: *KPerf) void {
        if (comptime builtin.target.os.tag != .macos) return;
        _ = self.kpc.set_counting(0);
        _ = self.kpc.set_thread_counting(0);
        _ = self.kpc.force_all_ctrs_set(0);
        self.kperfdata.close();
        self.kperf.close();
    }
};

// ── shared prove-before-claiming scaffolding ─────────────────────────────────

/// Somewhere for the validation loop's result to land, so the optimizer can't
/// delete the work whose cycles we are trying to observe.
var probe_sink: u64 = 0;

/// A little real, non-elidable work — the interval each backend's
/// prove-before-claiming step measures across. Shared because "the counter
/// opened" and "the counter counts" are different claims on every one of them,
/// and a per-backend copy of this loop is a copy that can drift into proving
/// something else.
fn churn() void {
    var acc: u64 = probe_sink;
    for (0..4096) |i| acc +%= i ^ (acc >> 3);
    probe_sink = acc;
}

/// A value no counter can plausibly hold, pre-written into every field a kernel
/// is about to fill. Both the macOS short-read case and the Linux group read
/// need it for the same reason: a success return is not evidence that the bytes
/// arrived, so the only way to know a field was written is to have made it
/// recognizable beforehand.
const poison: u64 = 0xA5A5_A5A5_DEAD_BEEF;

// ── macOS unprivileged backend: thread_selfcounts ────────────────────────────

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
/// kernel filled both fields before trusting either.
///
/// That proof needs the shared `poison` sentinel for a specific reason: the
/// kernel accepts an undersized buffer and returns **success** having written
/// only part of the struct (verified on macOS 26: `size=8` fills instructions
/// and leaves cycles untouched). A zero return is therefore not evidence the
/// read happened, and a field still holding the sentinel afterwards means the
/// contract moved under us.
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
        churn();
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
        return .{ .cycles = c.cycles, .instructions = c.instructions, .valid = true, .counts_instructions = true };
    }

    fn close(self: *Thsc) void {
        if (comptime builtin.target.os.tag != .macos) return;
        self.libsystem.close();
    }
};

// ── Linux unprivileged backend: perf_event_open ──────────────────────────────

/// `PERF_COUNT_HW_CPU_CYCLES` and `PERF_COUNT_HW_INSTRUCTIONS` for the calling
/// thread — the same two numbers as both macOS tiers, through the one interface
/// Linux gives a process that is not root.
///
/// Three decisions carry this backend:
///
/// **One group, one `read()`.** The cycles event is the group leader and
/// instructions joins it as a member, so `PERF_FORMAT_GROUP` returns both in a
/// single syscall. Two independent reads would let the scheduler deschedule this
/// thread between them, and the pair would then describe two different instants
/// — reporting an IPC no core can physically produce. Grouping is also what lets
/// one `ioctl` zero and start both counters together.
///
/// **`exclude_kernel`.** This is what makes the reading survive
/// `kernel.perf_event_paranoid = 2` — the default on Debian, Ubuntu, and most
/// container images — which refuses any unprivileged event that has not
/// excluded kernel samples. It is also the right window on the merits: the
/// certificate prices the scan loop, not the reader's own syscall.
///
/// **`std.os.linux.perf_event_open`, not `std.posix`.** The posix wrapper maps
/// `EINVAL` and `ENOENT` to `unreachable`, and those are exactly what a
/// PMU-less virtualized host answers with. A meter whose whole contract is
/// "degrade, never fail" cannot sit on a wrapper that panics on the degrade
/// path. Going one layer down is still the std wrapper, so no syscall number is
/// spelled here.
const Perf = struct {
    leader: i32,
    member: i32,
    note: []const u8,

    /// `PERF_FORMAT_GROUP` from `enum perf_event_read_format`
    /// (`linux/perf_event.h`). `std.os.linux.PERF` carries TYPE, COUNT, FLAG and
    /// EVENT_IOC but no read formats, so this is the one constant here std
    /// cannot supply.
    const format_total_time_enabled: u64 = 1 << 0;
    const format_total_time_running: u64 = 1 << 1;
    const format_group: u64 = 1 << 3;
    const format_read: u64 = format_total_time_enabled |
        format_total_time_running |
        format_group;

    /// The `struct read_format` a `PERF_FORMAT_GROUP` read returns with both
    /// time fields asked for: the event count, how long the group was ENABLED,
    /// how long it was actually RUNNING on the hardware, then one value per
    /// event in the order they joined. `nr` is a layout check the kernel hands
    /// over for free — a kernel that filled a different shape cannot also say 2.
    ///
    /// The two time fields are the whole reason a read can be trusted. This
    /// struct did not carry them, on the reasoning that cycles and instructions
    /// land on fixed-function counters a two-event per-thread group never has
    /// to multiplex. That is true of ONE group and false of a machine running
    /// several: with twelve concurrent readers on this box, a group opened
    /// successfully, was never scheduled onto the PMU, and every `read` came
    /// back **zero** — so the meter reported `has_pmu` and handed out zeros,
    /// which is precisely the "a measurement or a zero" failure its own tests
    /// exist to catch. `zig build test` runs the roofline and portbound lanes
    /// beside this module's tests, each opening its own group, so the condition
    /// is not exotic: it is what the suite does every time.
    const Group = extern struct {
        nr: u64,
        time_enabled: u64,
        time_running: u64,
        cycles: u64,
        instructions: u64,
    };

    fn open() !Perf {
        // `inherit = false` because a certificate number is this thread's work
        // and not its children's — and because the ABI refuses to combine
        // inherited counters with a group read at all. `exclude_hv` is the
        // `exclude_kernel` argument one level down.
        var attr: std.os.linux.perf_event_attr = .{
            .type = .HARDWARE,
            .config = @intFromEnum(std.os.linux.PERF.COUNT.HW.CPU_CYCLES),
            .read_format = format_read,
            .flags = .{
                .disabled = true,
                .inherit = false,
                .exclude_kernel = true,
                .exclude_hv = true,
            },
        };
        const leader = try openEvent(&attr, -1);
        errdefer _ = std.os.linux.close(leader);

        attr.config = @intFromEnum(std.os.linux.PERF.COUNT.HW.INSTRUCTIONS);
        // Only the leader carries `disabled`; members are governed by it.
        attr.flags.disabled = false;
        const member = try openEvent(&attr, leader);
        errdefer _ = std.os.linux.close(member);

        // `IOC_FLAG_GROUP` so both counters zero and start on the same
        // instruction. A leader left enabled from its own `open` would already
        // hold the cycles spent opening the member, and the pair's first read
        // would report an interval the core never ran that way.
        const ioc = std.os.linux.PERF.EVENT_IOC;
        try groupIoctl(leader, ioc.RESET);
        try groupIoctl(leader, ioc.ENABLE);

        var self: Perf = .{ .leader = leader, .member = member, .note = "" };

        // Prove the counters before claiming them, the same way `Thsc.open`
        // does. An event opens cleanly on a paravirtual PMU that then never
        // increments; zeros reported as a measurement are worse than an honest
        // wall clock, because nothing downstream can tell the two apart.
        const a = self.sample() orelse return error.CountersUnavailable;
        churn();
        const b = self.sample() orelse return error.CountersUnavailable;
        if (b.cycles <= a.cycles or b.instructions <= a.instructions) return error.CountersNotAdvancing;

        self.note = "perf_event_open · HW_CPU_CYCLES + HW_INSTRUCTIONS group (unprivileged, per-thread, kernel excluded)";
        return self;
    }

    /// One event on **this thread, whichever core it lands on** (`pid = 0`,
    /// `cpu = -1`): following the thread rather than a core is the difference
    /// between measuring the kernel under test and measuring whoever else was
    /// scheduled beside it. Classified into the failure modes a reader can act
    /// on, and every arm degrades — none may panic.
    fn openEvent(attr: *std.os.linux.perf_event_attr, group_fd: i32) !i32 {
        const rc = std.os.linux.perf_event_open(attr, 0, -1, group_fd, 0);
        return switch (std.os.linux.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .ACCES, .PERM => error.PermissionDenied,
            .NOSYS => error.PerfEventsUnconfigured,
            // A hardware event the PMU cannot name, or no PMU to name it with.
            .NOENT, .INVAL, .NODEV, .OPNOTSUPP => error.NoHardwareCounters,
            .BUSY => error.PmuBusy,
            .MFILE, .NFILE => error.OutOfDescriptors,
            else => error.PerfEventOpenFailed,
        };
    }

    fn groupIoctl(fd: i32, request: u32) !void {
        const rc = std.os.linux.ioctl(fd, request, std.os.linux.PERF.IOC_FLAG_GROUP);
        if (std.os.linux.errno(rc) != .SUCCESS) return error.CountersUnavailable;
    }

    /// The degrade note. A reader looking at ns/byte instead of cycles/byte
    /// needs to know **which** wall the meter hit: two of these are one `sysctl`
    /// away from a real number and the rest are properties of the box.
    fn explain(err: anyerror) []const u8 {
        return switch (err) {
            error.PermissionDenied => "wall-clock only (perf_event_open refused with EACCES/EPERM — lower the ceiling with `sysctl kernel.perf_event_paranoid=1`, or grant this binary CAP_PERFMON)",
            error.PerfEventsUnconfigured => "wall-clock only (perf_event_open is ENOSYS — this kernel was built without CONFIG_PERF_EVENTS)",
            error.NoHardwareCounters => "wall-clock only (no hardware PMU visible — usual inside a VM or a container without PMU passthrough; check `perf stat true` on the host)",
            error.CountersUnavailable, error.CountersNotAdvancing => "wall-clock only (the PMU opened but never incremented — a paravirtual counter reporting zeros)",
            error.PmuBusy => "wall-clock only (another process holds the PMU exclusively)",
            error.OutOfDescriptors => "wall-clock only (no file descriptors left for a perf event)",
            else => "wall-clock only (perf_event_open failed)",
        };
    }

    /// One grouped read, or `null` if the kernel refused it, short-filled it, or
    /// answered with a group of some other width. The sentinel is the same
    /// argument as on macOS: a byte count is not proof the fields were written.
    fn sample(self: *const Perf) ?Group {
        var g: Group = .{
            .nr = poison,
            .time_enabled = poison,
            .time_running = poison,
            .cycles = poison,
            .instructions = poison,
        };
        const rc = std.os.linux.read(self.leader, @ptrCast(&g), @sizeOf(Group));
        if (std.os.linux.errno(rc) != .SUCCESS or rc != @sizeOf(Group)) return null;
        if (g.nr != 2 or g.cycles == poison or g.instructions == poison) return null;
        if (g.time_enabled == poison or g.time_running == poison) return null;
        // The counts are only what they claim to be if the group held the
        // hardware for the WHOLE window it was enabled for. Anything less and
        // the kernel time-sliced it against another reader, so the number is a
        // fraction of the truth with no way to tell which fraction from the
        // count alone. Refused rather than scaled: `enabled/running` recovers
        // an ESTIMATE, and a certificate that cannot tell an estimate from a
        // measurement is the thing this module exists to prevent.
        if (g.time_running == 0 or g.time_running != g.time_enabled) return null;
        return g;
    }

    // `Meter.counters` and `Meter.deinit` switch over every union prong, so
    // these two are analyzed on every target even though only Linux can reach
    // them. Each states its own OS precondition rather than the caller doing it
    // once and leaving the arms compiling by luck.
    fn read(self: *Perf) Counters {
        if (comptime builtin.target.os.tag != .linux) return .{};
        const g = self.sample() orelse return .{};
        return .{ .cycles = g.cycles, .instructions = g.instructions, .valid = true, .counts_instructions = true };
    }

    fn close(self: *Perf) void {
        if (comptime builtin.target.os.tag != .linux) return;
        _ = std.os.linux.close(self.member);
        _ = std.os.linux.close(self.leader);
    }
};

// ── Windows unprivileged backend: QueryThreadCycleTime ───────────────────────

extern "kernel32" fn QueryThreadCycleTime(
    thread: std.os.windows.HANDLE,
    cycle_time: *u64,
) callconv(.winapi) std.os.windows.BOOL;

extern "kernel32" fn SetThreadPriority(
    thread: std.os.windows.HANDLE,
    priority: c_int,
) callconv(.winapi) std.os.windows.BOOL;

extern "kernel32" fn Sleep(milliseconds: std.os.windows.DWORD) callconv(.winapi) void;

/// The calling thread's CPU cycle time — unprivileged, no driver, no PMU to
/// program. `GetCurrentThread()` is the constant pseudo-handle `(HANDLE)-2`, so
/// there is nothing to store per meter and nothing to close; the struct exists
/// so this tier resolves through the same `open`/`read`/`close` shape as the
/// others rather than as a special case in `Meter`.
///
/// **Cycles only, and that is the honest shape of Windows.** There is no
/// unprivileged retired-instruction counter here: the PMU sits behind ETW/PMC
/// sessions that want `SeSystemProfilePrivilege`. So this backend leaves
/// `instructions` at zero with `counts_instructions = false`. An IPC derived
/// from a wall-clock stand-in would be a fabricated number wearing a measured
/// number's units, which is the one failure this whole module is built to
/// prevent.
///
/// Two more things the `note` has to say out loud. The count **includes
/// kernel-mode cycles** — there is no exclude-kernel knob, unlike
/// `perf_event_open` — and it is the scheduler's accounting of CPU clock cycles
/// rather than a retired-cycles event. Both mean it is comparable to itself
/// across runs on one box, which is what a ratio needs, and not directly
/// comparable to a `FIXED_CYCLES` or `HW_CPU_CYCLES` reading from another OS.
const Qtct = struct {
    note: []const u8,

    fn open() !Qtct {
        // Same prove-before-claiming discipline: a Hyper-V guest can answer the
        // call and hand back a cycle time that never moves.
        const a = sample() orelse return error.CountersUnavailable;
        churn();
        const b = sample() orelse return error.CountersUnavailable;
        if (b <= a) return error.CountersNotAdvancing;
        return .{ .note = "QueryThreadCycleTime · per-thread CPU cycles, kernel included (unprivileged; Windows exposes no instruction counter)" };
    }

    fn sample() ?u64 {
        var cycles: u64 = 0;
        if (!QueryThreadCycleTime(std.os.windows.GetCurrentThread(), &cycles).toBool()) return null;
        return cycles;
    }

    fn read(_: *Qtct) Counters {
        if (comptime builtin.target.os.tag != .windows) return .{};
        return .{ .cycles = sample() orelse return .{}, .valid = true };
    }

    fn close(_: *Qtct) void {}
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

/// Wall-clock wait, straight through the platform — the module already links
/// libc for `dlopen` and kernel32 for the cycle counter, and threading a
/// `std.Io` in just to pause a test would give this file a dependency none of
/// its production code has. Windows needs its own arm rather than sharing the
/// libc one: `std.c.timespec` is `void` there, so a single `nanosleep` call
/// would not merely be slower, it would not compile.
fn nap(ns: u64) void {
    if (comptime builtin.target.os.tag == .windows) {
        Sleep(@intCast(ns / std.time.ns_per_ms));
        return;
    }
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
    // A meter cannot advertise instructions it has no cycles for, and the
    // advertisement has to match what a read actually carries — that is the
    // whole point of publishing `has_instructions` before anything is measured.
    // A report that printed an IPC header off this flag and then found
    // `counts_instructions = false` would have a column it can only fill with a
    // zero that looks like a measurement.
    if (m.has_instructions) try std.testing.expect(m.has_pmu);
    if (m.has_pmu) try std.testing.expectEqual(m.has_instructions, m.counters().counts_instructions);
    try std.testing.expect(m.note.len > 0);
}

test "counters advance across real work and stay self-consistent" {
    var m = Meter.init();
    defer m.deinit();
    if (!m.has_pmu) return;

    const a = try stood(m.counters()) orelse return;
    std.mem.doNotOptimizeAway(spin(1 << 21));
    const b = try stood(m.counters()) orelse return;
    try std.testing.expect(b.cycles > a.cycles);

    // The instruction half of the contract is conditional, because Windows
    // honestly has no instruction counter — but conditional is not optional in
    // either direction. A meter that counts them must show them advancing; one
    // that does not must leave the field at a **zero**, not at a number derived
    // from something else that happens to be lying around.
    if (!m.has_instructions) {
        try std.testing.expectEqual(@as(u64, 0), a.instructions);
        try std.testing.expectEqual(@as(u64, 0), b.instructions);
        return;
    }
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

/// A sample the meter stands behind, or `null` when it refused this window.
///
/// The Linux group is refused when the kernel time-sliced it against another
/// reader, which `zig build test` guarantees: the roofline and portbound lanes
/// open their own groups beside this module's, and with enough concurrent
/// readers a group opens successfully and is never scheduled. A test asserting
/// a RATIO has nothing to assert then — but the refusal itself is still a
/// contract, so it is checked here rather than waved through. A backend may
/// decline a window; it may not decline one while leaving numbers in the
/// struct for a caller to read as work that did not happen.
fn stood(c: Counters) !?Counters {
    if (c.valid) return c;
    try std.testing.expectEqual(@as(u64, 0), c.cycles);
    try std.testing.expectEqual(@as(u64, 0), c.instructions);
    return null;
}

test "cycles measure work, not elapsed time" {
    var m = Meter.init();
    defer m.deinit();
    if (!m.has_pmu) return;

    // A sleeping thread retires almost nothing. If cycles tracked wall-clock,
    // 50 ms of sleep would look like ~10^8 cycles on any modern core; the
    // counter is only useful because it does not.
    const s0 = try stood(m.counters()) orelse return;
    nap(50 * std.time.ns_per_ms);
    const s1 = try stood(m.counters()) orelse return;
    const idle = s1.cycles -% s0.cycles;

    const w0 = try stood(m.counters()) orelse return;
    std.mem.doNotOptimizeAway(spin(1 << 21));
    const w1 = try stood(m.counters()) orelse return;
    const busy = w1.cycles -% w0.cycles;

    try std.testing.expect(busy > idle * 4);
}

test "counters are per-thread, so a busy neighbor cannot inflate them" {
    var m = Meter.init();
    defer m.deinit();
    if (!m.has_pmu) return;

    const iters: usize = 1 << 21;
    const solo = blk: {
        const a = try stood(m.counters()) orelse return;
        std.mem.doNotOptimizeAway(spin(iters));
        const b = try stood(m.counters()) orelse return;
        break :blk b.cycles -% a.cycles;
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
        const a = try stood(m.counters()) orelse return;
        std.mem.doNotOptimizeAway(spin(iters));
        const b = try stood(m.counters()) orelse return;
        break :blk b.cycles -% a.cycles;
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
    var c: Thsc.Cpi = .{ .instructions = poison, .cycles = poison };
    _ = t.selfcounts(Thsc.kind_cpi, &c, @sizeOf(u64));
    try std.testing.expectEqual(poison, c.cycles);

    // And the full-size read the backend actually issues fills both.
    const full = t.sample() orelse return error.FullSizedReadRefused;
    try std.testing.expect(full.cycles != poison and full.instructions != poison);
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
