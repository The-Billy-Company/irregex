//! A self-index: it answers about a text it does not store, and can hand the text
//! back.
//!
//! An FM-index over bytes. Three things follow from that, and they are the reason
//! this is not "a search over a buffer you kept":
//!
//! * [`Codex::count`] costs the PATTERN, not the corpus. The occurrences are never
//!   enumerated to count them, so asking how many times a term appears in a
//!   gigabyte is the same work as asking about a kilobyte.
//! * [`Codex::extract`] reconstructs the text. The index IS the text — you can
//!   drop the original. Restoring the whole thing is [`Codex::extract`] at 0.
//! * [`Codex::locate`] can DECLINE. Positions need a sampled locate layer, and an
//!   index built without one still counts exactly. That is why it answers with an
//!   [`Answer`] and not an empty `Vec`: "this index cannot say where" and "the
//!   term does not occur" are opposite instructions, and a binding that returned
//!   `[]` for both would send you to rebuild nothing.
//!
//! [`Codex::rows`] and [`Codex::narrow`] expose the backward search itself, one
//! byte at a time, for a host driving its own matcher over the index — the pattern
//! is read RIGHT TO LEFT, and an interval that empties stays empty.

use std::ptr::NonNull;

use crate::Answer;
use crate::error::{self, Error};
use crate::sink;
use crate::sys;

/// The plane name a fault from here is reported under.
const PLANE: &str = "codex";

/// An opaque `irgx_codex`. Never dereferenced on this side.
#[repr(C)]
struct Handle {
    _opaque: [u8; 0],
}

/// How the wavelet layer is encoded.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum Encoding {
    /// Take the smaller of the two forms per block.
    #[default]
    AdoptMin,
    /// Forbid the compressed form, for a host that wants a predictable size over
    /// a smaller one.
    PlainOnly,
}

/// Build options. The default is what a host that has not measured anything
/// should use.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct Options {
    struct_size: u32,
    sample_rate: u32,
    encoding: u32,
    reserved: u32,
}

impl Default for Options {
    fn default() -> Self {
        // Zero is the documented default of every field: this build's own sample
        // rate, and ADOPT_MIN encoding.
        Self {
            struct_size: size_of::<Self>() as u32,
            sample_rate: 0,
            encoding: 0,
            reserved: 0,
        }
    }
}

impl Options {
    /// The build's own defaults.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// How often to sample a text position: larger is a smaller index and a
    /// slower [`Codex::locate`].
    ///
    /// 0 takes this build's own rate. See [`Options::without_locating`] for
    /// dropping the layer entirely.
    #[must_use]
    pub fn sample_rate(mut self, rate: u32) -> Self {
        self.sample_rate = rate;
        self
    }

    /// Build no locate layer at all: the smallest index, which counts and extracts
    /// but declines every [`Codex::locate`] and [`Codex::position`].
    ///
    /// Spelled as a method rather than as a magic `sample_rate` because it is a
    /// different decision from tuning one — and because the ABI says this with a
    /// sentinel value (`IRGX_NO_LOCATE`) that reads like an output.
    #[must_use]
    pub fn without_locating(mut self) -> Self {
        self.sample_rate = u32::MAX;
        self
    }

    /// How to encode the wavelet layer.
    #[must_use]
    pub fn encoding(mut self, encoding: Encoding) -> Self {
        self.encoding = match encoding {
            Encoding::AdoptMin => 0,
            Encoding::PlainOnly => 1,
        };
        self
    }
}

/// What the index cost, and what it can still do.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct Stats {
    struct_size: u32,
    sample_rate: u32,
    locates: u32,
    reserved: u32,
    text_len: usize,
    index_bytes: usize,
    tree_bytes: usize,
    locate_bytes: usize,
}

impl Default for Stats {
    fn default() -> Self {
        Self {
            struct_size: size_of::<Self>() as u32,
            sample_rate: 0,
            locates: 0,
            reserved: 0,
            text_len: 0,
            index_bytes: 0,
            tree_bytes: 0,
            locate_bytes: 0,
        }
    }
}

impl Stats {
    /// The sample rate this index was built at, or 0 when it holds no locate
    /// structures.
    #[must_use]
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    /// Whether the locate layer is present — that is, whether
    /// [`Codex::locate`] will answer rather than decline.
    #[must_use]
    pub fn locates(&self) -> bool {
        self.locates != 0
    }

