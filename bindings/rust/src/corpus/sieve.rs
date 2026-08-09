//! Narrowing, so most files are never opened at all.
//!
//! Two persisted tiers — a trigram index and a crest sieve — and one rule that
//! governs how every answer here may be used: **every answer is a SUPERSET.** A
//! sieve rules documents OUT; it never rules one in. A candidate still has to be
//! read and matched. Treating a candidate list as a result list is the one way to
//! misuse this plane, and it is the reason [`Sieve::candidates`] is spelled that
//! way rather than as a search.
//!
//! ## Declining is the normal case, not the error case
//!
//! Three things here answer with an [`Answer`] instead of a `Result`, because for
//! each of them an empty list would be a LIE:
//!
//! * [`Sieve::open`] declines when no index has been built. Nothing is wrong — this
//!   corpus simply has no narrowing tier, and the host reads every file exactly as
//!   it did before.
//! * [`Sieve::literal`] and [`Sieve::candidates`] decline when nothing could
//!   narrow. "Read everything" and "read nothing" are opposite instructions, and
//!   an empty candidate set means the second one.
//! * [`Sieve::stale_count`] declines when there is no usable anchor. With nothing
//!   to date against, the honest answer is not zero.
//!
//! ## The plan is derived once
//!
//! [`Winnow::of`] turns a compiled pattern into a narrowing plan, and the plan is
//! spent across many queries. It takes a [`Regex`](crate::Regex) and NOT a pattern
//! string on purpose: the plan is derived from the AST that handle compiled, so a
//! host cannot hand over a plan that disagrees with the pattern it will verify
//! with — there is nowhere to put one.
//!
//! ## A document path belongs to the sieve
//!
//! [`Sieve::doc_path`] and [`Sieve::root`] hand out the artifacts' own bytes, which
//! die at `irgx_sieve_close`. That is what makes turning a candidate list into
//! readable paths free rather than a copy per document, and the lifetime is what
//! keeps it sound:
//!
//! ```compile_fail,E0505
//! # use irgx::{Answer, corpus::sieve::Sieve};
//! let Answer::Given(sieve) = Sieve::here()? else { return Ok(()) };
//! let path = sieve.doc_path(0)?;  // borrows `sieve`
//! drop(sieve);                    // ... whose mapping dies here
//! println!("{path:?}");           // so this cannot compile
//! # Ok::<(), irgx::Error>(())
//! ```

use std::path::Path;
use std::ptr::NonNull;

use crate::error::{self, Error};
use crate::sink;
use crate::sys;
use crate::{Answer, Regex};

/// The plane name a fault from the artifacts is reported under.
const PLANE: &str = "sieve";
/// The plane name a fault from a narrowing plan is reported under.
const PLAN: &str = "winnow";

/// An opaque `irgx_sieve`. Never dereferenced on this side.
#[repr(C)]
struct SieveHandle {
    _opaque: [u8; 0],
}

/// An opaque `irgx_winnow`. Never dereferenced on this side.
#[repr(C)]
struct WinnowHandle {
    _opaque: [u8; 0],
}

/// What the artifacts contain, and which tiers are present at all.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct Facts {
    struct_size: u32,
    doc_count: u32,
    path_count: u32,
    posting_count: u32,
    root_count: u32,
    has_crest: u32,
    has_codicil: u32,
    reserved: u32,
}

impl Default for Facts {
    fn default() -> Self {
        Self {
            struct_size: size_of::<Self>() as u32,
            doc_count: 0,
            path_count: 0,
            posting_count: 0,
            root_count: 0,
            has_crest: 0,
            has_codicil: 0,
            reserved: 0,
        }
    }
}

impl Facts {
    /// How many documents the index covers.
    #[must_use]
    pub fn documents(&self) -> u32 {
        self.doc_count
    }

    /// How many distinct paths it holds.
    #[must_use]
    pub fn paths(&self) -> u32 {
        self.path_count
    }

    /// How many postings the trigram tier holds — the index's bulk.
    #[must_use]
    pub fn postings(&self) -> u32 {
        self.posting_count
    }

