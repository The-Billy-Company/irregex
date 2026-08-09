//! Rust bindings for the irregex regex engine.
//!
//! The API is the `regex` crate's shape - [`Regex::new`], [`Regex::is_match`],
//! [`Regex::find`], [`Regex::find_iter`], [`Regex::captures`],
//! [`Regex::split`], [`Regex::replace_all`] - because that is the API a Rust
//! programmer already knows. What is behind it is a Zig engine linked into your
//! process, reached through a small C ABI.
//!
//! ```
//! # fn main() -> Result<(), irgx::Error> {
//! let re = irgx::Regex::new(r"(\w+)@(\w+)")?;
//! let caps = re.captures("mail bob@host now").unwrap();
//! assert_eq!(&caps[1], "bob");
//! assert_eq!(caps.get(2).unwrap().as_str(), "host");
//! # Ok(())
//! # }
//! ```
//!
//! # Compiling, and the two ways a pattern is refused
//!
//! There are two grammars here, so a refused pattern splits into two facts with
//! two different repairs, and they are two variants rather than one string.
//!
//! [`Error::NeedsPcre`] means the pattern is fine and only the linear grammar
//! cannot express it - lookaround, a backreference, a flag letter it does not
//! have (`(?x)`, `(?U)`, `(?R)`). A *leading* `(?i)` is not in that list: it is
//! read as the flag it asks for, as `regex` reads it, and compiles. The
//! same pattern under [`RegexBuilder::pcre`] compiles, so the retry is a match
//! arm:
//!
//! ```
//! use irgx::{Error, Regex, RegexBuilder};
//!
//! fn compile(pattern: &str) -> Result<Regex, Error> {
//!     match Regex::new(pattern) {
//!         Err(Error::NeedsPcre { .. }) => RegexBuilder::new(pattern).pcre(true).build(),
//!         other => other,
//!     }
//! }
//!
//! assert_eq!(compile(r"(?<=\$)\d+")?.find("cost $42").unwrap().as_str(), "42");
//! # Ok::<(), Error>(())
//! ```
//!
//! It is not retried for you because the PCRE2 arm is not linear in the length
//! of the text, and a program compiling somebody else's patterns may want to
//! decline rather than accept that.
//!
//! [`Error::Syntax`] means the pattern is malformed, and carries the byte offset
//! the engine stopped at. `pcre` will not rescue it, so retrying only fails
//! twice. The offset is always a real index into the pattern - never past the
//! end, never mid-codepoint - so `&pattern[..at]` is what the engine got
//! through:
//!
//! ```
//! # use irgx::{Error, Regex};
//! let Err(Error::Syntax { at, .. }) = Regex::new("(unclosed") else { unreachable!() };
//! assert_eq!(at, 9);
//! ```
//!
//! # Threads
//!
//! [`Regex`] is `Send + Sync`, so the idiom works:
//!
//! ```
//! use std::sync::LazyLock;
//! use irgx::Regex;
//!
//! static WORD: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\w+").unwrap());
//!
//! let total: usize = std::thread::scope(|scope| {
//!     let handles: Vec<_> = ["one two", "three", "four five six"]
//!         .map(|text| scope.spawn(move || WORD.find_iter(text).count()))
//!         .into_iter()
//!         .collect();
//!     handles.into_iter().map(|h| h.join().unwrap()).sum()
//! });
//! assert_eq!(total, 6);
//! ```
//!
//! The C handle underneath is single-threaded: it owns the scratch its searches
//! run in. So a `Regex` owns a pool of handles and leases one per search. The
//! cost is one extra compile the first time a given level of concurrency is
//! reached, an uncontended mutex per search, and handles freed when the `Regex`
//! drops. Nothing is thread-bound and nothing leaks into a thread that outlives
//! the pattern.
//!
//! # Offsets are bytes
//!
//! [`Match::start`] and [`Match::end`] are byte offsets into the `&str` you
//! searched, which is the engine's own coordinate system - `&text[m.range()]`
//! is the matched text, no translation involved. A pattern compiled with
//! [`RegexBuilder::unicode`] off matches bytes, so it can report a boundary
//! inside a codepoint; that is [`Error::NotCharBoundary`] rather than a panic in
//! your slicing code.
//!
//! # How this differs from the `regex` crate
//!
//! * **[`Regex::find_iter`] is eager**, and therefore knows its length and runs
//!   backwards. The sequence itself is the `regex` crate's, empty matches
//!   included — `a*` over `"abc"` is `(0,1), (2,2), (3,3)` in both — and the
//!   differential in `tests/sequence.rs` holds it there over a corpus of
//!   nullable patterns.
//! * **Lookaround and backreferences exist**, behind
//!   [`RegexBuilder::pcre`]. The default engine is linear in the length of the
//!   text; the PCRE2 arm is not. A pattern that needs the other arm is
//!   [`Error::NeedsPcre`], not a syntax error, so `regex`'s single
//!   `Error::Syntax(String)` becomes two variants here.
//! * **[`RegexBuilder::fixed`], [`RegexBuilder::word`] and
//!   [`RegexBuilder::smart_case`] are first-class flags**, not things you build
//!   by rewriting the pattern.
//! * **Faults are possible after compiling.** The `regex`-shaped verbs panic on
//!   one; each has a `try_` sibling that returns [`Error`].
//! * **[`Munch`] has no `regex`-crate counterpart at all.** It answers the
//!   question a tokenizer asks and a search cannot: starting at exactly this
//!   offset, over these patterns, which reaches furthest? Maximal munch, with the
//!   permitted set narrowed per call, which is what makes a state-directed lexer
//!   possible without stepping the automaton by hand.
//!
//! # Linking
//!
//! The crate carries a prebuilt static archive per supported target, so the
//! usual build needs no Zig toolchain. `IRGX_LIB_DIR` points the build at a
//! library you built yourself instead. A target with no vendored archive falls
//! back to building the engine from source, and fails at build time with a
//! sentence if it cannot.

