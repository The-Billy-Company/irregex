//! The line grid: rows, bands, and the off-by-one that lives here instead of in
//! your host.
//!
//! Every grep-shaped program rebuilds this and most of them get an edge wrong.
//! The engines answer in byte offsets; a person reads row numbers, and the
//! translation is not "count the newlines": a final line with no terminator is
//! still a line, and an offset sitting ON a terminator belongs to the line that
//! terminator ENDS rather than the one after it. Those two rules are the whole
//! reason this plane exists in the ABI, and binding it means the crate and the
//! matching engine agree about what row 12 is.
//!
//! [`Line`] keeps content and terminator apart on purpose — render with
//! [`Line::content`], slice with [`Line::with_terminator`] — so nothing here has
//! to guess whether the file ended `"\n"`, `"\r\n"`, or with no terminator at
//! all. A CRLF's `'\r'` stays inside the content, which is ripgrep's default and
//! what the matching engines in this library see; a host that stripped it for
//! display would be matching on bytes it is not showing.

use crate::error::{self, Error};
use crate::sink;

/// The plane name a fault from here is reported under.
const PLANE: &str = "lines";

/// How many rows to size the first [`split`] attempt at.
///
/// Nothing tells us the row count in advance, so this is a guess, and the shape
/// of the guess matters more than the number: too small costs one extra crossing
/// on a big file, too large costs every caller on a small one. A 4 KiB source
/// file is about this many lines.
const FIRST_GUESS: usize = 128;

/// One row of the grid.
///
/// A `#[repr(C)]` mirror of `irgx_line`, which is what lets [`split`] fill a
/// `Vec<Line>` the library writes into directly — the rows are plain integers, so
/// there is no per-row translation between the C answer and this one.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
#[repr(C)]
pub struct Line {
    number: u64,
    start: u64,
    content_end: u64,
    term_end: u64,
}

impl Line {
    /// The 1-based row number, matching what `-n` prints and what an editor
    /// jumps to.
    ///
    /// Clamping a band at the top of a file shortens it; it never renumbers, so
    /// this is the row's identity in the file and not its index in a [`Band`].
    #[must_use]
    pub fn number(&self) -> u64 {
        self.number
    }

    /// The row's bytes, terminator excluded. What to print.
    ///
    /// # Panics
    ///
    /// If `text` is not the buffer the row was measured over.
    #[must_use]
    pub fn content<'t>(&self, text: &'t [u8]) -> &'t [u8] {
        &text[self.start as usize..self.content_end as usize]
    }

    /// The row's bytes including its terminator, so concatenating a band
    /// reproduces the file exactly. What to slice.
    ///
    /// # Panics
    ///
    /// If `text` is not the buffer the row was measured over.
    #[must_use]
    pub fn with_terminator<'t>(&self, text: &'t [u8]) -> &'t [u8] {
        &text[self.start as usize..self.term_end as usize]
    }

    /// Where the content begins and ends, as a byte range into the text.
    #[must_use]
    pub fn range(&self) -> std::ops::Range<usize> {
        self.start as usize..self.content_end as usize
    }

    /// Whether byte `at` belongs to this row.
    ///
    /// True for an offset on the terminator, and for `at == text.len()` on a
    /// final unterminated row — the two edges a hand-rolled comparison gets
    /// wrong.
    #[must_use]
    pub fn holds(&self, at: usize) -> bool {
        let at = at as u64;
        at >= self.start && (at < self.term_end || at == self.term_end && self.is_unterminated())
    }

    /// Whether the row runs to the end of the text with no terminator. Still a
    /// row: a host printing *n* rows has to print this one too.
    #[must_use]
    pub fn is_unterminated(&self) -> bool {
        self.content_end == self.term_end
    }

    /// The column byte `at` sits at within this row, counting from 1.
    ///
    /// One-based to match [`Line::number`], because these two are printed
    /// together: `path:line:col` is the locator every editor and compiler in this
    /// space emits, and a 1-based row beside a 0-based column would render the
    /// first character of row three as `3:0` — a position no other tool names that
    /// way, in a string a host pastes into an editor.
    ///
    /// Bytes, not codepoints, like every other offset here. Ask [`Line::holds`]
    /// first: an `at` outside this row gets arithmetic rather than an answer,
    /// clamped at 1 below the row.
    #[must_use]
    pub fn column(&self, at: usize) -> usize {
        (at as u64).saturating_sub(self.start) as usize + 1
    }
}

