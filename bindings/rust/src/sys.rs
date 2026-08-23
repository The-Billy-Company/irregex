//! The `extern "C"` seam onto `libirgx`, and the ABI gate in front of it.
//!
//! Nothing above this module names a status code, a raw pointer, or a C type.
//! Every declaration here is transcribed from `irgx.h`; the layouts are
//! `repr(C)` mirrors of the structs in that header and must be changed only in
//! lockstep with it.
//!
//! The engine is linked, not loaded: `build.rs` resolves a static archive (or a
//! shared library) at build time, so a missing symbol is a link error rather
//! than a runtime surprise. What *cannot* be settled at build time is whether
//! the library that got linked speaks the ABI this crate was written against -
//! a vendored archive is version-locked, but `IRGX_LIB_DIR` deliberately
//! lets someone substitute their own build. So the version is checked once, on
//! first use, and a mismatch is an error at every entry point instead of a
//! misread struct somewhere downstream.

use std::ffi::{CStr, c_char};
use std::sync::LazyLock;

/// The only C-ABI version this crate knows how to speak. The header promises
/// this bumps on any breaking change, so refusing anything else is the whole
/// point of it existing.
pub const ABI_VERSION: u32 = 2;

/// `IRGX_MATCH`. Success is any non-negative status; this is the one that
/// also means "there was at least one match", so it is the only success code the
/// crate needs to name.
pub const MATCH: i32 = 1;
/// `IRGX_STALE`, the one negative status that is not an error. A tier
/// declined and the caller is meant to answer through its fallback, so the
/// header is explicit that no fault is installed for it.
pub const STALE: i32 = -1;
/// `IRGX_OOM`, the one negative status that says nothing about the pattern.
pub const OOM: i32 = -2;
/// `IRGX_INVALID`, which for a compile means nothing here accepts the
/// pattern - not even the PCRE2 arm.
pub const INVALID: i32 = -4;

/// Which ruler [`Fault::at`] is measured in, from the `IRGX_AT_*` block.
/// One offset with two possible subjects, stated rather than inferred: reading
/// it out of a NULL `path` was a conjunction every consumer wrote for itself,
/// and a missed clause points a caret at the wrong string.
pub const AT_NONE: i32 = 0;
/// A byte offset within the fault's `path`, which only a library that walks a
/// corpus can produce.
pub const AT_FILE: i32 = 1;
/// A byte offset within the pattern that was being compiled.
pub const AT_PATTERN: i32 = 2;

/// Pattern semantics, from the `IRGX_*` block in `irgx.h`. Bits 3, 4 and
/// 7 are deliberately absent: the sibling search library claims them for its
/// own behavioral flags, and one numbering across the ecosystem is the point.
pub const FIXED: u32 = 1 << 0;
pub const IGNORE_CASE: u32 = 1 << 1;
pub const WORD: u32 = 1 << 2;
pub const SMART_CASE: u32 = 1 << 5;
pub const NO_UNICODE: u32 = 1 << 6;
pub const PCRE: u32 = 1 << 8;
pub const MULTILINE: u32 = 1 << 9;
pub const DOTALL: u32 = 1 << 10;

/// An opaque compiled pattern. Never dereferenced on this side.
#[repr(C)]
pub struct Regex {
    _opaque: [u8; 0],
}

/// An opaque compiled slate — many patterns over one text. Never dereferenced
/// on this side.
#[repr(C)]
pub struct Slate {
    _opaque: [u8; 0],
}

/// An opaque compiled anchored slate — the longest of many patterns starting at
/// one offset. Never dereferenced on this side.
#[repr(C)]
pub struct Munch {
    _opaque: [u8; 0],
}

/// `irgx_munch_pattern`: one terminal of a lexer slate. No flag word, because a
/// munch determinizes every pattern together under one set of options.
#[repr(C)]
pub struct MunchPattern {
    pub pattern: *const u8,
    pub len: usize,
}

/// `irgx_munch_refusal`: one pattern the slate could not take, and why.
#[derive(Clone, Copy, Debug, Default)]
#[repr(C)]
pub struct MunchRefusal {
    pub pattern: u32,
    pub why: u32,
}

