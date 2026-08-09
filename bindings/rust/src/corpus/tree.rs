//! One search over a warm corpus, and the records it borrows out.
//!
//! `Corpus::open` → [`Corpus::search`] → iterate → drop. A [`Search`] comes back
//! even for a corpus with no hits, because the status reports the ANSWER, never
//! whether there is a handle to release — so "nothing matched" is an empty
//! iterator rather than a special case.
//!
//! ## The arena rule, enforced by the compiler
//!
//! The ABI says a record's `path`, `line` and `spans` live in the CURSOR's arena
//! and die at `irgx_matches_close` — "copy anything you keep". In C that sentence
//! is the whole enforcement mechanism. Here [`Record`] borrows the [`Search`], so
//! keeping one too long is not a rule to remember but a program that does not
//! build:
//!
//! ```compile_fail,E0505
//! # use irgx::{Answer, corpus::{Corpus, tree::Query}};
//! let corpus = Corpus::here()?;
//! let Answer::Given(mut search) = corpus.search(&Query::new(b"fn"))? else { return Ok(()) };
//! let escaped = search.records().next();  // borrows `search`
//! drop(search);                           // ... which the arena dies with
//! println!("{escaped:?}");                // so this line cannot compile
//! # Ok::<(), irgx::Error>(())
//! ```
//!
//! Nothing here copies a record to buy that safety — [`Record::path`] and
//! [`Record::line`] hand out the arena's own bytes. A caller that wants to keep
//! one says so with `.to_vec()`, which is the copy being explicit rather than
//! automatic.
//!
//! ## Zero is today
//!
//! Every field of the ABI's request reads its own 0 as its documented default, so
//! [`Query::new`] is an unbudgeted, uncancelled, contextless leftmost search. The
//! one field where 0 is a legal VALUE rather than "unset" is the per-file ceiling,
//! which is why the ABI needs a flag bit to say it is present and why
//! [`Query::max_count`] is the only knob here that cannot be spelled by leaving
//! something out.

use std::marker::PhantomData;
use std::ptr::NonNull;
use std::time::Duration;

use super::{Cancel, CancelHandle, Corpus, EngineHandle, PLANE};
use crate::Answer;
use crate::error::{self, Error};
use crate::sys;

/// How many records to pull per crossing.
///
/// The batch verb is the engine of the iterator, so this is the only thing that
/// decides how many ABI crossings a scan costs: 32 records is under a kilobyte of
/// descriptors and turns the usual "a few hundred hits" answer into single-digit
/// calls.
const BATCH: usize = 32;

/// An opaque `irgx_cursor`. Never dereferenced on this side.
#[repr(C)]
struct CursorHandle {
    _opaque: [u8; 0],
}

/// `irgx_tree_request`. Lowered from a [`Query`] immediately before the call, so
/// nothing above this file has to know the flag bits or the sentinel.
#[repr(C)]
struct Request {
    struct_size: u32,
    flags: u32,
    max_count: u64,
    before_context: u64,
    after_context: u64,
    pattern: *const u8,
    pattern_len: usize,
    timeout_ns: u64,
    max_results: usize,
    cancel: *const CancelHandle,
}

/// `irgx_match`: one record, whose `path`, `line` and `spans` point into the
/// cursor's arena.
#[derive(Clone, Copy)]
#[repr(C)]
struct Raw {
    path: sys::Text,
    line: sys::Text,
    spans: *const sys::Span,
    nspans: usize,
    line_number: u64,
    kind: u32,
}

impl Default for Raw {
    fn default() -> Self {
        Self {
            path: sys::Text::default(),
            line: sys::Text::default(),
            spans: std::ptr::null(),
            nspans: 0,
            line_number: 0,
            kind: 0,
        }
    }
}

/// `IRGX_MAX_COUNT`: the per-file ceiling is set. The one flag that says a field
/// is PRESENT rather than what it means.
const FLAG_MAX_COUNT: u32 = 1 << 4;
/// `IRGX_INVERT`: select the non-matching lines.
const FLAG_INVERT: u32 = 1 << 7;

/// Whether a record is a line the pattern selected, or a neighbor carried along
/// by the context request.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum Kind {
    /// A line the pattern selected.
    #[default]
    Line,
    /// A neighbor, carried by [`Query::context`].
    Context,
}

