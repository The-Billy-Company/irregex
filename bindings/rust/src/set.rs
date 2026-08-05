//! [`RegexSet`] — which of many patterns match, in one pass over the text.
//!
//! The shape is `regex`'s [`RegexSet`], and so is the reason for it: asking N
//! compiled patterns separately reads the text N times, and asking one fused
//! `a|b|c` reads it once and throws away which pattern hit. What is underneath
//! is different — the engine has a slate plane with a SIMD literal sieve in
//! front of it, so a text nothing can match is often rejected before any
//! automaton runs, and a pattern whose literals *decide* it is answered by the
//! sieve alone.
//!
//! One rule shapes this file the way `irgx_find_all` shapes `pattern.rs`: **the
//! set's answer comes from the engine's own slate**, never from a loop over
//! [`crate::Regex::is_match`]. That is not a performance preference. A loop
//! would be a second implementation of "does this pattern match this text",
//! and the two would eventually disagree about an anchored or nullable pattern.
//! The engine holds the slate to the single-pattern answer pattern by pattern,
//! with its accelerators on and off, so this crate inherits that proof instead
//! of restating it.
//!
//! A set reports presence, not position. Once you know pattern 7 matched,
//! `Regex::find` on pattern 7 is the search you were going to run anyway,
//! against a text now known to be worth searching — so there is no per-pattern
//! span verb here, exactly as there is none in `regex`.

use std::ptr::NonNull;

use crate::error::{Error, compile_refusal, fault};
use crate::pattern::expect;
use crate::pool::{Pool, Recipe};
use crate::sys;

/// Many patterns, matched against one text in a single pass.
///
/// Immutable, and `Send + Sync` on the same terms as [`crate::Regex`]: the C
/// handle owns the scratch its scans run in, so the type keeps a pool of handles
/// and leases one per scan.
///
/// ```
/// # fn main() -> Result<(), irgx::Error> {
/// let set = irgx::RegexSet::new([r"^\w+@\w+$", r"^\d{3}-\d{4}$", r"^https?://"])?;
///
/// assert!(set.is_match("bob@host"));
/// assert_eq!(set.matches("555-1234").iter().collect::<Vec<_>>(), vec![1]);
/// assert!(!set.is_match("neither"));
/// # Ok(())
/// # }
/// ```
pub struct RegexSet {
    pool: Pool<Slate>,
}

impl RegexSet {
    /// Compile every pattern in `patterns` as one set, with the default
    /// semantics [`crate::Regex::new`] uses.
    ///
    /// # Errors
    ///
    /// The first pattern the engine will not take refuses the whole set, and the
    /// error names *that pattern* — [`Error::NeedsPcre`] when the PCRE2 arm would
    /// accept it, [`Error::Syntax`] when it is malformed. Admission is all or
    /// nothing, so a caller assembling a set out of somebody else's patterns
    /// should expect to drop one and rebuild.
    pub fn new<I, S>(patterns: I) -> Result<Self, Error>
    where
        S: AsRef<str>,
        I: IntoIterator<Item = S>,
    {
        RegexSetBuilder::new(patterns).build()
    }

    /// A set with no patterns, which matches nothing.
    ///
    /// # Panics
    ///
    /// On an allocation failure, which is the only way compiling no patterns can
    /// fail. `regex`'s `RegexSet::empty` is infallible and this keeps that
    /// signature; [`RegexSet::new`] with an empty iterator is the checked form.
    #[must_use]
    pub fn empty() -> Self {
        expect(Self::new(std::iter::empty::<&str>()))
    }

    /// How many patterns the set holds.
    #[must_use]
    pub fn len(&self) -> usize {
        self.patterns().len()
    }

