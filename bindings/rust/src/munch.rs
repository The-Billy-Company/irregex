//! [`Munch`] — the longest of many patterns, starting exactly here.
//!
//! Every other type in this crate answers a *search* question: it scans forward
//! looking for somewhere a pattern fits. [`Regex::find`](crate::Regex::find)
//! does, and so does [`RegexSet::matches`](crate::RegexSet::matches). A
//! tokenizer needs the opposite one, and it is the missing primitive between
//! "does this regex match" and "lex this file": **starting at exactly this
//! offset, which pattern reaches furthest?**
//!
//! There is no `regex`-crate equivalent to borrow a shape from, so this is the
//! one type here whose API is ours. Three things shape it.
//!
//! **A refusal is per pattern, not per slate.** [`RegexSet::new`] is
//! all-or-nothing: one pattern the engine will not take refuses the whole set,
//! because a classifier that silently dropped one would misreport which patterns
//! matched. A lexer is the other case — one terminal outside the linear grammar
//! must not cost the other hundred and fifty — so [`Munch::new`] succeeds and
//! names what it lost in [`Munch::declined`]. A caller with a fallback engine
//! runs it for exactly those ordinals; a caller without one at least knows what
//! it is blind to.
//!
//! **Ties are the grammar's business.** Longest is only half of a lexer's rule.
//! The tie-break — declared precedence, literal beats regex, first-declared-wins
//! — is a property of the language rather than of the automaton, so a scan
//! reports *every* pattern that reached the winning length and has no opinion
//! about which deserves it.
//!
//! **The permitted set is part of the walk.** A real lexer is state-directed:
//! only some terminals are legal where it stands. That cannot be recovered by
//! filtering the answer, because one long illegal match hides every short legal
//! one behind it — `if` inside `iffy` is the whole problem in four characters. So
//! [`Munch::token_among`] restricts the scan itself, which is lex's start
//! conditions, tree-sitter's valid-symbol set, and Lezer's contextual tokenizer.
//!
//! ```
//! # fn main() -> Result<(), irgx::Error> {
//! // A tiny operator lexer: maximal munch picks `>>=` over `>>` and `>`.
//! let ops = irgx::Munch::new([">", ">>", ">>="])?;
//! let token = ops.token(">>= 1", 0).unwrap();
//! assert_eq!(token.len(), 3);
//! assert_eq!(token.patterns(), &[2]);
//!
//! // Anchored: nothing starts at offset 0 of " >>=".
//! assert!(ops.token(" >>=", 0).is_none());
//! assert_eq!(ops.token(" >>=", 1).unwrap().len(), 3);
//! # Ok(())
//! # }
//! ```
//!
//! # Why this and not the automaton
//!
//! The obvious alternative is for the engine to export its DFA — `next_state`,
//! `is_match_state`, an accelerator — and let this crate build maximal munch
//! itself. It deliberately does not. A host stepping states is a second opinion
//! about what a pattern means, and one engine that disagrees with itself is
//! worse than one that is missing a verb; the engine's regex kernel is sealed
//! for exactly that reason, after a second, smaller parser inside it once
//! disagreed about the zero-width `\<` and `\>` boundaries and silently pruned
//! two thirds of a matching corpus. So the *rule* crosses the ABI, and this file
//! is a thin lowering of it rather than a reimplementation.

use std::ptr::NonNull;

use crate::error::{Error, fault};
use crate::pattern::expect;
use crate::pool::{Pool, Recipe};
use crate::sys;

/// Which reading of an offset a scan takes.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum Pick {
    /// Maximal munch: the match that reaches furthest. The lexer's rule, and
    /// what you want when a parser state asked for a specific set of terminals.
    #[default]
    Longest,
    /// The shortest non-empty match instead.
    ///
    /// Worth having for a reason worth knowing: asked over a slate nobody asked
    /// for — every terminal a grammar has — longest answers a fact about the
    /// grammar's *widest* regex rather than about the bytes, because such a slate
    /// almost always contains a run-of-anything-but-a-delimiter that reaches
    /// past every real token at every offset. A caller wanting a *name* for the
    /// byte under it asks for the shortest reading.
    Shortest,
}

