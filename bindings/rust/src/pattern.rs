//! [`Regex`], [`RegexBuilder`], and the two engine calls everything is built on.
//!
//! One rule shapes the whole file: **the match sequence comes from
//! `irgx_find_all`, never from a loop over `irgx_captures`.** The engine
//! owns what a sequence of matches is - whether an empty match adjacent to the
//! previous one counts, what happens at the end of the buffer, how `word(true)`
//! filtering interacts with resuming the scan - and none of that is derivable
//! from a `find(from)` cursor. So every verb here asks `find_all` once for the
//! authoritative spans, and only then, per match and only when the pattern
//! declares groups, asks `captures` for the detail.
//!
//! The consequence a caller can see is that [`Regex::find_iter`] is not lazy. It
//! cannot be: the sequence is one answer, so it is collected up front. The
//! iterator it returns therefore borrows only the text, and knows its own
//! length.

use crate::error::{Error, fault};
use crate::matches::{CaptureMatches, Captures, GroupSpans, Match, Matches, Split, crate_sequence};
use crate::pool::{Lease, Pool, Recipe};
use crate::sys;

use std::ptr::NonNull;

/// How many spans to ask `find_all` for on the first try.
///
/// The header's advice is to size the window at `len + 1`, which is the most
/// matches a text can hold; doing that unconditionally would allocate 16 MB of
/// span buffer for a 1 MB text that probably has four matches. So the first ask
/// is this, and a text with more matches than that is answered by one retry at
/// the count the engine reported.
const FIRST_WINDOW: usize = 4096;

/// A compiled pattern.
///
/// Immutable, and `Send + Sync`: put one in a `static` behind `LazyLock` and
/// search from as many threads as you like. The C handle underneath is
/// single-threaded, so the type keeps a pool of them and leases one per search;
/// see the crate docs for what that costs.
pub struct Regex {
    pool: Pool<Spell>,
    /// How many capture groups the pattern declares, or the refusal the engine's
    /// capture arm answered with. A refusal is not fatal: `find_all` still
    /// answers, so searching works and only the `captures` family cannot. The
    /// error is built once, here, where the fault detail behind it is still
    /// readable; a `captures` call minutes later has no way to recover it.
    groups: Result<usize, Error>,
    /// Named groups, in declaration order. A `Vec` and not a map because
    /// patterns have a handful of names at most, so a linear scan beats hashing
    /// and keeps the declaration order a caller can iterate.
    names: Box<[(Box<str>, usize)]>,
}

impl Regex {
    /// Compile `pattern` with the default semantics: a full regex, case
    /// sensitive, Unicode-aware, linear time.
    ///
    /// # Errors
    ///
    /// [`Error::NeedsPcre`] for a construct outside the linear grammar -
    /// lookaround, a backreference, an inline flag group - which the same
    /// pattern under [`RegexBuilder::pcre`] compiles. [`Error::Syntax`] for a
    /// malformed pattern, with the byte offset the engine stopped at; `pcre`
    /// will not rescue that one.
    pub fn new(pattern: &str) -> Result<Self, Error> {
        RegexBuilder::new(pattern).build()
    }

    fn compile(pattern: &str, flags: u32) -> Result<Self, Error> {
        let pool = Pool::new(Spell {
            pattern: pattern.into(),
            flags,
        })?;
        let lease = pool.lease()?;

        let mut count: u32 = 0;
        // SAFETY: the lease hands out a live handle this thread alone holds, and
        // `count` is a live `u32` slot the library writes only on success.
        let status = unsafe { sys::irgx_group_count(lease.raw(), &raw mut count) };
        // A negative status here means the capture arm refused the pattern, not
        // that the pattern is unusable. Record the refusal and let the verbs that
        // actually need a group be the ones that complain.
        let groups = if status < 0 {
            Err(fault(status, |status, detail| Error::Groups {
                pattern: pattern.to_owned(),
                status,
                detail,
            }))
        } else {
            Ok(count as usize)
        };
        let names = match groups {
            Ok(n) if n > 0 => name_table(&lease, count),
            _ => Box::default(),
        };
        drop(lease);

        Ok(Self {
            pool,
            groups,
            names,
        })
    }

