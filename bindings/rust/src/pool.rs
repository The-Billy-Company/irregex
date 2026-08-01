//! How a `Send + Sync` [`crate::Regex`] is built out of a handle that is not.
//!
//! The header is blunt: an `irregex_regex *` owns the scratch its finds run in,
//! so two threads sharing one corrupt a match rather than race a counter, and
//! the advice is to compile one per thread. A Rust programmer, meanwhile, will
//! write `static RE: LazyLock<Regex>` and hand it to Rayon without a second
//! thought, because that is what the `regex` crate's type allows.
//!
//! Both facts are satisfied by owning a **pool** of handles instead of one.
//! Every search leases a handle, uses it alone, and returns it; the pool grows
//! to the concurrency the caller actually reaches and every handle is freed when
//! the pool drops. `unsafe impl Sync` over one shared handle would have been the
//! other way to make the type compile, and it would have been a data race.
//!
//! A pool rather than a thread-local because a thread-local keyed by pattern
//! cannot be cleaned up: the owning `Regex` can only reach its *own* thread's
//! slot, so a handle parked in a long-lived worker thread outlives the pattern
//! that made it. The pool has no such hole, and it sizes itself by how many
//! threads search at once rather than by how many threads exist.

use std::mem::ManuallyDrop;
use std::ptr::NonNull;
use std::sync::{Mutex, PoisonError};

use crate::error::{Error, compile_refusal};
use crate::sys;

/// One `irregex_regex *`, freed when this value drops.
struct Handle(NonNull<sys::Regex>);

// SAFETY: the handle is single-threaded, which is not the same as thread-bound.
// Everything it owns lives in the C allocator, whose free is callable from any
// thread, and the engine keeps no thread-local state tied to a handle (the fault
// slot is per-thread and read on the thread that filled it). Moving one across
// threads is therefore sound as long as only one thread uses it at a time, and
// `Pool` is the thing that guarantees that: a handle is only ever reachable
// through a `Lease`, and the mutex that hands the lease out also supplies the
// happens-before edge between the previous holder's last write and this one's
// first read.
unsafe impl Send for Handle {}

impl Drop for Handle {
    fn drop(&mut self) {
        // SAFETY: `self.0` came from a successful `irregex_compile` and has not
        // been freed, since only this `Drop` frees it and it runs once.
        unsafe { sys::irregex_free(self.0.as_ptr()) }
    }
}

/// A pattern's compiled form, replicated per concurrent user.
pub(crate) struct Pool {
    pattern: Box<[u8]>,
    flags: u32,
    /// Handles nobody is holding. Never touched while a search runs, so the
    /// lock is uncontended in the common case and held only for a push or pop.
    idle: Mutex<Vec<Handle>>,
}

impl Pool {
    /// Compile `pattern` under `flags`, keeping the first handle idle.
    ///
    /// Compiling here rather than on first search means a bad pattern is an
    /// error from `Regex::new`, where the caller can see which pattern it was.
    pub(crate) fn new(pattern: &[u8], flags: u32) -> Result<Self, Error> {
        sys::abi_ok()?;
        let first = compile(pattern, flags)?;
        Ok(Self {
            pattern: pattern.into(),
            flags,
            idle: Mutex::new(vec![first]),
        })
    }

    /// A handle this thread may use until the lease drops.
    pub(crate) fn lease(&self) -> Result<Lease<'_>, Error> {
        let taken = self.idle().pop();
        let handle = match taken {
            Some(ready) => ready,
            None => compile(&self.pattern, self.flags)?,
        };
        Ok(Lease {
            pool: self,
            handle: ManuallyDrop::new(handle),
        })
    }

    /// A poisoned pool is still a correct pool: the lock is only ever held
    /// across a `Vec` push or pop, so no panic can leave the handles in a state
    /// a later borrower could misread.
    fn idle(&self) -> std::sync::MutexGuard<'_, Vec<Handle>> {
        self.idle.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

fn compile(pattern: &[u8], flags: u32) -> Result<Handle, Error> {
    let mut out: *mut sys::Regex = std::ptr::null_mut();
    // SAFETY: `pattern` is a live slice passed with its own length, `flags` is a
    // plain integer, and `out` is a live pointer slot the library only writes on
    // success. The call cannot unwind: every entry in this ABI returns a status.
    let status =
        unsafe { sys::irregex_compile(pattern.as_ptr(), pattern.len(), flags, &raw mut out) };
    if status < 0 {
        // `out` is deliberately not consulted: the header leaves it untouched on
        // a refusal, so there is no handle here to read, keep or free - not even
        // on the declinature, which is the path that looks most like success.
        return Err(compile_refusal(status, &String::from_utf8_lossy(pattern)));
    }
    // A non-negative status with a null handle would be the library breaking its
    // own contract; refusing beats handing a null pointer to every later call.
    NonNull::new(out)
        .map(Handle)
        .ok_or_else(|| Error::Inconsistent {
            message: "irregex_compile reported success but wrote no handle".to_owned(),
        })
}

/// Exclusive use of one handle, returned to its pool on drop.
pub(crate) struct Lease<'p> {
    pool: &'p Pool,
    /// `ManuallyDrop` because the handle is *moved back* into the pool rather
    /// than freed: dropping it here would free a handle the pool still wants.
    handle: ManuallyDrop<Handle>,
}

impl Lease<'_> {
    /// The raw handle, for the one call each verb makes with it.
    pub(crate) fn raw(&self) -> *mut sys::Regex {
        self.handle.0.as_ptr()
    }
}

impl Drop for Lease<'_> {
    fn drop(&mut self) {
        // SAFETY: `self.handle` has not been taken before - `Drop` runs once and
        // nothing else moves out of the `ManuallyDrop`.
        let handle = unsafe { ManuallyDrop::take(&mut self.handle) };
        self.pool.idle().push(handle);
    }
}