/// Why one pattern could not become an anchored automaton.
///
/// Carried rather than left to be inferred, because the four have different
/// owners and different repairs. [`Why::States`] and [`Why::BufferAnchor`] are
/// the load-bearing pair: a budget and a wall.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum Why {
    /// The engine's parser rejected the pattern — the pattern author's to fix.
    Syntax,
    /// Determinizing it reached this build's state bound. A statement about the
    /// build, not about regular languages: the pattern is fine, and a `Regex`
    /// will still match it.
    States,
    /// The pattern reaches a word-boundary assertion. An anchored automaton has
    /// no left context to resolve `\b` against, because the byte before the
    /// caller's offset is not in the text it was determinized over.
    WordContext,
    /// The pattern carries a buffer anchor (`\A` or `\z`). Unlike [`Why::States`]
    /// this is not a budget: the position it asserts is not something an
    /// automaton determinized over the pattern alone can see, so no build admits
    /// it. A scan is already anchored at the offset you pass, which leaves `\A`
    /// redundant and `\z` unsatisfiable — drop it from the terminal.
    BufferAnchor,
    /// A reason this crate does not know, from a newer engine.
    Unknown(u32),
}

impl Why {
    fn of(raw: u32) -> Self {
        match raw {
            sys::MUNCH_SYNTAX => Self::Syntax,
            sys::MUNCH_STATES => Self::States,
            sys::MUNCH_WORD_CONTEXT => Self::WordContext,
            sys::MUNCH_BUFFER_ANCHOR => Self::BufferAnchor,
            other => Self::Unknown(other),
        }
    }
}

/// One pattern a [`Munch`] could not take.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Refusal {
    /// Its index in the pattern list, as given.
    pub pattern: usize,
    /// Why it was refused.
    pub why: Why,
}

/// What a scan found: how far it reached, and which patterns got there.
///
/// `len` of zero is a *result*, not an absence — a pattern like `a*` accepts the
/// empty string, and a scan that found nothing is `None` instead. A lexer that
/// would spin forever advancing on a zero-length token can therefore see it:
///
/// ```
/// # fn main() -> Result<(), irgx::Error> {
/// let m = irgx::Munch::new(["a*"])?;
/// let token = m.token("bbb", 0).unwrap();
/// assert_eq!(token.len(), 0);
/// assert!(token.is_empty());
/// # Ok(())
/// # }
/// ```
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Token {
    len: usize,
    patterns: Box<[u32]>,
}

impl Token {
    /// How many bytes the token consumed.
    #[must_use]
    pub fn len(&self) -> usize {
        self.len
    }

    /// Whether the token consumed nothing — a nullable pattern accepting the
    /// empty string. Advancing on one does not make progress.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// Every pattern that reached this length, ascending, as indices into the
    /// list the [`Munch`] was built from.
    ///
    /// More than one is a tie, and breaking it is the caller's: see the module
    /// documentation.
    #[must_use]
    pub fn patterns(&self) -> &[u32] {
        &self.patterns
    }

    /// The byte range the token covers in the text it was scanned from, given
    /// the offset it was scanned at.
    #[must_use]
    pub fn range(&self, at: usize) -> std::ops::Range<usize> {
        at..at + self.len
    }
}

/// Many patterns, matched anchored at one offset, longest wins.
///
/// Immutable, and `Send + Sync` on the same terms as [`crate::Regex`]: the C
/// handle owns the buffers its scans rewrite, so the type keeps a pool of
/// handles and leases one per scan.
pub struct Munch {
    pool: Pool<Anchored>,
    /// Read once at build, both of them. Pure functions of the patterns and
    /// flags, so every handle in the pool answers identically and asking again
    /// per scan would be a lease for a constant.
    declined: Box<[Refusal]>,
    /// How many patterns can win at once, as the *engine* counts them rather
    /// than as `len() - declined.len()`. Derivable, and deliberately not
    /// derived: a slate's seats are a consequence of which patterns refused, and
    /// arithmetic here would be a second opinion about the engine's own bookkeeping.
    admitted: usize,
}