    /// The pattern this was compiled from, exactly as it was given.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.pool.recipe().pattern
    }

    /// How many capture groups the pattern declares, excluding the whole match.
    ///
    /// `None` means the engine's capture arm will not compile this pattern, so
    /// group detail is unavailable for its matches. Searching still works.
    #[must_use]
    pub fn groups(&self) -> Option<usize> {
        self.groups.as_ref().ok().copied()
    }

    /// The named groups, as `(name, group number)` in declaration order.
    pub fn group_names(&self) -> impl ExactSizeIterator<Item = (&str, usize)> {
        self.names.iter().map(|(name, at)| (&**name, *at))
    }

    /// The number of the group named `name`, or `None` when there is none.
    #[must_use]
    pub fn group_index(&self, name: &str) -> Option<usize> {
        self.names
            .iter()
            .find(|(known, _)| &**known == name)
            .map(|(_, at)| *at)
    }

    // ── the search surface ───────────────────────────────────────────────

    /// Whether `text` holds a match anywhere.
    ///
    /// The engine's cheapest question: it may stop at the first hit and never
    /// materializes a span.
    ///
    /// # Panics
    ///
    /// On an engine fault. See [`Regex::try_is_match`] for the checked form.
    #[must_use]
    pub fn is_match(&self, text: &str) -> bool {
        expect(self.try_is_match(text))
    }

    /// [`Regex::is_match`], reporting an engine fault instead of panicking.
    ///
    /// # Errors
    ///
    /// [`Error::Search`] or [`Error::OutOfMemory`] if the engine could not
    /// answer.
    pub fn try_is_match(&self, text: &str) -> Result<bool, Error> {
        let lease = self.pool.lease()?;
        let body = text.as_bytes();
        // SAFETY: the lease is exclusive to this thread, and `body` is a live
        // slice passed with its own length. A `&str`'s pointer is never null,
        // and the header accepts a zero length regardless.
        let status = unsafe { sys::irgx_is_match(lease.raw(), body.as_ptr(), body.len()) };
        if status < 0 {
            return Err(fault(status, |status, detail| Error::Search {
                status,
                detail,
            }));
        }
        Ok(status == sys::MATCH)
    }

    /// The leftmost match in `text`, or `None`.
    ///
    /// # Panics
    ///
    /// On an engine fault, or if the match boundary is not a UTF-8 boundary.
    /// See [`Regex::try_find`].
    #[must_use]
    pub fn find<'t>(&self, text: &'t str) -> Option<Match<'t>> {
        expect(self.try_find(text))
    }

    /// [`Regex::find`], reporting a fault instead of panicking.
    ///
    /// # Errors
    ///
    /// [`Error::Search`], [`Error::OutOfMemory`], or [`Error::NotCharBoundary`].
    pub fn try_find<'t>(&self, text: &'t str) -> Result<Option<Match<'t>>, Error> {
        // A window of one: the engine still scans the whole text, but only the
        // first span is written, so this costs no span buffer worth speaking of.
        // The count that comes back is how many the text holds, which is more
        // than this verb wants and exactly enough to answer whether there is a
        // leftmost match at all.
        let mut span = [sys::Span::default()];
        if self.scan(text, 0, &mut span)? == 0 {
            return Ok(None);
        }
        let (start, end) = self.checked(text, span[0])?;
        Ok(Some(Match::new(text, start, end)))
    }

    /// The leftmost match starting at or after `start`, or `None`.
    ///
    /// Like [`Regex::find`], but the scan begins at `start` **without** cutting
    /// the haystack there. That distinction is the whole reason this exists
    /// rather than being spelled `re.find(&text[start..])`: a slice moves the
    /// left edge, so `^`, `\A` and `\b` at the cut would answer about the slice.
    /// Here they still answer about `text`, so `^` can only match when
    /// `start == 0` and a `\b` at `start` reads the byte before it.
    ///
    /// # Panics
    ///
    /// On an engine fault, if `start` is past the end of `text`, or if the match
    /// boundary is not a UTF-8 boundary. See [`Regex::try_find_at`].
    #[must_use]
    pub fn find_at<'t>(&self, text: &'t str, start: usize) -> Option<Match<'t>> {
        expect(self.try_find_at(text, start))
    }

    /// [`Regex::find_at`], reporting a fault instead of panicking.
    ///
    /// # Errors
    ///
    /// [`Error::Search`], [`Error::OutOfMemory`], or [`Error::NotCharBoundary`]
    /// — the last one also when `start` itself is not a character boundary or
    /// lies outside `text`, since neither names a position this crate could
    /// report a match from.
    pub fn try_find_at<'t>(&self, text: &'t str, start: usize) -> Result<Option<Match<'t>>, Error> {
        self.reachable(text, start)?;
        // No thinning: `crate_sequence` only ever removes an empty match that
        // abuts the PREVIOUS one, and a single leftmost answer has no previous.
        let mut span = [sys::Span::default()];
        if self.scan(text, start, &mut span)? == 0 {
            return Ok(None);
        }
        let (from, end) = self.checked(text, span[0])?;
        Ok(Some(Match::new(text, from, end)))
    }

    /// Whether `text` holds a match starting at or after `start`.
    ///
    /// The cheap form of [`Regex::find_at`], and it reads the surrounding text
    /// for assertions in the same way.
    ///
    /// # Panics
    ///
    /// On an engine fault, or if `start` is not a character boundary of `text`.
    /// See [`Regex::try_is_match_at`].
    #[must_use]
    pub fn is_match_at(&self, text: &str, start: usize) -> bool {
        expect(self.try_is_match_at(text, start))
    }

    /// [`Regex::is_match_at`], reporting a fault instead of panicking.
    ///
    /// # Errors
    ///
    /// [`Error::Search`], [`Error::OutOfMemory`], or [`Error::NotCharBoundary`].
    pub fn try_is_match_at(&self, text: &str, start: usize) -> Result<bool, Error> {
        self.reachable(text, start)?;
        let lease = self.pool.lease()?;
        let body = text.as_bytes();
        // SAFETY: as `scan`, plus `from <= to` because `reachable` established
        // `start <= body.len()` and `to` IS `body.len()`.
        let status = unsafe {
            sys::irgx_is_match_in(lease.raw(), body.as_ptr(), body.len(), start, body.len())
        };
        if status < 0 {
            return Err(fault(status, |status, detail| Error::Search {
                status,
                detail,
            }));
        }
        Ok(status == sys::MATCH)
    }

    /// Reject a `start` that names no position in `text`.
    ///
    /// Checked here rather than left to the ABI's `IRGX_INVALID` so the error
    /// says which offset and why, and so an offset inside a multi-byte character
    /// is refused too — the ABI would accept it, being byte-addressed, and every
    /// span it then reported would have to be rejected on the way out anyway.
    fn reachable(&self, text: &str, start: usize) -> Result<(), Error> {
        if text.is_char_boundary(start) {
            return Ok(());
        }
        Err(Error::NotCharBoundary { offset: start })
    }

    /// Every match in `text`, in the engine's own order.
    ///
    /// Not lazy: the sequence is one answer from the engine, so it is collected
    /// before iteration starts. That is why the iterator knows its own length
    /// and can be walked from either end.
    ///
    /// # Panics
    ///
    /// On an engine fault, or if a match boundary is not a UTF-8 boundary. See
    /// [`Regex::try_find_iter`].
    #[must_use]
    pub fn find_iter<'t>(&self, text: &'t str) -> Matches<'t> {
        expect(self.try_find_iter(text))
    }

    /// [`Regex::find_iter`], reporting a fault instead of panicking.
    ///
    /// # Errors
    ///
    /// [`Error::Search`], [`Error::OutOfMemory`], or [`Error::NotCharBoundary`].
    pub fn try_find_iter<'t>(&self, text: &'t str) -> Result<Matches<'t>, Error> {
        Ok(Matches::new(text, self.find_all(text)?))
    }

    /// The capture groups of the leftmost match in `text`, or `None`.
    ///
    /// # Panics
    ///
    /// On an engine fault, or if the pattern's capture arm was refused (see
    /// [`Regex::groups`]). See [`Regex::try_captures`].
    #[must_use]
    pub fn captures<'r, 't>(&'r self, text: &'t str) -> Option<Captures<'r, 't>> {
        expect(self.try_captures(text))
    }

    /// [`Regex::captures`], reporting a fault instead of panicking.
    ///
    /// # Errors
    ///
    /// [`Error::Groups`] when this pattern has no group detail, plus everything
    /// [`Regex::try_find`] can report.
    pub fn try_captures<'r, 't>(
        &'r self,
        text: &'t str,
    ) -> Result<Option<Captures<'r, 't>>, Error> {
        let Some(found) = self.try_find(text)? else {
            return Ok(None);
        };
        let spans = self.captures_at(text, found.start(), found.end())?;
        Ok(Some(Captures::new(self, text, spans)))
    }

    /// The capture groups of every match in `text`.
    ///
    /// The spans come from one `find_all`, and each match's group detail is
    /// filled as the iterator reaches it.
    ///
    /// # Panics
    ///
    /// On an engine fault, or if the pattern's capture arm was refused. See
    /// [`Regex::try_captures_iter`].
    #[must_use]
    pub fn captures_iter<'r, 't>(&'r self, text: &'t str) -> CaptureMatches<'r, 't> {
        expect(self.try_captures_iter(text))
    }

    /// [`Regex::captures_iter`], reporting a fault instead of panicking.
    ///
    /// # Errors
    ///
    /// [`Error::Groups`] when this pattern has no group detail, plus everything
    /// [`Regex::try_find_iter`] can report. A fault while filling one match's
    /// groups panics from the iterator, because there is nowhere else for it to
    /// go; ask [`Regex::groups`] first if that matters to you.
    pub fn try_captures_iter<'r, 't>(
        &'r self,
        text: &'t str,
    ) -> Result<CaptureMatches<'r, 't>, Error> {
        self.groups.clone()?;
        Ok(CaptureMatches::new(self, text, self.find_all(text)?))
    }

    /// `text` split around every match, like [`str::split`].
    ///
    /// # Panics
    ///
    /// On an engine fault, or if a match boundary is not a UTF-8 boundary.
    #[must_use]
    pub fn split<'t>(&self, text: &'t str) -> Split<'t> {
        Split::new(text, self.find_iter(text), usize::MAX)
    }

    /// `text` split around at most `limit - 1` matches, so at most `limit`
    /// pieces come back, like [`str::splitn`].
    ///
    /// # Panics
    ///
    /// On an engine fault, or if a match boundary is not a UTF-8 boundary.
    #[must_use]
    pub fn splitn<'t>(&self, text: &'t str, limit: usize) -> Split<'t> {
        Split::new(text, self.find_iter(text), limit)
    }

    // ── the two engine calls ─────────────────────────────────────────────

    /// One `find_all` into `out`, returning how many matches the TEXT holds.
    ///
    /// That count is not a length: `out` is a window over the answer, so at
    /// most `out.len()` spans are written and the count may be larger. Only
    /// `out[..count.min(out.len())]` was filled, and reading past that is
    /// reading uninitialised span memory.
    fn scan(&self, text: &str, from: usize, out: &mut [sys::Span]) -> Result<usize, Error> {
        let lease = self.pool.lease()?;
        let body = text.as_bytes();
        let mut written: usize = 0;
        // SAFETY: the lease is exclusive to this thread; `body` and `out` are
        // live slices passed with their own lengths, so the library writes at
        // most `out.len()` spans into a buffer that holds that many; `written` is
        // a live slot. The header allows a zero-length text, and requires
        // `from <= to <= len` — `to` is the length here, and `from` is checked by
        // the caller, which is what makes this an inert bound the PCRE arm can
        // answer too.
        let status = unsafe {
            sys::irgx_find_all_in(
                lease.raw(),
                body.as_ptr(),
                body.len(),
                from,
                body.len(),
                out.as_mut_ptr(),
                out.len(),
                &raw mut written,
            )
        };
        if status < 0 {
            return Err(fault(status, |status, detail| Error::Search {
                status,
                detail,
            }));
        }
        Ok(written)
    }

    /// Every match span in `text`, in the sequence the `regex` crate reports.
    ///
    /// At most two searches, never a growth loop: the count that comes back is
    /// the text's own, so a window that came up short sizes its exact retry.
    /// There is nothing left to infer from a full window either - it used to
    /// mean "exactly filled" or "truncated here" indistinguishably, which is
    /// what forced a rescan of every text that happened to land on the size.
    ///
    /// The engine reports where the matches ARE; `crate_sequence` decides which
    /// of them this crate shows, which is a question each language's regex
    /// library answers for itself.
    fn find_all(&self, text: &str) -> Result<Vec<(usize, usize)>, Error> {
        // A text of n bytes cannot hold more than n + 1 matches, so a short one
        // is answered in a single pass without asking for a window it could
        // never fill.
        let mut out = vec![sys::Span::default(); FIRST_WINDOW.min(text.len() + 1)];
        let mut total = self.scan(text, 0, &mut out)?;
        if total > out.len() {
            out = vec![sys::Span::default(); total];
            total = self.scan(text, 0, &mut out)?;
        }
        // `total` is a count the engine reported, not a length this side wrote,
        // and the two part company exactly when the window was short. Clamping
        // is what keeps a retry that somehow answered differently from turning
        // into a read of span memory nobody filled.
        out.truncate(total.min(out.len()));
        // Thin BEFORE checking, not after. The engine's widest sequence puts an
        // empty match at every byte, including inside a multi-byte character,
        // and those are precisely the spans `crate_sequence` removes. Checking
        // first would reject a span this crate was never going to report and
        // turn a `héllo` into a fault.
        let raw = out
            .into_iter()
            .map(|span| self.set(span))
            .collect::<Result<_, _>>()?;
        crate_sequence(raw, text)
            .into_iter()
            .map(|span| self.boundaries(text, span))
            .collect()
    }

    /// Group spans for the match `find_all` reported at `[start, end)`.
    ///
    /// `captures` reports how many spans the PATTERN has rather than how many it
    /// wrote, so a window that came up short sizes its own retry without a
    /// second question.
    pub(crate) fn captures_at(
        &self,
        text: &str,
        start: usize,
        end: usize,
    ) -> Result<GroupSpans, Error> {
        let groups = self.groups.clone()?;
        if groups == 0 {
            return Ok(Box::new([Some((start, end))]));
        }

        let body = text.as_bytes();
        let mut window = groups + 1;
        let (out, written) = loop {
            let lease = self.pool.lease()?;
            let mut out = vec![sys::Span::default(); window];
            let mut written: usize = 0;
            // SAFETY: the lease is exclusive to this thread; `body` and `out` are
            // live slices passed with their own lengths; `start` is a byte offset
            // `find_all` reported inside `body`, so it satisfies the header's
            // `from <= len`; `written` is a live slot.
            let status = unsafe {
                sys::irgx_captures(
                    lease.raw(),
                    body.as_ptr(),
                    body.len(),
                    start,
                    out.as_mut_ptr(),
                    out.len(),
                    &raw mut written,
                )
            };
            drop(lease);
            if status < 0 {
                return Err(fault(status, |status, detail| Error::Groups {
                    pattern: self.as_str().to_owned(),
                    status,
                    detail,
                }));
            }
            if status != sys::MATCH {
                // `find_all` reported a match at this offset, so `captures`
                // finding none means the two arms disagree. Refusing beats
                // inventing groups.
                return Err(Error::Inconsistent {
                    message: format!(
                        "find_all reported a match at byte {start} for `{}`, but captures \
                         found none",
                        self.as_str()
                    ),
                });
            }
            if written <= window {
                break (out, written);
            }
            window = written;
        };

        let whole = out[0].range();
        if whole != Some((start, end)) {
            return Err(Error::Inconsistent {
                message: format!(
                    "find_all reported ({start}, {end}) for `{}`, but captures reported \
                     {whole:?} from the same offset",
                    self.as_str()
                ),
            });
        }
        out[..window.min(written)]
            .iter()
            .map(|span| match span.range() {
                None => Ok(None),
                Some(_) => self.checked(text, *span).map(Some),
            })
            .collect()
    }

    /// A span as a byte range that is safe to slice `text` with.
    ///
    /// Rust `str` is UTF-8 indexed by byte, exactly like the engine's spans, so
    /// there is no offset translation to do here - only a check. The engine
    /// matches bytes, and with `unicode(false)` a pattern like `.` can stop
    /// mid-codepoint; slicing there would panic in the caller's code with no
    /// explanation, so it becomes a named error instead.
    fn checked(&self, text: &str, span: sys::Span) -> Result<(usize, usize), Error> {
        self.boundaries(text, self.set(span)?)
    }

    /// The two halves of [`Self::checked`], separated so a whole-match walk can
    /// thin the sequence in between. A span the crate will not report should
    /// never be boundary-checked, because the engine's widest sequence puts
    /// empty matches mid-character on purpose.
    fn set(&self, span: sys::Span) -> Result<(usize, usize), Error> {
        span.range().ok_or_else(|| Error::Inconsistent {
            message: format!(
                "the whole-match span for `{}` came back unset ({}, {})",
                self.as_str(),
                span.start,
                span.end
            ),
        })
    }

    fn boundaries(&self, text: &str, span: (usize, usize)) -> Result<(usize, usize), Error> {
        // `is_char_boundary` is false for any index past the end, so this also
        // rejects a span the engine could not have produced from this text.
        for offset in [span.0, span.1] {
            if !text.is_char_boundary(offset) {
                return Err(Error::NotCharBoundary { offset });
            }
        }
        Ok(span)
    }
}

