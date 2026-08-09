//! What a pattern PROMISES about every byte sequence it can match.
//!
//! This is the input an indexer needs and cannot derive: to build a prefilter you
//! have to know which literals a match must contain, and — far more importantly —
//! whether that knowledge is a GUARANTEE or a guess. A prefilter built on the
//! wrong one silently drops real matches, and it drops them in a way no test over
//! the prefilter alone can see, because the prefilter is self-consistent.
//!
//! So the grade travels with the bytes rather than beside them. [`Literals::set`]
//! hands back a [`Verdict`] with every set, [`Verdict::eliminates`] is the whole
//! test, and there is no way to read the members without reading it.
//!
//! ## The borrow
//!
//! [`Literals`] owns an arena, and the member bytes live in it. So a
//! [`LiteralSet`] borrows the handle: the sets are readable for exactly as long
//! as the handle is alive, and the compiler enforces the header's "copy anything
//! that must outlive it" instead of a comment asking you to. The pattern itself
//! is NOT borrowed — the handle copies what it needs at open time, so a
//! [`Literals`] outlives the [`Regex`](crate::Regex) it came from.
//!
//! Which means a set cannot outlive its handle, and that is a compile error
//! rather than a caution:
//!
//! ```compile_fail,E0505
//! use irgx::{Answer, Regex};
//! use irgx::promise::{Literals, Place};
//!
//! let re = Regex::new("abc|abd").unwrap();
//! let Answer::Given(lits) = Literals::open(&re).unwrap() else { return };
//! let set = lits.set(Place::Prefix).unwrap(); // borrows `lits`
//! drop(lits);                                 // ... so this cannot happen first
//! let _ = set.len();
//! ```

use std::marker::PhantomData;
use std::ptr::NonNull;

use crate::error::{self, Error};
use crate::sink;
use crate::sys;
use crate::{Answer, Regex};

/// The plane name a fault from here is reported under.
const PLANE: &str = "literals";

/// An opaque `irgx_literals`. Never dereferenced on this side.
#[repr(C)]
struct Handle {
    _opaque: [u8; 0],
}

/// `IRGX_LEN_UNBOUNDED`: no ceiling at all, as in `a+` or `.*`. A measured
/// length is never this value, so the sentinel cannot collide with one.
const UNBOUNDED: u32 = u32::MAX;

/// Which set of literals — where in a match its members must appear.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Place {
    /// Somewhere inside every match, position unknown.
    Required,
    /// At the start of every match.
    Prefix,
    /// At the end of every match.
    Suffix,
    /// The entire match — the set of complete strings the pattern accepts.
    Whole,
}

impl Place {
    /// Every place, in ABI order.
    pub const ALL: [Self; 4] = [Self::Required, Self::Prefix, Self::Suffix, Self::Whole];

    /// The `IRGX_PLACE_*` ordinal, which is also the index into the promise's
    /// per-place arrays.
    const fn ordinal(self) -> usize {
        match self {
            Self::Required => 0,
            Self::Prefix => 1,
            Self::Suffix => 2,
            Self::Whole => 3,
        }
    }
}

/// How much a set proves. Ordered, so [`Verdict::eliminates`] is a comparison.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Verdict {
    /// No set. Proves nothing either way — scan.
    #[default]
    Nothing,
    /// The absence of EVERY member proves there is no match. Presence proves
    /// nothing and must be verified by the engine.
    Candidate,
    /// Containment and matching are one question: a member being present is a
    /// match, so no verification pass is needed.
    Exact,
}

impl Verdict {
    /// Whether a set with this grade may be used to rule a document OUT.
    ///
    /// The one question a prefilter has to get right, and the reason the grade is
    /// not optional at the read.
    #[must_use]
    pub fn eliminates(self) -> bool {
        self >= Self::Candidate
    }

    fn from_abi(raw: u32) -> Self {
        match raw {
            1 => Self::Candidate,
            2 => Self::Exact,
            // Forward-compatible by construction: an unknown grade from a newer
            // library reads as the grade that permits nothing, so a set this
            // build cannot interpret can only ever cost a scan.
            _ => Self::Nothing,
        }
    }
}

/// The whole-pattern promise: every set's grade and size, the length bounds, the
/// first-byte set, and the language signature — in one read.
///
/// Read this BEFORE a set. It is what says whether the set you are about to read
/// is a guarantee or a guess.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct Promise {
    struct_size: u32,
    verdict: [u32; 4],
    count: [u32; 4],
    anchored: u32,
    nullable: u32,
    min_len: u32,
    max_len: u32,
    first_bytes: [u64; 4],
    signature: [u64; 2],
}

impl Default for Promise {
    fn default() -> Self {
        // Zeroed but for the size stamp, which the header requires be set before
        // the call and is how a fail-closed struct_size can refuse a mismatch.
        Self {
            struct_size: size_of::<Self>() as u32,
            verdict: [0; 4],
            count: [0; 4],
            anchored: 0,
            nullable: 0,
            min_len: 0,
            max_len: 0,
            first_bytes: [0; 4],
            signature: [0; 2],
        }
    }
}

