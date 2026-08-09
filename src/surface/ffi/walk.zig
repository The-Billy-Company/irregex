//! Which files a search is even allowed to read, and in what order.
//!
//! Every host that has ever wrapped a grep has rewritten this badly: gitignore
//! precedence across nested files and a global excludes file, hidden-entry
//! policy, binary sniffing, a per-file ceiling, and a type registry with a few
//! hundred entries. It is the least glamorous half of a search engine and the
//! half that decides whether the answers are right, because a walk that admits
//! one file too many is slow and a walk that admits one too few is wrong.
//!
//! The tier underneath is ripgrep-compatible and pinned by a differential suite.
//! None of it was reachable from C.
//!
//! ## WHICH walk this is, said plainly
//!
//! There are two descents in this package and they do not agree, so a host that
//! cannot see inside must be told which one answers here:
//!
//!   * `exec/cold/quarry/walk.zig` — the rg-DEFAULT file set. Honors `-L`,
//!     `--max-depth`, `--one-file-system`, every `--no-ignore-*` axis, the
//!     hidden rule, and `-g`/`-t` overrides. Prunes no directory by name beyond
//!     what the tree itself declared. **This is the one this plane exposes.**
//!   * `corpus/tree/haystack.zig` — the INDEX build's corpus. Fixed at default
//!     ignore options (it constructs `ignore.Options{}` and takes no argument
//!     for it), and additionally prunes 36 VCS/build/cache basenames
//!     (`node_modules`, `target`, `vendor`, `.local`, …) that rg would descend.
//!     Narrower on purpose, and NOT what a host asking "what may a search read"
//!     means.
//!
//! So: **symlinks are not followed by default and are followed under
//! `IRGX_WALK_FOLLOW`**, exactly as `rg` and `rg -L` differ. The corpus walk has
//! no such knob, which is the second reason this plane is the other one.
//!
//! ## Two questions, one cursor
//!
//! `admits` and `is a member` are different facts and the difference is IO.
//!
//! The file set is a decision about PATHS: ignore precedence (low to high, last
//! matching rule winning — `--ignore-file` entries, then git's global excludes,
//! then ancestor `.gitignore`/`.ignore`/`.rgignore`, then `.git/info/exclude`,
//! then each directory's own files as the walk descends, deeper overriding
//! shallower), the hidden-dotfile rule, and the `-g`/`-t` whitelist asymmetry (a
//! `-g` match un-ignores AND un-hides; a `-t` match only un-hides). Not one byte
//! of any file is read to decide it.
//!
//! Membership in the CORPUS is a decision about BYTES, and there are three
//! rules: a file with a NUL in its first 8192 bytes is binary, a file whose size
//! reaches or exceeds 4 MiB is over the ceiling, and an empty file is not a
//! member. All three are refusals, and all three cost a read.
//!
//! `IRGX_WALK_MEMBERS` asks for the second on top of the first. Without it this
//! walk touches no file's contents; with it every admitted path is read through
//! the same `corpus.readMember` the index build applies, so the two cannot come
//! apart on what counts. It is opt-in because it is the expensive answer, not
//! because it is the unusual one.
//!
//! (The layered set is the rg file set MINUS the content refusals — it is not the
//! indexed corpus, which is narrower still by the skip-dir policy above.)
//!
//! ## ONE lifetime, and one order
//!
//! **Every byte an `Entry` points at belongs to the walk and stays valid until
//! `irgx_walk_close`.** Nothing a host reads is invalidated by a later pull.
//!
//! That is a deliberate divergence from the Zig tier, where `Haystack.dir` and
//! `.name` borrow the directory walker's own reused entry and die at the next
//! `next()` — a contract a Zig caller can read in the walker's doc comment and a
//! C host structurally cannot. Handing a struct across the seam whose fields
//! expire at the following call is handing out a landmine, so the walk is
//! MATERIALIZED at `open`: every path is copied into the handle's arena, the list
//! is sorted, and `next` hands out borrows of a list that no longer moves. It
//! also buys the two things a streaming cursor could not offer — `irgx_walk_count`
//! before you allocate, and `irgx_walk_holds` as a real predicate rather than a
//! second walk that might disagree with the first.
//!
//! Order is **lexicographic by path, globally**, using the same comparator the
//! parallel corpus load assigns doc ids with (`loadpar.pathLess`). The tier below
//! has two orders — lexicographic after a parallel load, DFS-discovery order when
//! serial — and a walk whose order depends on which engine engaged is not a
//! contract. Lexicographic is the one that survives being asked twice.
//!
//! ## Ownership and threads
//!
//! A walk handle is SINGLE-THREADED: it advances a read position. Any thread may
//! read `irgx_walk_count`/`irgx_walk_holds`, which touch no cursor state.
//!
//! Nothing here writes to the host's streams and nothing here ends the host's
//! process. Both are enforced rather than promised: the descent below reports an
//! unreadable directory through `assay.note`, so `open` holds a `dark` sink for
//! its duration; and the tree's charter is consulted by the skip policy, so
//! `open` states `charter.Refusal.fault` for its duration too. A CLI's fail-loud
//! exit on a malformed charter is right for a CLI and is kept there
//! (`charter.honorNoConfig` arms it); a malformed charter reaches a host as
//! `IRGX_OPEN_FAILED` with `Corrupt` in `irgx_last_fault`.

const std = @import("std");
const assay = @import("../../assay/assay.zig");
const charter = @import("../../corpus/scope/charter.zig");
const contract = @import("contract.zig");
const corpus = @import("../../corpus/tree/corpus.zig");
const fault = @import("../../fault.zig");
const genus_mod = @import("../../corpus/scope/genus.zig");
const glob = @import("../../kernel/math/glob.zig");
const ignore = @import("../../corpus/tree/ignore.zig");
const intent = @import("../../exec/cold/argv/intent.zig");
const quarry = @import("../../exec/cold/quarry/walk.zig");
const rows = @import("rows.zig");
const types = @import("../../corpus/scope/types.zig");
const verdict = @import("../../exec/cold/argv/verdict.zig");

const Status = contract.Status;
const gpa = std.heap.c_allocator;

// ── what the tier decides, published so a host stops guessing ────────────────

/// The three content constants and the registry's size — the numbers a host
/// would otherwise hardcode from a README and then hold wrongly forever.
///
/// `struct_size`-guarded like every other struct here, because the honest way to
/// add a fourth constant later is to append a field.
pub const Limits = extern struct {
    struct_size: u32,
    /// How far into a file the binary verdict looks. A NUL anywhere in this many
    /// leading bytes ⇒ binary. Reading fewer could miss a NUL a whole-file read
    /// would have seen; reading more is IO the rule ignores.
    binary_window: u32,
    /// The per-file ceiling, in bytes. A file whose size REACHES or exceeds this
    /// is not a member — the boundary is `>=`, not `>`, because it is the
    /// capped-read boundary and a file exactly this large is indistinguishable
    /// from a larger one at the moment the read stops.
    file_cap: u64,
    /// Rows in the type registry, and distinct `-t` names across them (a row
    /// carries its aliases). Both comptime facts about THIS build.
    type_rows: u32,
    type_names: u32,
};