/// What a [`Regex`]'s pool recompiles from: one pattern and its flag word.
///
/// Held here rather than beside the pool so that a `Regex` stores the pattern
/// once. `as_str` reads it back out of the recipe, which is the same string the
/// next handle will be compiled from — there is no second copy to fall out of
/// step with.
pub(crate) struct Spell {
    pattern: Box<str>,
    flags: u32,
}

impl Recipe for Spell {
    type Raw = sys::Regex;

    fn compile(&self) -> Result<NonNull<sys::Regex>, Error> {
        let body = self.pattern.as_bytes();
        let mut out: *mut sys::Regex = std::ptr::null_mut();
        // SAFETY: `body` is a live slice passed with its own length, `flags` is a
        // plain integer, and `out` is a live pointer slot the library only writes
        // on success. The call cannot unwind: every entry in this ABI returns a
        // status.
        let status =
            unsafe { sys::irgx_compile(body.as_ptr(), body.len(), self.flags, &raw mut out) };
        if status < 0 {
            // `out` is deliberately not consulted: the header leaves it untouched
            // on a refusal, so there is no handle here to read, keep or free -
            // not even on the declinature, which is the path that looks most like
            // success.
            return Err(crate::error::compile_refusal(status, &self.pattern));
        }
        crate::pool::wrote(out, "irgx_compile")
    }