impl Munch {
    /// Compile every pattern in `patterns` as one anchored slate, with the
    /// default semantics [`crate::Regex::new`] uses.
    ///
    /// # Errors
    ///
    /// [`Error::NothingLexable`] when *no* pattern could be determinized, which
    /// is the only refusal that leaves nothing to work with. A partial refusal is
    /// success — read it with [`Munch::declined`].
    pub fn new<I, S>(patterns: I) -> Result<Self, Error>
    where
        S: AsRef<str>,
        I: IntoIterator<Item = S>,
    {
        MunchBuilder::new(patterns).build()
    }

    /// The patterns this was compiled from, in order, exactly as they were
    /// given. Index `i` here is the index a [`Token`] reports.
    #[must_use]
    pub fn patterns(&self) -> &[String] {
        &self.pool.recipe().patterns
    }

    /// How many patterns the slate was built from, refusals included.
    #[must_use]
    pub fn len(&self) -> usize {
        self.patterns().len()
    }

    /// Whether the slate holds no patterns at all. Such a slate matches nothing.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.patterns().is_empty()
    }

    /// Every pattern the engine could not take, ascending. Empty is the normal
    /// case.
    ///
    /// ```
    /// # fn main() -> Result<(), irgx::Error> {
    /// // A backreference cannot be determinized, and must not cost the others.
    /// let m = irgx::Munch::new(["[a-z]+", r"(a)\1", "[0-9]+"])?;
    /// assert_eq!(m.declined().len(), 1);
    /// assert_eq!(m.declined()[0].pattern, 1);
    /// assert_eq!(m.token("123", 0).unwrap().patterns(), &[2]);
    /// # Ok(())
    /// # }
    /// ```
    #[must_use]
    pub fn declined(&self) -> &[Refusal] {
        &self.declined
    }

    /// How many patterns can win at once — the upper bound on
    /// [`Token::patterns`]'s length, and the capacity
    /// [`Munch::scan_into`] never needs to grow past.
    ///
    /// The *admitted* count, not [`Munch::len`]: a declined pattern can never
    /// win, so it can never be reported.
    #[must_use]
    pub fn admitted(&self) -> usize {
        self.admitted
    }

    /// The longest token beginning at exactly `at`, over every pattern.
    ///
    /// `None` when nothing starts there. `at == text.len()` is legal and asks
    /// the only question left at the end of the input: does anything accept the
    /// empty string.
    ///
    /// # Panics
    ///
    /// On an engine fault, or if `at` is past the end of `text`. See
    /// [`Munch::try_token`].
    #[must_use]
    pub fn token(&self, text: &str, at: usize) -> Option<Token> {
        expect(self.try_token(text, at))
    }

    /// [`Munch::token`], reporting a fault instead of panicking.
    ///
    /// # Errors
    ///
    /// [`Error::Search`] or [`Error::OutOfMemory`] if the engine could not
    /// answer, and [`Error::Inconsistent`] if `at` is past the end of `text`.
    pub fn try_token(&self, text: &str, at: usize) -> Result<Option<Token>, Error> {
        self.owned(text, at, None, Pick::Longest)
    }

    /// The longest token beginning at exactly `at`, restricted to the patterns
    /// `allow` names.
    ///
    /// Restriction happens *during* the walk, not after: a forbidden pattern
    /// reaching further would otherwise hide every permitted one behind it.
    ///
    /// ```
    /// # fn main() -> Result<(), irgx::Error> {
    /// let m = irgx::Munch::new(["if", "[a-z]+"])?;
    /// // Unrestricted, the identifier wins and swallows the keyword.
    /// assert_eq!(m.token("iffy", 0).unwrap().patterns(), &[1]);
    /// // Restricted to the keyword, the answer is `if` — not nothing, which is
    /// // what filtering the unrestricted answer would have produced.
    /// assert_eq!(m.token_among("iffy", 0, &[0]).unwrap().len(), 2);
    /// # Ok(())
    /// # }
    /// ```
    ///
    /// An empty `allow` permits nothing, which is a real question with a
    /// knowable answer (`None`) rather than an error: a lexer state can
    /// legitimately reach a point where no terminal is legal. Naming a pattern
    /// the engine declined is a no-op, so a caller with a fallback need not also
    /// remember which its blind terminals were.
    ///
    /// # Panics
    ///
    /// As [`Munch::token`]. See [`Munch::try_token_among`].
    #[must_use]
    pub fn token_among(&self, text: &str, at: usize, allow: &[u32]) -> Option<Token> {
        expect(self.try_token_among(text, at, allow))
    }

    /// [`Munch::token_among`], reporting a fault instead of panicking.
    ///
    /// # Errors
    ///
    /// As [`Munch::try_token`].
    pub fn try_token_among(
        &self,
        text: &str,
        at: usize,
        allow: &[u32],
    ) -> Result<Option<Token>, Error> {
        self.owned(text, at, Some(allow), Pick::Longest)
    }

    /// The *shortest* non-empty token beginning at exactly `at`, restricted to
    /// the patterns `allow` names. See [`Pick::Shortest`] for when that is the
    /// question you have.
    ///
    /// # Panics
    ///
    /// As [`Munch::token`]. See [`Munch::try_shortest_among`].
    #[must_use]
    pub fn shortest_among(&self, text: &str, at: usize, allow: &[u32]) -> Option<Token> {
        expect(self.try_shortest_among(text, at, allow))
    }

    /// [`Munch::shortest_among`], reporting a fault instead of panicking.
    ///
    /// # Errors
    ///
    /// As [`Munch::try_token`].
    pub fn try_shortest_among(
        &self,
        text: &str,
        at: usize,
        allow: &[u32],
    ) -> Result<Option<Token>, Error> {
        self.owned(text, at, Some(allow), Pick::Shortest)
    }

    /// One scan, writing the winning patterns into `winners` instead of
    /// allocating — the allocation-free form the other four are built on.
    ///
    /// A lexer calls this once per token, and a `Box<[u32]>` per token is a real
    /// cost for an answer that is almost always one number long. This form
    /// reuses the caller's buffer: `winners` is cleared, filled with the winning
    /// pattern indices ascending, and the token's byte length is returned.
    /// `Ok(None)` means nothing starts at `at`, and leaves `winners` empty.
    ///
    /// ```
    /// # fn main() -> Result<(), irgx::Error> {
    /// let m = irgx::Munch::new(["[a-z]+", "[0-9]+", r"\s+"])?;
    /// let text = "ab 12";
    /// let mut winners = Vec::with_capacity(m.admitted());
    /// let mut at = 0;
    /// let mut spans = Vec::new();
    /// while at < text.len() {
    ///     let len = m
    ///         .scan_into(text, at, None, irgx::Pick::Longest, &mut winners)?
    ///         .filter(|len| *len > 0)
    ///         .expect("every byte of this text starts some token");
    ///     spans.push((at..at + len, winners[0]));
    ///     at += len;
    /// }
    /// assert_eq!(spans, vec![(0..2, 0), (2..3, 2), (3..5, 1)]);
    /// # Ok(())
    /// # }
    /// ```
    ///
    /// # Errors
    ///
    /// As [`Munch::try_token`].
    pub fn scan_into(
        &self,
        text: &str,
        at: usize,
        allow: Option<&[u32]>,
        pick: Pick,
        winners: &mut Vec<u32>,
    ) -> Result<Option<usize>, Error> {
        winners.clear();
        let body = text.as_bytes();
        if at > body.len() {
            return Err(Error::Inconsistent {
                message: format!("scanned at {at} in a text of {} bytes", body.len()),
            });
        }
        // The admitted count is the widest answer possible, so this is the one
        // capacity at which the engine can never come up short and there is no
        // retry loop to write.
        let room = self.admitted;
        winners.resize(room, 0);
        let mut tok = sys::MunchToken::default();
        let lease = self.pool.lease()?;
        // SAFETY: the lease is exclusive to this thread; `body`, `allow` and
        // `winners` are live slices passed with their own lengths; `tok` is a
        // live slot. A `&str`'s pointer is never null and the header accepts a
        // zero length regardless, and `at <= body.len()` was checked above.
        let status = unsafe {
            sys::irgx_munch_scan(
                lease.raw(),
                body.as_ptr(),
                body.len(),
                at,
                allow.map_or(std::ptr::null(), <[u32]>::as_ptr),
                allow.map_or(0, <[u32]>::len),
                match pick {
                    Pick::Longest => sys::MUNCH_LONGEST,
                    Pick::Shortest => sys::MUNCH_SHORTEST,
                },
                &raw mut tok,
                winners.as_mut_ptr(),
                room,
            )
        };
        drop(lease);
        if status < 0 {
            winners.clear();
            return Err(fault(status, |status, detail| Error::Search {
                status,
                detail,
            }));
        }
        if status != sys::MATCH {
            winners.clear();
            return Ok(None);
        }
        if tok.count > room {
            // Only `room` patterns can win, so a larger count cannot be true.
            // Refusing beats trusting a length that says otherwise.
            winners.clear();
            return Err(Error::Inconsistent {
                message: format!(
                    "a slate admitting {room} patterns reported {} winning",
                    tok.count
                ),
            });
        }
        winners.truncate(tok.count);
        Ok(Some(tok.len))
    }

    /// [`Munch::scan_into`] into a fresh buffer, as a [`Token`].
    fn owned(
        &self,
        text: &str,
        at: usize,
        allow: Option<&[u32]>,
        pick: Pick,
    ) -> Result<Option<Token>, Error> {
        let mut winners = Vec::new();
        let Some(len) = self.scan_into(text, at, allow, pick, &mut winners)? else {
            return Ok(None);
        };
        Ok(Some(Token {
            len,
            patterns: winners.into(),
        }))
    }
}

