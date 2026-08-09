//! Which files a search is even ALLOWED to read.
//!
//! gitignore precedence, the type registry, hidden and binary policy — the half of
//! a grep that has nothing to do with matching and everything to do with whether
//! the answer is the one a person expected. It is a question you can ask on its
//! own here, rather than a side effect of searching, which is what makes "why
//! didn't it look in `vendor/`?" answerable without a pattern.
//!
//! The set is MATERIALIZED at [`Walk::open`]: one filesystem pass, then
//! [`Walk::holds`] is a binary search and [`Walk::rewind`] re-reads nothing.
//!
//! ## Gaps are counted, not swallowed
//!
//! An unreadable directory fails the walk by default, because "nothing matched"
//! and "we never looked there" are different answers and only one of them is worth
//! trusting. [`Policy::TolerateGaps`] turns it into [`Walk::gapped`] — a number you
//! can print — rather than into silence.
//!
//! ## An entry's path belongs to the walk
//!
//! The ABI borrows each `path` from the walk's arena until `irgx_walk_close`, so
//! [`Entry`] borrows the [`Walk`] and outliving it is a compile error rather than a
//! rule in a comment:
//!
//! ```compile_fail,E0505
//! # use irgx::corpus::walk::{Spec, Walk};
//! let mut walk = Walk::open(&Spec::new())?;
//! let escaped = walk.entries().next();  // borrows `walk`
//! drop(walk);                           // ... whose arena dies here
//! println!("{escaped:?}");              // so this cannot compile
//! # Ok::<(), irgx::Error>(())
//! ```

use std::marker::PhantomData;
use std::path::Path;
use std::ptr::NonNull;

use crate::error::{self, Error};
use crate::sys;

/// The plane name a fault from here is reported under.
const PLANE: &str = "walk";

/// How many entries to pull per crossing, as in [`super::tree`].
const BATCH: usize = 64;

/// An opaque `irgx_walk`. Never dereferenced on this side.
#[repr(C)]
struct Handle {
    _opaque: [u8; 0],
}

/// `irgx_walk_term`: one clause of a spec. `text` is borrowed for the duration of
/// the open call only — the walk copies what it keeps.
#[derive(Clone, Copy)]
#[repr(C)]
struct Term {
    kind: u32,
    reserved: u32,
    text: *const u8,
    text_len: usize,
}

/// `irgx_walk_spec`.
#[repr(C)]
struct RawSpec {
    struct_size: u32,
    flags: u32,
    max_depth: u64,
    terms: *const Term,
    term_count: usize,
}

/// `irgx_walk_entry`.
#[derive(Clone, Copy, Default)]
#[repr(C)]
struct Raw {
    path: sys::Text,
    size: u64,
    genus: u32,
    reserved: u32,
}

/// What a path is FOR.
///
/// A total, disjoint partition, which is the property that matters: an unfamiliar
/// extension lands in [`Genus::Code`] rather than falling through a gap, so a
/// classification bug can only ever show one file too many — never hide one.
///
/// This is the eligibility axis a language filter cannot express. `-t rust` is what
/// a file is written IN; this is what it is FOR.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum Genus {
    /// Implementation, and everything unrecognized.
    #[default]
    Code,
    /// The paper trail: markdown, rst, man pages, TeX, licences, changelogs.
    Docs,
    /// Configuration and payload: json, yaml, toml, lockfiles.
    Data,
}

impl Genus {
    fn from_abi(raw: u32) -> Self {
        match raw {
            1 => Self::Docs,
            2 => Self::Data,
            _ => Self::Code,
        }
    }
}

/// A declinature of a default the walk would otherwise apply.
///
/// They all read as negatives because the safe spelling is to set none of them:
/// a walk with no policy honours every ignore file, skips hidden entries and
/// refuses to guess about an unreadable directory.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Policy {
    /// Descend into dotfiles and dot-directories.
    Hidden,
    /// Honour no ignore file at all.
    NoIgnore,
    /// Honour every ignore file except `.gitignore`.
    NoIgnoreVcs,
    /// … except `.ignore`.
    NoIgnoreDot,
    /// … except the ones above the root.
    NoIgnoreParent,
    /// … except `.git/info/exclude`.
    NoIgnoreExclude,
    /// … except the global one.
    NoIgnoreGlobal,
    /// … except the ones named by a [`Spec::ignore_file`] term.
    NoIgnoreFiles,
    /// Apply VCS ignore rules even outside a repository.
    NoRequireGit,
    /// Match ignore-file names case-insensitively.
    IgnoreFileIcase,
    /// Follow symlinks.
    Follow,
    /// Do not cross a filesystem boundary.
    OneFileSystem,
    /// Match globs case-insensitively.
    GlobIcase,
    /// Include directories, not only files.
    Members,
    /// Count unreadable directories ([`Walk::gapped`]) instead of failing.
    TolerateGaps,
}