    unsafe fn release(raw: NonNull<sys::Regex>) {
        // SAFETY: the caller promises `raw` came from `compile` above and has not
        // been released.
        unsafe { sys::irgx_free(raw.as_ptr()) }
    }
}

/// The `regex`-shaped verbs report an engine fault by panicking, because that is
/// what makes `re.find(text)` return an `Option` rather than a `Result` and read
/// like the crate every Rust programmer already knows. The faults reachable here
/// are an allocation failure - which Rust code already treats as fatal - and a
/// pattern whose capture arm the engine refused, which [`Regex::groups`] reports
/// without searching. Every one of them also has a `try_` sibling.
pub(crate) fn expect<T>(result: Result<T, Error>) -> T {
    result.unwrap_or_else(|why| panic!("{why}"))
}

/// The name of every group the pattern declares, in declaration order.
///
/// Asked group by group rather than read out of the pattern source, because
/// only the engine knows which parentheses are groups. A name has two spellings
/// under the linear grammar and a third under PCRE2, `\(` is a literal, `(?:`
/// is a group that cannot be named, and `(?#` is a comment whose contents mean
/// nothing - so a scan of the pattern text is a parser competing with the one
/// that already ran, and it loses quietly, by missing a name rather than by
/// inventing one.
///
/// The bytes come back borrowed from the handle, which goes home to the pool
/// when this returns, so each name is copied here rather than held.
fn name_table(lease: &Lease<'_, Spell>, count: u32) -> Box<[(Box<str>, usize)]> {
    let mut found: Vec<(Box<str>, usize)> = Vec::new();
    // Group 0 is the whole match and is never named, so the walk starts at 1
    // and stops at the count the engine just reported: an index past it is
    // `IRGX_INVALID`, not an absent name.
    for index in 1..=count {
        let mut name = sys::Text::default();
        // SAFETY: the lease is exclusive to this thread, `index` is within the
        // group count the engine reported for this same handle, and `name` is a
        // live slot the library writes only when it reports a match.
        let status = unsafe { sys::irgx_group_name(lease.raw(), index, &raw mut name) };
        if status != sys::MATCH || name.ptr.is_null() {
            continue;
        }
        // SAFETY: the header documents the span as the parser's own name
        // storage, borrowed from the handle and valid until `irgx_free`; the
        // lease is alive for this whole loop and the bytes are copied below.
        let bytes = unsafe { std::slice::from_raw_parts(name.ptr, name.len) };
        if let Ok(text) = std::str::from_utf8(bytes) {
            found.push((text.into(), index as usize));
        }
    }
    found.into()
}