/// Publish the constants. `.invalid` for a null slot; never fails otherwise.
pub fn limits(out: ?*Limits) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    slot.* = .{
        .struct_size = @sizeOf(Limits),
        .binary_window = @intCast(corpus.binary_window),
        .file_cap = corpus.per_file_cap,
        .type_rows = types.type_table.len,
        .type_names = comptime blk: {
            var n: u32 = 0;
            for (types.type_table) |row| n += row.names.len;
            break :blk n;
        },
    };
    return .ok;
}

// ── the spec: one struct, and an ordered list of terms ───────────────────────

/// What a `Term` IS. Explicitly numbered: these cross as a `uint32_t` a host
/// switches on, and the numbering is append-only.
///
/// `root` is 0 so a memset term is the commonest kind rather than an
/// unrecognized one — and since a root with no text is refused, a zeroed term
/// is still an error rather than a silent no-op.
pub const term_root: u32 = 0;
/// `-g <glob>`, case-sensitive. Also the only term that can un-IGNORE a path, so
/// `-g '*'` reaches into a gitignored directory exactly as it does in rg.
pub const term_glob: u32 = 1;
/// `-g '!<glob>'` — an exclude, which vetoes ahead of every include.
pub const term_glob_not: u32 = 2;
/// `--iglob <glob>`, case-insensitive.
pub const term_iglob: u32 = 3;
/// `-t <name>`: a registry type (`rust`), a genus (`docs`/`code`/`data`, and
/// their `prose`/`source` spellings), or `all`. Un-HIDES a match and never
/// un-ignores it — rg's asymmetry, kept.
pub const term_type: u32 = 4;
/// `-T <name>`: the same vocabulary, aimed the other way.
pub const term_type_not: u32 = 5;
/// `--ignore-file <path>`: an extra ignore source, at the BOTTOM of precedence.
/// Order among these is load-bearing and is the order they appear here.
pub const term_ignore_file: u32 = 6;

/// One element of the walk's corpus declaration.
///
/// A single ordered, tagged list rather than seven `(pointer, count)` pairs, and
/// the reason is not brevity. A struct with seven parallel arrays is twenty-one
/// fields a host must memset correctly, it forgets the INTERLEAVING (which
/// `--ignore-file` came first, which root an argument named), and it makes a
/// new KIND into a new field — an ABI widening — where here it is a new enum
/// value with the struct unchanged. This shape is also the shape argv already
/// has, which is what keeps a C host and a command line describing the same
/// corpus.
///
/// `reserved` must be 0. It is padding that a host has to initialize, which is
/// strictly better than padding the compiler inserts and nobody initializes.
pub const Term = extern struct {
    kind: u32,
    reserved: u32,
    /// The term's bytes. Null WITH a length is a caller bug, not empty text.
    text: ?[*]const u8,
    text_len: usize,
};

/// `--hidden`: descend into and match dotfiles and dot-directories.
pub const flag_hidden: u32 = 1 << 0;
/// `--no-ignore` / `-u`: every ignore source off at once. The individual axes
/// below exist because rg's do, and because "off" is rarely what a host means.
pub const flag_no_ignore: u32 = 1 << 1;
/// `--no-ignore-vcs`: `.gitignore` and `.git/info/exclude` off.
pub const flag_no_ignore_vcs: u32 = 1 << 2;
/// `--no-ignore-dot`: `.ignore` / `.rgignore` off.
pub const flag_no_ignore_dot: u32 = 1 << 3;
/// `--no-ignore-parent`: ignore files ABOVE the walk root off.
pub const flag_no_ignore_parent: u32 = 1 << 4;
/// `--no-ignore-exclude`: `.git/info/exclude` off.
pub const flag_no_ignore_exclude: u32 = 1 << 5;
/// `--no-ignore-global`: git's `core.excludesFile` off.
pub const flag_no_ignore_global: u32 = 1 << 6;
/// `--no-ignore-files`: the `IRGX_WALK_IGNORE_FILE` terms off. Present so a host
/// can keep the terms in its spec and disable them without rebuilding it.
pub const flag_no_ignore_files: u32 = 1 << 7;
/// `--no-require-git`: honor `.gitignore` in a tree that is not a repository.
pub const flag_no_require_git: u32 = 1 << 8;
/// `--ignore-file-case-insensitive`: match ignore globs without regard to case.
pub const flag_ignore_file_case_insensitive: u32 = 1 << 9;
/// `-L` / `--follow`: resolve symlinks — a linked directory is walked as a
/// subtree, a linked file is admitted. Cycles are refused by realpath ancestry
/// (rg's own strategy) and by a 40-link depth cap. **Off by default**, which is
/// the answer to "does this plane follow symlinks".
pub const flag_follow: u32 = 1 << 10;
/// `--one-file-system`: never descend a directory sitting on another device.
pub const flag_one_file_system: u32 = 1 << 11;
/// `--glob-case-insensitive`: fold every `IRGX_WALK_GLOB` term into the
/// case-insensitive set, as if each had been an `IRGX_WALK_IGLOB`.
pub const flag_glob_case_insensitive: u32 = 1 << 12;
/// Additionally apply the CORPUS content rules — binary sniff, per-file ceiling,
/// empty — and report each admitted file's member length in `Entry.size`. This
/// is the only flag that makes the walk read file bytes.
pub const flag_members: u32 = 1 << 13;
/// Serve a set the walk knows is INCOMPLETE rather than refusing it.
///
/// Off by default, deliberately: a directory the descent could not enter is a
/// potential false negative, and a library that hands back a silently gapped
/// list has answered a question it was not asked. `rg` prints the gap and exits
/// 2 — it gets to do both. Here the default is to refuse (`IRGX_OPEN_FAILED`),
/// and a host that would rather have the partial answer sets this bit and reads
/// `irgx_walk_gapped` to learn that it got one.
pub const flag_tolerate_gaps: u32 = 1 << 14;

/// The flags a walk accepts. An unrecognized bit is `.invalid` — a host that
/// sets one has a wrong belief about the file set it is about to be handed, and
/// hearing so now beats inferring it from an answer.
pub const walk_flags: u32 = flag_hidden | flag_no_ignore | flag_no_ignore_vcs |
    flag_no_ignore_dot | flag_no_ignore_parent | flag_no_ignore_exclude |
    flag_no_ignore_global | flag_no_ignore_files | flag_no_require_git |
    flag_ignore_file_case_insensitive | flag_follow | flag_one_file_system |
    flag_glob_case_insensitive | flag_members | flag_tolerate_gaps;