    /// How many roots the artifacts were built over. The upper bound for
    /// [`Sieve::root`].
    #[must_use]
    pub fn roots(&self) -> u32 {
        self.root_count
    }

    /// Whether the crest tier is present — the second narrowing, beyond trigrams.
    #[must_use]
    pub fn has_crest(&self) -> bool {
        self.has_crest != 0
    }

    /// Whether the sidecar is present.
    #[must_use]
    pub fn has_codicil(&self) -> bool {
        self.has_codicil != 0
    }
}

/// Whether the artifacts still describe the tree.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Freshness {
    /// Anchored to this tree, at this wall-clock instant. Every file changed since
    /// the anchor is folded in on top of the index, so an old anchor costs
    /// pruning rather than correctness.
    Anchored {
        /// The instant the verdict is measured against, in nanoseconds.
        anchor_ns: i64,
    },
    /// No anchor was recorded, so freshness cannot be judged and nothing may be
    /// elided.
    Unanchored,
    /// The artifacts were built over a DIFFERENT tree. They are inert here rather
    /// than wrong — seeing the instant is how a host recognizes that.
    Foreign {
        /// The anchor the artifacts carry, which belongs to somebody else's tree.
        anchor_ns: i64,
    },
    /// A state this build does not know, from a newer library. Reported rather
    /// than read as fresh.
    Unknown {
        /// The raw state code.
        state: i32,
    },
}

/// `irgx_freshness`.
#[derive(Clone, Copy)]
#[repr(C)]
struct RawFreshness {
    struct_size: u32,
    state: i32,
    anchor_ns: i64,
    reserved: i32,
}

impl Default for RawFreshness {
    fn default() -> Self {
        Self {
            struct_size: size_of::<Self>() as u32,
            state: 0,
            anchor_ns: 0,
            reserved: 0,
        }
    }
}

impl Freshness {
    /// Whether an index answer may be trusted to prune.
    #[must_use]
    pub fn is_usable(&self) -> bool {
        matches!(self, Self::Anchored { .. })
    }

    /// The anchor instant, when there is one.
    #[must_use]
    pub fn anchor_ns(&self) -> Option<i64> {
        match self {
            Self::Anchored { anchor_ns } | Self::Foreign { anchor_ns } => Some(*anchor_ns),
            Self::Unanchored | Self::Unknown { .. } => None,
        }
    }
}

/// What a narrowing plan is made of, and whether it can narrow at all.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct WinnowFacts {
    struct_size: u32,
    flags: u32,
    clauses: u32,
    atoms: u32,
    literals: u32,
    alternatives: u32,
    sieve_active: u32,
    idle: u32,
}

impl Default for WinnowFacts {
    fn default() -> Self {
        Self {
            struct_size: size_of::<Self>() as u32,
            flags: 0,
            clauses: 0,
            atoms: 0,
            literals: 0,
            alternatives: 0,
            sieve_active: 0,
            idle: 0,
        }
    }
}

impl WinnowFacts {
    /// How many clauses the plan holds — the conjunction the index intersects.
    #[must_use]
    pub fn clauses(&self) -> u32 {
        self.clauses
    }

    /// How many atoms across all clauses.
    #[must_use]
    pub fn atoms(&self) -> u32 {
        self.atoms
    }

    /// How many literals the plan extracted.
    #[must_use]
    pub fn literals(&self) -> u32 {
        self.literals
    }

    /// How many alternative branches it had to keep.
    #[must_use]
    pub fn alternatives(&self) -> u32 {
        self.alternatives
    }

    /// Whether the crest tier participates in this plan.
    #[must_use]
    pub fn sieve_active(&self) -> bool {
        self.sieve_active != 0
    }

    /// Whether the plan rules NOTHING out.
    ///
    /// The honest answer that this pattern cannot be narrowed — an empty candidate
    /// list would have been a lie. A host seeing this reads every file.
    #[must_use]
    pub fn is_idle(&self) -> bool {
        self.idle != 0
    }
}