impl Clone for Regex {
    /// Recompiles the pattern, because a compiled handle cannot be duplicated
    /// through the C ABI. The compile is pure, so the clone behaves identically.
    ///
    /// # Panics
    ///
    /// If the recompile fails. The pattern already compiled once, so the only
    /// way that happens is an allocation failure.
    fn clone(&self) -> Self {
        let spell = self.pool.recipe();
        expect(Self::compile(&spell.pattern, spell.flags))
    }
}

impl std::fmt::Debug for Regex {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        std::fmt::Debug::fmt(self.as_str(), f)
    }
}

impl std::fmt::Display for Regex {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

impl std::str::FromStr for Regex {
    type Err = Error;

    fn from_str(pattern: &str) -> Result<Self, Error> {
        Self::new(pattern)
    }
}

/// Compile a pattern with the flags spelled out.
///
/// ```
/// # fn main() -> Result<(), irgx::Error> {
/// let re = irgx::RegexBuilder::new("café").ignore_case(true).build()?;
/// assert!(re.is_match("le CAFÉ noir"));
/// # Ok(())
/// # }
/// ```
#[derive(Clone, Debug)]
pub struct RegexBuilder {
    pattern: String,
    flags: u32,
}

impl RegexBuilder {
    /// A builder for `pattern`, with the same defaults as [`Regex::new`].
    #[must_use]
    pub fn new(pattern: &str) -> Self {
        // Unicode semantics are the engine's default, so the bit that exists is
        // `IRGX_NO_UNICODE` and the default flag word is empty.
        Self {
            pattern: pattern.to_owned(),
            flags: 0,
        }
    }