impl Policy {
    const fn bit(self) -> u32 {
        1 << match self {
            Self::Hidden => 0,
            Self::NoIgnore => 1,
            Self::NoIgnoreVcs => 2,
            Self::NoIgnoreDot => 3,
            Self::NoIgnoreParent => 4,
            Self::NoIgnoreExclude => 5,
            Self::NoIgnoreGlobal => 6,
            Self::NoIgnoreFiles => 7,
            Self::NoRequireGit => 8,
            Self::IgnoreFileIcase => 9,
            Self::Follow => 10,
            Self::OneFileSystem => 11,
            Self::GlobIcase => 12,
            Self::Members => 13,
            Self::TolerateGaps => 14,
        }
    }
}

/// The ceilings this build enforces, so a host sizes its request against the
/// truth instead of a constant it copied.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct Limits {
    struct_size: u32,
    binary_window: u32,
    file_cap: u64,
    type_rows: u32,
    type_names: u32,
    brace_cap: u32,
    brace_group_cap: u32,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            struct_size: size_of::<Self>() as u32,
            binary_window: 0,
            file_cap: 0,
            type_rows: 0,
            type_names: 0,
            brace_cap: 0,
            brace_group_cap: 0,
        }
    }
}

impl Limits {
    /// How many leading bytes are sniffed for the binary verdict — and therefore
    /// the smallest prefix [`is_binary`] needs to agree with a real walk.
    #[must_use]
    pub fn binary_window(&self) -> usize {
        self.binary_window as usize
    }

    /// The most files one walk may materialize.
    #[must_use]
    pub fn file_cap(&self) -> u64 {
        self.file_cap
    }

    /// How many rows the type registry holds.
    #[must_use]
    pub fn type_rows(&self) -> usize {
        self.type_rows as usize
    }

    /// How many distinct type names it answers to.
    #[must_use]
    pub fn type_names(&self) -> usize {
        self.type_names as usize
    }

    /// Most globs one `{a,b}` term may expand to. This bounds the PRODUCT, which
    /// is what a hostile pattern multiplies; past it [`Walk::open`] refuses
    /// rather than allocating, as [`Error::OutOfMemory`] whose `detail` reads
    /// `BudgetExceeded` — the spec was well-formed and the remedy is a smaller
    /// glob, not more memory.
    #[must_use]
    pub fn brace_cap(&self) -> usize {
        self.brace_cap as usize
    }

    /// Most groups one such term may carry — a second ceiling, because
    /// `{a}{a}{a}…` has a product of one and so clears [`Limits::brace_cap`]
    /// while still recursing once per group. A host checking only the first will
    /// still build a term the open refuses.
    #[must_use]
    pub fn brace_group_cap(&self) -> usize {
        self.brace_group_cap as usize
    }
}

/// One complete eligibility question.
///
/// Terms are borrowed until [`Walk::open`] copies them, which is what the lifetime
/// says.
#[derive(Clone, Default)]
pub struct Spec<'t> {
    terms: Vec<Term>,
    flags: u32,
    max_depth: u64,
    borrowed: PhantomData<&'t [u8]>,
}

impl std::fmt::Debug for Spec<'_> {
    /// Shows the terms as the text they name, which is the question the spec
    /// asks; the derived form would print the pointers it asks it with.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let terms = self.terms.iter().map(|term| {
            // SAFETY: `'t` outlives `&self`, so every term still points into the
            // borrow it was built from.
            let text = unsafe { std::slice::from_raw_parts(term.text, term.text_len) };
            (
                KINDS.get(term.kind as usize).copied().unwrap_or("?"),
                String::from_utf8_lossy(text),
            )
        });
        f.debug_struct("Spec")
            .field("terms", &terms.collect::<Vec<_>>())
            .field("flags", &format_args!("{:#014b}", self.flags))
            .field("max_depth", &self.max_depth)
            .finish()
    }
}

/// The `IRGX_TERM_*` kinds, in ABI order, for [`Spec`]'s `Debug`.
const KINDS: [&str; 7] = [
    "root",
    "glob",
    "not_glob",
    "iglob",
    "of_type",
    "not_type",
    "ignore_file",
];