/// One complete search, built by leaving out everything you do not need.
///
/// The flag gap is deliberate and comes from the ABI: a warm-engine search has no
/// knob for the PCRE grammar, multiline mode or dot-matches-newline, because the
/// request has nowhere for them to travel. Compile a [`Regex`](crate::Regex) for
/// those and search a buffer.
#[derive(Clone, Debug)]
pub struct Query<'p> {
    pattern: &'p [u8],
    flags: u32,
    max_count: u64,
    before: u64,
    after: u64,
    timeout: Option<Duration>,
    max_results: Option<usize>,
    cancel: Option<Cancel>,
}

impl<'p> Query<'p> {
    /// A leftmost, case-sensitive, unbudgeted search for `pattern` with no
    /// context.
    #[must_use]
    pub fn new(pattern: &'p [u8]) -> Self {
        Self {
            pattern,
            flags: 0,
            max_count: 0,
            before: 0,
            after: 0,
            timeout: None,
            max_results: None,
            cancel: None,
        }
    }

    /// Treat the pattern as a fixed string rather than a regex (`-F`).
    #[must_use]
    pub fn fixed(mut self, yes: bool) -> Self {
        self.bit(sys::FIXED, yes);
        self
    }

    /// Fold case (`-i`).
    #[must_use]
    pub fn ignore_case(mut self, yes: bool) -> Self {
        self.bit(sys::IGNORE_CASE, yes);
        self
    }

    /// Fold case only if the pattern has no uppercase of its own (`-S`).
    #[must_use]
    pub fn smart_case(mut self, yes: bool) -> Self {
        self.bit(sys::SMART_CASE, yes);
        self
    }

    /// Require whole-word matches (`-w`).
    #[must_use]
    pub fn word(mut self, yes: bool) -> Self {
        self.bit(sys::WORD, yes);
        self
    }

    /// Match bytes rather than codepoints: ASCII classes, folding and word
    /// boundaries.
    #[must_use]
    pub fn ascii(mut self, yes: bool) -> Self {
        self.bit(sys::NO_UNICODE, yes);
        self
    }

    /// Select the lines that do NOT match (`-v`).
    #[must_use]
    pub fn invert(mut self, yes: bool) -> Self {
        self.bit(FLAG_INVERT, yes);
        self
    }

    /// Stop after `n` matching lines per FILE (`-m`).
    ///
    /// `Some(0)` is a real ceiling meaning "no lines from any file", which is why
    /// this takes an `Option` where the other budgets read 0 as unset.
    #[must_use]
    pub fn max_count(mut self, n: Option<u64>) -> Self {
        self.bit(FLAG_MAX_COUNT, n.is_some());
        self.max_count = n.unwrap_or(0);
        self
    }

    /// Carry `before` lines above and `after` lines below each match (`-B`/`-A`).
    #[must_use]
    pub fn context(mut self, before: u64, after: u64) -> Self {
        self.before = before;
        self.after = after;
        self
    }

    /// Give up after this long.
    #[must_use]
    pub fn timeout(mut self, budget: Duration) -> Self {
        self.timeout = Some(budget);
        self
    }

    /// Stop after `n` records across the whole corpus.
    ///
    /// `1` is how existence is asked here: there is deliberately no second
    /// spelling of an early halt.
    #[must_use]
    pub fn max_results(mut self, n: usize) -> Self {
        self.max_results = Some(n);
        self
    }

    /// Abandon the search when `cancel` is tripped.
    #[must_use]
    pub fn cancel(mut self, cancel: &Cancel) -> Self {
        self.cancel = Some(cancel.clone());
        self
    }

    fn bit(&mut self, flag: u32, on: bool) {
        if on {
            self.flags |= flag;
        } else {
            self.flags &= !flag;
        }
    }

    /// The ABI request this query means.
    fn lower(&self) -> Request {
        Request {
            struct_size: size_of::<Request>() as u32,
            flags: self.flags,
            max_count: self.max_count,
            before_context: self.before,
            after_context: self.after,
            pattern: self.pattern.as_ptr(),
            pattern_len: self.pattern.len(),
            // Saturating rather than wrapping: a budget so long it overflows a
            // u64 of nanoseconds is unbudgeted in every sense that matters, and
            // 0 would mean exactly the opposite of what was asked.
            timeout_ns: self.timeout.map_or(0, |budget| {
                u64::try_from(budget.as_nanos()).unwrap_or(u64::MAX)
            }),
            max_results: self.max_results.unwrap_or(0),
            cancel: self
                .cancel
                .as_ref()
                .map_or(std::ptr::null(), Cancel::as_ptr),
        }
    }
}

