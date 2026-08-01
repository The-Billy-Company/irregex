//! What a search hands back: [`Match`], [`Captures`], and the three iterators.
//!
//! Offsets here are byte offsets into the searched `&str`, and that is not a
//! translation - it is the same coordinate system the engine reports in. Rust
//! `str` is UTF-8 and sliced by byte index, exactly like the engine's spans, so
//! `&text[m.range()]` is the matched text by construction. The one thing that
//! needs care is that slicing a `str` at a non-boundary panics, so every span is
//! checked for boundary alignment before it becomes a `Match`; see
//! [`crate::Error::NotCharBoundary`].

use std::iter::FusedIterator;
use std::ops::{Index, Range};

use crate::pattern::{Regex, expect};

/// One match's group spans, index 0 first. `None` is a group the match did not
/// enter, which the C ABI reports as `(-1, -1)` and which is a different fact
/// from a group that matched empty.
pub(crate) type GroupSpans = Box<[Option<(usize, usize)>]>;

/// One match: a byte range in the text that was searched.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Match<'t> {
    text: &'t str,
    start: usize,
    end: usize,
}

impl<'t> Match<'t> {
    /// Both offsets are checked UTF-8 boundaries in `text` before this is
    /// called, which is what lets [`Match::as_str`] slice without panicking.
    pub(crate) fn new(text: &'t str, start: usize, end: usize) -> Self {
        debug_assert!(text.is_char_boundary(start) && text.is_char_boundary(end));
        Self { text, start, end }
    }

    /// The byte offset the match starts at.
    #[must_use]
    pub fn start(&self) -> usize {
        self.start
    }

    /// The byte offset just past the match.
    #[must_use]
    pub fn end(&self) -> usize {
        self.end
    }

    /// The match as a byte range, for slicing the text you searched.
    #[must_use]
    pub fn range(&self) -> Range<usize> {
        self.start..self.end
    }

    /// Whether the match is zero-width. Nullable patterns produce these, and
    /// they are real matches.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.start == self.end
    }

    /// The match length in bytes.
    #[must_use]
    pub fn len(&self) -> usize {
        self.end - self.start
    }

    /// The matched text.
    #[must_use]
    pub fn as_str(&self) -> &'t str {
        &self.text[self.start..self.end]
    }

    /// The matched bytes. Always available, including for a pattern compiled
    /// with `unicode(false)` over text where the boundaries would not align.
    #[must_use]
    pub fn as_bytes(&self) -> &'t [u8] {
        &self.text.as_bytes()[self.start..self.end]
    }
}

impl<'t> From<Match<'t>> for &'t str {
    fn from(found: Match<'t>) -> Self {
        found.as_str()
    }
}

impl From<Match<'_>> for Range<usize> {
    fn from(found: Match<'_>) -> Self {
        found.range()
    }
}

/// Every match in one text, in the engine's own order.
///
/// Eager rather than lazy, because the engine reports the whole sequence in one
/// call and that is deliberate: empty matches, adjacency, and `word(true)`
/// filtering are its rules, and re-deriving them from a resumable cursor is
/// exactly how a binding gets nullable patterns wrong. The upside is that this
/// iterator knows its length, runs backwards, and borrows only the text.
#[derive(Clone, Debug)]
pub struct Matches<'t> {
    text: &'t str,
    spans: std::vec::IntoIter<(usize, usize)>,
}

impl<'t> Matches<'t> {
    pub(crate) fn new(text: &'t str, spans: Vec<(usize, usize)>) -> Self {
        Self {
            text,
            spans: spans.into_iter(),
        }
    }
}

impl<'t> Iterator for Matches<'t> {
    type Item = Match<'t>;

    fn next(&mut self) -> Option<Self::Item> {
        let (start, end) = self.spans.next()?;
        Some(Match::new(self.text, start, end))
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        self.spans.size_hint()
    }
}

impl DoubleEndedIterator for Matches<'_> {
    fn next_back(&mut self) -> Option<Self::Item> {
        let (start, end) = self.spans.next_back()?;
        Some(Match::new(self.text, start, end))
    }
}

impl ExactSizeIterator for Matches<'_> {}
impl FusedIterator for Matches<'_> {}

/// The capture groups of one match.
///
/// Index 0 is the whole match; index `k` is group `k`. A group the match did not
/// enter is `None`, which is a different fact from a group that matched empty -
/// `(a)|(b)` produces one of each, every time.
#[derive(Clone, Debug)]
pub struct Captures<'r, 't> {
    re: &'r Regex,
    text: &'t str,
    spans: GroupSpans,
}

impl<'r, 't> Captures<'r, 't> {
    pub(crate) fn new(re: &'r Regex, text: &'t str, spans: GroupSpans) -> Self {
        Self { re, text, spans }
    }

    /// How many groups this match reports, counting the whole match. Always at
    /// least 1.
    //
    // No `is_empty`: the count includes the whole match, so it is never zero and
    // a method that can only answer `false` would be noise.
    #[must_use]
    #[allow(clippy::len_without_is_empty)]
    pub fn len(&self) -> usize {
        self.spans.len()
    }