/// One complete corpus declaration. Extern and APPEND-ONLY, with a FAIL-CLOSED
/// `struct_size`: a size this build does not recognize is `.invalid`, never a
/// best-effort read of the prefix it thinks it recognizes.
///
/// **Zero is today.** A struct a host memsets and stamps `struct_size` onto is
/// the rg-default walk of the working directory: no roots (so the rootless CWD
/// descent, whose paths carry no `./` prefix — name `"."` as a root explicitly
/// and they do, exactly as `rg pat .` prints them), unlimited depth, ignore
/// precedence and the hidden rule in force, symlinks unfollowed, no content
/// read, and a refusal rather than a gapped answer.
pub const Spec = extern struct {
    struct_size: u32,
    flags: u32,
    /// `--max-depth`: root children are depth 1. 0 = unlimited.
    max_depth: u64,
    /// The declaration itself, in the order it was stated. Null with a zero
    /// count is the empty declaration; null WITH a count is a caller bug.
    terms: ?[*]const Term,
    term_count: usize,
};

// ── what a pull hands back ───────────────────────────────────────────────────

/// The partition `-t docs` / `--code` / `--data` selects on: total, disjoint, and
/// computed from the path rather than matched against a glob list. Numbered
/// explicitly; these cross as a `uint32_t`.
pub const Genus = enum(u32) { code = 0, docs = 1, data = 2 };

fn genusOfPath(path: []const u8) Genus {
    // Switched rather than `@enumFromInt`'d off the ordinal: a fourth member in
    // the partition becomes a compile error here instead of an integer a host
    // has no name for.
    return switch (genus_mod.of(path)) {
        .code => .code,
        .docs => .docs,
        .data => .data,
    };
}

/// One admitted file. `path` borrows the walk and dies with it — see the
/// lifetime rule at the top of this file, which has no exceptions.
///
/// `size` is the file's member length in bytes, and 0 means the walk never
/// asked: without `IRGX_WALK_MEMBERS` no file is read, and WITH it 0 cannot
/// occur, since an empty file is not a member. So the field is unambiguous in
/// both modes rather than needing a second one to say whether it is set.
pub const Entry = extern struct {
    path: rows.Text,
    size: u64,
    genus: Genus,
    reserved: u32,
};

// ── the handle ───────────────────────────────────────────────────────────────

/// A materialized walk: the admitted paths, sorted, plus a read position.
///
/// Heap-allocated and arena-backed for the same reason the engine handle is —
/// the threaded-I/O interface captures `&self.threaded`, so the struct may not
/// move — and because one arena is what makes the lifetime rule a property of
/// the handle rather than a per-field promise.
pub const Walk = struct {
    arena: std.heap.ArenaAllocator,
    threaded: std.Io.Threaded,
    paths: []const []const u8,
    sizes: []const u64,
    pos: usize = 0,
    /// Set when the descent could not enter part of the tree. Only ever readable
    /// under `flag_tolerate_gaps`; without it such a walk is refused and no
    /// handle is written.
    gapped: bool = false,
};

/// Materialize the file set `spec` declares and write the handle to `out`.
///
/// `.match` when the walk admitted at least one file, `.ok` when it admitted
/// none — and in BOTH cases a handle was written and the host owns it, exactly
/// as a tree search hands back an empty cursor. The status reports the ANSWER,
/// never whether there is something to release.
///
/// `.invalid` is a caller error, and it covers every spec this build cannot
/// honor rather than only the malformed ones: a null slot, an unrecognized
/// `struct_size`, an unknown flag bit, a term with uninitialized padding or no
/// text, an unrecognized type name, an unclosed glob class, an unclosed brace
/// alternation. A refusal, because each of those would otherwise read as a
/// corpus that happened to be empty. A WELL-FORMED `{a,b}` alternation is not
/// among them: it expands here, once, into the concrete globs it names — see
/// `plan`.
///
/// `IRGX_OPEN_FAILED` carries `Corrupt` (or `Oversized`) for a `.irregex.toml`
/// that would not parse, and `AccessDenied` for a walk that could not be
/// completed — see `flag_tolerate_gaps`. `IRGX_OOM` is the only other failure,
/// and it carries `BudgetExceeded` rather than `OutOfMemory` when one glob's
/// alternation expands past `glob.brace_cap`: the machine did not run out, a
/// ceiling was reached, and `irgx_last_fault`'s `name` is where that difference
/// survives the fold onto one status.
pub fn open(spec_ptr: ?*const Spec, out: ?**Walk) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    const spec = spec_ptr orelse return .invalid;
    if (spec.struct_size != @sizeOf(Spec) or spec.flags & ~walk_flags != 0) return .invalid;
    if (spec.term_count != 0 and spec.terms == null) return .invalid;

    // The two host-safety guards, both held for exactly this call and both
    // restored on the way out. A library may not end its host's process, and
    // this walk reads the tree's charter through the skip policy; a library may
    // not write to its host's streams, and the descent reports an unreadable
    // directory through `assay.note`.
    const posture = charter.stateRefusal(.fault);
    defer posture.release();
    const quiet = assay.scope(.dark);
    defer quiet.end();

    // A charter that would not parse is refused BEFORE the tree is touched: the
    // walk would otherwise proceed on defaults the tree explicitly declared
    // against, which is the "corpus nobody described" a face refuses outright.
    // Suppressed configuration is not a fault — the host asked for the tree's
    // declaration to be ignored, so there is nothing to be wrong about.
    if (!charter.suppressedNow()) if (charter.faulted()) |f|
        return contract.report(.{ .code = charterFault(f.err), .path = f.path });

    const w = gpa.create(Walk) catch return contract.report(.{ .code = error.OutOfMemory });
    w.* = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .threaded = std.Io.Threaded.init(gpa, .{}),
        .paths = &.{},
        .sizes = &.{},
    };
    // Unwound by a flag rather than by `errdefer`, because every refusal below
    // is a returned STATUS and not a Zig error — an `errdefer` here would look
    // like it covered them and would leak the handle on all three.
    var keep = false;
    defer if (!keep) destroy(w);

    if (!(fill(w, spec) catch |e| return contract.report(.{ .code = e })))
        return .invalid;
    if (w.gapped and spec.flags & flag_tolerate_gaps == 0)
        return contract.report(.{ .code = error.AccessDenied });
    keep = true;
    slot.* = w;
    return if (w.paths.len == 0) .ok else .match;
}

/// How many files the walk admitted. Answers without advancing anything, which
/// is why `nextBatch` may report what it CONSUMED rather than a total.
///
/// A bare count, like every other infallible reader on this ABI (`slate_len`,
/// `needles_len`, `munch_len`, `codex_len`, `walk_gapped`): the walk is
/// materialized by `open`, so this is a field read that cannot fail, and a
/// `Status` here would have made the caller handle an outcome that cannot
/// happen. Emptiness is `0`, which is the same fact `.ok` was encoding.
pub fn count(w: *const Walk) usize {
    return w.paths.len;
}

