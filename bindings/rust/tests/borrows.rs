//! The thread posture of every handle the new planes added, asserted at compile
//! time.
//!
//! This file contains almost no runtime assertions on purpose. `Send` and `Sync`
//! are the two properties a test cannot usefully check by running — a handle that
//! is wrongly `Send` does not fail when sent, it fails later, somewhere else, in a
//! way that looks like corruption rather than like a threading bug. So what is
//! held here is that the crate's *declarations* are what they claim to be, and the
//! file fails to build rather than fails to pass.
//!
//! The positive direction is `fn needs<T: Send>()`. The negative direction — that
//! a single-threaded handle is NOT `Send` — cannot be written as a passing test at
//! all; it is `compile_fail` doctests, which live beside the types they constrain
//! in `src/corpus/`, plus [`the_negative_cases`] below, which says in one place
//! what those are and where to read them.
//!
//! The companion property, that a borrowed record cannot outlive the handle that
//! lent it, is also a `compile_fail` doctest per plane, for the same reason: the
//! only way to demonstrate that a program is rejected is to have the compiler
//! reject it.

use irgx::corpus::{Cancel, Corpus, sieve::Sieve, tree::Search, walk::Walk};
use irgx::{Regex, codex::Codex, needles::Needles, promise::Literals};

fn needs_send<T: Send>() {}
fn needs_sync<T: Sync>() {}

#[test]
fn a_cancel_token_crosses_threads_because_that_is_its_entire_purpose() {
    // The one handle in the corpus module that must be both: a budget you cannot
    // trip from another thread is not a cancellation mechanism.
    needs_send::<Cancel>();
    needs_sync::<Cancel>();

    // And it really works, not just type-checks.
    let cancel = Cancel::new().unwrap();
    let other = cancel.clone();
    std::thread::spawn(move || other.request()).join().unwrap();
}

#[test]
fn a_regex_still_crosses_threads() {
    // The pre-existing guarantee, restated here so a new plane cannot quietly
    // take it away by adding a field to `Regex`.
    needs_send::<Regex>();
    needs_sync::<Regex>();
}

/// The handles that are deliberately NOT `Send`, and where each one's proof lives.
///
/// Every type named here holds C state bound to the thread that made it — a scan
/// cursor, an arena, a memory mapping with an I/O context, or a lazily-built table.
/// Making any of them `Send` would need an `unsafe impl` and a reason to believe
/// the engine's own thread-affinity claim is wrong, and there is none.
///
/// This test's body is the list. Its enforcement is the absence of an `unsafe impl
/// Send` anywhere in `src/corpus/`, `src/codex.rs`, `src/needles.rs` or
/// `src/promise.rs` — a reviewer greps for that, and a reader finds this.
#[test]
fn the_negative_cases() {
    // `Search`, `Walk`, `Sieve`, `Winnow`, `Codex`, `Needles` and `Literals` are
    // `!Send` and `!Sync` by the ordinary rule: each is a `NonNull<T>` and nothing
    // opts them in. Compile-time proof that they cannot be sent is not expressible
    // as a passing assertion, so it is a `compile_fail` doctest per type.
    //
    // What IS assertable here is that the crate still exposes them at all, which
    // keeps this list from rotting into a comment about types that were renamed.
    let _ = std::mem::size_of::<Search<'static>>();
    let _ = std::mem::size_of::<Walk>();
    let _ = std::mem::size_of::<Sieve>();
    let _ = std::mem::size_of::<Codex>();
    let _ = std::mem::size_of::<Needles>();
    let _ = std::mem::size_of::<Literals>();
    let _ = std::mem::size_of::<Corpus>();
}

/// `Cancel` is the one thing shared, so the pattern the module documents has to
/// actually work: a search on this thread, a token tripped from another.
#[test]
fn the_documented_sharing_pattern_compiles_and_runs() {
    let cancel = Cancel::new().unwrap();
    let watcher = cancel.clone();
    let stopper = std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(5));
        watcher.request();
    });

    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("f.txt"), "needle\n").unwrap();
    let corpus = Corpus::open(&[dir.path()]).unwrap();
    // The cursor never leaves this thread; only the token did.
    let query = irgx::corpus::tree::Query::new(b"needle").cancel(&cancel);
    let _ = corpus.search(&query);
    stopper.join().unwrap();
}
