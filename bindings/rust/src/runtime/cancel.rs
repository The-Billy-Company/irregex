//! Giving up on an in-process analytic query.
//!
//! `AnalyticRunFn` has taken a `*mut irgx_cancel` since the plane landed, and
//! until this module existed the crate had exactly one value to pass: null. The
//! three functions that make a token were never bound, so the parameter was
//! structurally unfillable — a cancellation surface that looked present in the
//! type and could not work. The Go binding wired the same trio to
//! `context.Context` on day one, which is how the gap survived: there was always
//! a language in which it worked.
//!
//! It matters because these are the long calls. `relate echoes --shape distinct`
//! is a claim about every pair in the corpus, with no cheaper form and a measured
//! 27 seconds; a host that cannot abandon one has to either block a thread to
//! completion or lose the whole process.
//!
//! Rust has no ambient `Context` to bind to, so the token IS the Rust surface:
//! clone it to whoever decides, call [`CancelToken::cancel`] there. The engine's
//! own token is thread-safe (`api.CancelToken`), which is what lets this be
//! `Send + Sync` with no lock of its own — the `Arc` is for the *lifetime*, so the
//! last holder frees it and a running query's pointer cannot dangle.

use std::ffi::CStr;
use std::sync::Arc;

use super::sys;
use super::{Error, Result};

/// The resolved trio. Held together because a partial one is unusable: a token
/// you can make and not free is a leak, and one you can make and not signal is
/// the null pointer with extra steps.
#[derive(Clone, Copy)]
pub(super) struct Vtable {
    pub(super) new: sys::CancelNewFn,
    pub(super) request: sys::CancelRequestFn,
    pub(super) free: sys::CancelFreeFn,
}

impl Vtable {
    /// All three or none, from this process's symbols.
    pub(super) fn resolve(
        resolve: impl Fn(&CStr) -> Option<*mut std::ffi::c_void>,
    ) -> Option<Self> {
        // Each transmute is a dlsym code address onto the shape `sys` declares,
        // reviewed against `include/irgx.h` exactly as an `extern` block is.
        let (new, request, free) = (
            resolve(c"irgx_cancel_new")?,
            resolve(c"irgx_cancel_request")?,
            resolve(c"irgx_cancel_free")?,
        );
        Some(unsafe {
            Self {
                new: std::mem::transmute::<*mut std::ffi::c_void, sys::CancelNewFn>(new),
                request: std::mem::transmute::<*mut std::ffi::c_void, sys::CancelRequestFn>(
                    request,
                ),
                free: std::mem::transmute::<*mut std::ffi::c_void, sys::CancelFreeFn>(free),
            }
        })
    }
}

/// The owned token, freed when the last handle drops.
struct Owned {
    ptr: *mut sys::irgx_cancel,
    vt: Vtable,
}

impl Drop for Owned {
    fn drop(&mut self) {
        // SAFETY: `ptr` came from this `vt`'s own `new` and is freed once, here,
        // because `Arc` hands the last holder exclusive ownership.
        unsafe { (self.vt.free)(self.ptr) };
    }
}

// SAFETY: the engine's token is documented thread-safe — a request is an atomic
// set, and a concurrent scan reads it. So sharing the pointer is sound, and the
// `Arc` is what makes the FREE sound: it cannot run while a scan still holds a
// clone.
unsafe impl Send for Owned {}
unsafe impl Sync for Owned {}

/// A thread-safe request to stop, handed to an in-process analytic query.
///
/// Clone it to whoever gets to decide and call [`cancel`](Self::cancel) there;
/// the query it was passed to gives up and its verb answers as a declinature, so
/// the caller falls through to the subprocess tier rather than seeing a fault.
/// Signaling is idempotent and signaling after the query finished is harmless,
/// which is what lets a watchdog fire without racing the answer.
///
/// ```no_run
/// # fn main() -> Result<(), irgx::runtime::Error> {
/// let token = irgx::runtime::CancelToken::new()?;
/// let watchdog = token.clone();
/// std::thread::spawn(move || {
///     std::thread::sleep(std::time::Duration::from_secs(2));
///     watchdog.cancel();
/// });
/// # Ok(())
/// # }
/// ```
#[derive(Clone)]
pub struct CancelToken {
    inner: Arc<Owned>,
}

impl CancelToken {
    /// Allocate a fresh, unset token.
    ///
    /// # Errors
    ///
    /// [`Error::Uncancellable`] when this process has no analytic plane to cancel — the
    /// honest answer, since there is then nothing a token could stop. Otherwise
    /// [`Error::Failed`] if the engine could not allocate one.
    pub fn new() -> Result<Self> {
        let vt = super::plane::cancellation().ok_or(Error::Uncancellable)?;
        let mut ptr: *mut sys::irgx_cancel = std::ptr::null_mut();
        // SAFETY: `new` writes through `out` on success and is the trio's own.
        let status = unsafe { (vt.new)(&raw mut ptr) };
        if status < 0 || ptr.is_null() {
            return Err(Error::Failed(
                "irregex: the engine would not allocate a cancel token".into(),
            ));
        }
        Ok(Self {
            inner: Arc::new(Owned { ptr, vt }),
        })
    }

    /// Ask the query using this token to stop. Idempotent.
    pub fn cancel(&self) {
        // SAFETY: the token outlives this call (we hold an `Arc`), and a request
        // is thread-safe by the engine's contract.
        unsafe { (self.inner.vt.request)(self.inner.ptr) };
    }

    /// The raw token, for the one frame that passes it across the ABI.
    pub(super) fn raw(&self) -> *mut sys::irgx_cancel {
        self.inner.ptr
    }
}

impl std::fmt::Debug for CancelToken {
    /// Deliberately says nothing about whether it has been signaled: the ABI
    /// offers no read-back, and inventing one out of a Rust-side flag would be a
    /// second source of truth that a `cancel()` through another clone could
    /// already have made wrong.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CancelToken")
            .field("holders", &Arc::strong_count(&self.inner))
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The property the `unsafe impl`s claim, asserted at compile time.
    #[test]
    fn a_token_crosses_threads() {
        const fn assert<T: Send + Sync + Clone>() {}
        assert::<CancelToken>();
    }

    /// A host without the analytic plane gets a reason, not a null token it
    /// would then pass into a call that ignores it.
    #[test]
    fn no_plane_is_an_answer_rather_than_a_useless_token() {
        if super::super::plane::cancellation().is_none() {
            assert!(matches!(CancelToken::new(), Err(Error::Uncancellable)));
        }
    }

    /// The trio resolves together or not at all — a token that cannot be freed
    /// is a leak, and one that cannot be signaled is null with extra steps.
    #[test]
    fn a_partial_trio_resolves_to_nothing() {
        let only_new = Vtable::resolve(|name| {
            (name == c"irgx_cancel_new").then_some(std::ptr::dangling_mut())
        });
        assert!(only_new.is_none());
    }
}