/// Whether the walk knows itself to be incomplete — a directory it could not
/// enter, an explicitly named root it could not open. Non-zero is a potential
/// FALSE NEGATIVE in every answer derived from this set.
pub fn gapped(w: *const Walk) u32 {
    return @intFromBool(w.gapped);
}

/// Write the next entry. `.match` when one was written, `.ok` at the end of the
/// stream (`out` untouched), `.invalid` for a null slot.
pub fn next(w: *Walk, out: ?*Entry) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    if (w.pos >= w.paths.len) return .ok;
    slot.* = entryAt(w, w.pos);
    w.pos += 1;
    return .match;
}

/// Fill up to `cap` entries into `out[0..cap]` and write how many landed to
/// `written` — one crossing amortized over N entries, which is the whole reason
/// a binding batches.
///
/// `*written` is what this call CONSUMED, not a total that exists: a cursor
/// counting past `cap` would be counting entries it had already dropped. The
/// count-only probe is `irgx_walk_count`, which advances nothing. So `cap == 0`
/// is a legal no-op that consumes nothing.
pub fn nextBatch(w: *Walk, out: ?[*]Entry, cap: usize, written: ?*usize) Status {
    contract.beginCall();
    var sink = contract.Sink(Entry).open(out, cap, written) orelse return .invalid;
    while (sink.n < cap and w.pos < w.paths.len) {
        sink.push(entryAt(w, w.pos));
        w.pos += 1;
    }
    return sink.close();
}

/// Put the read position back at the first entry. The payoff of materializing:
/// a second pass costs nothing, where a streaming cursor would re-walk the tree
/// and could answer differently the second time.
pub fn rewind(w: *Walk) void {
    w.pos = 0;
}

/// Is `path` in this walk's file set? `.match` yes, `.ok` no, `.invalid` for a
/// null pointer carrying a length.
///
/// Answered by binary search over the walk's OWN sorted list rather than by
/// re-deciding the path against a freshly compiled ignore chain, which is what
/// makes it a predicate instead of a second opinion: a host that asks about a
/// path this walk yielded cannot be told no. Spell the path as the walk does —
/// root-joined, `/`-separated (`irgx_walk_next` shows you the spelling).
pub fn holds(w: *const Walk, path_ptr: ?[*]const u8, path_len: usize) Status {
    contract.beginCall();
    const path = contract.view(path_ptr, path_len) orelse return .invalid;
    var lo: usize = 0;
    var hi: usize = w.paths.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, w.paths[mid], path)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return .match,
        }
    }
    return .ok;
}

/// Release the walk and every byte it lent out.
pub fn close(w: *Walk) void {
    destroy(w);
}

fn destroy(w: *Walk) void {
    w.arena.deinit();
    w.threaded.deinit();
    gpa.destroy(w);
}

fn entryAt(w: *const Walk, i: usize) Entry {
    return .{
        .path = rows.Text.of(w.paths[i]),
        .size = w.sizes[i],
        .genus = genusOfPath(w.paths[i]),
        .reserved = 0,
    };
}

// ── the two pure predicates, for a host that already holds the bytes ─────────

/// Is this text binary? `.match` yes, `.ok` no, `.invalid` for a null pointer
/// carrying a length.
///
/// THE rule, not an approximation of it: a NUL byte within the first
/// `binary_window` bytes. A host that hands over more than the window pays
/// nothing for the excess, and one that hands over fewer gets the answer for
/// what it has — which is why `irgx_walk_limits` publishes the window: reading
/// exactly that much reaches the same verdict a whole-file read would.
pub fn binary(ptr: ?[*]const u8, len: usize) Status {
    contract.beginCall();
    const bytes = contract.view(ptr, len) orelse return .invalid;
    return if (corpus.isBinary(bytes)) .match else .ok;
}

/// Which genus a path belongs to. `.invalid` for a null pointer carrying a
/// length, or an empty path — a path with no bytes classifies as nothing.
///
/// Pure and cheap: the answer is a function of the path alone, so a host can
/// partition a list it already has without a walk. This is the one eligibility
/// axis `-t <language>` cannot express — what a file is FOR, rather than what it
/// is written in.
pub fn genusOf(ptr: ?[*]const u8, len: usize, out: ?*Genus) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    const path = contract.view(ptr, len) orelse return .invalid;
    if (path.len == 0) return .invalid;
    slot.* = genusOfPath(path);
    return .ok;
}

// ── lowering: the spec becomes the walk the certified tier already runs ──────

/// The charter fault a host is told about.
///
/// Two of the parse faults ARE taxonomy members already — Zig unifies error
/// names globally, so the charter's `Oversized` and the persist domain's are one
/// value — and they travel as themselves. Everything else is a file whose bytes
/// do not say what they must, which is exactly what `Corrupt` folds
/// (`BadFormat` and `CorruptIndex` collapsed into it for this reason). All three
/// cross as `IRGX_OPEN_FAILED`: this corpus could not be stood up.
///
/// The charter's LINE number does not travel. `irgx_fault.at` is a byte offset
/// in one of two declared coordinate spaces and a line is neither, so pointing
/// `at` at a line would be a number measured with the wrong ruler. `path` names
/// the file, which is enough to open it.
fn charterFault(e: anyerror) fault.Fault {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Oversized => error.Oversized,
        else => error.Corrupt,
    };
}

/// Everything the descent needs, lowered from the spec. `null` from `plan` is a
/// spec this build cannot honor — an unrecognized term kind, an unknown type
/// name, an unparseable glob — and becomes `.invalid` at the seam.
const Plan = struct {
    roots: []const []const u8,
    opts: intent.Opts,
};