/// The persisted narrowing artifacts for one tree.
///
/// Not `Send`: the handle owns the memory-mapped artifacts, the fold cache and the
/// I/O context it reads them with.
pub struct Sieve {
    handle: NonNull<SieveHandle>,
}

impl Sieve {
    /// Open the artifacts in the corpus's own artifact home.
    ///
    /// [`Answer::Declined`] when no index has been built.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] if the artifacts exist and could not be read.
    pub fn here() -> Result<Answer<Self>, Error> {
        // A zero length is the ABI's spelling of "the artifact home", which the
        // library resolves itself — a host guessing at the path would be encoding a
        // policy it does not own.
        Self::opened(std::ptr::null(), 0)
    }

    /// Open the artifacts in `dir`.
    ///
    /// A deliberate override, and it costs freshness: artifacts outside the home
    /// cannot be anchored to this tree, so [`Sieve::freshness`] will say
    /// [`Freshness::Foreign`] and nothing may be elided on their word.
    ///
    /// [`Answer::Declined`] when there is no index there.
    ///
    /// # Errors
    ///
    /// As [`Sieve::here`].
    pub fn at(dir: &Path) -> Result<Answer<Self>, Error> {
        let bytes = dir.as_os_str().as_encoded_bytes();
        if bytes.is_empty() {
            // Empty would silently mean `here()`, and a caller that built a path
            // and got an empty one has a bug worth hearing about.
            return Err(Error::Plane {
                plane: PLANE,
                status: crate::Status::INVALID,
                detail: Some("an empty directory is not an artifact location".to_owned()),
            });
        }
        Self::opened(bytes.as_ptr(), bytes.len())
    }

    fn opened(dir: *const u8, len: usize) -> Result<Answer<Self>, Error> {
        let mut out: *mut SieveHandle = std::ptr::null_mut();
        // SAFETY: `dir`/`len` are a live borrowed span (or null with 0, which the
        // header accepts), and `out` is a live slot written only on success.
        let status = unsafe { ffi::irgx_sieve_open(dir, len, &raw mut out) };
        if status == sys::STALE {
            return Ok(Answer::Declined);
        }
        if status < 0 {
            return Err(error::plane_fault(status, PLANE));
        }
        NonNull::new(out)
            .map(|handle| Answer::Given(Self { handle }))
            .ok_or_else(|| Error::Inconsistent {
                message: "the sieve plane reported success and produced no handle".to_owned(),
            })
    }

    /// What this artifact set contains.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] if the linked library rejected the struct this crate
    /// declares.
    pub fn facts(&self) -> Result<Facts, Error> {
        let mut out = Facts::default();
        // SAFETY: `out` is a live `irgx_sieve_facts` whose `struct_size` we
        // stamped, and the handle is live for `&self`.
        let status = unsafe { ffi::irgx_sieve_describe(self.handle.as_ptr(), &raw mut out) };
        if status < 0 {
            return Err(error::plane_fault(status, PLANE));
        }
        Ok(out)
    }

    /// The path a document id names.
    ///
    /// Borrowed from the sieve, which is what turns every candidate list into
    /// something readable without a copy per document.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] for a document id this index does not hold.
    pub fn doc_path(&self, doc: u32) -> Result<&[u8], Error> {
        self.text(|handle, out| {
            // SAFETY: the handle is live for `&self` and `out` is a live
            // `irgx_text` the library writes only on success.
            unsafe { ffi::irgx_sieve_doc_path(handle, doc, out) }
        })
    }

    /// The `i`-th root the artifacts were built over.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] for an `i` past [`Facts::roots`].
    pub fn root(&self, i: u32) -> Result<&[u8], Error> {
        self.text(|handle, out| {
            // SAFETY: as `doc_path`.
            unsafe { ffi::irgx_sieve_root(handle, i, out) }
        })
    }

