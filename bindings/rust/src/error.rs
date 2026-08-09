//! The error type, and the one place a negative status becomes one.
//!
//! The C ABI answers with a status code and leaves per-incident detail in a
//! thread-local fault slot. A binding that surfaced the number would make every
//! caller re-learn the vocabulary, so nothing above this module ever sees an
//! `i32`: [`fault`] reads the status sentence and the fault name together and
//! returns a typed [`Error`].
//!
//! Three rules the file keeps. `IRGX_OOM` gets its own variant, because
//! "the machine is out of memory" and "your pattern is wrong" call for
//! different handling. No negative status is ever treated as a result, because
//! folding one into "no match" is how a binding reports a failure as an answer.
//!
//! And a refused pattern is sorted by its **status code**, never by the fault
//! name behind it. The header spends two paragraphs on this: `IRGX_STALE`
//! means the linear grammar declined something PCRE2 can express, and
//! `IRGX_INVALID` means nothing here accepts it. Those are different
//! outcomes with different repairs, they are decidable from the return value
//! alone, and the engine decides between them by asking PCRE2 rather than by
//! consulting a list of constructs that could drift from it. Matching on the
//! fault string would re-introduce exactly the drift the seam removed.

use std::fmt;

use crate::sys;

/// One raw status code from the C ABI, with the library's own sentence for it.
///
/// Public because an unrecognized negative status is still a real answer and a
/// caller logging it should be able to print the number the engine used.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct Status(i32);

impl Status {
    /// A tier declined, and the caller is expected to answer through its
    /// fallback. The one negative status that is not a failure.
    pub const DECLINED: Self = Self(sys::STALE);

    /// The engine ran out of memory.
    pub const OUT_OF_MEMORY: Self = Self(sys::OOM);

    /// An argument the library will not accept. Also what this crate reports for
    /// an argument it refuses on the library's behalf, rather than passing down a
    /// value the ABI has no way to express.
    pub const INVALID: Self = Self(sys::INVALID);

    /// The raw code, as `irgx.h` spells it.
    #[must_use]
    pub const fn code(self) -> i32 {
        self.0
    }

    /// The library's static human sentence for this code.
    #[must_use]
    pub fn message(self) -> &'static str {
        sys::status_message(self.0)
    }
}

impl fmt::Display for Status {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let text = self.message();
        if text.is_empty() {
            return write!(f, "status {}", self.0);
        }
        write!(f, "{text} (status {})", self.0)
    }
}

impl fmt::Debug for Status {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Status({}: {})", self.0, self.message())
    }
}

/// An answer, or the tier declining to give one.
///
/// `IRGX_STALE` is the one negative status that is not a failure: a tier says it
/// will not answer *this* question and installs no fault, so the caller is meant
/// to fall back rather than to handle an error. Folding it into `Err` would make
/// a routine handoff look like a defect, and folding it into an empty `Ok` would
/// make "the index has no locate layer" indistinguishable from "the pattern does
/// not occur" — which are opposite instructions.
///
/// So it is neither. A verb that can decline answers with this, and the two
/// cases are decidable without looking at a status code:
///
/// ```
/// # use irgx::{Answer, codex::Codex};
/// # let codex = Codex::build(b"mississippi")?;
/// match codex.locate(b"ssi")? {
///     Answer::Given(offsets) => assert_eq!(offsets, [2, 5]),
///     // Built without the locate layer: ask a tier that has one.
///     Answer::Declined => {},
/// }
/// # Ok::<(), irgx::Error>(())
/// ```
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Answer<T> {
    /// The tier answered.
    Given(T),
    /// The tier declined, with no fault behind it. Ask something else.
    Declined,
}

impl<T> Answer<T> {
    /// The answer, or `None` for a declinature.
    ///
    /// The conversion to lose the distinction, for a caller whose fallback is
    /// the same either way.
    pub fn given(self) -> Option<T> {
        match self {
            Self::Given(value) => Some(value),
            Self::Declined => None,
        }
    }

    /// Whether the tier stepped aside.
    #[must_use]
    pub fn is_declined(&self) -> bool {
        matches!(self, Self::Declined)
    }

    /// Transform the answer, leaving a declinature a declinature.
    pub fn map<U>(self, f: impl FnOnce(T) -> U) -> Answer<U> {
        match self {
            Self::Given(value) => Answer::Given(f(value)),
            Self::Declined => Answer::Declined,
        }
    }
}