impl<'t> Spec<'t> {
    /// Every default, and therefore not an empty question: **a spec with no root
    /// walks the working directory**, which is what `rg pat` with no path does.
    ///
    /// Ignore precedence and the hidden rule are in force, depth is unlimited,
    /// symlinks are unfollowed, no file is read, and an unreadable directory is a
    /// refusal rather than a gap. Naming `.` with [`Spec::root`] is a different
    /// walk in one visible way — the paths then carry the `./` prefix, exactly as
    /// `rg pat .` prints them.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// A place to walk from. Repeatable.
    #[must_use]
    pub fn root(self, path: &'t Path) -> Self {
        self.term(0, path.as_os_str().as_encoded_bytes())
    }

    /// Keep only paths matching this glob. Repeatable.
    #[must_use]
    pub fn glob(self, glob: &'t str) -> Self {
        self.term(1, glob.as_bytes())
    }

    /// Drop paths matching this glob. Repeatable.
    #[must_use]
    pub fn not_glob(self, glob: &'t str) -> Self {
        self.term(2, glob.as_bytes())
    }

    /// Keep only paths matching this glob, case-insensitively. Repeatable.
    #[must_use]
    pub fn iglob(self, glob: &'t str) -> Self {
        self.term(3, glob.as_bytes())
    }

    /// Keep only files of this registered type, e.g. `"rust"`, `"docs"`.
    /// Repeatable.
    #[must_use]
    pub fn of_type(self, name: &'t str) -> Self {
        self.term(4, name.as_bytes())
    }

    /// Drop files of this registered type. Repeatable.
    #[must_use]
    pub fn not_type(self, name: &'t str) -> Self {
        self.term(5, name.as_bytes())
    }

    /// Also honour an ignore file of this name, e.g. `".gistignore"`.
    /// Repeatable.
    #[must_use]
    pub fn ignore_file(self, name: &'t str) -> Self {
        self.term(6, name.as_bytes())
    }

    /// Decline one of the walk's defaults. Repeatable.
    #[must_use]
    pub fn with(mut self, policy: Policy) -> Self {
        self.flags |= policy.bit();
        self
    }

    /// How deep to descend. 0, the default, is unbounded.
    #[must_use]
    pub fn max_depth(mut self, depth: u64) -> Self {
        self.max_depth = depth;
        self
    }

    fn term(mut self, kind: u32, text: &'t [u8]) -> Self {
        self.terms.push(Term {
            kind,
            reserved: 0,
            text: text.as_ptr(),
            text_len: text.len(),
        });
        self
    }
}

/// A materialized set of eligible files.
///
/// Not `Send`: the handle owns the arena every [`Entry`] borrows from and the
/// iteration cursor over it.
pub struct Walk {
    handle: NonNull<Handle>,
}

impl Walk {
    /// The ceilings this build enforces.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] if the linked library rejected the struct this crate
    /// declares.
    pub fn limits() -> Result<Limits, Error> {
        let mut out = Limits::default();
        // SAFETY: `out` is a live `irgx_limits` whose `struct_size` we stamped.
        let status = unsafe { ffi::irgx_walk_limits(&raw mut out) };
        if status < 0 {
            return Err(error::plane_fault(status, PLANE));
        }
        Ok(out)
    }

    /// Materialize the eligible set.
    ///
    /// One filesystem pass. Everything after this is memory.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] for a malformed glob or unknown type name, for an
    /// unreadable directory without [`Policy::TolerateGaps`], or for a set past
    /// [`Limits::file_cap`].
    pub fn open(spec: &Spec<'_>) -> Result<Self, Error> {
        let raw = RawSpec {
            struct_size: size_of::<RawSpec>() as u32,
            flags: spec.flags,
            max_depth: spec.max_depth,
            terms: spec.terms.as_ptr(),
            term_count: spec.terms.len(),
        };
        let mut out: *mut Handle = std::ptr::null_mut();
        // SAFETY: `raw` is a live `irgx_walk_spec` whose `struct_size` we stamped,
        // its terms are live for the duration of the call (the lifetime on `Spec`
        // is what guarantees that), and `out` is a live slot.
        let status = unsafe { ffi::irgx_walk_open(&raw const raw, &raw mut out) };
        if status < 0 {
            return Err(error::plane_fault(status, PLANE));
        }
        NonNull::new(out)
            .map(|handle| Self { handle })
            .ok_or_else(|| Error::Inconsistent {
                message: "the walk plane reported success and produced no handle".to_owned(),
            })
    }