    /// Treat the pattern as a literal string rather than a regex, so every
    /// metacharacter in it is data. Wins over [`RegexBuilder::pcre`], as it
    /// does in the engine: a fixed string needs no grammar at all.
    pub fn fixed(&mut self, yes: bool) -> &mut Self {
        self.set(sys::FIXED, yes)
    }

    /// Match without regard to case.
    pub fn ignore_case(&mut self, yes: bool) -> &mut Self {
        self.set(sys::IGNORE_CASE, yes)
    }

    /// Report only matches whose edges are word boundaries. A span the word rule
    /// rejects is not a match, and the scan resumes past it.
    pub fn word(&mut self, yes: bool) -> &mut Self {
        self.set(sys::WORD, yes)
    }

    /// Fold case only when the pattern itself has no uppercase letter. Resolved
    /// at compile time against the same predicate the engine's command line
    /// uses, so a pattern means one thing in both places.
    pub fn smart_case(&mut self, yes: bool) -> &mut Self {
        self.set(sys::SMART_CASE, yes)
    }

    /// Unicode-aware classes, folding, and boundaries. On by default; turning it
    /// off makes `.`, `\w` and `\b` operate on bytes, which is faster and can
    /// report a span that lands inside a codepoint
    /// ([`Error::NotCharBoundary`]).
    pub fn unicode(&mut self, yes: bool) -> &mut Self {
        // Inverted: the flag the ABI has is NO_UNICODE.
        self.set(sys::NO_UNICODE, !yes)
    }