    /// The length of the text this index stands for.
    #[must_use]
    pub fn text_len(&self) -> usize {
        self.text_len
    }

    /// The whole index, in bytes.
    #[must_use]
    pub fn index_bytes(&self) -> usize {
        self.index_bytes
    }

    /// The wavelet tree's share of it.
    #[must_use]
    pub fn tree_bytes(&self) -> usize {
        self.tree_bytes
    }

    /// The locate layer's share of it — what
    /// [`Options::without_locating`] saves.
    #[must_use]
    pub fn locate_bytes(&self) -> usize {
        self.locate_bytes
    }
}

/// A half-open row interval `[lo, hi)`: the suffixes a pattern prefix still
/// admits.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
#[repr(C)]
pub struct Rows {
    lo: usize,
    hi: usize,
}

impl Rows {
    /// The first row in the interval.
    #[must_use]
    pub fn low(&self) -> usize {
        self.lo
    }

    /// One past the last row.
    #[must_use]
    pub fn high(&self) -> usize {
        self.hi
    }

    /// How many suffixes the interval holds — which, once the whole pattern has
    /// been consumed, is its occurrence count.
    #[must_use]
    pub fn len(&self) -> usize {
        self.hi.saturating_sub(self.lo)
    }

    /// Whether the interval is empty, meaning the pattern cannot occur.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// A self-index over some bytes.
///
/// Not `Send`: the C handle holds decode scratch, and [`Codex::save`] parks a
/// serialized image on it between a sizing probe and the copy. Move the saved
/// bytes between threads instead — that is what [`Codex::save`] and
/// [`Codex::load`] are for.
pub struct Codex {
    handle: NonNull<Handle>,
}

impl Codex {
    /// The longest text this build can index, so a host can refuse before
    /// allocating.
    #[must_use]
    pub fn max_text_len() -> usize {
        // SAFETY: a pure reader taking no arguments.
        unsafe { ffi::irgx_codex_max_text_len() }
    }

    /// Build a self-index over `text` with this build's defaults.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] for a text past [`Codex::max_text_len`],
    /// [`Error::OutOfMemory`] if the index would not fit.
    pub fn build(text: &[u8]) -> Result<Self, Error> {
        Self::build_with(text, &Options::default())
    }

    /// Build a self-index over `text`.
    ///
    /// # Errors
    ///
    /// As [`Codex::build`].
    pub fn build_with(text: &[u8], options: &Options) -> Result<Self, Error> {
        // SAFETY: `text` is a live slice with its own length, `options` a live
        // `irgx_codex_options` whose `struct_size` its constructor stamped, and
        // `out` a live slot. The index copies what it needs, so nothing borrows
        // `text` afterwards.
        Self::opened(|out| unsafe {
            ffi::irgx_codex_build(text.as_ptr(), text.len(), options, out)
        })
    }

    /// Load an index saved by [`Codex::save`].
    ///
    /// A blob this build cannot read fails closed rather than being read
    /// half-way.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] for a blob that is not one of these, or is from an
    /// incompatible build.
    pub fn load(bytes: &[u8]) -> Result<Self, Error> {
        // SAFETY: as `build_with`.
        Self::opened(|out| unsafe { ffi::irgx_codex_load(bytes.as_ptr(), bytes.len(), out) })
    }

    /// The two constructors' shared tail: a status and an out-pointer become a
    /// handle or a typed failure.
    fn opened(open: impl FnOnce(*mut *mut Handle) -> i32) -> Result<Self, Error> {
        let mut out: *mut Handle = std::ptr::null_mut();
        let status = open(&raw mut out);
        if status < 0 {
            return Err(error::plane_fault(status, PLANE));
        }
        NonNull::new(out)
            .map(|handle| Self { handle })
            .ok_or_else(|| Error::Inconsistent {
                message: "the codex plane reported success and produced no handle".to_owned(),
            })
    }

    /// The length of the text this index stands for — which need not exist any
    /// more.
    #[must_use]
    pub fn len(&self) -> usize {
        // SAFETY: a pure reader over a handle live for `&self`.
        unsafe { ffi::irgx_codex_len(self.handle.as_ptr()) }
    }