/// Compile a [`Munch`] with the flags spelled out.
///
/// The flags apply to the whole slate, and that is forced rather than chosen:
/// the engine determinizes every pattern *together*, so "pattern 3 is
/// case-insensitive" is not a thing the machine can be. This is the one place
/// this type is less flexible than [`crate::RegexSetBuilder`], whose C ABI does
/// take a flag word per pattern.
///
/// ```
/// # fn main() -> Result<(), irgx::Error> {
/// let m = irgx::MunchBuilder::new(["let", "in"]).ignore_case(true).build()?;
/// assert_eq!(m.token("LET x", 0).unwrap().patterns(), &[0]);
/// # Ok(())
/// # }
/// ```
#[derive(Clone, Debug)]
pub struct MunchBuilder {
    patterns: Vec<String>,
    flags: u32,
}

impl MunchBuilder {
    /// A builder for `patterns`, with the same defaults as [`Munch::new`].
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

    /// Match without regard to case.
    pub fn ignore_case(&mut self, yes: bool) -> &mut Self {
        self.set(sys::IGNORE_CASE, yes)
    }

    /// Unicode-aware classes, folding, and boundaries. On by default.
    pub fn unicode(&mut self, yes: bool) -> &mut Self {
        // Inverted: the flag the ABI has is NO_UNICODE.
        self.set(sys::NO_UNICODE, !yes)
    }

