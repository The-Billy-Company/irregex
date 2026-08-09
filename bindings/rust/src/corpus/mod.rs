//! Searching a TREE, not a buffer you already hold.
//!
//! Everything else in this crate takes bytes you have. These three planes are
//! about the bytes you have not read yet, and they are three separate questions
//! on purpose — because in a real corpus the expensive one is not matching:
//!
//! * [`Walk`] — which files a search is even ALLOWED to read. gitignore
//!   precedence, the type registry, hidden and binary policy, answered as a set
//!   you can iterate rather than as a side effect of searching.
//! * [`Sieve`] — narrowing, so most of those files are never opened at all. Every
//!   answer is a SUPERSET: a sieve rules documents out, it never rules one in.
//! * [`Corpus`] + [`Search`] — the search itself, over a warm engine that keeps
//!   its index and its walk between queries.
//!
//! ## The borrow, which is the whole reason Rust binds this well
//!
//! Every record, entry and path in this module BORROWS the handle it came from.
//! The ABI says so in comments — "`path` and `line` are borrowed from the
//! CURSOR's arena and stay valid until `irgx_matches_close`; copy anything you
//! keep" — and in C that is a rule you remember. Here it is a lifetime:
//! [`Record`](tree::Record) borrows its [`Search`], [`Entry`](walk::Entry) borrows
//! its [`Walk`], and a document path borrows its [`Sieve`]. Keeping one too long
//! does not read freed memory; it fails to compile.
//!
//! What is copied is the DESCRIPTOR — six words of pointer, length and line
//! number per record — because the ABI writes those into a buffer we own. The
//! payload behind them is never copied.
//!
//! ## Threads
//!
//! [`Cancel`] is `Send + Sync`: the engine's token is thread-safe, and being able
//! to trip one from elsewhere is the entire point of it. Nothing else here is.
//! Cursors, walks and sieves are single-threaded C handles holding scan state, so
//! they stay on the thread that made them; share the [`Cancel`] instead.

pub mod sieve;
pub mod tree;
pub mod walk;

use std::ffi::CString;
use std::path::Path;
use std::ptr::NonNull;
use std::sync::Arc;

use crate::Status;
use crate::error::{self, Error};

pub use sieve::{Facts, Freshness, Sieve, Winnow, WinnowFacts};
pub use tree::{Kind, Query, Record, Records, Search};
pub use walk::{Entry, Genus, Limits, Policy, Spec, Walk};

/// The plane name a fault from the engine itself is reported under.
const PLANE: &str = "tree";

/// An opaque `irgx_engine`. Never dereferenced on this side.
#[repr(C)]
struct EngineHandle {
    _opaque: [u8; 0],
}

/// An opaque `irgx_cancel`. Never dereferenced on this side.
#[repr(C)]
struct CancelHandle {
    _opaque: [u8; 0],
}

/// A warm corpus: an engine with its roots, its index and its walk already stood
/// up.
///
/// Open one and ask it many questions. Standing it up is the expensive part — the
/// index, the atlas and the walk load lazily on first use and are not cheap — so a
/// program asking six questions about the same tree should pay for it once.
///
/// Not `Send`: the handle is a single-threaded C object. A corpus per worker
/// thread is the shape that works, and they share nothing but the filesystem.
pub struct Corpus {
    handle: NonNull<EngineHandle>,
}

impl Corpus {
    /// Stand a corpus up over `roots`.
    ///
    /// An empty slice walks the current directory, which is not an error — it is
    /// what a tool invoked with no path argument means.
    ///
    /// # Errors
    ///
    /// [`Error::Plane`] if a root cannot be read, or if one contains an interior
    /// NUL byte — the ABI takes NUL-terminated paths, so such a path cannot be
    /// passed at all and is refused here rather than silently truncated.
    pub fn open<P: AsRef<Path>>(roots: &[P]) -> Result<Self, Error> {
        // Held as owned `CString`s for the duration of the call: the pointer array
        // below borrows them, and the engine copies what it keeps.
        let owned = roots
            .iter()
            .map(|root| CString::new(root.as_ref().as_os_str().as_encoded_bytes()))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| Error::Plane {
                plane: PLANE,
                status: Status::INVALID,
                detail: Some("a root path contains an interior NUL byte".to_owned()),
            })?;
        let pointers: Vec<*const std::ffi::c_char> =
            owned.iter().map(|root| root.as_ptr()).collect();
        let mut out: *mut EngineHandle = std::ptr::null_mut();
        // SAFETY: `pointers` is a live array of live NUL-terminated strings passed
        // with its own length, both outliving the call, and `out` is a live slot
        // the library writes only on success. A zero length with a dangling
        // pointer is the documented "walk the CWD" spelling.
        let status =
            unsafe { ffi::irgx_engine_open(pointers.as_ptr(), pointers.len(), &raw mut out) };
        if status < 0 {
            return Err(error::plane_fault(status, PLANE));
        }
        NonNull::new(out)
            .map(|handle| Self { handle })
            .ok_or_else(|| Error::Inconsistent {
                message: "the engine reported success and produced no handle".to_owned(),
            })
    }

    /// Stand a corpus up over the current directory.
    ///
    /// # Errors
    ///
    /// As [`Corpus::open`].
    pub fn here() -> Result<Self, Error> {
        Self::open::<&Path>(&[])
    }
}