/// `IRGX_MUNCH_SYNTAX`: the parser rejected the pattern.
pub const MUNCH_SYNTAX: u32 = 0;
/// `IRGX_MUNCH_STATES`: the engine's `max_states` bound, a fact about the build.
pub const MUNCH_STATES: u32 = 1;
/// `IRGX_MUNCH_WORD_CONTEXT`: `\b`, with no left context for it to resolve
/// against.
pub const MUNCH_WORD_CONTEXT: u32 = 2;
/// `IRGX_MUNCH_BUFFER_ANCHOR`: `\A` or `\z`, which no build's budget admits.
pub const MUNCH_BUFFER_ANCHOR: u32 = 3;

/// `irgx_munch_token`: how far a scan reached, and how many patterns got there.
#[derive(Clone, Copy, Debug, Default)]
#[repr(C)]
pub struct MunchToken {
    pub len: usize,
    pub count: usize,
}

/// `IRGX_MUNCH_LONGEST`: maximal munch.
pub const MUNCH_LONGEST: u32 = 0;
/// `IRGX_MUNCH_SHORTEST`: the shortest non-empty reading instead.
pub const MUNCH_SHORTEST: u32 = 1;

/// `irgx_slate_pattern`: one pattern of a slate, and the flag word
/// [`irgx_compile`] takes for a single one.
#[repr(C)]
pub struct SlatePattern {
    pub pattern: *const u8,
    pub len: usize,
    pub flags: u32,
}

/// `irgx_span`: one byte range `[start, end)`, or `(-1, -1)` for a capture
/// group the match did not enter.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[repr(C)]
pub struct Span {
    pub start: i64,
    pub end: i64,
}

impl Span {
    /// The span as a byte range, or `None` for a group that did not participate.
    ///
    /// Either coordinate being negative is enough to mean absence: the header
    /// spells it `{-1, -1}`, and treating a half-negative pair as a range would
    /// turn a malformed answer into a panic far from here.
    pub fn range(self) -> Option<(usize, usize)> {
        if self.start < 0 || self.end < 0 {
            return None;
        }
        Some((self.start as usize, self.end as usize))
    }
}

/// `irgx_fault`: per-incident detail for this thread's last failure.
#[repr(C)]
pub struct Fault {
    pub struct_size: u32,
    pub status: i32,
    pub at_space: i32,
    pub name: *const c_char,
    pub path: *const u8,
    pub path_len: usize,
    pub at: u64,
}

impl Default for Fault {
    fn default() -> Self {
        Self {
            struct_size: size_of::<Self>() as u32,
            status: 0,
            at_space: AT_NONE,
            name: std::ptr::null(),
            path: std::ptr::null(),
            path_len: 0,
            at: 0,
        }
    }
}

/// `irgx_text`: a borrowed UTF-8 span, not NUL-terminated, `len`
/// authoritative. The library's one string shape - it is how a group name comes
/// back and how the row protocol carries every field - so one reader serves
/// both.
///
/// `Copy` because it is two words of borrowed span and every plane that answers
/// with a list of them fills a `Vec<Text>` the library writes into directly.
#[derive(Clone, Copy)]
#[repr(C)]
pub struct Text {
    pub ptr: *const u8,
    pub len: usize,
}

impl Default for Text {
    fn default() -> Self {
        Self {
            ptr: std::ptr::null(),
            len: 0,
        }
    }
}

/// The bytes an `irgx_text` names, borrowed for `'a`.
///
/// Every plane that answers with borrowed spans — the literal sets, a tree
/// record's path and line, a walk entry, a sieve's document paths — reads them
/// through here, so the null-and-empty case is handled once. An empty span comes
/// back as an empty slice rather than a dangling one.
///
/// # Safety
///
/// `text` must have been written by a live library handle, and `'a` must not
/// outlive the handle that owns the arena those bytes are in. Callers get that
/// from a lifetime tied to the owning handle; this function cannot check it.
pub unsafe fn borrowed<'a>(text: &Text) -> &'a [u8] {
    if text.ptr.is_null() || text.len == 0 {
        return &[];
    }
    // SAFETY: the caller promises the span is live for `'a`; the header documents
    // `len` as authoritative and the bytes as contiguous.
    unsafe { std::slice::from_raw_parts(text.ptr, text.len) }
}