fn plan(a: std.mem.Allocator, spec: *const Spec) glob.BraceError!?Plan {
    var o: intent.Opts = .{};
    o.hidden = spec.flags & flag_hidden != 0;
    o.no_ignore = spec.flags & flag_no_ignore != 0;
    o.no_ignore_vcs = spec.flags & flag_no_ignore_vcs != 0;
    o.no_ignore_dot = spec.flags & flag_no_ignore_dot != 0;
    o.no_ignore_parent = spec.flags & flag_no_ignore_parent != 0;
    o.no_ignore_exclude = spec.flags & flag_no_ignore_exclude != 0;
    o.no_ignore_global = spec.flags & flag_no_ignore_global != 0;
    o.no_ignore_files = spec.flags & flag_no_ignore_files != 0;
    o.no_require_git = spec.flags & flag_no_require_git != 0;
    o.ignore_case_insensitive = spec.flags & flag_ignore_file_case_insensitive != 0;
    o.follow = spec.flags & flag_follow != 0;
    o.one_file_system = spec.flags & flag_one_file_system != 0;
    o.max_depth = std.math.cast(usize, spec.max_depth) orelse return null;

    var roots: std.ArrayList([]const u8) = .empty;
    var ignore_files: std.ArrayList([]const u8) = .empty;
    var exts: std.ArrayList([]const u8) = .empty;
    var neg_exts: std.ArrayList([]const u8) = .empty;
    var includes: std.ArrayList([]const u8) = .empty;
    var iglobs: std.ArrayList([]const u8) = .empty;
    var excludes: std.ArrayList([]const u8) = .empty;

    const terms = if (spec.terms) |p| p[0..spec.term_count] else &.{};
    for (terms) |term| {
        if (term.reserved != 0) return null;
        const text = contract.view(term.text, term.text_len) orelse return null;
        if (text.len == 0) return null;
        switch (term.kind) {
            term_root => try roots.append(a, text),
            term_ignore_file => try ignore_files.append(a, text),
            term_glob, term_glob_not, term_iglob => {
                // A leading `!` is the same exclude a command line spells that
                // way, so a host porting an argv string needs no rewrite; the
                // dedicated kind exists for a host BUILDING terms, which should
                // not have to concatenate a sigil onto a pattern to negate it.
                const negated = term.kind == term_glob_not or text[0] == '!';
                const core = verdict.stripAnchor(if (text[0] == '!') text[1..] else text);
                if (core.len == 0) return null;
                // An explicit glob compiles STRICTLY, as rg's `Glob::new` does:
                // an unclosed `{` and an unclosed `[` are both errors, not the
                // literal bytes a lenient gitignore line would read them as.
                // Refused rather than matched literally, because a glob that
                // matches nothing reads exactly like a corpus that narrowed to
                // nothing.
                if (glob.unterminatedBrace(core)) return null;
                const list = if (negated)
                    &excludes
                else if (term.kind == term_iglob or spec.flags & flag_glob_case_insensitive != 0)
                    &iglobs
                else
                    &includes;
                // A well-formed `*.{js,ts}` becomes `*.js` and `*.ts` HERE, once,
                // while the spec is materialized — never per candidate path,
                // which would make a linear walk quadratic in the group's
                // cartesian size. It is the same expander `-g` runs on a command
                // line, so the two admit one set by construction rather than by
                // two implementations agreeing. A product past `brace_cap` is
                // `BudgetExceeded`, never a shortened list.
                const base = list.items.len;
                try glob.braceExpand(a, core, list, glob.brace_cap);
                for (list.items[base..]) |v| if (glob.unterminatedClass(v)) return null;
            },
            term_type, term_type_not => {
                const negated = term.kind == term_type_not;
                if (std.mem.eql(u8, text, "all")) {
                    (if (negated) &o.filter.ntype_all else &o.filter.type_all).* = true;
                } else if (genus_mod.named(text)) |g| {
                    (if (negated) &o.filter.neg_genera else &o.filter.genera).merge(g);
                } else {
                    // The registry is comptime and the seam does not widen it, so
                    // an unknown name is refused rather than silently matching
                    // nothing — a typo'd type is the one filter mistake that
                    // reads exactly like an empty corpus.
                    const g = types.extsForType(text) orelse return null;
                    try (if (negated) &neg_exts else &exts).appendSlice(a, g);
                }
            },
            else => return null,
        }
    }

    o.ignore_files = try ignore_files.toOwnedSlice(a);
    o.filter.exts = try exts.toOwnedSlice(a);
    o.filter.neg_exts = try neg_exts.toOwnedSlice(a);
    o.filter.includes = try includes.toOwnedSlice(a);
    o.filter.iglobs = try iglobs.toOwnedSlice(a);
    o.filter.excludes = try excludes.toOwnedSlice(a);
    return .{ .roots = try roots.toOwnedSlice(a), .opts = o };
}

/// Run the descent and freeze its answer into `w`. `false` is a spec this build
/// cannot honor, which the seam crosses as `IRGX_INVALID`; an error is either
/// allocation failure or a brace alternation past its ceiling, and both cross
/// as `IRGX_OOM` with the difference kept in `irgx_last_fault`.
fn fill(w: *Walk, spec: *const Spec) glob.BraceError!bool {
    const a = w.arena.allocator();
    const io = w.threaded.io();
    const p = try plan(a, spec) orelse return false;

    // The one place the certified tier is entered, and in the order its own
    // caller uses it (`quarry/intake.zig`): compile the ignore chain from the
    // same options, descend, then apply the type/glob scope to what came back.
    // `gather` is the SOLE authority on what is in the corpus — nothing here
    // re-derives a walk.
    var ig = try ignore.Ignore.init(a, io, ignore.Options.from(p.opts), p.roots);
    var found: std.ArrayList(quarry.Candidate) = .empty;
    const g = try quarry.gather(a, io, p.roots, p.opts, &ig, &found, null);
    w.gapped = g.path_error;

    // A path-only `-t`/`-T`/`-g` verdict is a WALK verdict and not a read
    // verdict: rg never opens a file its type set excluded, and deciding it
    // here keeps an excluded file's bytes unread under `IRGX_WALK_MEMBERS`.
    // Judged against `scope` — the gitignore-relative path — because that is
    // the spelling the filter's globs are written against.
    if (p.opts.filter.active()) {
        var kept = try std.ArrayList(quarry.Candidate).initCapacity(a, found.items.len);
        for (found.items) |c| if (p.opts.filter.admits(a, c.scope)) kept.appendAssumeCapacity(c);
        found = kept;
    }

    // Sorted BEFORE the content rules run, so the read order is the reported
    // order: the member reads then walk the tree in path locality rather than in
    // whatever order the descent happened to finish.
    std.mem.sortUnstable(quarry.Candidate, found.items, {}, candidateLess);

    const members = spec.flags & flag_members != 0;
    var paths = try std.ArrayList([]const u8).initCapacity(a, found.items.len);
    var sizes = try std.ArrayList(u64).initCapacity(a, found.items.len);
    // The member read borrows a scratch arena that is reset per file, so the
    // peak is one file's bytes rather than the whole corpus's — this plane
    // reports LENGTHS, and keeping the bodies to hand them back would be a
    // corpus load wearing a walk's name.
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    for (found.items) |c| {
        var size: u64 = 0;
        if (members) {
            defer _ = scratch.reset(.retain_capacity);
            // The shared rule, applied through the shared function: unreadable,
            // empty, at-or-over the ceiling, or binary ⇒ not a member. The index
            // build and every freshness fold call this same one, which is what
            // keeps a walk and a build from disagreeing about what counts.
            const body = corpus.readMember(io, std.Io.Dir.cwd(), c.disk, scratch.allocator()) orelse continue;
            size = body.len;
        }
        paths.appendAssumeCapacity(c.rel);
        sizes.appendAssumeCapacity(size);
    }
    w.paths = try paths.toOwnedSlice(a);
    w.sizes = try sizes.toOwnedSlice(a);
    return true;
}

