//! Many literals, one pass, with attribution.
//!
//! The question a regex alternation answers slowly and a wordlist scanner answers
//! quickly: given four hundred terms, which of them are in this buffer, and where?
//! Writing it as `a|b|c|…` makes the engine determinize four hundred branches;
//! this plane seats them in a machine built for exactly that shape and tells you
//! which one it used.
//!
//! Three questions, cheapest first, and the cost difference between them is real
//! rather than a rounding error:
//!
//! * [`Needles::is_match`] — does ANY term occur? Stops at the first hit and
//!   attributes nothing.
//! * [`Needles::which`] — WHICH terms occur? Presence per term, not one row per
//!   occurrence, so a term appearing a thousand times is one answer.
//! * [`Needles::find_all`] — every occurrence, each carrying its term and span.
//!
//! [`Needles::shape`] reports which machine seated the set, so a host budgeting a
//! scan can ask what it is about to cost instead of guessing. The tier is a
//! consequence of the needles, never a choice: one needle is a substring find, a
//! few are a SIMD multi-substring pass, many are Aho-Corasick.
//!
//! There is no flag word here on purpose. The ABI takes one and this build accepts
//! no bits in it, because the honest alternative to case-insensitive matching
//! would be a folded copy of every haystack or a quietly weaker answer under the
//! same verb. Fold the terms yourself with [`crate::unicode::orbit`] if you need
//! it, and you will fold with the same table the engine does.

use std::ptr::NonNull;

use crate::error::{self, Error};
use crate::sink;
use crate::sys;

/// The plane name a fault from here is reported under.
const PLANE: &str = "needles";

/// An opaque `irgx_needles`. Never dereferenced on this side.
#[repr(C)]
struct Handle {
    _opaque: [u8; 0],
}

/// `irgx_needle`: one term, as the ABI takes it.
#[repr(C)]
struct Term {
    needle: *const u8,
    len: usize,
}

/// Which machine seated the set.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum Tier {
    /// Nothing seated — the empty set, which is a legal set that matches nothing.
    #[default]
    None,
    /// One needle: a plain substring find.
    Memmem,
    /// A few: a SIMD multi-substring pass.
    LiteralSet,
    /// Many: Aho-Corasick.
    Trawl,
}

impl Tier {
    fn from_abi(raw: u32) -> Self {
        match raw {
            1 => Self::Memmem,
            2 => Self::LiteralSet,
            3 => Self::Trawl,
            _ => Self::None,
        }
    }
}

/// What the set is, and which machine answers about it.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct Shape {
    struct_size: u32,
    presence_tier: u32,
    attributed_tier: u32,
    reserved: u32,
    count: usize,
    longest: usize,
    bytes: usize,
}

impl Default for Shape {
    fn default() -> Self {
        Self {
            struct_size: size_of::<Self>() as u32,
            presence_tier: 0,
            attributed_tier: 0,
            reserved: 0,
            count: 0,
            longest: 0,
            bytes: 0,
        }
    }
}

impl Shape {
    /// The machine [`Needles::is_match`] runs on.
    ///
    /// It can be cheaper than [`Shape::attributed_tier`]: presence is sometimes
    /// answerable by a machine that cannot say which term produced the hit, and a
    /// host budgeting a scan needs the tier it will actually use.
    #[must_use]
    pub fn presence_tier(&self) -> Tier {
        Tier::from_abi(self.presence_tier)
    }

    /// The machine [`Needles::which`] and [`Needles::find_all`] run on.
    #[must_use]
    pub fn attributed_tier(&self) -> Tier {
        Tier::from_abi(self.attributed_tier)
    }

    /// How many terms the set seated.
    #[must_use]
    pub fn len(&self) -> usize {
        self.count
    }

    /// Whether the set seated nothing.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.count == 0
    }

    /// The longest term, in bytes — the overlap a chunked reader must carry
    /// between buffers so a term straddling the boundary is still found.
    #[must_use]
    pub fn longest(&self) -> usize {
        self.longest
    }

    /// How many bytes of needle the set holds in total.
    #[must_use]
    pub fn bytes(&self) -> usize {
        self.bytes
    }
}

/// One occurrence, attributed to the term that produced it.
///
/// A `#[repr(C)]` mirror of `irgx_occurrence`, so [`Needles::find_all`] fills a
/// `Vec<Occurrence>` the library writes into directly.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
#[repr(C)]
pub struct Occurrence {
    needle: u32,
    reserved: u32,
    start: usize,
    end: usize,
}