impl<T> From<Answer<T>> for Option<T> {
    fn from(answer: Answer<T>) -> Self {
        answer.given()
    }
}

/// Everything that can go wrong between a pattern and an answer.
#[derive(Clone, Debug, PartialEq, Eq)]
#[non_exhaustive]
pub enum Error {
    /// The engine would not compile this pattern, and said nothing about where.
    ///
    /// The refusals with no position are the engine's own ceilings rather than
    /// a misplaced character - a pattern whose determinised form is too large,
    /// too many alternatives, a literal too short to index. There is no offset
    /// to point at because no single byte is the problem. A malformed pattern
    /// is [`Error::Syntax`], which does have one.
    Pattern {
        /// The pattern source, as it was given.
        pattern: String,
        /// The status the refusal crossed the seam as.
        status: Status,
        /// The engine's per-incident fault name, when it left one.
        detail: Option<String>,
    },
    /// A search over a valid pattern could not complete.
    Search {
        /// The status the failure crossed the seam as.
        status: Status,
        /// The engine's per-incident fault name, when it left one.
        detail: Option<String>,
    },
    /// The engine's capture arm will not compile this pattern, so group detail
    /// is unavailable for its matches. Searching still works: `is_match`,
    /// `find` and `find_iter` answer, and only the `captures` family cannot.
    Groups {
        /// The pattern source, as it was given.
        pattern: String,
        /// The status the refusal crossed the seam as.
        status: Status,
        /// The engine's per-incident fault name, when it left one.
        detail: Option<String>,
    },
    /// The engine could not allocate. Kept separate from every other failure
    /// because it says nothing about the pattern.
    OutOfMemory {
        /// The engine's per-incident fault name, when it left one.
        detail: Option<String>,
    },
    /// The linked library speaks a different C ABI than this crate was written
    /// against. Reported instead of read, because the alternative to a loud
    /// failure here is a struct misread quietly somewhere else.
    Abi {
        /// The ABI version this crate speaks.
        expected: u32,
        /// The ABI version the linked library reports.
        found: u32,
    },
    /// A match boundary landed inside a UTF-8 codepoint, so the span cannot
    /// slice the caller's `&str`.
    ///
    /// Reachable with `unicode(false)`, where the engine matches bytes and a
    /// pattern like `.` can legitimately stop mid-codepoint. It is an error and
    /// not a panic because the caller chose byte semantics and deserves to hear
    /// which offset the choice produced.
    NotCharBoundary {
        /// The byte offset that fell inside a codepoint.
        offset: usize,
    },
    /// The engine's own arms disagreed about a match. Not a caller error;
    /// reported rather than papered over, because inventing a plausible answer
    /// from two contradictory ones is how a binding launders an engine bug.
    Inconsistent {
        /// What the two arms each said.
        message: String,
    },
    // Appended, and new variants belong here too. Inserting one further up
    // renumbers every variant after it, which `cargo-semver-checks` reports as
    // a break even when the enum carries data in every variant and so cannot be
    // cast to an integer at all.
    /// The pattern is well formed, but the linear grammar cannot express it -
    /// lookaround, a backreference, an atomic group, an inline flag group. The
    /// PCRE2 arm can, and compiling the same pattern with
    /// [`RegexBuilder::pcre(true)`](crate::RegexBuilder::pcre) succeeds.
    ///
    /// This is the engine stepping aside rather than failing, so there is no
    /// fault behind it and nothing to report but the repair:
    ///
    /// ```
    /// use irgx::{Error, Regex, RegexBuilder};
    ///
    /// let pattern = r"(?<=\$)\d+";
    /// let re = match Regex::new(pattern) {
    ///     Err(Error::NeedsPcre { .. }) => RegexBuilder::new(pattern).pcre(true).build(),
    ///     other => other,
    /// }?;
    /// assert_eq!(re.find("cost $42").unwrap().as_str(), "42");
    /// # Ok::<(), Error>(())
    /// ```
    ///
    /// Retrying is a decision, not a formality: the linear engine is linear in
    /// the length of the text and the PCRE2 arm is not, so a program that
    /// accepts patterns from someone else may prefer to report this instead.
    NeedsPcre {
        /// The pattern source, as it was given.
        pattern: String,
    },
    /// The pattern is malformed, and no arm of the engine accepts it -
    /// [`RegexBuilder::pcre`](crate::RegexBuilder::pcre) will not rescue it.
    ///
    /// Distinct from [`Error::NeedsPcre`], which is a grammar this build
    /// declined rather than a pattern nobody can read.
    Syntax {
        /// The pattern source, as it was given.
        pattern: String,
        /// Where the engine detected the problem, as a byte offset into
        /// `pattern`. Never past its end, and always on a `char` boundary, so
        /// `&pattern[..at]` is the text the engine got through.
        at: usize,
        /// The status the refusal crossed the seam as.
        status: Status,
        /// The engine's per-incident fault name, when it left one.
        detail: Option<String>,
    },
    /// A [`Munch`](crate::Munch) whose every pattern the engine declined, so
    /// there is no automaton behind it and no scan it could answer.
    ///
    /// The only refusal that plane has, and it exists because a *partial* one is
    /// not an error there: a lexer with one undeterminizable terminal keeps the
    /// other hundred and fifty and reads what it lost from
    /// [`Munch::declined`](crate::Munch::declined). Losing all of them leaves
    /// nothing to read, so it crosses as this instead.
    ///
    /// Compiling *no* patterns is not this — an empty slate is a legal slate
    /// that matches nothing, as an empty [`RegexSet`](crate::RegexSet) is.
    NothingLexable {
        /// How many patterns were offered, every one of which was declined.
        offered: usize,
    },
    /// A search window whose end is before its start.
    ///
    /// Refused here rather than passed down because the ABI answers a crossed
    /// pair with the same `IRGX_INVALID` it uses for an out-of-range one, so the
    /// caller would not learn which of the two mistakes it made. It carries no
    /// [`Status`] for the same reason it is a distinct variant: the engine never
    /// saw the call, and reporting a code it did not return would be inventing a
    /// verdict.
    BadWindow {
        /// Where the window was asked to begin.
        start: usize,
        /// Where it was asked to end — less than `start`, which is the defect.
        end: usize,
    },
    /// A plane outside the regex face could not answer: the corpus search, the
    /// walk, the sieve, the codex, the needle set, the line grid, the Unicode
    /// tables.
    ///
    /// One variant for all of them rather than seven, because the repair is the
    /// same shape in every case — read `plane` for what was asked and the
    /// [`Status`] and fault detail for why it was refused. These planes touch
    /// the filesystem, so unlike a pattern refusal the fault behind one often
    /// names a *path* rather than an offset, and that path is folded into
    /// `detail`.
    Plane {
        /// Which plane refused, spelled as the ABI verb family: `"tree"`,
        /// `"walk"`, `"sieve"`, `"winnow"`, `"codex"`, `"needles"`,
        /// `"literals"`, `"lines"`, `"unicode"`.
        plane: &'static str,
        /// The status the refusal crossed the seam as.
        status: Status,
        /// The engine's per-incident fault name, and the path it was about when
        /// there was one.
        detail: Option<String>,
    },
    /// A `cap`/`written` verb kept asking for a larger buffer than the one it
    /// had just been given.
    ///
    /// The protocol is that a short `cap` comes back with the count the answer
    /// *needs*, so one retry at that size is enough. A plane reading a tree that
    /// is being written underneath it can legitimately grow between two calls,
    /// so the retry is bounded and this is what running out looks like — an
    /// honest "the corpus would not hold still", never a truncated answer
    /// wearing a success code.
    Unsettled {
        /// Which plane could not be sized. Spelled as in [`Error::Plane`].
        plane: &'static str,
        /// The size of the last buffer offered.
        offered: usize,
        /// The size it asked for after that.
        wanted: usize,
    },
}

