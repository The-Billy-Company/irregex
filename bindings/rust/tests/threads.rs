//! One `static` `Regex`, many threads.
//!
//! The C handle owns the scratch its searches run in, so it is single-threaded and
//! the header says to compile one per thread. A `Regex` that inherited that would
//! be `!Sync`, which breaks the pattern every Rust programmer reaches for first:
//!
//! ```ignore
//! static WORD: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\w+").unwrap());
//! ```
//!
//! So `Regex` keeps a pool of handles and leases one per search. These tests are
//! the proof: the same `static` searched from many threads at once has to give
//! every thread the answer it would have got alone.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Barrier, LazyLock};

use irgx::{Regex, RegexBuilder};

static WORD: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[a-z]+").unwrap());
static GROUPED: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?P<key>\w+)=(?P<value>\d+)").unwrap());

/// A compile-time proof, which is really the whole point: this fails to build if
/// `Regex` loses either bound.
#[test]
fn regex_is_send_and_sync() {
    fn require<T: Send + Sync + 'static>() {}
    require::<Regex>();
    require::<irgx::RegexBuilder>();
    require::<irgx::Error>();
    // A `Match` borrows the text, so it travels with it.
    fn require_send<T: Send>() {}
    require_send::<irgx::Match<'static>>();
    require_send::<irgx::Matches<'static>>();
}

/// Every thread searches a different text through one `static`, and every answer
/// is checked against what that thread alone would have got. A pool that leaked a
/// handle across a search would show up as a wrong span, not a crash.
#[test]
fn many_threads_one_static() {
    const THREADS: usize = 16;
    const ROUNDS: usize = 200;

    // A barrier so the threads are actually inside the engine at the same time,
    // rather than politely queuing.
    let gate = Arc::new(Barrier::new(THREADS));
    let mut crew = Vec::new();
    for id in 0..THREADS {
        let gate = Arc::clone(&gate);
        crew.push(std::thread::spawn(move || {
            // Each thread's own text, so a shared handle would produce visibly
            // wrong offsets rather than a coincidentally right answer.
            let text = format!("{}alpha beta{} gamma", " ".repeat(id), "x".repeat(id));
            let want: Vec<(usize, usize)> = Regex::new(r"[a-z]+")
                .unwrap()
                .find_iter(&text)
                .map(|m| (m.start(), m.end()))
                .collect();
            gate.wait();
            for _ in 0..ROUNDS {
                let got: Vec<(usize, usize)> = WORD
                    .find_iter(&text)
                    .map(|m| (m.start(), m.end()))
                    .collect();
                assert_eq!(got, want, "thread {id}");
                // The slices have to be right too, not just the numbers.
                for found in WORD.find_iter(&text) {
                    assert_eq!(found.as_str(), &text[found.range()]);
                }
            }
        }));
    }
    for worker in crew {
        worker.join().expect("no thread should panic");
    }
}

/// Groups run through a second engine call per match, on the same leased handle,
/// so they are the place a pool bug would corrupt state rather than just report
/// it. Named lookups go through the shared name table, which is read-only.
#[test]
fn many_threads_reading_groups() {
    const THREADS: usize = 12;
    let counted = Arc::new(AtomicUsize::new(0));
    let gate = Arc::new(Barrier::new(THREADS));

    let mut crew = Vec::new();
    for id in 0..THREADS {
        let counted = Arc::clone(&counted);
        let gate = Arc::clone(&gate);
        crew.push(std::thread::spawn(move || {
            let text: String = (0..8).map(|n| format!("k{id}n{n}={n}{id} ")).collect();
            gate.wait();
            for _ in 0..100 {
                for caps in GROUPED.captures_iter(&text) {
                    let key = caps.name("key").expect("key participates");
                    let value = caps.name("value").expect("value participates");
                    assert!(key.as_str().starts_with(&format!("k{id}n")));
                    assert!(value.as_str().ends_with(&id.to_string()));
                    // Whole match spans both groups and nothing else.
                    let whole = caps.get(0).unwrap();
                    assert_eq!(whole.start(), key.start());
                    assert_eq!(whole.end(), value.end());
                    counted.fetch_add(1, Ordering::Relaxed);
                }
            }
        }));
    }
    for worker in crew {
        worker.join().expect("no thread should panic");
    }
    assert_eq!(counted.load(Ordering::Relaxed), THREADS * 100 * 8);
}

/// Handles are pooled, not per-thread-forever: a thread that finishes returns its
/// handle for the next one. Spawning far more threads than could ever run at once
/// checks that the pool does not grow without bound and that a handle a dead
/// thread used is still good.
#[test]
fn handles_outlive_the_threads_that_used_them() {
    let re = Arc::new(RegexBuilder::new("café").ignore_case(true).build().unwrap());
    for round in 0..40 {
        let mut crew = Vec::new();
        for _ in 0..8 {
            let re = Arc::clone(&re);
            crew.push(std::thread::spawn(move || {
                let text = format!("{}le CAFÉ noir", "é".repeat(round));
                let found = re.find(&text).expect("a match");
                assert_eq!(found.as_str(), "CAFÉ");
                assert_eq!(&text[found.range()], "CAFÉ");
            }));
        }
        for worker in crew {
            worker.join().expect("no thread should panic");
        }
    }
    // Still usable on the parent thread after every worker has gone.
    assert!(re.is_match("un café"));
}

/// A `Regex` that outlives the thread that compiled it, and is dropped on a third
/// one. The pool frees each handle exactly once, wherever it ends up.
#[test]
fn compile_on_one_thread_drop_on_another() {
    let built = std::thread::spawn(|| Regex::new(r"\d+").unwrap())
        .join()
        .unwrap();
    let used = std::thread::spawn(move || {
        assert_eq!(built.find_iter("a1 b22").count(), 2);
        built
    })
    .join()
    .unwrap();
    std::thread::spawn(move || drop(used)).join().unwrap();
}