    /// The two borrowed-span readers' shared tail.
    fn text(
        &self,
        read: impl FnOnce(*const SieveHandle, *mut sys::Text) -> i32,
    ) -> Result<&[u8], Error> {
        let mut out = sys::Text::default();
        let status = read(self.handle.as_ptr(), &raw mut out);
        if status < 0 {
            return Err(error::plane_fault(status, PLANE));
        }
        // SAFETY: the header documents the span as borrowed until
        // `irgx_sieve_close`, and the returned lifetime is `&self` — so the
        // compiler will not let it outlive the handle.
        Ok(unsafe { sys::borrowed(&out) })
    }

    /// Documents that could contain `needle`, ascending. A superset.
    ///
    /// [`Answer::Declined`] when the tier cannot bound this literal, which means
    /// "read everything" — never an empty candidate set.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] for an empty needle, or if the artifacts could not be
    /// read.
    pub fn literal(&self, needle: &[u8]) -> Result<Answer<Vec<u32>>, Error> {
        sink::reap(PLANE, CANDIDATE_GUESS, |out, cap, written| {
            // SAFETY: the handle is live for `&self`, `needle` a live slice with
            // its own length, and `out`/`cap`/`written` are `reap`'s buffer, its
            // true capacity, and a live count slot.
            unsafe {
                ffi::irgx_sieve_literal(
                    self.handle.as_ptr(),
                    needle.as_ptr(),
                    needle.len(),
                    out,
                    cap,
                    written,
                )
            }
        })
    }

    /// The same, for a UNION of literals — merged inside the index rather than by
    /// N crossings a host stitches together.
    ///
    /// Sound only because it is a union: one branch the tier cannot bound leaves
    /// the whole answer unbounded, so it declines rather than hand back the
    /// branches it could do.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] for an empty set or an empty branch — an empty
    /// alternation is not a question, and an empty branch admits everything.
    pub fn alternation<N: AsRef<[u8]>>(&self, needles: &[N]) -> Result<Answer<Vec<u32>>, Error> {
        let list: Vec<sys::Text> = needles
            .iter()
            .map(|needle| {
                let bytes = needle.as_ref();
                sys::Text {
                    ptr: bytes.as_ptr(),
                    len: bytes.len(),
                }
            })
            .collect();
        sink::reap(PLANE, CANDIDATE_GUESS, |out, cap, written| {
            // SAFETY: as `literal`, plus `list` being a live array of live borrowed
            // spans passed with its own length and outliving the call.
            unsafe {
                ffi::irgx_sieve_alternation(
                    self.handle.as_ptr(),
                    list.as_ptr(),
                    list.len(),
                    out,
                    cap,
                    written,
                )
            }
        })
    }

    /// What a whole plan admits, in document-id order.
    ///
    /// The raw index answer, for a host that wants to intersect it with something
    /// else. It is sound against the INDEX rather than against live bytes, so a
    /// file changed since the anchor may be missing — use
    /// [`Sieve::reading_list`] when that matters.
    ///
    /// [`Answer::Declined`] when nothing could narrow.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] if the artifacts could not be read.
    pub fn candidates(&self, plan: &Winnow) -> Result<Answer<Vec<u32>>, Error> {
        self.admitted(plan, |handle, w, out, cap, written| {
            // SAFETY: both handles are live for their borrows, and
            // `out`/`cap`/`written` are `reap`'s buffer, capacity and count slot.
            unsafe { ffi::irgx_sieve_candidates(handle, w, out, cap, written) }
        })
    }

    /// The same set, sequenced by what is cheapest to read — and sound against
    /// live bytes, folding in everything changed since the anchor.
    ///
    /// This is the one to iterate. Without a usable anchor the fold stands down and
    /// every document is a candidate: correct, and slower, and
    /// [`Sieve::freshness`] says so.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] if the artifacts could not be read.
    pub fn reading_list(&self, plan: &Winnow) -> Result<Answer<Vec<u32>>, Error> {
        self.admitted(plan, |handle, w, out, cap, written| {
            // SAFETY: as `candidates`.
            unsafe { ffi::irgx_sieve_reading_list(handle, w, out, cap, written) }
        })
    }

