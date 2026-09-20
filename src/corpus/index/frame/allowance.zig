//! allowance — how many bytes of disk a tree's artifact set may occupy.
//!
//! The memory question already has an answer one tier up (`gist`'s
//! `warden/ration.zig`: a resident session may hold a share of RAM, and a
//! machine too small to lend it arms nothing). This is the same question asked
//! of the other resource, and it went unasked for the same reason the memory
//! one did — every artifact here is individually justified, and nobody was
//! adding them up.
//!
//! Added up on this repository they came to **635 MB**, against a corpus of
//! about 300: a 60 MB trigram pair and its 6 MB crest sieve, a 303 MB content
//! shard, and — from the sibling kinship package writing into the same home —
//! an 87 MB codex shelf, a 69 MB atlas, and a 40 MB fragment atlas. Every one
//! of those is a good trade in a checkout an agent searches five hundred times
//! a day. None of them is a good trade in a folder somebody searched twice,
//! and that is now a place these binaries run: they ship inside a product, on
//! the user's own machine, pointed at the user's own directories.
//!
//! ## What is actually rationed, and what is not
//!
//! The trigram pair is **never** declined. It is what "indexed search" means
//! here, its size is a modest fraction of the corpus (~22% measured), and a
//! build that refuses it has not saved the user disk — it has uninstalled the
//! product. The boundary rule in `home.zig` is what bounds the pair: it can
//! only ever describe a project, because a corpus with no edge no longer
//! resolves a home to write into at all.
//!
//! What is rationed is every tier that stores a **copy of the corpus**:
//! `content.shard` here, the codex shelf and both kinship atlases in the
//! kinship package. Those are the tiers whose size IS the corpus rather than a
//! fraction of it, so they are the ones that turn a hidden directory into a
//! second copy of someone's files — which is a disk cost, and, on a machine
//! that is not a developer's checkout, a duplicate of their documents sitting
//! in a blob they never made.
//!
//! ## Why one number and not a share of the disk
//!
//! A share of free space is the intuitive rule and it is the wrong one, for the
//! reason `ration.zig` gives about RAM: the size of these artifacts is set by
//! the CORPUS, not by the machine, so a bigger disk is not a reason to write a
//! bigger copy of the same tree. A share would also make the same tree index
//! differently on two machines, and differently on one machine on two days.
//!
//! So it is a flat ceiling, the tiers are admitted against it in priority
//! order, and an operator who wants the copy on a tree bigger than the ceiling
//! says so with `<prefix>DISK_MB` — the same shape and the same units as
//! `<prefix>MEMORY_MB`, because it is the same question about the other
//! resource.

const std = @import("std");
const assay = @import("../../../assay/assay.zig");

/// The default ceiling on the copy-shaped tiers, in bytes.
///
/// Chosen as the smallest round number that leaves every tier standing on the
/// largest tree we actually index, so that fixing the user-machine problem
/// costs a developer checkout nothing: this repository's corpus is 303 MiB and
/// its shard is the same, which clears 512 with room to grow. The tree that
/// motivated the number from the other side is llvm-project at roughly 1.5 GB
/// — a shard there is a gigabyte and a half of duplicated source, which is
/// precisely the write this ceiling exists to refuse.
///
/// It is deliberately NOT sized to the biggest corpus anyone might have. A
/// ceiling that admits every case bounds nothing; this one is meant to bind,
/// and the tier it declines is one whose absence costs syscalls and not
/// answers.
const copy_ceiling: u64 = 512 << 20;

/// Operator override, in **megabytes** — same spelling and units as the
/// resident session's `<prefix>MEMORY_MB`. `0` is a legitimate answer and means
/// "write no copy-shaped artifact on this machine at all", which is the setting
/// a product embedding these binaries on someone else's computer may well want.
const override_key = "DISK_MB";

/// The ceiling in force for this process.
pub fn ceiling() u64 {
    if (assay.knobUsize(override_key)) |mb| return @as(u64, mb) << 20;
    return copy_ceiling;
}

/// May a corpus-copy tier of `want` bytes be written, given that `already`
/// bytes of the allowance are spent by copy tiers published before it?
///
/// Priority order is the caller's: tiers ask in the order they are worth
/// having, and the first one that does not fit is the one that declines. That
/// is what keeps the failure graceful — a tree just past the ceiling loses its
/// least valuable copy and keeps the rest, rather than losing all of them at
/// one cliff.
pub fn admits(want: u64, already: u64) bool {
    const cap = ceiling();
    if (cap == 0) return false;
    return want <= cap - @min(already, cap);
}

test "allowance: a copy the size of the corpus is admitted until the ceiling" {
    const t = std.testing;
    // This repository, measured: a 303 MiB shard with nothing spent ahead of
    // it. The number exists to leave a developer checkout untouched, so a
    // regression here is the ceiling having quietly stopped doing that.
    try t.expect(admits(303 << 20, 0));
    // llvm-project's, which is the write worth refusing.
    try t.expect(!admits(1536 << 20, 0));
    // The boundary itself, from both sides.
    try t.expect(admits(copy_ceiling, 0));
    try t.expect(!admits(copy_ceiling + 1, 0));
}

test "allowance: spend is cumulative, so the cheap tier survives the expensive one" {
    const t = std.testing;
    // Two copy tiers over one tree. The first fits; the second is asked with
    // the first already charged, and the arithmetic must not wrap when the
    // spend has already passed the ceiling.
    try t.expect(admits(200 << 20, 300 << 20));
    try t.expect(!admits(300 << 20, 300 << 20));
    try t.expect(!admits(1, copy_ceiling));
    try t.expect(!admits(1, copy_ceiling * 4));
    // A tier that costs nothing is admitted whatever came before — declining a
    // zero-byte write would be arithmetic for its own sake.
    try t.expect(admits(0, copy_ceiling * 4));
}