impl Promise {
    /// What the set at `place` proves.
    #[must_use]
    pub fn verdict(&self, place: Place) -> Verdict {
        Verdict::from_abi(self.verdict[place.ordinal()])
    }

    /// How many members the set at `place` holds.
    #[must_use]
    pub fn count(&self, place: Place) -> usize {
        self.count[place.ordinal()] as usize
    }

    /// The place whose set is most worth building a prefilter from: the highest
    /// grade, and among equal grades the one with fewest members to check.
    ///
    /// `None` when no set proves anything, which is the honest answer that this
    /// pattern cannot be narrowed on and the corpus has to be scanned.
    #[must_use]
    pub fn best(&self) -> Option<(Place, Verdict)> {
        Place::ALL
            .into_iter()
            .map(|place| (place, self.verdict(place)))
            .filter(|(_, verdict)| verdict.eliminates())
            .max_by_key(|&(place, verdict)| (verdict, std::cmp::Reverse(self.count(place))))
    }

    /// Whether every match must begin at the start of the text.
    #[must_use]
    pub fn is_anchored(&self) -> bool {
        self.anchored != 0
    }

    /// Whether the pattern can match the empty string — in which case every
    /// position matches and no prefilter can rule anything out.
    #[must_use]
    pub fn is_nullable(&self) -> bool {
        self.nullable != 0
    }

    /// The shortest match this pattern admits, in bytes.
    #[must_use]
    pub fn min_len(&self) -> usize {
        self.min_len as usize
    }

    /// The longest match this pattern admits, or `None` when it has no ceiling
    /// at all (`a+`, `.*`).
    #[must_use]
    pub fn max_len(&self) -> Option<usize> {
        (self.max_len != UNBOUNDED).then_some(self.max_len as usize)
    }

    /// Whether a match may BEGIN with `byte`.
    ///
    /// Ask [`Promise::first_bytes_known`] first: an empty set means *unknown*,
    /// not "no byte can start a match", and treating those alike turns an
    /// unanalyzable pattern into one that matches nothing.
    #[must_use]
    pub fn may_start_with(&self, byte: u8) -> bool {
        !self.first_bytes_known()
            || self.first_bytes[usize::from(byte >> 6)] >> (byte & 63) & 1 == 1
    }

    /// Whether the first-byte set carries information at all.
    #[must_use]
    pub fn first_bytes_known(&self) -> bool {
        self.first_bytes.iter().any(|word| *word != 0)
    }

    /// A fingerprint of the LANGUAGE the pattern denotes, not of its text: two
    /// patterns spelled differently that accept the same set share it.
    ///
    /// For keying a derived artifact — an index, a compiled prefilter — across
    /// spellings.
    #[must_use]
    pub fn signature(&self) -> u128 {
        u128::from(self.signature[0]) | u128::from(self.signature[1]) << 64
    }
}

/// What a compiled pattern promises. Open one, read the [`Promise`], then the
/// sets that promise says are worth reading.
///
/// Not `Send`: the C handle is single-threaded, and a handle is cheap to derive
/// again on the thread that wants one — [`Regex`] itself is `Send + Sync`, so
/// that is the thing to share.
pub struct Literals {
    handle: NonNull<Handle>,
}

impl Literals {
    /// Extract what `re` promises about its matches.
    ///
    /// [`Answer::Declined`] for a pattern compiled on the PCRE2 arm
    /// ([`RegexBuilder::pcre`](crate::RegexBuilder::pcre)): that arm has no AST in
    /// this tree to under-claim from, so there is nothing to promise. The remedy
    /// is real rather than nominal — recompile the same pattern text without
    /// `pcre` and ask again, which is the tier down the declinature names.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] if the engine could not analyze the pattern.
    pub fn open(re: &Regex) -> Result<Answer<Self>, Error> {
        let mut out: *mut Handle = std::ptr::null_mut();
        // SAFETY: the closure holds an exclusive lease on the pattern for the
        // call, and `out` is a live slot the library writes only on success. The
        // handle borrows nothing from `re`, which the header states outright, so
        // it is sound to carry past the lease.
        let status = re.with_handle(|raw| unsafe { ffi::irgx_literals_open(raw, &raw mut out) })?;
        if status == sys::STALE {
            return Ok(Answer::Declined);
        }
        if status < 0 {
            return Err(error::plane_fault(status, PLANE));
        }
        NonNull::new(out)
            .map(|handle| Answer::Given(Self { handle }))
            .ok_or(Error::Inconsistent {
                message: "the literal plane reported success and produced no handle".to_owned(),
            })
    }