/// A band of rows around one byte, and which of them the byte is in.
///
/// The center is band-relative and cannot be derived from the length: a band
/// clipped at the start of the text has fewer preceding rows than it asked for,
/// so `before` is a request and this is the answer.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Band {
    rows: Vec<Line>,
    center: usize,
}

impl Band {
    /// The rows, in file order.
    #[must_use]
    pub fn rows(&self) -> &[Line] {
        &self.rows
    }

    /// The index within [`Band::rows`] of the row holding the byte asked about —
    /// the number a caret needs.
    #[must_use]
    pub fn center(&self) -> usize {
        self.center
    }

    /// The row holding the byte asked about.
    ///
    /// `None` only for a band with no rows, which is empty text.
    #[must_use]
    pub fn focus(&self) -> Option<&Line> {
        self.rows.get(self.center)
    }

    /// The rows before the focus, then the focus, then the rows after — as three
    /// slices, so a renderer can style context differently without arithmetic.
    #[must_use]
    pub fn around(&self) -> (&[Line], Option<&Line>, &[Line]) {
        let (before, rest) = self.rows.split_at(self.center.min(self.rows.len()));
        match rest.split_first() {
            Some((focus, after)) => (before, Some(focus), after),
            None => (before, None, &[]),
        }
    }
}

impl std::ops::Deref for Band {
    type Target = [Line];

    fn deref(&self) -> &Self::Target {
        &self.rows
    }
}

/// How many rows `text` holds.
///
/// An unterminated tail counts. Empty text holds no rows.
///
/// # Errors
///
/// [`Error::Plane`] if the engine could not answer.
pub fn count(text: &[u8]) -> Result<u64, Error> {
    let mut out = 0u64;
    // SAFETY: `text` is a live slice passed with its own length, and `out` is a
    // live `u64` the library writes only on success.
    let status = unsafe { ffi::irgx_lines_count(text.as_ptr(), text.len(), &raw mut out) };
    if status < 0 {
        return Err(error::plane_fault(status, PLANE));
    }
    Ok(out)
}

/// The whole grid of `text`.
///
/// # Errors
///
/// [`Error::Plane`] if the engine could not answer.
pub fn split(text: &[u8]) -> Result<Vec<Line>, Error> {
    sink::reap_all(PLANE, FIRST_GUESS, |out, cap, written| {
        // SAFETY: `out`/`cap` are the buffer `reap` owns and its true capacity,
        // `written` a live slot, and `text` a live slice with its own length.
        unsafe { ffi::irgx_lines_split(text.as_ptr(), text.len(), out, cap, written) }
    })
}

/// The band around byte `at`: up to `before` rows preceding it, the row holding
/// it, then up to `after` following.
///
/// `at == text.len()` is legal and lands on the tail, which is what a caret after
/// the last character needs.
///
/// # Errors
///
/// [`Error::Plane`] if `at` is past the end of `text`, or the engine could not
/// answer.
pub fn context(text: &[u8], at: usize, before: usize, after: usize) -> Result<Band, Error> {
    let mut center = 0usize;
    // The band's size is known exactly, so this never retries.
    let rows = sink::reap_all(PLANE, before + after + 1, |out, cap, written| {
        // SAFETY: as `split`, plus `center`, a live `usize` slot the header
        // documents as optional and writes only on success.
        unsafe {
            ffi::irgx_lines_context(
                text.as_ptr(),
                text.len(),
                at,
                before,
                after,
                out,
                cap,
                written,
                &raw mut center,
            )
        }
    })?;
    Ok(Band { rows, center })
}

/// The line plane's seam. Transcribed from the `irgx_lines_*` block of
/// `irgx.h`; `Line` above is the `repr(C)` mirror these write.
mod ffi {
    use super::Line;

    unsafe extern "C" {
        pub fn irgx_lines_count(text: *const u8, len: usize, out: *mut u64) -> i32;
        pub fn irgx_lines_context(
            text: *const u8,
            len: usize,
            at: usize,
            before: usize,
            after: usize,
            out: *mut Line,
            cap: usize,
            written: *mut usize,
            center: *mut usize,
        ) -> i32;
        pub fn irgx_lines_split(
            text: *const u8,
            len: usize,
            out: *mut Line,
            cap: usize,
            written: *mut usize,
        ) -> i32;
    }
}