impl Occurrence {
    /// Which term this is, as an index into the list the set was compiled from.
    #[must_use]
    pub fn needle(&self) -> usize {
        self.needle as usize
    }

    /// Where the term begins and ends in the text.
    #[must_use]
    pub fn range(&self) -> std::ops::Range<usize> {
        self.start..self.end
    }

    /// The matched bytes.
    ///
    /// # Panics
    ///
    /// If `text` is not the buffer this occurrence was found in.
    #[must_use]
    pub fn as_bytes<'t>(&self, text: &'t [u8]) -> &'t [u8] {
        &text[self.start..self.end]
    }
}

/// A compiled set of literal terms.
///
/// Not `Send`: the C handle carries scan state and is single-threaded. Compiling
/// is cheap relative to scanning a corpus, so a worker pool gives each thread its
/// own set rather than sharing one.
pub struct Needles {
    handle: NonNull<Handle>,
    /// How many terms were offered. Kept so [`Needles::seated`] can be compared
    /// against it without the caller having to remember the input.
    offered: usize,
}

impl Needles {
    /// Compile `terms` into one scanner.
    ///
    /// An empty set is legal and matches nothing. An empty TERM is not: it occurs
    /// at every position, so admitting one would turn every answer into the
    /// haystack's own length and bury the terms you asked about.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] naming the offending term's index, for an empty term or a
    /// set past this build's total byte budget.
    pub fn new<T: AsRef<[u8]>>(terms: &[T]) -> Result<Self, Error> {
        let list: Vec<Term> = terms
            .iter()
            .map(|term| {
                let bytes = term.as_ref();
                Term {
                    needle: bytes.as_ptr(),
                    len: bytes.len(),
                }
            })
            .collect();
        let mut out: *mut Handle = std::ptr::null_mut();
        // The ABI's third argument is a reserved flag word this build accepts no
        // bits in; passing anything else is IRGX_INVALID by design.
        const NO_FLAGS: u32 = 0;
        // `refused` is the INDEX of the term that caused a refusal, not a count of
        // partially-seated terms: this build seats all or none. Only meaningful on
        // a negative status.
        let mut culprit = usize::MAX;
        // SAFETY: `list` outlives the call and is passed with its own length; the
        // header documents the terms as borrowed for the duration of the call
        // only. `culprit` and `out` are live slots.
        let status = unsafe {
            ffi::irgx_needles_compile(
                list.as_ptr(),
                list.len(),
                NO_FLAGS,
                &raw mut culprit,
                &raw mut out,
            )
        };
        if status < 0 {
            return Err(refusal(status, culprit, list.len()));
        }
        let handle = NonNull::new(out).ok_or_else(|| Error::Inconsistent {
            message: "the needle plane reported success and produced no handle".to_owned(),
        })?;
        Ok(Self {
            handle,
            offered: list.len(),
        })
    }

    /// How many terms the set holds.
    ///
    /// The exact `cap` [`Needles::which`] never has to retry at.
    #[must_use]
    pub fn seated(&self) -> usize {
        // SAFETY: a pure reader over a live handle, taking no buffer.
        unsafe { ffi::irgx_needles_len(self.handle.as_ptr()) }
    }

    /// How many terms were offered at compile time.
    ///
    /// Equal to [`Needles::seated`] on this build, which seats all or none. They
    /// are both reported so a set that ever does come back smaller than what was
    /// handed in is visible rather than quietly narrower.
    #[must_use]
    pub fn offered(&self) -> usize {
        self.offered
    }