    /// Whether the set holds no patterns at all. Such a set matches nothing.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.patterns().is_empty()
    }

    /// The patterns this was compiled from, in order, exactly as they were
    /// given. Index `i` here is the index [`SetMatches`] reports.
    #[must_use]
    pub fn patterns(&self) -> &[String] {
        &self.pool.recipe().patterns
    }

    /// Whether *any* pattern in the set matches `text`.
    ///
    /// The cheapest question the plane answers: the sieve can reject a hopeless
    /// text with no automaton run at all, and the scan stops at the first yes
    /// rather than finishing the attribution.
    ///
    /// # Panics
    ///
    /// On an engine fault. See [`RegexSet::try_is_match`].
    #[must_use]
    pub fn is_match(&self, text: &str) -> bool {
        expect(self.try_is_match(text))
    }

    /// [`RegexSet::is_match`], reporting an engine fault instead of panicking.
    ///
    /// # Errors
    ///
    /// [`Error::Search`] or [`Error::OutOfMemory`] if the engine could not
    /// answer.
    pub fn try_is_match(&self, text: &str) -> Result<bool, Error> {
        let lease = self.pool.lease()?;
        let body = text.as_bytes();
        // SAFETY: the lease is exclusive to this thread, and `body` is a live
        // slice passed with its own length. A `&str`'s pointer is never null, and
        // the header accepts a zero length regardless.
        let status = unsafe { sys::irgx_slate_is_match(lease.raw(), body.as_ptr(), body.len()) };
        if status < 0 {
            return Err(fault(status, |status, detail| Error::Search {
                status,
                detail,
            }));
        }
        Ok(status == sys::MATCH)
    }

    /// Which patterns match `text`.
    ///
    /// # Panics
    ///
    /// On an engine fault. See [`RegexSet::try_matches`].
    #[must_use]
    pub fn matches(&self, text: &str) -> SetMatches {
        expect(self.try_matches(text))
    }

    /// [`RegexSet::matches`], reporting an engine fault instead of panicking.
    ///
    /// # Errors
    ///
    /// [`Error::Search`] or [`Error::OutOfMemory`] if the engine could not
    /// answer.
    pub fn try_matches(&self, text: &str) -> Result<SetMatches, Error> {
        let total = self.len();
        // Sized at the set's own length, which the header promises the count can
        // never exceed. So unlike the span window in `pattern.rs`, there is no
        // retry loop to write here and no way for a short buffer to exist.
        let mut hits: Vec<u32> = vec![0; total];
        let lease = self.pool.lease()?;
        let body = text.as_bytes();
        let mut written: usize = 0;
        // SAFETY: the lease is exclusive to this thread; `body` and `hits` are
        // live slices passed with their own lengths; `written` is a live slot.
        let status = unsafe {
            sys::irgx_slate_which(
                lease.raw(),
                body.as_ptr(),
                body.len(),
                hits.as_mut_ptr(),
                hits.len(),
                &raw mut written,
            )
        };
        drop(lease);
        if status < 0 {
            return Err(fault(status, |status, detail| Error::Search {
                status,
                detail,
            }));
        }
        if written > total {
            // The count is the number of patterns that matched, and there are
            // only `total` patterns. Refusing beats trusting a length that
            // cannot be true.
            return Err(Error::Inconsistent {
                message: format!("a slate of {total} patterns reported {written} of them matching"),
            });
        }
        hits.truncate(written);
        Ok(SetMatches {
            hits: hits.into(),
            total,
        })
    }
}

/// Which patterns of a [`RegexSet`] matched one text.
///
/// Stored as the matching indices rather than as a bit per pattern, because that
/// is what the engine reports and because the interesting case is a large set
/// with a few hits. [`SetMatches::matched`] therefore costs a binary search
/// rather than an array index — nothing a caller will measure, and it makes
/// [`SetMatches::iter`] free.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SetMatches {
    /// The matching indices, ascending.
    hits: Box<[u32]>,
    /// How many patterns the set holds — what [`SetMatches::len`] reports, as in
    /// `regex`, where `len` is the size of the set and not the number of hits.
    total: usize,
}

impl SetMatches {
    /// Whether any pattern matched.
    #[must_use]
    pub fn matched_any(&self) -> bool {
        !self.hits.is_empty()
    }

    /// Whether the pattern at `index` matched. `false` for an index past the end
    /// of the set, which cannot have matched anything.
    #[must_use]
    pub fn matched(&self, index: usize) -> bool {
        u32::try_from(index).is_ok_and(|wanted| self.hits.binary_search(&wanted).is_ok())
    }

    /// How many patterns the *set* holds — not how many matched. This is
    /// `regex`'s meaning for the same name; [`SetMatches::iter`] counts the hits.
    #[must_use]
    pub fn len(&self) -> usize {
        self.total
    }

    /// Whether the set that produced this held no patterns at all.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.total == 0
    }

    /// The indices of the patterns that matched, ascending.
    pub fn iter(&self) -> impl ExactSizeIterator<Item = usize> + DoubleEndedIterator + '_ {
        self.hits.iter().map(|&at| at as usize)
    }
}

impl IntoIterator for SetMatches {
    type Item = usize;
    type IntoIter = std::vec::IntoIter<usize>;

    fn into_iter(self) -> Self::IntoIter {
        self.hits
            .iter()
            .map(|&at| at as usize)
            .collect::<Vec<_>>()
            .into_iter()
    }
}

impl<'m> IntoIterator for &'m SetMatches {
    type Item = usize;
    type IntoIter = std::iter::Map<std::slice::Iter<'m, u32>, fn(&'m u32) -> usize>;

    fn into_iter(self) -> Self::IntoIter {
        fn widen(at: &u32) -> usize {
            *at as usize
        }
        self.hits.iter().map(widen as fn(&u32) -> usize)
    }
}

/// Compile a [`RegexSet`] with the flags spelled out.
///
/// The flags apply to every pattern in the set, as `regex`'s `RegexSetBuilder`
/// does it. (The C ABI underneath takes a flag word *per pattern*; nothing here
/// asks for that yet, and a knob with no caller is a knob that gets maintained
/// for nobody.)
///
/// ```
/// # fn main() -> Result<(), irgx::Error> {
/// let set = irgx::RegexSetBuilder::new(["café", "CIGAR"])
///     .ignore_case(true)
///     .build()?;
/// assert_eq!(set.matches("le CAFÉ noir").iter().collect::<Vec<_>>(), vec![0]);
/// # Ok(())
/// # }
/// ```
#[derive(Clone, Debug)]
pub struct RegexSetBuilder {
    patterns: Vec<String>,
    flags: u32,
}

