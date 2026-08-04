//! How a `Send + Sync` [`crate::Regex`] is built out of a handle that is not.
//!
//! The header is blunt: an `irgx_regex *` owns the scratch its finds run in,
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
//!
//! Two kinds of handle need this and the reasoning is identical for both, so the
//! pool is generic over a [`Recipe`] — what to compile, and how to release it —
//! and the `unsafe impl Send` that carries the argument lives in exactly one
//! place. `RegexSet` inherited a correct pool the day it was written rather than
//! a second copy of this file with `slate` substituted for `regex`.

use std::marker::PhantomData;
use std::mem::ManuallyDrop;
use std::ptr::NonNull;
use std::sync::{Mutex, PoisonError};

use crate::error::Error;
use crate::sys;

/// What a pool replicates: how to mint one handle, and how to release it.
///
/// The recipe is also the pool's *storage* — it holds the pattern text a later
/// handle is compiled from — which is why it is one trait and not a compile
/// closure beside a free function. A pool that could not recompile could not
/// grow, and a pool that borrowed its pattern from elsewhere would put the
/// lifetime back into the type the caller wanted to put in a `static`.
pub(crate) trait Recipe {
    /// The opaque C type this recipe's handles point at.
    type Raw;

    /// Mint one handle, or report why the library would not.
    fn compile(&self) -> Result<NonNull<Self::Raw>, Error>;

    /// Release one handle.
    ///
    /// # Safety
    ///
    /// `raw` came from this recipe's `compile` and has not been released.
    unsafe fn release(raw: NonNull<Self::Raw>);
}

/// One handle, released when this value drops.
struct Handle<R: Recipe>(NonNull<R::Raw>, PhantomData<fn() -> R>);

// SAFETY: the handle is single-threaded, which is not the same as thread-bound.
// Everything it owns lives in the C allocator, whose free is callable from any
// thread, and the engine keeps no thread-local state tied to a handle (the fault
// slot is per-thread and read on the thread that filled it). Moving one across
// threads is therefore sound as long as only one thread uses it at a time, and
// `Pool` is the thing that guarantees that: a handle is only ever reachable
// through a `Lease`, and the mutex that hands the lease out also supplies the
// happens-before edge between the previous holder's last write and this one's
// first read.
unsafe impl<R: Recipe> Send for Handle<R> {}

impl<R: Recipe> Drop for Handle<R> {
    fn drop(&mut self) {
        // SAFETY: `self.0` came from a successful `R::compile` and has not been
        // released, since only this `Drop` releases it and it runs once.
        unsafe { R::release(self.0) }
    }
}

/// A recipe's compiled form, replicated per concurrent user.
pub(crate) struct Pool<R: Recipe> {
    recipe: R,
    /// Handles nobody is holding. Never touched while a search runs, so the
    /// lock is uncontended in the common case and held only for a push or pop.
    idle: Mutex<Vec<Handle<R>>>,
}

impl<R: Recipe> Pool<R> {
    /// Run `recipe` once, keeping the first handle idle.
    ///
    /// Compiling here rather than on first search means a bad pattern is an
    /// error from `Regex::new`, where the caller can see which pattern it was.
    pub(crate) fn new(recipe: R) -> Result<Self, Error> {
        sys::abi_ok()?;
        let first = Handle(recipe.compile()?, PhantomData);
        Ok(Self {
            recipe,
            idle: Mutex::new(vec![first]),
        })
    }

    /// What the pool was built from — the patterns, for a caller that asks.
    pub(crate) fn recipe(&self) -> &R {
        &self.recipe
    }

    /// A handle this thread may use until the lease drops.
    pub(crate) fn lease(&self) -> Result<Lease<'_, R>, Error> {
        let taken = self.idle().pop();
        let handle = match taken {
            Some(ready) => ready,
            None => Handle(self.recipe.compile()?, PhantomData),
        };
        Ok(Lease {
            pool: self,
            handle: ManuallyDrop::new(handle),
        })
    }

    /// A poisoned pool is still a correct pool: the lock is only ever held
    /// across a `Vec` push or pop, so no panic can leave the handles in a state
    /// a later borrower could misread.
    fn idle(&self) -> std::sync::MutexGuard<'_, Vec<Handle<R>>> {
        self.idle.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// Exclusive use of one handle, returned to its pool on drop.
pub(crate) struct Lease<'p, R: Recipe> {
    pool: &'p Pool<R>,
    /// `ManuallyDrop` because the handle is *moved back* into the pool rather
    /// than freed: dropping it here would free a handle the pool still wants.
    handle: ManuallyDrop<Handle<R>>,
}

impl<R: Recipe> Lease<'_, R> {
    /// The raw handle, for the one call each verb makes with it.
    pub(crate) fn raw(&self) -> *mut R::Raw {
        self.handle.0.as_ptr()
    }
}

impl<R: Recipe> Drop for Lease<'_, R> {
    fn drop(&mut self) {
        // SAFETY: `self.handle` has not been taken before - `Drop` runs once and
        // nothing else moves out of the `ManuallyDrop`.
        let handle = unsafe { ManuallyDrop::take(&mut self.handle) };
        self.pool.idle().push(handle);
    }
}

/// A non-negative status that wrote no handle is the library breaking its own
/// contract. Refusing beats handing a null pointer to every later call.
pub(crate) fn wrote<T>(raw: *mut T, entry: &str) -> Result<NonNull<T>, Error> {
    NonNull::new(raw).ok_or_else(|| Error::Inconsistent {
        message: format!("{entry} reported success but wrote no handle"),
    })
}