/// The comparator, and the whole ordering contract: plain byte order over the
/// display path. Deliberately the SAME comparator `loadpar.pathLess` assigns doc
/// ids with, so a host walking the tree and a host reading the index see the
/// corpus in one order.
fn candidateLess(_: void, x: quarry.Candidate, y: quarry.Candidate) bool {
    return std.mem.lessThan(u8, x.rel, y.rel);
}

// ── tests ────────────────────────────────────────────────────────────────────
// Over a REAL tree through REAL syscalls, because every claim this plane makes
// is a claim about what a descent decides: a fake corpus would prove the seam
// forwards a field rather than that the field is the rg answer.

const Dir = std.Io.Dir;

/// The fixture: a nested tree with a `.gitignore`, a hidden file, a binary file,
/// an empty file, and two ordinary ones whose DISCOVERY order is not their sort
/// order (`zz` is planted before `aa`, and `sub/` before both).
const fixture = [_][2][]const u8{
    .{ ".gitignore", "ignored.txt\n" },
    .{ "zz.txt", "zulu\n" },
    .{ "sub/nested.md", "# nested\n" },
    .{ "aa.txt", "alpha\n" },
    .{ "ignored.txt", "you should not see me\n" },
    .{ ".hidden.txt", "dotfile\n" },
    .{ "empty.txt", "" },
    .{ "blob.bin", "head\x00tail\n" },
};

/// A planted tree that owns the io it was planted through, so a test says
/// `plant` and `uproot` and never holds a second `Threaded` of its own.
///
/// `seed` separates the tests within one process; the PID separates the
/// processes, and both halves are needed. Seeding alone covers the shards, which
/// share a process — but not a second concurrent `zig build test`, which is the
/// normal condition here and on any machine running two CI jobs. Two runs that
/// agreed on this path would not merely share a directory: this used to
/// `deleteTree` it first, so the later run deleted the earlier one's fixture out
/// from under a walk already reading it. With the pair there is no reachable
/// collision left to clear, which is why the pre-delete is gone rather than
/// kept as insurance — and a leaked directory now names the process to blame.
const Fixture = struct {
    root: []const u8,
    threaded: std.Io.Threaded,

    fn plant(arena: std.mem.Allocator, seed: u32) !Fixture {
        var self = Fixture{
            .root = try std.fmt.allocPrint(arena, "/tmp/irgx_walk_{x}_{d}", .{ seed, std.c.getpid() }),
            .threaded = std.Io.Threaded.init(std.testing.allocator, .{}),
        };
        const io = self.threaded.io();
        try Dir.cwd().createDirPath(io, self.root);
        try Dir.cwd().createDirPath(io, try std.fmt.allocPrint(arena, "{s}/sub", .{self.root}));
        for (fixture) |f| {
            const p = try std.fmt.allocPrint(arena, "{s}/{s}", .{ self.root, f[0] });
            try Dir.cwd().writeFile(io, .{ .sub_path = p, .data = f[1] });
        }
        return self;
    }

    /// Plant one more file into an already-planted tree, for a test whose claim
    /// needs a file the shared fixture has no reason to carry.
    fn sow(self: *Fixture, arena: std.mem.Allocator, rel: []const u8, data: []const u8) !void {
        const p = try std.fmt.allocPrint(arena, "{s}/{s}", .{ self.root, rel });
        try Dir.cwd().writeFile(self.threaded.io(), .{ .sub_path = p, .data = data });
    }

    fn uproot(self: *Fixture) void {
        fault.spare("remove fixture", Dir.cwd().deleteTree(self.threaded.io(), self.root));
        self.threaded.deinit();
    }
};

/// A spec naming `root`, plus whatever else the test wants to say about it. The
/// term array lives in `arena`, which every caller outlives.
fn rooted(arena: std.mem.Allocator, root: []const u8, flags: u32, extra: []const Term) !Spec {
    const terms = try arena.alloc(Term, 1 + extra.len);
    terms[0] = .{ .kind = term_root, .reserved = 0, .text = root.ptr, .text_len = root.len };
    @memcpy(terms[1..], extra);
    return .{
        .struct_size = @sizeOf(Spec),
        .flags = flags,
        .max_depth = 0,
        .terms = terms.ptr,
        .term_count = terms.len,
    };
}

/// Every path the walk yields, with the fixture root stripped off so the
/// assertions read as the tree rather than as a temp directory.
fn listed(arena: std.mem.Allocator, w: *Walk, root: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var e: Entry = undefined;
    while (next(w, &e) == .match)
        try out.append(arena, std.mem.trimStart(u8, e.path.slice()[root.len..], "/"));
    return out.toOwnedSlice(arena);
}

test "walk: the rg default file set, in one order, twice" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.plant(a, 0x71);
    defer fx.uproot();
    const root = fx.root;

    var spec = try rooted(a, root, 0, &.{});
    var w: *Walk = undefined;
    try t.expectEqual(Status.match, open(&spec, &w));
    defer close(w);

    // Sorted, not discovered: `aa` was planted after `zz`, and `sub/` before
    // both. This is the ordering contract, and it is why the fixture plants out
    // of order — a DFS-discovery answer would fail here.
    const want = [_][]const u8{ "aa.txt", "blob.bin", "empty.txt", "sub/nested.md", "zz.txt" };
    try t.expectEqualDeep(@as([]const []const u8, &want), try listed(a, w, root));

    // `.gitignore` itself is hidden and so is `.hidden.txt`; `ignored.txt` is
    // named by the ignore file. All three are absent above — the hidden rule and
    // the gitignore verdict, both decided by the tier this plane exposes.
    try t.expectEqual(@as(usize, want.len), count(w));
    try t.expectEqual(@as(u32, 0), gapped(w));

    // The stream is exhausted; rewinding replays it byte-identically, which is
    // the property materializing bought.
    var spent: Entry = undefined;
    try t.expectEqual(Status.ok, next(w, &spent));
    rewind(w);
    try t.expectEqualDeep(@as([]const []const u8, &want), try listed(a, w, root));
}

test "walk: a path the walk yielded cannot be told it is not a member" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.plant(a, 0x72);
    defer fx.uproot();
    const root = fx.root;

    var spec = try rooted(a, root, 0, &.{});
    var w: *Walk = undefined;
    try t.expectEqual(Status.match, open(&spec, &w));
    defer close(w);

    // Every entry, asked back. This is the predicate's whole warrant: it reads
    // the same list `next` reads, so the two cannot disagree.
    var e: Entry = undefined;
    while (next(w, &e) == .match)
        try t.expectEqual(Status.match, holds(w, e.path.ptr, e.path.len));

    const gone = try std.fmt.allocPrint(a, "{s}/ignored.txt", .{root});
    try t.expectEqual(Status.ok, holds(w, gone.ptr, gone.len));
    try t.expectEqual(Status.ok, holds(w, "", 0));
    // Null WITH a length is the caller's arithmetic bug, never an empty path.
    try t.expectEqual(Status.invalid, holds(w, null, 7));
}