    /// Whether the indexed text was empty.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// What the index cost and what it can still do.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] if the linked library rejected the struct this crate
    /// declares.
    pub fn measure(&self) -> Result<Stats, Error> {
        let mut out = Stats::default();
        // SAFETY: `out` is a live `irgx_codex_stats` whose `struct_size` we
        // stamped, and the handle is live for `&self`.
        let status = unsafe { ffi::irgx_codex_measure(self.handle.as_ptr(), &raw mut out) };
        if status < 0 {
            return Err(error::plane_fault(status, PLANE));
        }
        Ok(out)
    }

    /// How many times `pattern` occurs, in time proportional to the PATTERN.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] if the index could not answer.
    pub fn count(&self, pattern: &[u8]) -> Result<usize, Error> {
        let mut out = 0usize;
        // SAFETY: the handle is live for `&self`, `pattern` a live slice with its
        // own length, `out` a live slot written only on success.
        let status = unsafe {
            ffi::irgx_codex_count(
                self.handle.as_ptr(),
                pattern.as_ptr(),
                pattern.len(),
                &raw mut out,
            )
        };
        if status < 0 {
            return Err(error::plane_fault(status, PLANE));
        }
        Ok(out)
    }

    /// WHERE `pattern` occurs, as ascending text offsets.
    ///
    /// [`Answer::Declined`] when the index was built without the locate layer —
    /// a declinature with a real remedy (rebuild with a `sample_rate`), not an
    /// empty answer. [`Codex::count`] is exact either way.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] if the index could not answer.
    pub fn locate(&self, pattern: &[u8]) -> Result<Answer<Vec<usize>>, Error> {
        // The count is exact, cheap, and declines nothing, so it sizes the buffer
        // and this never retries.
        let hint = self.count(pattern)?;
        sink::reap(PLANE, hint, |out, cap, written| {
            // SAFETY: as `count`, plus `out`/`cap`/`written` being `reap`'s
            // buffer, its true capacity, and a live count slot.
            unsafe {
                ffi::irgx_codex_locate(
                    self.handle.as_ptr(),
                    pattern.as_ptr(),
                    pattern.len(),
                    out,
                    cap,
                    written,
                )
            }
        })
    }

    /// The text offset one row stands for.
    ///
    /// [`Answer::Declined`] for a row with no sampled position, which is every
    /// row of an index built [`Options::without_locating`].
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] for a row past the end of the index.
    pub fn position(&self, row: usize) -> Result<Answer<usize>, Error> {
        let mut out = 0usize;
        // SAFETY: the handle is live for `&self` and `out` is a live slot the
        // library writes only when it has a position.
        let status = unsafe { ffi::irgx_codex_position(self.handle.as_ptr(), row, &raw mut out) };
        if status == sys::STALE {
            return Ok(Answer::Declined);
        }
        if status < 0 {
            return Err(error::plane_fault(status, PLANE));
        }
        Ok(Answer::Given(out))
    }

    /// The whole row range: the interval before any byte has narrowed it, which
    /// is where a backward search starts.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] if the index could not answer.
    pub fn rows(&self) -> Result<Rows, Error> {
        let mut out = Rows::default();
        // SAFETY: the handle is live for `&self`, `out` a live `irgx_codex_rows`.
        let status = unsafe { ffi::irgx_codex_rows_whole(self.handle.as_ptr(), &raw mut out) };
        if status < 0 {
            return Err(error::plane_fault(status, PLANE));
        }
        Ok(out)
    }