impl Error {
    /// Whether this is an allocation failure.
    #[must_use]
    pub fn is_out_of_memory(&self) -> bool {
        matches!(self, Self::OutOfMemory { .. })
    }

    /// The raw status behind this error, when one crossed the seam.
    #[must_use]
    pub fn status(&self) -> Option<Status> {
        match self {
            Self::Pattern { status, .. }
            | Self::Syntax { status, .. }
            | Self::Search { status, .. }
            | Self::Plane { status, .. }
            | Self::Groups { status, .. } => Some(*status),
            Self::NeedsPcre { .. } => Some(Status::DECLINED),
            Self::OutOfMemory { .. } => Some(Status::OUT_OF_MEMORY),
            _ => None,
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NeedsPcre { pattern } => write!(
                f,
                "the linear grammar cannot express `{pattern}`, but the PCRE2 arm can: \
                 compiling it with RegexBuilder::pcre(true) accepts this pattern. That arm \
                 is not linear in the length of the text, which is why it is opt-in."
            ),
            Self::Syntax {
                pattern,
                at,
                status,
                detail,
            } => {
                write!(f, "cannot compile pattern `{pattern}`: at byte {at}, ")?;
                write_reason(f, *status, detail.as_deref())
            },
            Self::Pattern {
                pattern,
                status,
                detail,
            } => {
                write!(f, "cannot compile pattern `{pattern}`: ")?;
                write_reason(f, *status, detail.as_deref())
            },
            Self::Search { status, detail } => {
                write!(f, "search failed: ")?;
                write_reason(f, *status, detail.as_deref())
            },
            Self::Groups {
                pattern,
                status,
                detail,
            } => {
                write!(
                    f,
                    "the capture engine will not compile `{pattern}`, so group detail is \
                     unavailable for its matches (searching still works): "
                )?;
                write_reason(f, *status, detail.as_deref())
            },
            Self::OutOfMemory { detail } => {
                write!(f, "the engine ran out of memory: ")?;
                write_reason(f, Status::OUT_OF_MEMORY, detail.as_deref())
            },
            Self::Abi { expected, found } => write!(
                f,
                "irregex ABI mismatch: this crate speaks ABI {expected}, but the linked \
                 library reports ABI {found}. Link a matching pair, or unset IRGX_LIB_DIR."
            ),
            Self::NotCharBoundary { offset } => write!(
                f,
                "the engine reported a match boundary at byte {offset}, which is inside a \
                 UTF-8 codepoint; that span cannot slice the searched string. A pattern \
                 compiled with unicode(false) matches bytes, so this is the byte semantics \
                 you asked for showing through."
            ),
            Self::Inconsistent { message } => {
                write!(f, "internal disagreement in the engine: {message}")
            },
            Self::NothingLexable { offered } => write!(
                f,
                "none of the {offered} patterns offered could be determinized as an anchored \
                 automaton, so the munch has nothing to scan with. Compiling them one at a time \
                 with Regex::new says which, and why."
            ),
            Self::BadWindow { start, end } => write!(
                f,
                "the search window ends at byte {end}, before it starts at {start}. \
                 Bounds are not clamped, because a miscomputed one is worth hearing about."
            ),
            Self::Plane {
                plane,
                status,
                detail,
            } => {
                write!(f, "the {plane} plane could not answer: ")?;
                write_reason(f, *status, detail.as_deref())
            },
            Self::Unsettled {
                plane,
                offered,
                wanted,
            } => write!(
                f,
                "the {plane} plane asked for {wanted} rows after being offered {offered}, and \
                 kept growing across every retry. The answer is over something that is still \
                 being written; ask again when it has settled."
            ),
        }
    }
}