unsafe extern "C" {
    pub fn irgx_abi_version() -> u32;
    pub fn irgx_version() -> *const c_char;
    pub fn irgx_pcre2_version() -> *const c_char;
    pub fn irgx_status_message(code: i32) -> *const c_char;
    pub fn irgx_last_fault(out: *mut Fault) -> i32;

    pub fn irgx_compile(pattern: *const u8, len: usize, flags: u32, out: *mut *mut Regex) -> i32;
    pub fn irgx_free(re: *mut Regex);
    pub fn irgx_is_match(re: *mut Regex, text: *const u8, len: usize) -> i32;
    // `irgx_find_all` is deliberately not declared: it is the windowed verb below
    // with an inert bound, and this crate needs the bound anyway for `find_at`.
    // Declaring both would leave two spellings of one call for a reader to
    // reconcile.
    /// Whether this pattern's engine honors a LIVE `to` bound (1) or not (0).
    ///
    /// A property of the pattern, not of the call: the linear engine treats the
    /// bound as a ceiling on its walk, and PCRE2 structurally cannot, since its
    /// subject has one length and stopping at `to` would move every anchor. So a
    /// windowed call on the PCRE arm faults rather than quietly answering the
    /// sliced question, and this is how a host finds out before it asks.
    pub fn irgx_pattern_windows(re: *mut Regex) -> i32;
    /// Whether this pattern can report EARLIEST-mode spans (1) or not (0).
    ///
    /// The companion to `irgx_pattern_windows`, and 0 is a refusal rather than a
    /// slower path: asking for spans under the earliest mode then faults instead
    /// of answering with the leftmost match under an earliest label.
    pub fn irgx_pattern_earliest(re: *mut Regex) -> i32;
    pub fn irgx_is_match_in(
        re: *mut Regex,
        text: *const u8,
        len: usize,
        from: usize,
        to: usize,
    ) -> i32;
    pub fn irgx_find_all_in(
        re: *mut Regex,
        text: *const u8,
        len: usize,
        from: usize,
        to: usize,
        out: *mut Span,
        cap: usize,
        written: *mut usize,
    ) -> i32;
    /// The leftmost match, and then stop.
    ///
    /// Not `irgx_find_all_in` with a one-span window: that window bounds what
    /// the engine WRITES and never what it walks, because `*written` owes the
    /// caller the count the whole text holds — the contract that lets a short
    /// buffer size its own retry in one pass. So asking it for one match still
    /// pays for every match in the text. This verb is the same walk halted at
    /// the first one, which is what `find` and `find_at` actually want.
    ///
    /// Only the windowed spelling is declared, for the reason given above
    /// `irgx_find_all_in`: `find_at` needs the bound anyway, and `from == 0`,
    /// `to == len` is the inert case.
    pub fn irgx_find_first_in(
        re: *mut Regex,
        text: *const u8,
        len: usize,
        from: usize,
        to: usize,
        out: *mut Span,
    ) -> i32;
    pub fn irgx_captures(
        re: *mut Regex,
        text: *const u8,
        len: usize,
        from: usize,
        out: *mut Span,
        cap: usize,
        written: *mut usize,
    ) -> i32;
    pub fn irgx_slate_compile(
        patterns: *const SlatePattern,
        count: usize,
        refused: *mut usize,
        out: *mut *mut Slate,
    ) -> i32;
    pub fn irgx_slate_free(slate: *mut Slate);
    // `irgx_slate_len` is deliberately not declared: a `RegexSet` holds the
    // patterns it was built from, so its own length is a field rather than a
    // call, and the ABI's only use for the number is sizing the `which` buffer.
    pub fn irgx_slate_is_match(slate: *mut Slate, text: *const u8, len: usize) -> i32;
    pub fn irgx_slate_which(
        slate: *mut Slate,
        text: *const u8,
        len: usize,
        out: *mut u32,
        cap: usize,
        written: *mut usize,
    ) -> i32;

    pub fn irgx_munch_compile(
        patterns: *const MunchPattern,
        count: usize,
        flags: u32,
        out: *mut *mut Munch,
    ) -> i32;
    pub fn irgx_munch_free(munch: *mut Munch);
    // Declared, where the slate's equivalent above is not, because it is a
    // different number: the slate's length is the pattern count the crate already
    // holds, and a munch's is how many patterns it SEATED, which only the engine
    // knows once a refusal has happened.
    pub fn irgx_munch_len(munch: *const Munch) -> usize;
    pub fn irgx_munch_declined(
        munch: *const Munch,
        out: *mut MunchRefusal,
        cap: usize,
        written: *mut usize,
    ) -> i32;
    pub fn irgx_munch_scan(
        munch: *mut Munch,
        text: *const u8,
        len: usize,
        at: usize,
        allow: *const u32,
        nallow: usize,
        pick: u32,
        tok: *mut MunchToken,
        out: *mut u32,
        cap: usize,
    ) -> i32;

    pub fn irgx_group_count(re: *mut Regex, out: *mut u32) -> i32;
    // The inverse direction, `irgx_group_index`, is deliberately not declared:
    // the crate reads the whole name table at compile time, so resolving a name
    // to a number is a lookup in memory it already holds rather than a call.
    pub fn irgx_group_name(re: *mut Regex, index: u32, out: *mut Text) -> i32;
}