    /// How many entries the set holds.
    #[must_use]
    pub fn len(&self) -> usize {
        // SAFETY: a pure reader over a handle live for `&self`.
        unsafe { ffi::irgx_walk_count(self.handle.as_ptr()) }
    }

    /// Whether the set is empty.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// How many directories were unreadable but tolerated.
    ///
    /// The number that separates "nothing matched" from "we never looked there".
    /// Always 0 without [`Policy::TolerateGaps`], because then the walk failed
    /// instead.
    #[must_use]
    pub fn gapped(&self) -> u32 {
        // SAFETY: a pure reader over a handle live for `&self`.
        unsafe { ffi::irgx_walk_gapped(self.handle.as_ptr()) }
    }

    /// Whether this exact path is in the set — membership, without iterating.
    #[must_use]
    pub fn holds(&self, path: &Path) -> bool {
        let bytes = path.as_os_str().as_encoded_bytes();
        // SAFETY: the handle is live for `&self` and `bytes` is a live slice passed
        // with its own length.
        let status =
            unsafe { ffi::irgx_walk_holds(self.handle.as_ptr(), bytes.as_ptr(), bytes.len()) };
        status == sys::MATCH
    }

    /// Restart iteration.
    ///
    /// The set is already materialized, so this re-reads nothing from the
    /// filesystem.
    pub fn rewind(&mut self) {
        // SAFETY: the handle is live and exclusively ours for `&mut self`.
        unsafe { ffi::irgx_walk_rewind(self.handle.as_ptr()) };
    }

    /// The next eligible file, one ABI crossing at a time.
    ///
    /// For a host pulling one file per unit of its own work — otherwise use
    /// [`Walk::entries`], which batches.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] if the walk could not produce the entry.
    pub fn next_entry(&mut self) -> Result<Option<Entry<'_>>, Error> {
        let mut raw = Raw::default();
        // SAFETY: the handle is live and exclusively ours for `&mut self`, and
        // `raw` is a live `irgx_walk_entry` the library writes only when it has
        // one.
        let status = unsafe { ffi::irgx_walk_next(self.handle.as_ptr(), &raw mut raw) };
        if status < 0 {
            return Err(error::plane_fault(status, PLANE));
        }
        Ok((status == sys::MATCH).then_some(Entry {
            raw,
            owner: PhantomData,
        }))
    }

    /// The eligible files, in order.
    ///
    /// Batched, for the same reason the record stream is: a crossing per file over
    /// a hundred thousand of them is cost with nothing to show for it. Each
    /// [`Entry`] borrows this walk.
    pub fn entries(&mut self) -> Entries<'_> {
        Entries {
            handle: self.handle,
            buffer: [Raw::default(); BATCH],
            filled: 0,
            at: 0,
            drained: false,
            owner: PhantomData,
        }
    }
}

impl Drop for Walk {
    fn drop(&mut self) {
        // SAFETY: the handle came from `irgx_walk_open` and is closed exactly once,
        // here. Every `Entry` borrowing its arena is gone — the lifetime on
        // `entries` is what proves that.
        unsafe { ffi::irgx_walk_close(self.handle.as_ptr()) };
    }
}

impl std::fmt::Debug for Walk {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Walk")
            .field("files", &self.len())
            .field("gapped", &self.gapped())
            .finish()
    }
}

/// The eligible set, batched.
pub struct Entries<'w> {
    handle: NonNull<Handle>,
    buffer: [Raw; BATCH],
    filled: usize,
    at: usize,
    drained: bool,
    owner: PhantomData<&'w mut ()>,
}

impl<'w> Iterator for Entries<'w> {
    type Item = Result<Entry<'w>, Error>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.at == self.filled {
            if self.drained {
                return None;
            }
            let mut written = 0usize;
            // SAFETY: the walk is live for `'w`; `buffer` is ours and passed with
            // its true capacity, and `written` is a live slot holding what this
            // call CONSUMED — so a short fill ends the stream rather than sizing a
            // retry.
            let status = unsafe {
                ffi::irgx_walk_next_batch(
                    self.handle.as_ptr(),
                    self.buffer.as_mut_ptr(),
                    BATCH,
                    &raw mut written,
                )
            };
            if status < 0 {
                self.drained = true;
                return Some(Err(error::plane_fault(status, PLANE)));
            }
            if written == 0 {
                self.drained = true;
                return None;
            }
            self.drained = written < BATCH;
            self.filled = written;
            self.at = 0;
        }
        let raw = self.buffer[self.at];
        self.at += 1;
        Some(Ok(Entry {
            raw,
            owner: PhantomData,
        }))
    }
}