test "walk: MEMBERS applies the three content rules and reports lengths" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.plant(a, 0x73);
    defer fx.uproot();
    const root = fx.root;

    var spec = try rooted(a, root, flag_members, &.{});
    var w: *Walk = undefined;
    try t.expectEqual(Status.match, open(&spec, &w));
    defer close(w);

    // `blob.bin` holds a NUL and `empty.txt` holds nothing, so neither is a
    // member — the two files the path-only walk above DID admit.
    const want = [_][]const u8{ "aa.txt", "sub/nested.md", "zz.txt" };
    var e: Entry = undefined;
    var seen: std.ArrayList([]const u8) = .empty;
    while (next(w, &e) == .match) {
        try seen.append(a, std.mem.trimStart(u8, e.path.slice()[root.len..], "/"));
        // 0 is unambiguous under MEMBERS: an empty file is not a member, so
        // every size here is a real length.
        try t.expect(e.size > 0);
    }
    try t.expectEqualDeep(@as([]const []const u8, &want), seen.items);
    try t.expectEqual(@as(?u64, "alpha\n".len), try lengthOf(w, root, "aa.txt", a));
    // The two the content rules dropped are not merely zero-length here; they
    // are absent, which is the difference between "not a member" and "empty".
    try t.expectEqual(@as(?u64, null), try lengthOf(w, root, "blob.bin", a));
    try t.expectEqual(@as(?u64, null), try lengthOf(w, root, "empty.txt", a));
}

/// The reported length of one entry, or null when the walk never yielded it —
/// an optional rather than an error, because "absent" is one of the two answers
/// a caller here is asking about, and because inventing a fault name for a test
/// lookup would widen the taxonomy the ratchet guards.
fn lengthOf(w: *Walk, root: []const u8, rel: []const u8, a: std.mem.Allocator) !?u64 {
    const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, rel });
    rewind(w);
    var e: Entry = undefined;
    while (next(w, &e) == .match)
        if (std.mem.eql(u8, e.path.slice(), full)) return e.size;
    return null;
}

test "walk: a type term narrows, and an unknown one is refused rather than empty" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.plant(a, 0x74);
    defer fx.uproot();
    const root = fx.root;

    const md = Term{ .kind = term_type, .reserved = 0, .text = "md", .text_len = 2 };
    var spec = try rooted(a, root, 0, &.{md});
    var w: *Walk = undefined;
    try t.expectEqual(Status.match, open(&spec, &w));
    defer close(w);
    const want = [_][]const u8{"sub/nested.md"};
    try t.expectEqualDeep(@as([]const []const u8, &want), try listed(a, w, root));

    // A typo'd type is the one filter mistake that reads exactly like an empty
    // corpus, so it is `.invalid` and never `.ok` with nothing in it.
    const typo = Term{ .kind = term_type, .reserved = 0, .text = "markdwon", .text_len = 8 };
    var bad = try rooted(a, root, 0, &.{typo});
    var unused: *Walk = undefined;
    try t.expectEqual(Status.invalid, open(&bad, &unused));
}

test "walk: a glob un-ignores where a type only un-hides" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.plant(a, 0x75);
    defer fx.uproot();
    const root = fx.root;

    // rg's asymmetry, and the reason the two term kinds are not one: `-g` is an
    // Override whitelist that beats the gitignore verdict outright.
    const g = Term{ .kind = term_glob, .reserved = 0, .text = "*.txt", .text_len = 5 };
    var spec = try rooted(a, root, 0, &.{g});
    var w: *Walk = undefined;
    try t.expectEqual(Status.match, open(&spec, &w));
    defer close(w);
    const got = try listed(a, w, root);
    var found_ignored = false;
    for (got) |p| if (std.mem.eql(u8, p, "ignored.txt")) {
        found_ignored = true;
    };
    try t.expect(found_ignored);
}

test "walk: the spec is fail-closed on every shape it does not recognize" {
    const t = std.testing;
    var w: *Walk = undefined;
    var spec = Spec{ .struct_size = @sizeOf(Spec), .flags = 0, .max_depth = 0, .terms = null, .term_count = 0 };

    try t.expectEqual(Status.invalid, open(null, &w));
    try t.expectEqual(Status.invalid, open(&spec, null));
    // A size this build does not recognize is refused, never read as the prefix
    // it thinks it recognizes.
    spec.struct_size = @sizeOf(Spec) - 8;
    try t.expectEqual(Status.invalid, open(&spec, &w));
    spec.struct_size = @sizeOf(Spec);
    // The highest unclaimed bit: a host that sets one has a wrong belief about
    // the file set it is about to be handed.
    spec.flags = 1 << 31;
    try t.expectEqual(Status.invalid, open(&spec, &w));
    spec.flags = 0;
    // Null WITH a count, which is the caller's arithmetic bug and not an empty
    // declaration.
    spec.term_count = 3;
    try t.expectEqual(Status.invalid, open(&spec, &w));
}

test "walk: a batch is the stream, and cap 0 consumes nothing" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.plant(a, 0x76);
    defer fx.uproot();
    const root = fx.root;

    var spec = try rooted(a, root, 0, &.{});
    var w: *Walk = undefined;
    try t.expectEqual(Status.match, open(&spec, &w));
    defer close(w);

    // `cap == 0` is a legal no-op: it consumes nothing, so the cursor is where
    // it was and the count is the batch's own, never a total it never held.
    var n: usize = 7;
    try t.expectEqual(Status.ok, nextBatch(w, null, 0, &n));
    try t.expectEqual(@as(usize, 0), n);

    // Two short batches then the tail: the concatenation is the stream `next`
    // would have given, in the same order.
    var room: [2]Entry = undefined;
    var seen: std.ArrayList([]const u8) = .empty;
    while (nextBatch(w, &room, room.len, &n) == .match)
        for (room[0..@min(n, room.len)]) |e|
            try seen.append(a, std.mem.trimStart(u8, e.path.slice()[root.len..], "/"));
    const want = [_][]const u8{ "aa.txt", "blob.bin", "empty.txt", "sub/nested.md", "zz.txt" };
    try t.expectEqualDeep(@as([]const []const u8, &want), seen.items);
    // Exhausted: `.ok` with nothing written, exactly as `next` ends.
    try t.expectEqual(Status.ok, nextBatch(w, &room, room.len, &n));
    try t.expectEqual(@as(usize, 0), n);
    // A sink with no total to publish into is the caller's bug.
    try t.expectEqual(Status.invalid, nextBatch(w, &room, room.len, null));
}