/// A static, NUL-terminated string from the library, as a `&'static str`.
///
/// The header promises every one of these is static-lifetime and never NULL, so
/// the borrow is genuinely `'static`. A NULL or non-UTF-8 answer would mean the
/// linked library is not the one this crate declares; report that rather than
/// panic, since these feed diagnostics.
fn borrow(raw: *const c_char) -> &'static str {
    if raw.is_null() {
        return "";
    }
    // SAFETY: `raw` came from a library entry the header documents as returning
    // a static, NUL-terminated C string, so it is valid for reads up to its
    // terminator and lives for the whole process.
    unsafe { CStr::from_ptr(raw) }.to_str().unwrap_or("")
}

/// The engine's semantic version, e.g. `"1.0.0"`. Distinct from this crate's
/// version: one crate release can carry a newer engine without an API change.
pub fn engine_version() -> &'static str {
    // SAFETY: a pure reader taking no arguments, which the header documents as
    // always answering with a static NUL-terminated string.
    borrow(unsafe { irgx_version() })
}

/// The vendored PCRE2 version the [`crate::RegexBuilder::pcre`] arm runs on.
pub fn pcre2_version() -> &'static str {
    // SAFETY: as `engine_version` above.
    borrow(unsafe { irgx_pcre2_version() })
}

/// The human sentence behind a status code. For a message, never for a
/// decision - the typed code is the contract.
pub fn status_message(code: i32) -> &'static str {
    // SAFETY: takes a plain `int32_t` by value and answers with a static string
    // for any input, including a code it does not recognize. The header also
    // promises it leaves the fault slot alone, which is why it is safe to call
    // while building an error.
    borrow(unsafe { irgx_status_message(code) })
}

/// The ABI version the linked library reports, resolved once.
///
/// Cached because the answer cannot change within a process and because every
/// `Regex::new` consults it. `LazyLock` gives the one-time initialization
/// without a lock on the hot path.
static LINKED_ABI: LazyLock<u32> = LazyLock::new(|| {
    // SAFETY: a pure reader taking no arguments and returning a plain `uint32_t`.
    // It is the one call that is sound to make before the ABI is confirmed,
    // because confirming it is what the call is for.
    unsafe { irgx_abi_version() }
});

/// `Ok(())` when the linked library speaks [`ABI_VERSION`].
pub fn abi_ok() -> Result<(), crate::Error> {
    let found = *LINKED_ABI;
    if found == ABI_VERSION {
        return Ok(());
    }
    Err(crate::Error::Abi {
        expected: ABI_VERSION,
        found,
    })
}