impl Corpus {
    /// Run one search over this corpus.
    ///
    /// [`Answer::Declined`] when the engine's tier stepped aside for this query —
    /// a handoff with no fault behind it, which a host answers by searching some
    /// other way rather than by reporting a failure.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] for a malformed request or a search that could not
    /// complete, [`Error::OutOfMemory`] if the corpus would not fit.
    pub fn search<'c>(&'c self, query: &Query<'_>) -> Result<Answer<Search<'c>>, Error> {
        let request = query.lower();
        let mut out: *mut CursorHandle = std::ptr::null_mut();
        // SAFETY: the engine handle is live for `&self`; `request` is a live
        // `irgx_tree_request` whose `struct_size` `lower` stamped, borrowing the
        // pattern for the duration of this call only; `out` is a live slot.
        let status = unsafe {
            ffi::irgx_tree_search(self.handle.as_ptr(), &raw const request, &raw mut out)
        };
        if status == sys::STALE {
            return Ok(Answer::Declined);
        }
        if status < 0 {
            return Err(error::plane_fault(status, PLANE));
        }
        // A cursor comes back on a no-match too, so this is not "success implies a
        // handle" — it is the ABI's own promise that every non-negative return
        // owes a close.
        NonNull::new(out)
            .map(|handle| {
                Answer::Given(Search {
                    handle,
                    // The token outlives the search that pointed at it, which is
                    // what the clone buys.
                    cancel: query.cancel.clone(),
                    corpus: PhantomData,
                })
            })
            .ok_or_else(|| Error::Inconsistent {
                message: "the tree plane reported an answer and produced no cursor".to_owned(),
            })
    }
}

/// One search's records, and the arena they live in.
///
/// Borrows the [`Corpus`] it came from: the ABI says to close the engine last,
/// after every cursor drawn from it, and this is that rule as a lifetime.
pub struct Search<'c> {
    handle: NonNull<CursorHandle>,
    /// Kept alive for as long as the search can still be running.
    cancel: Option<Cancel>,
    corpus: PhantomData<&'c Corpus>,
}

impl<'c> Search<'c> {
    /// How many records the stream holds, without advancing it.
    #[must_use]
    pub fn len(&self) -> usize {
        // SAFETY: a pure reader over a handle live for `&self`.
        unsafe { ffi::irgx_matches_count(self.handle.as_ptr()) }
    }

    /// Whether the search found nothing.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// The records, in order.
    ///
    /// Pulled in batches under the hood — the one-record ABI verb exists and is
    /// the same answer, but paying a crossing per record for a corpus-wide search
    /// is a cost with nothing to show for it.
    ///
    /// Each [`Record`] borrows this `Search`, so the whole stream stays readable
    /// for as long as the search does: collecting them into a `Vec` and reading
    /// the paths afterwards is fine, and only outliving the `Search` is refused.
    pub fn records(&mut self) -> Records<'_> {
        Records {
            handle: self.handle,
            buffer: [Raw::default(); BATCH],
            filled: 0,
            at: 0,
            drained: false,
            owner: PhantomData,
        }
    }

    /// The next record, one ABI crossing at a time.
    ///
    /// For a host that is already pulling one record per unit of its own work —
    /// otherwise use [`Search::records`], which batches.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] if the stream could not produce the record.
    pub fn next_record(&mut self) -> Result<Option<Record<'_>>, Error> {
        let mut raw = Raw::default();
        // SAFETY: the cursor is live for `&mut self` and `raw` is a live
        // `irgx_match` the library writes only when it has a record.
        let status = unsafe { ffi::irgx_matches_next(self.handle.as_ptr(), &raw mut raw) };
        if status < 0 {
            return Err(error::plane_fault(status, PLANE));
        }
        Ok((status == sys::MATCH).then_some(Record {
            raw,
            owner: PhantomData,
        }))
    }
}

impl Drop for Search<'_> {
    fn drop(&mut self) {
        // SAFETY: the cursor came from `irgx_tree_search` and is closed exactly
        // once, here. Every `Record` borrowing its arena is gone — the lifetime on
        // `records` is what proves that.
        unsafe { ffi::irgx_matches_close(self.handle.as_ptr()) };
        drop(self.cancel.take());
    }
}

/// The record stream, batched.
///
/// Yields `Result` because a pull can fault mid-stream; a fault ends the
/// iteration rather than being retried, since the cursor has already rolled back
/// to the record nobody received.
pub struct Records<'s> {
    handle: NonNull<CursorHandle>,
    buffer: [Raw; BATCH],
    /// How many of `buffer` the last crossing filled.
    filled: usize,
    /// How far into `buffer` this iterator has handed out.
    at: usize,
    drained: bool,
    owner: PhantomData<&'s mut ()>,
}