    /// Whether the set seated nothing.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.seated() == 0
    }

    /// What the set is and which machine answers about it.
    ///
    /// A pure reader: it starts no work, so it cannot disturb the fault a previous
    /// call left behind.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] if the linked library rejected the struct this crate
    /// declares, which means the two disagree about the ABI.
    pub fn shape(&self) -> Result<Shape, Error> {
        let mut out = Shape::default();
        // SAFETY: `out` is a live `irgx_needle_shape` whose `struct_size` we
        // stamped, and the handle is live for `&self`.
        let status = unsafe { ffi::irgx_needles_describe(self.handle.as_ptr(), &raw mut out) };
        if status < 0 {
            return Err(error::plane_fault(status, PLANE));
        }
        Ok(out)
    }

    /// Whether ANY term occurs in `text`.
    ///
    /// The cheapest question — it may stop at the first hit and attributes
    /// nothing.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] if the scan could not complete.
    pub fn is_match(&self, text: &[u8]) -> Result<bool, Error> {
        // SAFETY: the handle is live and, being `!Sync`, not reachable from
        // another thread for the duration; `text` is a live slice with its own
        // length.
        let status =
            unsafe { ffi::irgx_needles_is_match(self.handle.as_ptr(), text.as_ptr(), text.len()) };
        if status < 0 {
            return Err(error::plane_fault(status, PLANE));
        }
        Ok(status == sys::MATCH)
    }

    /// WHICH terms occur, as ascending indices into the compiled list.
    ///
    /// Presence per term, NOT one row per occurrence: a term appearing a thousand
    /// times is one entry. Sized from [`Needles::seated`], so it never retries.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] if the scan could not complete.
    pub fn which(&self, text: &[u8]) -> Result<Vec<u32>, Error> {
        sink::reap_all(PLANE, self.seated(), |out, cap, written| {
            // SAFETY: as `is_match`, plus `out`/`cap`/`written` being `reap`'s
            // buffer, its true capacity, and a live count slot.
            unsafe {
                ffi::irgx_needles_which(
                    self.handle.as_ptr(),
                    text.as_ptr(),
                    text.len(),
                    out,
                    cap,
                    written,
                )
            }
        })
    }

    /// Every occurrence, each carrying its term and span.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] if the scan could not complete.
    pub fn find_all(&self, text: &[u8]) -> Result<Vec<Occurrence>, Error> {
        // Nothing knows the occurrence count in advance, so this is a guess sized
        // to the common case: a wordlist pass over a source file. A busier text
        // pays one retry, at the exact count the engine reports.
        const FIRST_GUESS: usize = 64;
        sink::reap_all(PLANE, FIRST_GUESS, |out, cap, written| {
            // SAFETY: as `which`.
            unsafe {
                ffi::irgx_needles_find_all(
                    self.handle.as_ptr(),
                    text.as_ptr(),
                    text.len(),
                    out,
                    cap,
                    written,
                )
            }
        })
    }
}

impl Drop for Needles {
    fn drop(&mut self) {
        // SAFETY: the handle came from `irgx_needles_compile` and is freed exactly
        // once, here. Nothing borrows from it — every answer this plane gives is
        // owned integers.
        unsafe { ffi::irgx_needles_free(self.handle.as_ptr()) };
    }
}

impl std::fmt::Debug for Needles {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Needles")
            .field("seated", &self.seated())
            .field("shape", &self.shape().ok())
            .finish()
    }
}

/// A compile refusal, with the offending term's index folded into the detail.
///
/// The index is the diagnosis a wordlist needs and a single term does not: with
/// four hundred terms, "one of them is empty" is not actionable. It rides in the
/// message rather than in a variant of its own because it is one number about one
/// verb, and a `Needles`-shaped error variant would have no other member.
fn refusal(status: i32, culprit: usize, offered: usize) -> Error {
    let plane = error::plane_fault(status, PLANE);
    let (Error::Plane { status, detail, .. }, true) = (&plane, culprit < offered) else {
        return plane;
    };
    let named = match detail {
        Some(why) => format!("term #{culprit}: {why}"),
        None => format!("term #{culprit}"),
    };
    Error::Plane {
        plane: PLANE,
        status: *status,
        detail: Some(named),
    }
}

/// The needle plane's seam, from the `irgx_needles_*` block of `irgx.h`.
mod ffi {
    use super::{Handle, Occurrence, Shape, Term};

    unsafe extern "C" {
        pub fn irgx_needles_compile(
            list: *const Term,
            count: usize,
            flags: u32,
            refused: *mut usize,
            out: *mut *mut Handle,
        ) -> i32;
        pub fn irgx_needles_free(handle: *mut Handle);
        pub fn irgx_needles_len(handle: *const Handle) -> usize;
        pub fn irgx_needles_describe(handle: *const Handle, out: *mut Shape) -> i32;
        pub fn irgx_needles_is_match(handle: *mut Handle, text: *const u8, len: usize) -> i32;
        pub fn irgx_needles_which(
            handle: *mut Handle,
            text: *const u8,
            len: usize,
            out: *mut u32,
            cap: usize,
            written: *mut usize,
        ) -> i32;
        pub fn irgx_needles_find_all(
            handle: *mut Handle,
            text: *const u8,
            len: usize,
            out: *mut Occurrence,
            cap: usize,
            written: *mut usize,
        ) -> i32;
    }
}