impl RegexSetBuilder {
    /// A builder for `patterns`, with the same defaults as [`RegexSet::new`].
    #[must_use]
    pub fn new<I, S>(patterns: I) -> Self
    where
        S: AsRef<str>,
        I: IntoIterator<Item = S>,
    {
        Self {
            patterns: patterns
                .into_iter()
                .map(|one| one.as_ref().to_owned())
                .collect(),
            flags: 0,
        }
    }

    /// Treat every pattern as a literal string rather than a regex.
    pub fn fixed(&mut self, yes: bool) -> &mut Self {
        self.set(sys::FIXED, yes)
    }

    /// Match without regard to case.
    pub fn ignore_case(&mut self, yes: bool) -> &mut Self {
        self.set(sys::IGNORE_CASE, yes)
    }

    /// Report only matches whose edges are word boundaries.
    pub fn word(&mut self, yes: bool) -> &mut Self {
        self.set(sys::WORD, yes)
    }

    /// Fold case only for the patterns that have no uppercase letter of their
    /// own. Resolved per pattern, at compile time.
    pub fn smart_case(&mut self, yes: bool) -> &mut Self {
        self.set(sys::SMART_CASE, yes)
    }

    /// Unicode-aware classes, folding, and boundaries. On by default.
    pub fn unicode(&mut self, yes: bool) -> &mut Self {
        // Inverted: the flag the ABI has is NO_UNICODE.
        self.set(sys::NO_UNICODE, !yes)
    }

    /// Use the PCRE2 grammar, which adds lookaround and backreferences.
    pub fn pcre(&mut self, yes: bool) -> &mut Self {
        self.set(sys::PCRE, yes)
    }

    // `multi_line` and `dot_matches_new_line` are deliberately absent, and the
    // engine refuses those two bits on a slate rather than ignoring them: the
    // slate compiles through a path with no `(?m)` / `(?s)` knob to carry them
    // into. A builder method that could only fail would be a worse way to say
    // that than not having one. A pattern whose own head says `(?m)` or `(?s)`
    // is refused for the same reason, naming its index; a leading `(?i)` or
    // `(?-u)` is read per pattern, as `RegexSet` reads it.

    /// Compile it.
    ///
    /// # Errors
    ///
    /// As [`RegexSet::new`]: the refusal names the pattern that caused it.
    pub fn build(&self) -> Result<RegexSet, Error> {
        Ok(RegexSet {
            pool: Pool::new(Slate {
                patterns: self.patterns.clone().into(),
                flags: self.flags,
            })?,
        })
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

/// What a [`RegexSet`]'s pool recompiles from: the patterns, and the one flag
/// word they share.
struct Slate {
    patterns: Box<[String]>,
    flags: u32,
}

impl Recipe for Slate {
    type Raw = sys::Slate;

    fn compile(&self) -> Result<NonNull<sys::Slate>, Error> {
        // Borrowed, not copied: the engine copies the pattern bytes itself, so
        // this list only has to outlive the call.
        let list: Vec<sys::SlatePattern> = self
            .patterns
            .iter()
            .map(|one| sys::SlatePattern {
                pattern: one.as_ptr(),
                len: one.len(),
                flags: self.flags,
            })
            .collect();
        let mut out: *mut sys::Slate = std::ptr::null_mut();
        // `usize::MAX` rather than 0, so a library that reported a refusal
        // without naming a pattern cannot be misread as blaming the first one.
        let mut refused: usize = usize::MAX;
        // SAFETY: `list` is a live slice passed with its own length, whose
        // elements borrow live `String`s; `refused` and `out` are live slots the
        // library writes at most once each.
        let status = unsafe {
            sys::irgx_slate_compile(list.as_ptr(), list.len(), &raw mut refused, &raw mut out)
        };
        if status < 0 {
            let blamed = self.patterns.get(refused).map_or("", String::as_str);
            return Err(compile_refusal(status, blamed));
        }
        crate::pool::wrote(out, "irgx_slate_compile")
    }

    unsafe fn release(raw: NonNull<sys::Slate>) {
        // SAFETY: the caller promises `raw` came from `compile` above and has not
        // been released.
        unsafe { sys::irgx_slate_free(raw.as_ptr()) }
    }
}

impl Clone for RegexSet {
    /// Recompiles the patterns, because a compiled slate cannot be duplicated
    /// through the C ABI. The compile is pure, so the clone behaves identically.
    ///
    /// # Panics
    ///
    /// If the recompile fails. The patterns already compiled once, so the only
    /// way that happens is an allocation failure.
    fn clone(&self) -> Self {
        let slate = self.pool.recipe();
        expect(
            RegexSetBuilder {
                patterns: slate.patterns.to_vec(),
                flags: slate.flags,
            }
            .build(),
        )
    }
}

impl std::fmt::Debug for RegexSet {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("RegexSet").field(&self.patterns()).finish()
    }
}