    /// The two plan readers' shared tail.
    fn admitted(
        &self,
        plan: &Winnow,
        mut ask: impl FnMut(*mut SieveHandle, *const WinnowHandle, *mut u32, usize, *mut usize) -> i32,
    ) -> Result<Answer<Vec<u32>>, Error> {
        let hint = self.facts().map_or(CANDIDATE_GUESS, |facts| {
            // A plan that narrows well admits a fraction of the corpus, and a plan
            // that narrows badly admits nearly all of it. Sizing at the whole
            // document count spends memory to make the common case one crossing;
            // the ceiling below keeps that from being a surprise on a huge index.
            (facts.documents() as usize).min(MAX_GUESS)
        });
        sink::reap(PLANE, hint, |out, cap, written| {
            ask(
                self.handle.as_ptr(),
                plan.handle.as_ptr(),
                out,
                cap,
                written,
            )
        })
    }

    /// Whether the artifacts still describe the tree.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] if the linked library rejected the struct this crate
    /// declares.
    pub fn freshness(&self) -> Result<Freshness, Error> {
        let mut out = RawFreshness::default();
        // SAFETY: `out` is a live `irgx_freshness` whose `struct_size` we stamped,
        // and the handle is live for `&self`.
        let status = unsafe { ffi::irgx_sieve_freshness(self.handle.as_ptr(), &raw mut out) };
        if status < 0 {
            return Err(error::plane_fault(status, PLANE));
        }
        Ok(match out.state {
            1 => Freshness::Anchored {
                anchor_ns: out.anchor_ns,
            },
            2 => Freshness::Unanchored,
            3 => Freshness::Foreign {
                anchor_ns: out.anchor_ns,
            },
            state => Freshness::Unknown { state },
        })
    }

    /// HOW MANY documents changed since the anchor.
    ///
    /// The magnitude [`Sieve::freshness`] reduces to a state, for a host deciding
    /// whether a rebuild is worth it. It walks the tree, so it costs more than
    /// asking for the state.
    ///
    /// [`Answer::Declined`] when there is no usable anchor: with nothing to date
    /// against, the honest answer is not zero.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] if the tree could not be read.
    pub fn stale_count(&self) -> Result<Answer<usize>, Error> {
        let mut out = 0usize;
        // SAFETY: the handle is live for `&self` and `out` is a live slot the
        // library writes only when it has an answer.
        let status = unsafe { ffi::irgx_sieve_stale_count(self.handle.as_ptr(), &raw mut out) };
        if status == sys::STALE {
            return Ok(Answer::Declined);
        }
        if status < 0 {
            return Err(error::plane_fault(status, PLANE));
        }
        Ok(Answer::Given(out))
    }
}

/// How many document ids to size a narrowing answer at before asking the index
/// how many there really are.
const CANDIDATE_GUESS: usize = 256;

/// The ceiling on that guess, so a million-document index does not allocate four
/// megabytes for a query that admits nine files.
const MAX_GUESS: usize = 4096;

impl Drop for Sieve {
    fn drop(&mut self) {
        // SAFETY: the handle came from `irgx_sieve_open` and is closed exactly
        // once, here. Every borrowed path is gone — they borrow `&self`.
        unsafe { ffi::irgx_sieve_close(self.handle.as_ptr()) };
    }
}

impl std::fmt::Debug for Sieve {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Sieve")
            .field("facts", &self.facts().ok())
            .field("freshness", &self.freshness().ok())
            .finish()
    }
}

/// A pattern's narrowing plan, derived once and spent across many queries.
///
/// Not `Send`: the plan owns an arena of extracted literals.
pub struct Winnow {
    handle: NonNull<WinnowHandle>,
}