impl<'s> Iterator for Records<'s> {
    type Item = Result<Record<'s>, Error>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.at == self.filled {
            if self.drained {
                return None;
            }
            let mut written = 0usize;
            // SAFETY: the cursor is live for `'s`; `buffer` is ours and passed
            // with its true capacity, and `written` is a live slot. `written` is
            // what this call CONSUMED, so there is nothing to retry — a short fill
            // is the end of the stream.
            let status = unsafe {
                ffi::irgx_matches_next_batch(
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
        Some(Ok(Record {
            raw,
            owner: PhantomData,
        }))
    }
}

/// One matching (or context) line, borrowed from the [`Search`] that produced it.
///
/// The descriptor is copied — it is six words the ABI wrote into our buffer — and
/// the bytes behind it are not: the path, the line and the spans all point into
/// the cursor's arena, which the lifetime keeps alive.
#[derive(Clone, Copy)]
pub struct Record<'s> {
    raw: Raw,
    owner: PhantomData<&'s ()>,
}

impl<'s> Record<'s> {
    /// The file this line came from.
    ///
    /// Bytes, because a path is not guaranteed to be UTF-8 on any platform this
    /// runs on. [`Record::path_str`] is the checked conversion.
    #[must_use]
    pub fn path(&self) -> &'s [u8] {
        // SAFETY: the header documents `path` as borrowed from the cursor's arena
        // until `irgx_matches_close`, and `'s` proves the cursor is still open.
        unsafe { sys::borrowed(&self.raw.path) }
    }

    /// The file this line came from, if its name is UTF-8.
    #[must_use]
    pub fn path_str(&self) -> Option<&'s str> {
        std::str::from_utf8(self.path()).ok()
    }

    /// The line itself, terminator excluded.
    #[must_use]
    pub fn line(&self) -> &'s [u8] {
        // SAFETY: as `path`.
        unsafe { sys::borrowed(&self.raw.line) }
    }

    /// The line itself, if it is UTF-8. `None` for a line of bytes, which a
    /// pattern compiled with [`Query::ascii`] can legitimately select.
    #[must_use]
    pub fn line_str(&self) -> Option<&'s str> {
        std::str::from_utf8(self.line()).ok()
    }

    /// The 1-based line number, as `-n` prints it.
    #[must_use]
    pub fn line_number(&self) -> u64 {
        self.raw.line_number
    }

    /// Whether this is a selected line or a context neighbor.
    #[must_use]
    pub fn kind(&self) -> Kind {
        match self.raw.kind {
            1 => Kind::Context,
            _ => Kind::Line,
        }
    }

    /// The matched ranges within [`Record::line`], for highlighting.
    ///
    /// Empty for a context record, which was carried along rather than selected.
    pub fn highlights(&self) -> impl ExactSizeIterator<Item = std::ops::Range<usize>> + 's {
        let spans: &'s [sys::Span] = if self.raw.spans.is_null() || self.raw.nspans == 0 {
            &[]
        } else {
            // SAFETY: the header documents `spans`/`nspans` as borrowed from the
            // cursor's arena until `irgx_matches_close`, and `'s` proves the
            // cursor is still open.
            unsafe { std::slice::from_raw_parts(self.raw.spans, self.raw.nspans) }
        };
        spans
            .iter()
            .filter_map(|span| span.range())
            .map(|(start, end)| start..end)
            // Collected so the iterator is `ExactSizeIterator`: a highlighter
            // wants to know whether there is anything to draw before it starts.
            .collect::<Vec<_>>()
            .into_iter()
    }
}

impl std::fmt::Debug for Record<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Record")
            .field("path", &String::from_utf8_lossy(self.path()))
            .field("line_number", &self.raw.line_number)
            .field("kind", &self.kind())
            .field("line", &String::from_utf8_lossy(self.line()))
            .finish()
    }
}

/// The tree plane's seam, from the `irgx_tree_*` / `irgx_matches_*` block of
/// `irgx.h`.
mod ffi {
    use super::{CursorHandle, EngineHandle, Raw, Request};

    unsafe extern "C" {
        pub fn irgx_tree_search(
            engine: *mut EngineHandle,
            req: *const Request,
            out: *mut *mut CursorHandle,
        ) -> i32;
        pub fn irgx_matches_next(cursor: *mut CursorHandle, out: *mut Raw) -> i32;
        pub fn irgx_matches_next_batch(
            cursor: *mut CursorHandle,
            out: *mut Raw,
            cap: usize,
            written: *mut usize,
        ) -> i32;
        pub fn irgx_matches_count(cursor: *const CursorHandle) -> usize;
        pub fn irgx_matches_close(cursor: *mut CursorHandle);
    }
}