fn write_reason(f: &mut fmt::Formatter<'_>, status: Status, detail: Option<&str>) -> fmt::Result {
    match detail {
        Some(name) => write!(f, "{name}; {status}"),
        None => write!(f, "{status}"),
    }
}

impl std::error::Error for Error {}

/// The typed error for a negative `status` from this thread's last call.
///
/// `build` decides which variant the status belongs in; this function's job is
/// to attach the fault detail while it is still readable. The header says the
/// fault slot holds the last failure *on this thread*, so the read has to
/// happen here, before the caller does anything else with the library.
pub(crate) fn fault(status: i32, build: impl FnOnce(Status, Option<String>) -> Error) -> Error {
    debug_assert!(status < 0, "a non-negative status is not a failure");
    let detail = last_fault();
    if status == sys::OOM {
        return Error::OutOfMemory {
            detail: detail.map(|found| found.text),
        };
    }
    build(Status(status), detail.map(|found| found.text))
}

/// The typed error for a negative `status` from a plane outside the regex face.
///
/// The one call every corpus, index and table verb makes on a failure, so which
/// plane refused is a word at the call site instead of a variant per plane. Never
/// pass `IRGX_STALE` here: that status installs no fault, so this would attach an
/// unrelated one and report a handoff as a failure. Decline it before you get
/// this far — see [`Answer`].
pub(crate) fn plane_fault(status: i32, plane: &'static str) -> Error {
    debug_assert_ne!(status, sys::STALE, "a declinature is not a plane failure");
    fault(status, |status, detail| Error::Plane {
        plane,
        status,
        detail,
    })
}