/// One eligible file, borrowed from the [`Walk`] that produced it.
#[derive(Clone, Copy)]
pub struct Entry<'w> {
    raw: Raw,
    owner: PhantomData<&'w ()>,
}

impl<'w> Entry<'w> {
    /// The path, as bytes borrowed from the walk.
    #[must_use]
    pub fn path(&self) -> &'w [u8] {
        // SAFETY: the header documents `path` as borrowed from the walk until
        // `irgx_walk_close`, and `'w` proves the walk is still open.
        unsafe { sys::borrowed(&self.raw.path) }
    }

    /// The path, if it is UTF-8.
    #[must_use]
    pub fn path_str(&self) -> Option<&'w str> {
        std::str::from_utf8(self.path()).ok()
    }

    /// The file's length in bytes, or 0 for a walk that never asked.
    ///
    /// This plane reports lengths without keeping bodies, and it only reads a file
    /// under [`Policy::Members`] — so without that policy every size is 0, and
    /// with it none can be, since an empty file is not a member. The one field is
    /// therefore unambiguous in both modes, and `Some`/`None` would be a second
    /// way to say what the policy already says.
    #[must_use]
    pub fn size(&self) -> u64 {
        self.raw.size
    }

    /// What the file is FOR.
    #[must_use]
    pub fn genus(&self) -> Genus {
        Genus::from_abi(self.raw.genus)
    }
}

impl std::fmt::Debug for Entry<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Entry")
            .field("path", &String::from_utf8_lossy(self.path()))
            .field("size", &self.raw.size)
            .field("genus", &self.genus())
            .finish()
    }
}

/// Whether these bytes read as binary under the same window a walk applies.
///
/// For a host that already holds the bytes and wants the walk's verdict rather
/// than its own. Pass at least [`Limits::binary_window`] bytes for the two to
/// agree.
#[must_use]
pub fn is_binary(bytes: &[u8]) -> bool {
    // SAFETY: `bytes` is a live slice passed with its own length; an empty slice
    // with a dangling pointer is accepted, the header taking `len` as
    // authoritative.
    let status = unsafe { ffi::irgx_walk_binary(bytes.as_ptr(), bytes.len()) };
    status == sys::MATCH
}

/// What a path is FOR, from the path alone.
///
/// Pure and cheap — no filesystem access — so a host can partition a list it
/// already has without opening a walk.
///
/// # Errors
///
/// [`Error::Plane`] for an empty path, which classifies as nothing.
pub fn genus(path: &Path) -> Result<Genus, Error> {
    let bytes = path.as_os_str().as_encoded_bytes();
    let mut out = 0u32;
    // SAFETY: `bytes` is a live slice with its own length and `out` is a live slot
    // the library writes only on success.
    let status = unsafe { ffi::irgx_walk_genus(bytes.as_ptr(), bytes.len(), &raw mut out) };
    if status < 0 {
        return Err(error::plane_fault(status, PLANE));
    }
    Ok(Genus::from_abi(out))
}

/// The walk plane's seam, from the `irgx_walk_*` block of `irgx.h`.
mod ffi {
    use super::{Handle, Limits, Raw, RawSpec};

    unsafe extern "C" {
        pub fn irgx_walk_limits(out: *mut Limits) -> i32;
        pub fn irgx_walk_open(spec: *const RawSpec, out: *mut *mut Handle) -> i32;
        pub fn irgx_walk_count(w: *const Handle) -> usize;
        pub fn irgx_walk_gapped(w: *const Handle) -> u32;
        pub fn irgx_walk_next(w: *mut Handle, out: *mut Raw) -> i32;
        pub fn irgx_walk_next_batch(
            w: *mut Handle,
            out: *mut Raw,
            cap: usize,
            written: *mut usize,
        ) -> i32;
        pub fn irgx_walk_rewind(w: *mut Handle);
        pub fn irgx_walk_holds(w: *const Handle, path: *const u8, path_len: usize) -> i32;
        pub fn irgx_walk_close(w: *mut Handle);
        pub fn irgx_walk_binary(bytes: *const u8, len: usize) -> i32;
        pub fn irgx_walk_genus(path: *const u8, len: usize, out: *mut u32) -> i32;
    }
}
