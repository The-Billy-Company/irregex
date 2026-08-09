//! The Unicode tables this engine folds and classifies with.
//!
//! A host that builds its own index has to fold case and classify codepoints to
//! do it, and if it folds against a different Unicode version than the engine
//! doing the matching, the two disagree about what a letter is — quietly, in the
//! long tail, on exactly the inputs nobody has a fixture for. So the tables are
//! askable rather than reimplementable, and [`version`] is how a host finds out
//! whether its own agree.
//!
//! [`orbit`] is the load-bearing one. Case folding is not a pair: `'k'`, `'K'` and
//! U+212A KELVIN SIGN are one class, and a host that folds by lowercasing gets two
//! of the three. This is the table `-i` uses.

use std::sync::LazyLock;

use crate::error::{self, Error};
use crate::sink;
use crate::sys;

/// The plane name a fault from here is reported under.
const PLANE: &str = "unicode";

/// How many codepoints to size an orbit at. Case-folding classes are tiny — two
/// or three members, five at the extreme — so this never retries in practice.
const ORBIT_GUESS: usize = 8;

/// How many ranges to size a property at. `Nd` is 64, `Letter` is over 700; a
/// small script is under ten. Guessing low costs one retry on the big ones.
const PROPERTY_GUESS: usize = 64;

/// An inclusive range of codepoints, as the property tables spell them.
///
/// A `#[repr(C)]` mirror of `irgx_range`, so [`property`] fills a `Vec<Codepoints>`
/// the library writes into directly.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
#[repr(C)]
pub struct Codepoints {
    lo: u32,
    hi: u32,
}

impl Codepoints {
    /// The first codepoint in the range.
    #[must_use]
    pub fn low(&self) -> u32 {
        self.lo
    }

    /// The last codepoint in the range, inclusive.
    #[must_use]
    pub fn high(&self) -> u32 {
        self.hi
    }

    /// How many codepoints the range covers, which is never zero.
    ///
    /// `count` rather than `len`, because the bounds are inclusive: a range is at
    /// minimum the one codepoint `low == high`, so there is no empty range for an
    /// `is_empty` to report and the container vocabulary would only imply one.
    #[must_use]
    pub fn count(&self) -> u32 {
        self.hi.saturating_sub(self.lo) + 1
    }

    /// Whether `c` is in the range.
    #[must_use]
    pub fn holds(&self, c: char) -> bool {
        (self.lo..=self.hi).contains(&u32::from(c))
    }

    /// The range's members, skipping the surrogate block — which is a range of
    /// codepoints but not of Rust `char`s.
    pub fn chars(&self) -> impl Iterator<Item = char> {
        (self.lo..=self.hi).filter_map(char::from_u32)
    }
}

/// Every codepoint that case-folds together with `c`, INCLUDING `c` itself.
///
/// The orbit, not a pair. Ascending, and always at least one member.
///
/// ```
/// let orbit = irgx::unicode::orbit('k')?;
/// assert!(orbit.contains(&'K') && orbit.contains(&'\u{212A}'));
/// # Ok::<(), irgx::Error>(())
/// ```
///
/// # Errors
///
/// [`Error::Plane`] if the engine could not answer, or
/// [`Error::Inconsistent`] if it named something that is not a Unicode scalar
/// value.
pub fn orbit(c: char) -> Result<Vec<char>, Error> {
    let raw = sink::reap_all(PLANE, ORBIT_GUESS, |out, cap, written| {
        // SAFETY: `c` crosses by value; `out`/`cap` are the buffer `reap` owns
        // with its true capacity, and `written` is a live slot.
        unsafe { ffi::irgx_fold_orbit(u32::from(c), out, cap, written) }
    })?;
    raw.iter()
        .map(|cp| {
            char::from_u32(*cp).ok_or_else(|| Error::Inconsistent {
                message: format!("the fold table names U+{cp:04X}, which is not a scalar value"),
            })
        })
        .collect()
}

/// The inclusive ranges of the Unicode property `name` — `"Letter"`, `"Greek"`,
/// `"Nd"` — ascending and non-overlapping.
///
/// An unknown name is an error rather than an empty answer, so a misspelled
/// property and a genuinely empty class cannot look alike.
///
/// # Errors
///
/// [`Error::Plane`] for an unknown property name.
pub fn property(name: &str) -> Result<Vec<Codepoints>, Error> {
    let name = name.as_bytes();
    sink::reap_all(PLANE, PROPERTY_GUESS, |out, cap, written| {
        // SAFETY: `name` is a live slice passed with its own length, and
        // `out`/`cap`/`written` are `reap`'s buffer, capacity and count slot.
        unsafe { ffi::irgx_property_ranges(name.as_ptr(), name.len(), out, cap, written) }
    })
}

/// Whether `c` has the Unicode property `name`.
///
/// The membership test without materializing the ranges.
///
/// # Errors
///
/// [`Error::Plane`] for an unknown property name.
pub fn holds(name: &str, c: char) -> Result<bool, Error> {
    let name = name.as_bytes();
    // SAFETY: `name` is a live slice with its own length; `c` crosses by value.
    let status = unsafe { ffi::irgx_property_has(name.as_ptr(), name.len(), u32::from(c)) };
    if status < 0 {
        return Err(error::plane_fault(status, PLANE));
    }
    Ok(status == sys::MATCH)
}

/// The Unicode version these tables were generated from, e.g. `"16.0.0"`.
///
/// A host whose own tables disagree is a host whose prefilter and this engine
/// disagree about what a letter is.
///
/// Copied once into process-lifetime storage rather than borrowed: the header
/// does not promise the span outlives the call, and a version string is a fact
/// about the build that cannot change, so paying for it once is the whole cost.
/// An engine that cannot answer reports an empty string here — this is a
/// diagnostic, and a `Result` on it would put a `?` in front of every log line.
#[must_use]
pub fn version() -> &'static str {
    static VERSION: LazyLock<String> = LazyLock::new(|| {
        let mut out = sys::Text::default();
        // SAFETY: `out` is a live `irgx_text` the library writes only on success.
        if unsafe { ffi::irgx_unicode_version(&raw mut out) } < 0 {
            return String::new();
        }
        // SAFETY: the span is live until this thread's next work call, and this
        // read is the next thing that happens.
        let bytes = unsafe { sys::borrowed(&out) };
        String::from_utf8_lossy(bytes).into_owned()
    });
    &VERSION
}

/// The table plane's seam, from the `irgx_fold_*` / `irgx_property_*` /
/// `irgx_unicode_*` declarations of `irgx.h`.
mod ffi {
    use super::{Codepoints, sys};

    unsafe extern "C" {
        pub fn irgx_fold_orbit(cp: u32, out: *mut u32, cap: usize, written: *mut usize) -> i32;
        pub fn irgx_property_ranges(
            name: *const u8,
            len: usize,
            out: *mut Codepoints,
            cap: usize,
            written: *mut usize,
        ) -> i32;
        pub fn irgx_property_has(name: *const u8, len: usize, cp: u32) -> i32;
        pub fn irgx_unicode_version(out: *mut sys::Text) -> i32;
    }
}