    /// Narrow `rows` by one byte, extending the pattern LEFTWARD — the backward
    /// search step, so a host can drive its own matcher over the index.
    ///
    /// Read the pattern right to left: to search for `abc`, narrow by `c`, then
    /// `b`, then `a`. Answers whether the interval is still non-empty; an interval
    /// that has emptied stays empty under every further step, so the first `false`
    /// is final.
    ///
    /// ```
    /// # use irgx::codex::Codex;
    /// let cx = Codex::build(b"mississippi")?;
    /// let mut rows = cx.rows()?;
    /// for byte in b"ssi".iter().rev() {
    ///     assert!(cx.narrow(&mut rows, *byte)?);
    /// }
    /// assert_eq!(rows.len(), cx.count(b"ssi")?);
    /// # Ok::<(), irgx::Error>(())
    /// ```
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] for an interval this index never produced.
    pub fn narrow(&self, rows: &mut Rows, byte: u8) -> Result<bool, Error> {
        // SAFETY: the handle is live for `&self`, and `rows` is a live interval the
        // library reads and overwrites in place.
        let status = unsafe { ffi::irgx_codex_rows_extend(self.handle.as_ptr(), rows, byte) };
        if status < 0 {
            return Err(error::plane_fault(status, PLANE));
        }
        Ok(status == sys::MATCH)
    }

    /// Reconstruct the text from `at` onward. The index IS the text.
    ///
    /// `at == 0` is the whole thing. `at == len` is the empty answer, and a legal
    /// one; past the end is an error, because that is arithmetic rather than an
    /// edge.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] for an `at` past the end of the text.
    pub fn extract(&self, at: usize) -> Result<Vec<u8>, Error> {
        // What exists past `at` is known exactly, so this never retries.
        let hint = self.len().saturating_sub(at);
        sink::reap_all(PLANE, hint, |out, cap, written| {
            // SAFETY: the handle is live for `&self`, and `out`/`cap`/`written` are
            // `reap`'s buffer, its true capacity, and a live count slot.
            unsafe { ffi::irgx_codex_extract(self.handle.as_ptr(), at, out, cap, written) }
        })
    }

    /// Serialize the index, for [`Codex::load`] to read back.
    ///
    /// Two crossings by design: the first asks the size, the second copies. The
    /// image is produced once and parked on the handle in between, so the pair
    /// costs one serialization rather than two — which is why this asks rather
    /// than guessing from [`Stats::index_bytes`].
    ///
    /// # Errors
    ///
    /// [`Error::OutOfMemory`] if the image would not fit.
    pub fn save(&self) -> Result<Vec<u8>, Error> {
        sink::reap_all(PLANE, 0, |out, cap, written| {
            // SAFETY: as `extract`. A zero `cap` with a null `out` is the sizing
            // probe the header documents.
            unsafe { ffi::irgx_codex_save(self.handle.as_ptr(), out, cap, written) }
        })
    }
}

impl Drop for Codex {
    fn drop(&mut self) {
        // SAFETY: the handle came from `build`/`load` and is freed exactly once,
        // here. Nothing borrows from it — every answer this plane gives is owned.
        unsafe { ffi::irgx_codex_free(self.handle.as_ptr()) };
    }
}

impl std::fmt::Debug for Codex {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Codex")
            .field("text_len", &self.len())
            .field("stats", &self.measure().ok())
            .finish()
    }
}

/// The codex plane's seam, from the `irgx_codex_*` block of `irgx.h`.
mod ffi {
    use super::{Handle, Options, Rows, Stats};

    unsafe extern "C" {
        pub fn irgx_codex_max_text_len() -> usize;
        pub fn irgx_codex_build(
            text: *const u8,
            len: usize,
            opts: *const Options,
            out: *mut *mut Handle,
        ) -> i32;
        pub fn irgx_codex_load(bytes: *const u8, len: usize, out: *mut *mut Handle) -> i32;
        pub fn irgx_codex_free(cx: *mut Handle);
        pub fn irgx_codex_len(cx: *const Handle) -> usize;
        pub fn irgx_codex_measure(cx: *const Handle, out: *mut Stats) -> i32;
        pub fn irgx_codex_count(
            cx: *const Handle,
            pattern: *const u8,
            len: usize,
            out: *mut usize,
        ) -> i32;
        pub fn irgx_codex_locate(
            cx: *const Handle,
            pattern: *const u8,
            len: usize,
            out: *mut usize,
            cap: usize,
            written: *mut usize,
        ) -> i32;
        pub fn irgx_codex_position(cx: *const Handle, row: usize, out: *mut usize) -> i32;
        pub fn irgx_codex_rows_whole(cx: *const Handle, out: *mut Rows) -> i32;
        pub fn irgx_codex_rows_extend(cx: *const Handle, rows: *mut Rows, byte: u8) -> i32;
        pub fn irgx_codex_extract(
            cx: *mut Handle,
            at: usize,
            out: *mut u8,
            cap: usize,
            written: *mut usize,
        ) -> i32;
        pub fn irgx_codex_save(
            cx: *mut Handle,
            out: *mut u8,
            cap: usize,
            written: *mut usize,
        ) -> i32;
    }
}