    /// The whole-pattern promise.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] if the linked library rejected the struct this crate
    /// declares, which means the two disagree about the ABI.
    pub fn promise(&self) -> Result<Promise, Error> {
        let mut out = Promise::default();
        // SAFETY: `out` is a live `irgx_promise` whose `struct_size` we stamped,
        // which is exactly what the fail-closed read requires, and the handle is
        // live for `&self`.
        let status = unsafe { ffi::irgx_literals_promise(self.handle.as_ptr(), &raw mut out) };
        if status < 0 {
            return Err(error::plane_fault(status, PLANE));
        }
        Ok(out)
    }

    /// One set of literals, with the grade that says what it proves.
    ///
    /// The members borrow this handle. Size the read from
    /// [`Promise::count`] and it never retries.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] if the engine could not answer.
    pub fn set(&self, place: Place) -> Result<LiteralSet<'_>, Error> {
        let mut verdict = 0u32;
        let hint = self.promise().map(|p| p.count(place)).unwrap_or_default();
        let rows = sink::reap_all(PLANE, hint, |out, cap, written| {
            // SAFETY: the handle is live for `&self`, `verdict` is a live `u32`
            // slot the header documents as mandatory, and `out`/`cap` are the
            // buffer `reap` owns with its true capacity.
            unsafe {
                ffi::irgx_literals_set(
                    self.handle.as_ptr(),
                    place.ordinal() as u32,
                    &raw mut verdict,
                    out,
                    cap,
                    written,
                )
            }
        })?;
        Ok(LiteralSet {
            verdict: Verdict::from_abi(verdict),
            rows,
            owner: PhantomData,
        })
    }
}

impl Drop for Literals {
    fn drop(&mut self) {
        // SAFETY: the handle came from `irgx_literals_open`, is freed exactly
        // once here, and every `LiteralSet` borrowing its arena is gone — the
        // lifetime on `set` is what guarantees that.
        unsafe { ffi::irgx_literals_free(self.handle.as_ptr()) };
    }
}

/// One set of literals, borrowed from the [`Literals`] handle that produced it.
///
/// The lifetime is the header's "copy anything that must outlive it", made into a
/// compile error.
pub struct LiteralSet<'a> {
    verdict: Verdict,
    /// The row array is ours — the ABI wrote it into our buffer — but every row's
    /// BYTES point into the handle's arena, which is the borrow that matters.
    rows: Vec<sys::Text>,
    owner: PhantomData<&'a Literals>,
}

impl<'a> LiteralSet<'a> {
    /// What this set proves. Read it before using the members.
    #[must_use]
    pub fn verdict(&self) -> Verdict {
        self.verdict
    }

    /// How many members the set holds.
    #[must_use]
    pub fn len(&self) -> usize {
        self.rows.len()
    }

    /// Whether the set is empty. An empty set with [`Verdict::Nothing`] means the
    /// pattern could not be analyzed; an empty one that [`Verdict::eliminates`]
    /// would mean nothing can match at all.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.rows.is_empty()
    }

    /// The members, as bytes borrowed from the handle.
    ///
    /// Bytes and not `&str` because a literal is what the pattern requires of the
    /// *text*, and a pattern compiled with `unicode(false)` can require bytes
    /// that are not valid UTF-8 on their own.
    pub fn iter(&self) -> impl ExactSizeIterator<Item = &'a [u8]> + '_ {
        // SAFETY: the header documents each row as a borrowed span into the
        // handle's arena, valid until `irgx_literals_free`. The `'a` on this set
        // proves the handle is still alive, and `Drop` on `Literals` is the only
        // thing that frees the arena.
        self.rows.iter().map(|row| unsafe { sys::borrowed(row) })
    }
}

impl<'a> IntoIterator for &'a LiteralSet<'a> {
    type Item = &'a [u8];
    type IntoIter = std::vec::IntoIter<&'a [u8]>;

    fn into_iter(self) -> Self::IntoIter {
        self.iter().collect::<Vec<_>>().into_iter()
    }
}

impl std::fmt::Debug for LiteralSet<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LiteralSet")
            .field("verdict", &self.verdict)
            .field(
                "members",
                &self.iter().map(String::from_utf8_lossy).collect::<Vec<_>>(),
            )
            .finish()
    }
}

/// The literal plane's seam, from the `irgx_literals_*` block of `irgx.h`.
mod ffi {
    use super::{Handle, Promise, sys};

    unsafe extern "C" {
        pub fn irgx_literals_open(re: *mut sys::Regex, out: *mut *mut Handle) -> i32;
        pub fn irgx_literals_free(lits: *mut Handle);
        pub fn irgx_literals_promise(lits: *const Handle, out: *mut Promise) -> i32;
        pub fn irgx_literals_set(
            lits: *const Handle,
            place: u32,
            verdict: *mut u32,
            out: *mut sys::Text,
            cap: usize,
            written: *mut usize,
        ) -> i32;
    }
}