    /// `.` matches a newline too.
    ///
    /// Present here and absent from [`crate::RegexSetBuilder`], where the slate
    /// plane has nowhere to carry it. Three planes, three flag masks; do not
    /// assume one from another.
    pub fn dot_matches_new_line(&mut self, yes: bool) -> &mut Self {
        self.set(sys::DOTALL, yes)
    }

    // `fixed`, `word`, `smart_case`, `pcre` and `multi_line` are deliberately
    // absent, and the engine refuses those five bits on a munch rather than
    // ignoring them. `pcre` because the PCRE2 arm has no
    // anchored-longest-over-N automaton, so there would be nothing to be longest
    // among; `word` because `\b` resolves against the byte before the caller's
    // offset, which is not in the text this automaton was determinized over;
    // `smart_case` because it is a question about one pattern's text and these
    // options are the whole slate's; `fixed` because a literal is already
    // expressible as a pattern, and a flag that rewrote every terminal
    // slate-wide is not what a lexer with a mix of literals and regexes wants.
    //
    // `multi_line` because an anchored automaton has no answer to the `(?m)`
    // question either way: it starts where the caller pointed, so `^` holds at
    // every scan offset regardless, and a longest-match walk never learns where
    // the buffer ended, so `$` and `\z` are reachable from neither. `\A` still
    // means the buffer's start and is false at a nonzero offset.
    //
    // A builder method that could only fail would be a worse way to say all
    // that than not having one.