#![forbid(unsafe_op_in_unsafe_fn)]

mod error;
mod matches;
mod munch;
mod pattern;
mod pool;
mod replace;
mod set;
mod sys;

/// Shared contract mirrors — engine/analytic/kinship constants and row tables.
#[allow(missing_docs)]
pub mod contract;
/// The unified `SearchRequest` → match stream for the exact plane.
#[allow(missing_docs)]
pub mod request;
/// Transports, the analytic ladder, and the substrate [`runtime::Error`].
///
/// Distinct from the crate-root [`Error`], which is the regex face's refusal
/// vocabulary. Analytic/search callers use [`runtime::Error`].
#[allow(clippy::undocumented_unsafe_blocks, missing_docs)]
pub mod runtime;

pub use crate::error::{Error, Status};
pub use crate::matches::{CaptureMatches, Captures, Match, Matches, Split};
pub use crate::munch::{Munch, MunchBuilder, Pick, Refusal, Token, Why};
pub use crate::pattern::{Regex, RegexBuilder};
pub use crate::replace::{NoExpand, Replacer};
pub use crate::set::{RegexSet, RegexSetBuilder, SetMatches};

/// The C-ABI version this crate speaks. The linked library must report the same
/// number or every [`Regex::new`] fails with [`Error::Abi`].
pub const ABI_VERSION: u32 = sys::ABI_VERSION;

/// The linked engine's semantic version, e.g. `"1.0.0"`.
///
/// Distinct from this crate's version: one crate release can carry a newer
/// engine without an API change.
#[must_use]
pub fn engine_version() -> &'static str {
    sys::engine_version()
}

/// The vendored PCRE2 version the [`RegexBuilder::pcre`] arm runs on.
#[must_use]
pub fn pcre2_version() -> &'static str {
    sys::pcre2_version()
}