/// The typed error for a negative `status` from compiling `pattern`.
///
/// Compile is the one verb with two ways to say no, and the whole point of the
/// seam is that they are told apart by the **status code** before anything
/// looks at a fault. `IRGX_STALE` returns here without reading the fault
/// slot at all - not as an optimization, but because the slot still holds this
/// thread's *previous* failure, and a declinature that reported it would blame
/// an unrelated pattern for stepping aside.
pub(crate) fn compile_refusal(status: i32, pattern: &str) -> Error {
    debug_assert!(status < 0, "a non-negative status is not a refusal");
    if status == sys::STALE {
        return Error::NeedsPcre {
            pattern: pattern.to_owned(),
        };
    }
    let detail = last_fault();
    if status == sys::OOM {
        return Error::OutOfMemory {
            detail: detail.map(|found| found.text),
        };
    }
    // A position only means a byte in the pattern for the status that says the
    // pattern is the problem, and only if it lands somewhere the caller can
    // actually slice to. Anything else is a refusal with no place to point.
    let at = detail
        .as_ref()
        .filter(|_| status == sys::INVALID)
        .and_then(|found| found.at)
        .filter(|at| pattern.is_char_boundary(*at));
    let (pattern, detail) = (pattern.to_owned(), detail.map(|found| found.text));
    match at {
        Some(at) => Error::Syntax {
            pattern,
            at,
            status: Status(status),
            detail,
        },
        None => Error::Pattern {
            pattern,
            status: Status(status),
            detail,
        },
    }
}

/// What the engine left in this thread's fault slot.
struct Detail {
    /// The fault name, and the file it was about when there was one.
    text: String,
    /// A byte offset into the PATTERN, when the fault carried one measured in
    /// that space.
    at: Option<usize>,
}

/// This thread's last fault, read once.
///
/// Once, because the name, the path and the offset are one incident: reading
/// them from separate calls would let a work call in between swap the slot and
/// pair an offset with the wrong name.
///
/// Absence is normal, not a second failure: the header is explicit that a
/// non-OK status does not imply a detail exists, because an argument guard has
/// nothing to add over its own status sentence.
fn last_fault() -> Option<Detail> {
    let mut slot = sys::Fault::default();
    // SAFETY: `slot` is a live, correctly-sized `irgx_fault` whose
    // `struct_size` we set, which is exactly what the header requires; the
    // library only writes through the pointer for the duration of the call.
    if unsafe { sys::irgx_last_fault(&raw mut slot) } != sys::MATCH {
        return None;
    }
    if slot.name.is_null() {
        return None;
    }
    // SAFETY: the header documents `name` as a static, NUL-terminated string
    // that is never NULL when a fault was written; we checked for NULL anyway.
    let name = unsafe { std::ffi::CStr::from_ptr(slot.name) }
        .to_str()
        .ok()?;
    if name.is_empty() {
        return None;
    }
    // The offset states which ruler it is measured in, so `Detail::at` — which
    // exists to index the pattern the caller handed over — may only take a
    // pattern-space one. The corpus planes ([`crate::corpus`]) reach the other
    // space: `AT_FILE` is measured inside the file `path` names, and putting it
    // in `at` would point a caret under the pattern at a byte from a different
    // document. It is not thrown away, though — it goes into the text beside the
    // file it belongs to, which is the only place it means anything.
    let offset = usize::try_from(slot.at).ok();
    let at = (slot.at_space == sys::AT_PATTERN)
        .then_some(offset)
        .flatten();
    let path = (!slot.path.is_null() && slot.path_len > 0).then(|| {
        // SAFETY: the header documents `path` / `path_len` as a borrowed byte
        // span valid until this thread's next work call, and no such call happens
        // between the `irgx_last_fault` above and this read.
        let bytes = unsafe { std::slice::from_raw_parts(slot.path, slot.path_len) };
        String::from_utf8_lossy(bytes)
    });
    let text = match (path, slot.at_space == sys::AT_FILE, offset) {
        (Some(path), true, Some(offset)) => format!("{name} at {path}:{offset}"),
        (Some(path), _, _) => format!("{name} at {path}"),
        (None, _, _) => name.to_owned(),
    };
    Some(Detail { text, at })
}