    /// Compile it.
    ///
    /// # Errors
    ///
    /// As [`Munch::new`].
    pub fn build(&self) -> Result<Munch, Error> {
        let pool = Pool::new(Anchored {
            patterns: self.patterns.clone().into(),
            flags: self.flags,
        })?;
        let (declined, admitted) = survey(&pool)?;
        Ok(Munch {
            pool,
            declined,
            admitted,
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

/// The two facts a freshly compiled handle knows and a scan does not need to ask
/// again: what it declined, and how many patterns it seated.
///
/// One lease for both, because they are one description of one compile and a
/// second lease could in principle describe a different handle.
fn survey(pool: &Pool<Anchored>) -> Result<(Box<[Refusal]>, usize), Error> {
    let total = pool.recipe().patterns.len();
    // Sized at the pattern count, which the refusal list can never exceed, so
    // there is no short-buffer retry to write.
    let mut raw = vec![sys::MunchRefusal::default(); total];
    let lease = pool.lease()?;
    let mut written: usize = 0;
    // SAFETY: the lease is exclusive to this thread; `raw` is a live slice
    // passed with its own length; `written` is a live slot.
    let status = unsafe {
        sys::irgx_munch_declined(lease.raw(), raw.as_mut_ptr(), raw.len(), &raw mut written)
    };
    // SAFETY: as above — the lease is still live and exclusive.
    let admitted = unsafe { sys::irgx_munch_len(lease.raw()) };
    drop(lease);
    if status < 0 {
        return Err(fault(status, |status, detail| Error::Search {
            status,
            detail,
        }));
    }
    if written > total || admitted + written != total {
        // The two counts describe the same compile from opposite ends, so they
        // have to add up. Refusing beats sizing every later scan's buffer from a
        // number that disagrees with the refusal list beside it.
        return Err(Error::Inconsistent {
            message: format!(
                "a slate of {total} patterns reported {admitted} seated and {written} declined"
            ),
        });
    }
    let refusals = raw[..written]
        .iter()
        .map(|r| Refusal {
            pattern: r.pattern as usize,
            why: Why::of(r.why),
        })
        .collect();
    Ok((refusals, admitted))
}

/// What a [`Munch`]'s pool recompiles from: the patterns, and the one flag word
/// the whole slate shares.
struct Anchored {
    patterns: Box<[String]>,
    flags: u32,
}

impl Recipe for Anchored {
    type Raw = sys::Munch;

    fn compile(&self) -> Result<NonNull<sys::Munch>, Error> {
        // Borrowed, not copied: the engine reads the pattern bytes during
        // determinization and retains none of them, so this list only has to
        // outlive the call.
        let list: Vec<sys::MunchPattern> = self
            .patterns
            .iter()
            .map(|one| sys::MunchPattern {
                pattern: one.as_ptr(),
                len: one.len(),
            })
            .collect();
        let mut out: *mut sys::Munch = std::ptr::null_mut();
        // SAFETY: `list` is a live slice passed with its own length, whose
        // elements borrow live `String`s; `out` is a live slot the library writes
        // at most once.
        let status =
            unsafe { sys::irgx_munch_compile(list.as_ptr(), list.len(), self.flags, &raw mut out) };
        // `IRGX_STALE` here is not "needs PCRE2", which is what it means to
        // `irgx_compile`; it is the engine saying it could determinize nothing at
        // all. Mapping it onto `NeedsPcre` would send a caller to retry on an arm
        // that has no anchored plane to retry with.
        if status == sys::STALE {
            return Err(Error::NothingLexable {
                offered: self.patterns.len(),
            });
        }
        if status < 0 {
            return Err(fault(status, |status, detail| Error::Search {
                status,
                detail,
            }));
        }
        crate::pool::wrote(out, "irgx_munch_compile")
    }

    unsafe fn release(raw: NonNull<sys::Munch>) {
        // SAFETY: the caller promises `raw` came from `compile` above and has not
        // been released.
        unsafe { sys::irgx_munch_free(raw.as_ptr()) }
    }
}

impl Clone for Munch {
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
            MunchBuilder {
                patterns: slate.patterns.to_vec(),
                flags: slate.flags,
            }
            .build(),
        )
    }
}

impl std::fmt::Debug for Munch {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Munch")
            .field("patterns", &self.patterns())
            .field("declined", &self.declined)
            .finish()
    }
}