    /// Make `^` and `$` match at line boundaries as well as at the ends of the
    /// text. Off by default, exactly as `regex`'s `multi_line` is.
    ///
    /// This does not change what the text IS. The text is always one buffer -
    /// `\s` matches a newline, and a match may span one - and this only moves
    /// the two anchors. Those are separate questions, and conflating them is
    /// what makes a grep tool's `-m` flag mean something different from a
    /// library's.
    pub fn multi_line(&mut self, yes: bool) -> &mut Self {
        self.set(sys::MULTILINE, yes)
    }

    /// Make `.` match a newline. Off by default, as `regex`'s
    /// `dot_matches_new_line` is.
    ///
    /// The builder is the portable way to ask: inline `(?s)` is PCRE2 grammar
    /// here, so it would silently need [`RegexBuilder::pcre`] and the
    /// backtracking engine that comes with it.
    pub fn dot_matches_new_line(&mut self, yes: bool) -> &mut Self {
        self.set(sys::DOTALL, yes)
    }

    /// Use the PCRE2 grammar, which adds lookaround and backreferences. The
    /// default engine is linear in the length of the text; PCRE2 is not, and a
    /// pathological pattern can backtrack for a long time.
    pub fn pcre(&mut self, yes: bool) -> &mut Self {
        self.set(sys::PCRE, yes)
    }

    /// Compile it.
    ///
    /// # Errors
    ///
    /// [`Error::NeedsPcre`] when only the PCRE2 arm can express the pattern,
    /// [`Error::Syntax`] when it is malformed, or [`Error::Abi`] when the linked
    /// library speaks a different C ABI than this crate.
    pub fn build(&self) -> Result<Regex, Error> {
        Regex::compile(&self.pattern, self.flags)
    }

    fn set(&mut self, bit: u32, yes: bool) -> &mut Self {
        if yes {
            self.flags |= bit;
        } else {
            self.flags &= !bit;
        }
        self
    }
}