test "walk: a brace alternation admits exactly what its alternatives admit" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.plant(a, 0x77);
    defer fx.uproot();
    const root = fx.root;
    // `app.tsx` is the adverse case, and the reason this is a set comparison
    // rather than "did anything come back": a near miss both spellings have to
    // reject, so an over-eager expansion fails here instead of passing wider.
    for ([_][]const u8{ "app.js", "app.ts", "app.tsx", "app.css" }) |n|
        try fx.sow(a, n, "x\n");

    const braced = Term{ .kind = term_glob, .reserved = 0, .text = "*.{js,ts}", .text_len = 9 };
    const js = Term{ .kind = term_glob, .reserved = 0, .text = "*.js", .text_len = 4 };
    const ts = Term{ .kind = term_glob, .reserved = 0, .text = "*.ts", .text_len = 4 };

    var one = try rooted(a, root, 0, &.{braced});
    var two = try rooted(a, root, 0, &.{ js, ts });
    var w1: *Walk = undefined;
    var w2: *Walk = undefined;
    try t.expectEqual(Status.match, open(&one, &w1));
    defer close(w1);
    try t.expectEqual(Status.match, open(&two, &w2));
    defer close(w2);

    // THE claim. Both walks report in the plane's own global lexicographic
    // order over a corpus that holds each path once, so equal lists here is
    // equal SETS — and the expected set is spelled out so a run where both
    // happened to be empty cannot pass.
    const want = [_][]const u8{ "app.js", "app.ts" };
    try t.expectEqualDeep(@as([]const []const u8, &want), try listed(a, w1, root));
    try t.expectEqualDeep(@as([]const []const u8, &want), try listed(a, w2, root));
}

test "walk: an unclosed brace stays refused where a well-formed one expands" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var w: *Walk = undefined;
    // The expansion is reachable now, so the well-formed alternation above is
    // legal. An UNCLOSED `{` is not: as a literal glob it matches nothing,
    // which reads exactly like a corpus that narrowed to nothing.
    const unclosed_brace = Term{ .kind = term_glob, .reserved = 0, .text = "*.{txt,md", .text_len = 9 };
    var spec = try rooted(a, ".", 0, &.{unclosed_brace});
    try t.expectEqual(Status.invalid, open(&spec, &w));

    // An unclosed character class is an error for the same reason, and it is
    // rg's own reading of an explicit `-g` (its `Glob::new`, not the lenient
    // gitignore parse).
    const unclosed = Term{ .kind = term_glob, .reserved = 0, .text = "src/[abc", .text_len = 8 };
    var bad = try rooted(a, ".", 0, &.{unclosed});
    try t.expectEqual(Status.invalid, open(&bad, &w));

    // And one hiding inside a single ALTERNATIVE, which only stays refused
    // because the class check runs on each expanded variant rather than on the
    // pattern that produced them: `src/a` is a fine glob and `src/[bc` is not.
    const inside = Term{ .kind = term_glob, .reserved = 0, .text = "src/{a,[bc}", .text_len = 11 };
    var mixed = try rooted(a, ".", 0, &.{inside});
    try t.expectEqual(Status.invalid, open(&mixed, &w));

    // A term with no text at all is refused whatever its kind: an empty root is
    // not the working directory, and an empty glob is not `*`.
    const blank = Term{ .kind = term_glob, .reserved = 0, .text = "", .text_len = 0 };
    var empty = try rooted(a, ".", 0, &.{blank});
    try t.expectEqual(Status.invalid, open(&empty, &w));
}

test "walk: an alternation past its ceiling faults instead of narrowing" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Thirteen two-way groups name 8192 globs against a 1024 ceiling — sixty-
    // five bytes of spec, and the reason expansion needs a bound at all.
    const hostile = "{a,b}" ** 13;
    const term = Term{ .kind = term_glob, .reserved = 0, .text = hostile.ptr, .text_len = hostile.len };
    var spec = try rooted(a, ".", 0, &.{term});
    var w: *Walk = undefined;
    // `IRGX_OOM` and not `IRGX_INVALID`, because the spec is well-formed: the
    // remedy is a bigger ceiling, which only the caller can grant. That the
    // machine did NOT run out is the half the status folds away, so the fault's
    // name is where a host reads it.
    try t.expectEqual(Status.out_of_memory, open(&spec, &w));
    try t.expectEqual(@as(fault.Fault, error.BudgetExceeded), fault.last().?.code);
}

test "walk: a term whose reserved padding was never initialized is refused" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dirty = Term{ .kind = term_root, .reserved = 0xdead, .text = ".", .text_len = 1 };
    var spec = try rooted(a, ".", 0, &.{dirty});
    var w: *Walk = undefined;
    try t.expectEqual(Status.invalid, open(&spec, &w));
}

test "walk: the constants a host would otherwise hardcode" {
    const t = std.testing;
    var l: Limits = undefined;
    try t.expectEqual(Status.ok, limits(&l));
    try t.expectEqual(@as(u32, @sizeOf(Limits)), l.struct_size);
    try t.expectEqual(@as(u32, 8192), l.binary_window);
    try t.expectEqual(@as(u64, 4 << 20), l.file_cap);
    // Names outnumber rows because a row carries its aliases; both are comptime
    // facts about this build, which is the point of publishing them.
    try t.expect(l.type_names >= l.type_rows);
    try t.expectEqual(Status.invalid, limits(null));
}

test "walk: the binary rule is the window, not the file" {
    const t = std.testing;
    try t.expectEqual(Status.ok, binary("plain text\n", 11));
    try t.expectEqual(Status.match, binary("head\x00tail", 9));
    try t.expectEqual(Status.ok, binary("", 0));
    try t.expectEqual(Status.invalid, binary(null, 4));

    // A NUL PAST the window is not a binary verdict — the rule is exactly the
    // first `binary_window` bytes, and a host reading that much reaches the same
    // answer a whole-file read would.
    var buf: [corpus.binary_window + 8]u8 = undefined;
    @memset(&buf, 'a');
    buf[corpus.binary_window + 2] = 0;
    try t.expectEqual(Status.ok, binary(&buf, buf.len));
    buf[corpus.binary_window - 1] = 0;
    try t.expectEqual(Status.match, binary(&buf, buf.len));
}

test "walk: the genus partition is total and answerable without a walk" {
    const t = std.testing;
    var g: Genus = undefined;
    try t.expectEqual(Status.ok, genusOf("src/main.zig", 12, &g));
    try t.expectEqual(Genus.code, g);
    try t.expectEqual(Status.ok, genusOf("README.md", 9, &g));
    try t.expectEqual(Genus.docs, g);
    try t.expectEqual(Status.ok, genusOf("contracts/engine.toml", 21, &g));
    try t.expectEqual(Genus.data, g);
    // An unfamiliar extension lands in `code`, the partition's default half, so
    // a gap shows one row too many rather than silently hiding a file.
    try t.expectEqual(Status.ok, genusOf("x.qqzz", 6, &g));
    try t.expectEqual(Genus.code, g);
    // A path with no bytes classifies as nothing.
    try t.expectEqual(Status.invalid, genusOf("", 0, &g));
    try t.expectEqual(Status.invalid, genusOf(null, 3, &g));
    try t.expectEqual(Status.invalid, genusOf("a", 1, null));
}