impl Drop for Corpus {
    fn drop(&mut self) {
        // SAFETY: the handle came from `irgx_engine_open` and is freed exactly
        // once, here. Every cursor drawn from it is gone — `Search` borrows the
        // `Corpus`, so the compiler will not let one outlive this.
        unsafe { ffi::irgx_engine_close(self.handle.as_ptr()) };
    }
}

/// A token that abandons the searches holding it.
///
/// The long queries are why this exists. A corpus-wide search with no cheaper
/// form can run for tens of seconds, and a host that cannot abandon one has to
/// either block a thread to completion or lose the process.
///
/// `Send + Sync` and cheap to clone: the engine's token is thread-safe, so hand a
/// clone to whoever decides — a signal handler, a timeout task, a UI thread — and
/// call [`Cancel::request`] there. The clone is what keeps the token alive: the
/// last holder frees it, so a running search's pointer cannot dangle.
#[derive(Clone)]
pub struct Cancel {
    token: Arc<Token>,
}

/// The owned token, freed by the last [`Cancel`] holding it.
struct Token {
    handle: NonNull<CancelHandle>,
}

// SAFETY: moving the token to another thread is sound because nothing about it is
// bound to the thread that made it — the header introduces the type as one to
// "trip from any thread", this side never dereferences the pointer, and the free
// is the `Arc`'s to schedule rather than any one thread's.
unsafe impl Send for Token {}

// SAFETY: a *shared* token is the stronger claim, and the one the design rests on:
// two threads may hold `&Token` at once, and the only thing either can do with it
// is `irgx_cancel_request`, which the header documents as thread-safe. There is no
// `&mut` path to the handle and no interior state on this side to race over. The
// `Arc` closes the lifetime half: a search holds a clone for as long as it runs, so
// the free happens strictly after every query using it has returned.
unsafe impl Sync for Token {}

impl Drop for Token {
    fn drop(&mut self) {
        // SAFETY: the handle came from `irgx_cancel_new`, every search holding a
        // clone has returned (that is what the `Arc` count proves), and this runs
        // exactly once.
        unsafe { ffi::irgx_cancel_free(self.handle.as_ptr()) };
    }
}

impl Cancel {
    /// A fresh, unset token.
    ///
    /// # Errors
    ///
    /// [`Error::OutOfMemory`] if the token could not be allocated.
    pub fn new() -> Result<Self, Error> {
        let mut out: *mut CancelHandle = std::ptr::null_mut();
        // SAFETY: `out` is a live slot the library writes only on success.
        let status = unsafe { ffi::irgx_cancel_new(&raw mut out) };
        if status < 0 {
            return Err(error::plane_fault(status, PLANE));
        }
        NonNull::new(out)
            .map(|handle| Self {
                token: Arc::new(Token { handle }),
            })
            .ok_or_else(|| Error::Inconsistent {
                message: "the cancellation plane reported success and produced no token".to_owned(),
            })
    }

    /// Trip the token: every search using it stops.
    ///
    /// Idempotent, and safe from any thread. A search that has already finished
    /// is unaffected.
    pub fn request(&self) {
        // SAFETY: the token is live for `&self`, and the header documents this
        // call as thread-safe.
        unsafe { ffi::irgx_cancel_request(self.token.handle.as_ptr()) };
    }

    /// The raw token, for a request struct to point at.
    fn as_ptr(&self) -> *const CancelHandle {
        self.token.handle.as_ptr()
    }
}

impl std::fmt::Debug for Cancel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // The token has no readable state — tripped-ness is not askable across
        // the ABI — so there is nothing to print but the sharing.
        f.debug_struct("Cancel")
            .field("holders", &Arc::strong_count(&self.token))
            .finish()
    }
}

/// The engine and cancellation seam. These two symbols are also probed by
/// [`crate::runtime`], which resolves them with `dlsym` because the analytic
/// producers it dispatches to may be absent; here they are linked, because a
/// corpus search is this library's own and a missing engine is a link error rather
/// than a fallback.
mod ffi {
    use std::ffi::c_char;

    use super::{CancelHandle, EngineHandle};

    unsafe extern "C" {
        pub fn irgx_engine_open(
            roots: *const *const c_char,
            nroots: usize,
            out: *mut *mut EngineHandle,
        ) -> i32;
        pub fn irgx_engine_close(engine: *mut EngineHandle);
        pub fn irgx_cancel_new(out: *mut *mut CancelHandle) -> i32;
        pub fn irgx_cancel_request(token: *mut CancelHandle);
        pub fn irgx_cancel_free(token: *mut CancelHandle);
    }
}