impl Winnow {
    /// Derive `re`'s narrowing plan.
    ///
    /// The plan copies what it needs, so it outlives the pattern it came from.
    ///
    /// # Errors
    ///
    /// [`Error::OutOfMemory`] if the plan would not fit.
    pub fn of(re: &Regex) -> Result<Self, Error> {
        let mut out: *mut WinnowHandle = std::ptr::null_mut();
        // SAFETY: the closure holds an exclusive lease on the pattern for the
        // call, and `out` is a live slot written only on success. The plan borrows
        // nothing from `re`, which the ABI states outright.
        let status = re.with_handle(|raw| unsafe { ffi::irgx_winnow_of(raw, &raw mut out) })?;
        if status < 0 {
            return Err(error::plane_fault(status, PLAN));
        }
        NonNull::new(out)
            .map(|handle| Self { handle })
            .ok_or_else(|| Error::Inconsistent {
                message: "the winnow plane reported success and produced no plan".to_owned(),
            })
    }

    /// What the plan is made of, and whether it can narrow at all.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] if the linked library rejected the struct this crate
    /// declares.
    pub fn facts(&self) -> Result<WinnowFacts, Error> {
        let mut out = WinnowFacts::default();
        // SAFETY: `out` is a live `irgx_winnow_facts` whose `struct_size` we
        // stamped, and the plan is live for `&self`.
        let status = unsafe { ffi::irgx_winnow_describe(self.handle.as_ptr(), &raw mut out) };
        if status < 0 {
            return Err(error::plane_fault(status, PLAN));
        }
        Ok(out)
    }
}

impl Drop for Winnow {
    fn drop(&mut self) {
        // SAFETY: the plan came from `irgx_winnow_of` and is freed exactly once,
        // here. Nothing borrows from it.
        unsafe { ffi::irgx_winnow_free(self.handle.as_ptr()) };
    }
}

impl std::fmt::Debug for Winnow {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Winnow")
            .field("facts", &self.facts().ok())
            .finish()
    }
}

/// The sieve plane's seam, from the `irgx_sieve_*` / `irgx_winnow_*` block of
/// `irgx.h`.
mod ffi {
    use super::{Facts, RawFreshness, SieveHandle, WinnowFacts, WinnowHandle, sys};

    unsafe extern "C" {
        pub fn irgx_sieve_open(dir: *const u8, dir_len: usize, out: *mut *mut SieveHandle) -> i32;
        pub fn irgx_sieve_close(s: *mut SieveHandle);
        pub fn irgx_sieve_describe(s: *const SieveHandle, out: *mut Facts) -> i32;
        pub fn irgx_sieve_doc_path(s: *const SieveHandle, doc: u32, out: *mut sys::Text) -> i32;
        pub fn irgx_sieve_root(s: *const SieveHandle, i: u32, out: *mut sys::Text) -> i32;
        pub fn irgx_sieve_literal(
            s: *mut SieveHandle,
            needle: *const u8,
            len: usize,
            out: *mut u32,
            cap: usize,
            written: *mut usize,
        ) -> i32;
        pub fn irgx_sieve_alternation(
            s: *mut SieveHandle,
            needles: *const sys::Text,
            n: usize,
            out: *mut u32,
            cap: usize,
            written: *mut usize,
        ) -> i32;
        pub fn irgx_sieve_candidates(
            s: *mut SieveHandle,
            w: *const WinnowHandle,
            out: *mut u32,
            cap: usize,
            written: *mut usize,
        ) -> i32;
        pub fn irgx_sieve_reading_list(
            s: *mut SieveHandle,
            w: *const WinnowHandle,
            out: *mut u32,
            cap: usize,
            written: *mut usize,
        ) -> i32;
        pub fn irgx_sieve_freshness(s: *const SieveHandle, out: *mut RawFreshness) -> i32;
        pub fn irgx_sieve_stale_count(s: *const SieveHandle, out: *mut usize) -> i32;
        pub fn irgx_winnow_of(re: *mut sys::Regex, out: *mut *mut WinnowHandle) -> i32;
        pub fn irgx_winnow_free(w: *mut WinnowHandle);
        pub fn irgx_winnow_describe(w: *const WinnowHandle, out: *mut WinnowFacts) -> i32;
    }
}