    /// Group `index`, or `None` when there is no such group or the match did not
    /// enter it.
    #[must_use]
    pub fn get(&self, index: usize) -> Option<Match<'t>> {
        let (start, end) = (*self.spans.get(index)?)?;
        Some(Match::new(self.text, start, end))
    }

    /// The group named `name`, or `None` when the pattern declares no such name
    /// or the match did not enter it.
    #[must_use]
    pub fn name(&self, name: &str) -> Option<Match<'t>> {
        self.get(self.re.group_index(name)?)
    }

    /// Every group in order, starting with the whole match.
    pub fn iter(&self) -> impl ExactSizeIterator<Item = Option<Match<'t>>> {
        let text = self.text;
        self.spans
            .iter()
            .map(move |span| span.map(|(start, end)| Match::new(text, start, end)))
    }

    /// Append `template` to `dst`, with `$1` / `${name}` references filled in.
    ///
    /// The syntax is the `regex` crate's, not `re`'s: `$name` takes the longest
    /// run of `[0-9A-Za-z_]`, `${name}` delimits it explicitly, and `$$` is a
    /// literal `$`. A reference to a group that does not exist or that the match
    /// did not enter expands to nothing.
    pub fn expand(&self, template: &str, dst: &mut String) {
        crate::replace::expand(self, template, dst);
    }
}

/// Panics when there is no such group, or when the match did not enter it. Use
/// [`Captures::get`] when absence is a possibility you want to handle.
impl<'t> Index<usize> for Captures<'_, 't> {
    type Output = str;

    fn index(&self, index: usize) -> &str {
        match self.get(index) {
            Some(found) => found.as_str(),
            // The two reasons are different bugs in the caller, so the message
            // says which one happened rather than making them guess.
            None if index < self.spans.len() => {
                panic!("group {index} did not participate in this match; use get({index})")
            },
            None => panic!(
                "no group at index {index}: `{}` declares {}",
                self.re,
                self.spans.len() - 1
            ),
        }
    }
}

/// Panics when the pattern declares no such name, or when the match did not
/// enter that group. Use [`Captures::name`] when absence is a possibility.
impl<'t> Index<&str> for Captures<'_, 't> {
    type Output = str;

    fn index(&self, name: &str) -> &str {
        if let Some(found) = self.name(name) {
            return found.as_str();
        }
        // The two reasons are different bugs in the caller, so the message says
        // which one happened rather than making them guess.
        assert!(
            self.re.group_index(name).is_none(),
            "group `{name}` did not participate in this match; use name(\"{name}\")"
        );
        panic!(
            "no group named `{name}`: `{}` declares none by that name",
            self.re
        )
    }
}

/// The capture groups of every match in one text.
///
/// The spans come from one `find_all`; each match's group detail is filled as
/// the iterator reaches it, so walking this purely to count costs no capture
/// passes beyond the ones you consume.
#[derive(Clone, Debug)]
pub struct CaptureMatches<'r, 't> {
    re: &'r Regex,
    text: &'t str,
    spans: std::vec::IntoIter<(usize, usize)>,
}

impl<'r, 't> CaptureMatches<'r, 't> {
    pub(crate) fn new(re: &'r Regex, text: &'t str, spans: Vec<(usize, usize)>) -> Self {
        Self {
            re,
            text,
            spans: spans.into_iter(),
        }
    }
}

impl<'r, 't> Iterator for CaptureMatches<'r, 't> {
    type Item = Captures<'r, 't>;

    /// # Panics
    ///
    /// If the engine faults while reading one match's groups. There is nowhere
    /// for an error to go from inside `Iterator::next`, and the fault this could
    /// report - a capture arm the engine refuses - is already reported by
    /// [`Regex::try_captures_iter`] before iteration starts.
    fn next(&mut self) -> Option<Self::Item> {
        let (start, end) = self.spans.next()?;
        let spans = expect(self.re.captures_at(self.text, start, end));
        Some(Captures::new(self.re, self.text, spans))
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        self.spans.size_hint()
    }
}

impl ExactSizeIterator for CaptureMatches<'_, '_> {}
impl FusedIterator for CaptureMatches<'_, '_> {}

/// The pieces of a text between its matches.
#[derive(Clone, Debug)]
pub struct Split<'t> {
    text: &'t str,
    matches: Matches<'t>,
    cut: usize,
    /// How many pieces may still be produced. `usize::MAX` for an unlimited
    /// split; 0 means this iterator is finished.
    left: usize,
}

impl<'t> Split<'t> {
    pub(crate) fn new(text: &'t str, matches: Matches<'t>, limit: usize) -> Self {
        Self {
            text,
            matches,
            cut: 0,
            left: limit,
        }
    }
}

impl<'t> Iterator for Split<'t> {
    type Item = &'t str;

    fn next(&mut self) -> Option<Self::Item> {
        if self.left == 0 {
            return None;
        }
        self.left -= 1;
        // The last piece a limit allows is the whole remainder, matches and all;
        // so is the piece after the final match.
        if self.left == 0 {
            return Some(&self.text[self.cut..]);
        }
        match self.matches.next() {
            Some(found) => {
                let piece = &self.text[self.cut..found.start()];
                self.cut = found.end();
                Some(piece)
            },
            None => {
                self.left = 0;
                Some(&self.text[self.cut..])
            },
        }
    }
}

impl FusedIterator for Split<'_> {}
