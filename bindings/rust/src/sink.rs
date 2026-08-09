//! The one place a `cap`/`written` call becomes a `Vec`.
//!
//! Fourteen verbs across five planes share one shape: hand the library a buffer
//! and its capacity, get back a status and a count. What the count MEANS splits
//! them in two, and conflating the two dialects is how a binding truncates an
//! answer while reporting success:
//!
//! * **The total dialect.** `*written` is the count the answer HOLDS, whether or
//!   not it fit. A short `cap` is therefore not a failure — it is the library
//!   sizing your retry for you, and one retry at the reported count is enough.
//!   Every enumerating verb speaks this: `irgx_lines_split`,
//!   `irgx_needles_find_all`, `irgx_sieve_candidates`, `irgx_codex_locate`,
//!   `irgx_codex_save`, and so on. [`reap`] is that loop, written once.
//! * **The consumed dialect.** `*written` is what THIS CALL took off a cursor,
//!   never a total that exists — so `cap == 0` is a legal no-op and a retry at a
//!   larger size would skip records. Only the two pull verbs
//!   (`irgx_matches_next_batch`, `irgx_walk_next_batch`) speak it, they fill a
//!   buffer the caller already owns, and they deliberately do NOT come through
//!   here: see [`crate::corpus::tree`] and [`crate::corpus::walk`], where the
//!   batch call is the engine of an iterator rather than a collector.
//!
//! The retry is bounded rather than a `loop`. These planes read a tree that up
//! to ten agents may be writing, so an answer really can grow between two calls;
//! spinning on it forever is worse than saying so ([`Error::Unsettled`]).

use crate::error::{self, Error};
use crate::sys;

use crate::Answer;

/// How many times to re-ask after the library has told us the size it needs.
///
/// One is the protocol; the rest are for a corpus that changed underneath the
/// first retry. Four total attempts, then the caller hears that the tree would
/// not hold still — which is a real answer, where a silently short `Vec` is not.
const ATTEMPTS: usize = 4;

/// Collect a total-dialect `cap`/`written` verb into a `Vec`.
///
/// `hint` is the first capacity to try. Size it from something the library
/// already told you when there is such a number (`irgx_needles_len`,
/// `irgx_matches_count`) — then the first call is the only call. Where the count
/// is genuinely unknowable in advance, guess low: the retry is one crossing, and
/// over-allocating for the common case costs every caller.
///
/// `call` receives `(out, cap, written)` exactly as the header spells them, and
/// is called with a null `out` when `hint` is 0 — which every one of these verbs
/// documents as the legal way to ask for a size.
///
/// # Errors
///
/// [`Error::Plane`] for a fault, [`Error::OutOfMemory`] for an allocation
/// failure, [`Error::Unsettled`] if the answer outgrew every retry. `IRGX_STALE`
/// is not an error: it comes back as [`Answer::Declined`].
pub(crate) fn reap<T: Copy + Default>(
    plane: &'static str,
    hint: usize,
    mut call: impl FnMut(*mut T, usize, *mut usize) -> i32,
) -> Result<Answer<Vec<T>>, Error> {
    let mut buf: Vec<T> = vec![T::default(); hint];
    let mut wanted = 0usize;
    for _ in 0..ATTEMPTS {
        // A zero-length `Vec`'s pointer is dangling-but-aligned, which is not
        // what a C caller means by "I am asking for the size"; null is.
        let out = if buf.is_empty() {
            std::ptr::null_mut()
        } else {
            buf.as_mut_ptr()
        };
        let offered = buf.len();
        let status = call(out, offered, &raw mut wanted);
        if status < 0 {
            if status == sys::STALE {
                return Ok(Answer::Declined);
            }
            return Err(error::plane_fault(status, plane));
        }
        if wanted <= offered {
            buf.truncate(wanted);
            return Ok(Answer::Given(buf));
        }
        buf.resize(wanted, T::default());
    }
    Err(Error::Unsettled {
        plane,
        offered: buf.len(),
        wanted,
    })
}

/// [`reap`] for a verb that cannot decline, unwrapped at the seam.
///
/// Most of these verbs have no `IRGX_STALE` arm at all, and forcing their callers
/// to match on an [`Answer`] that is structurally always `Given` would teach the
/// wrong lesson about which tiers can step aside. A declinature here is the
/// linked library disagreeing with the header, so it is reported rather than
/// silently read as empty.
///
/// # Errors
///
/// As [`reap`], plus [`Error::Plane`] carrying [`crate::Status::DECLINED`] if the
/// verb declined after all.
pub(crate) fn reap_all<T: Copy + Default>(
    plane: &'static str,
    hint: usize,
    call: impl FnMut(*mut T, usize, *mut usize) -> i32,
) -> Result<Vec<T>, Error> {
    match reap(plane, hint, call)? {
        Answer::Given(items) => Ok(items),
        Answer::Declined => Err(Error::Plane {
            plane,
            status: crate::Status::DECLINED,
            detail: Some("this verb has no declining arm in the header".to_owned()),
        }),
    }
}
