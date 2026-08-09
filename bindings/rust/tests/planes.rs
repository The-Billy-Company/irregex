//! The eight planes the ABI grew after the regex face: `lines`, `literals`,
//! `needles`, `unicode`, `codex`, and the three corpus planes `walk`, `tree` and
//! `sieve`.
//!
//! What these tests are FOR, since `quality/parity/check.py` already proves the
//! symbols are named: naming a symbol is not calling it. Every `#[repr(C)]` struct
//! here is checked by the library against a `struct_size` this crate stamps, and
//! every enumerating verb speaks a `cap`/`written` dialect that a binding can get
//! subtly wrong in a way that returns success and a truncated answer. Both
//! failures are invisible to a linker and to a parity gate. So the assertions
//! below are deliberately about the shapes a mistake would take:
//!
//! * **A rejected struct.** Every `describe`/`measure`/`limits` verb is called and
//!   its result asserted, not merely reached: a size disagreement comes back as
//!   `IRGX_INVALID`, so an unchecked call would pass while the field it filled in
//!   stayed zero.
//! * **A truncated answer.** The enumerating verbs are asked for answers LARGER
//!   than the first buffer this crate offers, so the retry is exercised rather
//!   than skipped. `lines::split` over 500 rows and `needles::find_all` over
//!   hundreds of hits both start from a hint far below the true count.
//! * **A declinature read as emptiness.** Where a tier can step aside, the test
//!   asserts on the `Answer` rather than on a length — the bug being guarded is a
//!   binding that turns "I cannot narrow this" into "nothing matches".
//! * **A borrow that outlived its owner.** `tests/borrows.rs` holds that one, at
//!   compile time, because that is the only place it can be held.
//!
//! Both corpus iterators yield a `Result` per item, as `std::fs::ReadDir` does and
//! for the same reason: a walk of a real tree can fail on the ninth file after
//! succeeding on eight, and a plane that reads a filesystem cannot promise
//! otherwise. The `.unwrap()`s below are a test asserting no such fault occurred.

use std::fs;
use std::path::Path;

use irgx::corpus::{
    Corpus,
    sieve::{Sieve, Winnow},
    tree::{Kind, Query},
    walk::{self, Genus, Policy, Spec, Walk},
};
use irgx::{Answer, Regex, codex, lines, needles, promise, unicode};

// ── lines: the grid, and the off-by-one that lives here ──────────────────────

#[test]
fn rows_are_numbered_from_one_and_the_last_may_be_unterminated() {
    let text = b"alpha\nbeta\ngamma";
    assert_eq!(lines::count(text).unwrap(), 3, "the tail counts as a row");

    let rows = lines::split(text).unwrap();
    assert_eq!(rows.len(), 3);
    assert_eq!(rows[0].number(), 1, "rows are 1-based, as an editor counts");
    assert_eq!(rows[0].content(text), b"alpha");
    assert_eq!(rows[0].with_terminator(text), b"alpha\n");
    assert!(!rows[0].is_unterminated());

    let last = &rows[2];
    assert_eq!(last.content(text), b"gamma");
    assert!(last.is_unterminated(), "no trailing newline in the input");
    assert_eq!(
        last.with_terminator(text),
        b"gamma",
        "there is no terminator to include"
    );
}

#[test]
fn empty_text_holds_no_rows() {
    assert_eq!(lines::count(b"").unwrap(), 0);
    assert!(lines::split(b"").unwrap().is_empty());
}

#[test]
fn a_row_locates_a_byte_within_itself() {
    let text = b"alpha\nbeta\n";
    let rows = lines::split(text).unwrap();
    let beta = &rows[1];
    assert!(beta.holds(6));
    assert!(!beta.holds(0));
    assert_eq!(
        beta.column(6),
        1,
        "columns are 1-based, to pair with number()"
    );
    assert_eq!(beta.column(8), 3);
    assert_eq!(
        beta.range(),
        6..10,
        "the range is the content, terminator excluded"
    );
    assert_eq!(beta.content(text), b"beta");
    assert_eq!(beta.with_terminator(text), b"beta\n");
    assert!(beta.holds(10), "the terminator belongs to the row it ends");
}

#[test]
fn split_retries_past_its_first_guess() {
    // 500 rows against a hint that cannot hold them: the `cap`/`written` retry is
    // the thing under test, and a binding that read `written` as "how many fit"
    // would return a short Vec here and call it success.
    let text: Vec<u8> = (0..500)
        .flat_map(|i| format!("row {i}\n").into_bytes())
        .collect();
    let rows = lines::split(&text).unwrap();
    assert_eq!(rows.len(), 500);
    assert_eq!(
        u64::try_from(rows.len()).unwrap(),
        lines::count(&text).unwrap()
    );
    assert_eq!(rows[499].content(&text), b"row 499");
    assert_eq!(rows[499].number(), 500);
}

#[test]
fn a_context_band_knows_which_row_was_asked_about() {
    let text = b"one\ntwo\nthree\nfour\nfive\n";
    // "three" starts at 8.
    let band = lines::context(text, 8, 1, 1).unwrap();
    assert_eq!(band.rows().len(), 3);
    assert_eq!(band.focus().unwrap().content(text), b"three");

    let (before, focus, after) = band.around();
    assert_eq!(before.len(), 1);
    assert_eq!(before[0].content(text), b"two");
    assert_eq!(focus.unwrap().content(text), b"three");
    assert_eq!(after.len(), 1);
    assert_eq!(after[0].content(text), b"four");
}

#[test]
fn a_band_clamps_at_the_edges_rather_than_refusing() {
    let text = b"one\ntwo\n";
    let band = lines::context(text, 0, 5, 5).unwrap();
    assert_eq!(band.rows().len(), 2, "there is no row before the first");
    assert_eq!(band.center(), 0);
    let (before, focus, after) = band.around();
    assert!(before.is_empty());
    assert_eq!(focus.unwrap().content(text), b"one");
    assert_eq!(after.len(), 1);
}

// ── literals: what a pattern promises about every byte it can match ──────────

#[test]
fn a_literal_prefix_is_extracted_and_priced() {
    let re = Regex::new("hello (world|there)").unwrap();
    let Answer::Given(lits) = promise::Literals::open(&re).unwrap() else {
        panic!("a pattern with a literal run should have a promise");
    };
    let p = lits.promise().unwrap();
    assert!(!p.is_nullable(), "this pattern cannot match empty");
    assert!(p.min_len() >= "hello there".len());
    assert!(p.may_start_with(b'h'));
    assert!(
        !p.may_start_with(b'z'),
        "first-byte knowledge is what a prefilter runs on"
    );
    assert!(p.first_bytes_known());

    let set = lits.set(promise::Place::Prefix).unwrap();
    assert!(!set.is_empty(), "`hello ` is a prefix every match carries");
    assert!(
        set.iter()
            .all(|lit| b"hello ".starts_with(&lit[..lit.len().min(6)])),
        "every extracted prefix must really be one: {:?}",
        set.iter().map(String::from_utf8_lossy).collect::<Vec<_>>()
    );
}

#[test]
fn a_whole_match_set_is_exact_and_eliminating() {
    let re = Regex::new("cat|dog").unwrap();
    let Answer::Given(lits) = promise::Literals::open(&re).unwrap() else {
        panic!("an alternation of literals is the exact case");
    };
    let set = lits.set(promise::Place::Whole).unwrap();
    assert!(
        set.verdict().eliminates(),
        "an exact set means a match IS one of these, so a miss is a real miss"
    );
    let mut got: Vec<_> = set.iter().map(|l| l.to_vec()).collect();
    got.sort();
    assert_eq!(got, vec![b"cat".to_vec(), b"dog".to_vec()]);
}

#[test]
fn a_pattern_with_no_literal_floor_still_answers() {
    // `.+` promises nothing extractable. The honest answer is a promise whose sets
    // do not eliminate — never a fabricated literal, and never an error.
    let re = Regex::new(".+").unwrap();
    match promise::Literals::open(&re).unwrap() {
        Answer::Given(lits) => {
            let p = lits.promise().unwrap();
            assert!(
                !promise::Place::ALL
                    .iter()
                    .any(|place| p.verdict(*place).eliminates()),
                "nothing about `.+` can rule a document out"
            );
        },
        Answer::Declined => {},
    }
}

// ── unicode: the tables this engine folds with ───────────────────────────────

#[test]
fn a_fold_orbit_carries_every_spelling_including_the_one_asked_for() {
    let orbit = unicode::orbit('k').unwrap();
    assert!(orbit.contains(&'k'));
    assert!(orbit.contains(&'K'));
    assert!(
        orbit.contains(&'\u{212A}'),
        "KELVIN SIGN folds to k, and a caseless matcher that misses it is wrong"
    );

    // Final sigma: the three-way orbit that catches a naive fold.
    let sigma = unicode::orbit('\u{3C3}').unwrap();
    assert!(sigma.contains(&'\u{3C2}'), "final sigma");
    assert!(sigma.contains(&'\u{3A3}'), "capital sigma");
}

#[test]
fn a_codepoint_with_no_other_spelling_orbits_alone() {
    let orbit = unicode::orbit('7').unwrap();
    assert_eq!(orbit, vec!['7'], "a digit folds to itself and nothing else");
}

#[test]
fn a_property_is_a_range_list_that_agrees_with_the_membership_test() {
    let ranges = unicode::property("Nd").unwrap();
    assert!(!ranges.is_empty());
    assert!(
        ranges.iter().any(|r| r.holds('0') && r.holds('9')),
        "ASCII digits live in Nd"
    );
    // The two verbs must not disagree: one is the table, the other is the lookup.
    for c in ['0', '9', '\u{660}'] {
        assert!(unicode::holds("Nd", c).unwrap(), "{c:?} is a decimal digit");
        assert!(ranges.iter().any(|r| r.holds(c)), "{c:?} in the range list");
    }
    for c in ['a', ' ', '!'] {
        assert!(!unicode::holds("Nd", c).unwrap());
        assert!(!ranges.iter().any(|r| r.holds(c)));
    }
}

#[test]
fn an_unknown_property_is_refused_rather_than_answered_false() {
    // The failure this guards: reading "no such property" as "the codepoint is not
    // in it", which makes every typo silently match nothing.
    assert!(unicode::holds("NotAProperty", 'a').is_err());
    assert!(unicode::property("NotAProperty").is_err());
}

#[test]
fn the_unicode_version_is_reported() {
    let version = unicode::version();
    assert!(
        version
            .split('.')
            .next()
            .and_then(|m| m.parse::<u32>().ok())
            .is_some_and(|m| m >= 15),
        "expected a real Unicode version, got {version:?}"
    );
}

// ── needles: many literals, one pass, with attribution ───────────────────────

#[test]
fn every_seated_needle_is_found_and_attributed() {
    let terms = ["alpha", "beta", "gamma"];
    let n = needles::Needles::new(&terms).unwrap();
    assert_eq!(n.seated(), 3);
    assert_eq!(n.offered(), 3);

    let shape = n.shape().unwrap();
    assert_eq!(shape.len(), 3);
    assert_eq!(shape.longest(), 5);
    assert_eq!(shape.bytes(), 5 + 4 + 5);

    let text = b"gamma then alpha then gamma";
    assert!(n.is_match(text).unwrap());

    let which = n.which(text).unwrap();
    assert!(which.contains(&0), "alpha is present");
    assert!(!which.contains(&1), "beta is not, and must not be reported");
    assert!(which.contains(&2));

    let hits = n.find_all(text).unwrap();
    assert_eq!(hits.len(), 3, "gamma twice, alpha once");
    for hit in &hits {
        assert_eq!(
            hit.as_bytes(text),
            terms[hit.needle()].as_bytes(),
            "the span a hit reports must hold the needle it is attributed to"
        );
    }
    assert_eq!(hits[0].range().start, 0);
}

#[test]
fn a_needle_absent_from_the_text_is_not_reported() {
    let n = needles::Needles::new(&["zebra"]).unwrap();
    assert!(!n.is_match(b"nothing here").unwrap());
    assert!(n.which(b"nothing here").unwrap().is_empty());
    assert!(n.find_all(b"nothing here").unwrap().is_empty());
}

#[test]
fn find_all_retries_past_its_first_guess() {
    // Hundreds of hits from three needles: the retry path again, on the plane
    // where a truncated answer would read as a correct one.
    let n = needles::Needles::new(&["ab", "cd", "ef"]).unwrap();
    let text = b"abcdef".repeat(200);
    let hits = n.find_all(&text).unwrap();
    assert_eq!(hits.len(), 600);
    assert!(
        hits.windows(2)
            .all(|w| w[0].range().start <= w[1].range().start)
    );
}

#[test]
fn an_empty_needle_is_refused_by_name() {
    // An empty needle matches at every position, so admitting one would make the
    // whole set useless. The refusal must say WHICH term.
    let err = needles::Needles::new(&["ok", "", "also ok"]).unwrap_err();
    let text = err.to_string();
    assert!(
        text.contains('1') || text.to_lowercase().contains("empty"),
        "a refusal should name the offending term: {text}"
    );
}

// ── codex: an index that answers about a text it does not store ──────────────

#[test]
fn counting_costs_the_pattern_not_the_corpus() {
    let cx = codex::Codex::build(b"mississippi").unwrap();
    assert_eq!(cx.len(), 11);
    assert!(!cx.is_empty());
    assert_eq!(cx.count(b"ssi").unwrap(), 2);
    assert_eq!(cx.count(b"i").unwrap(), 4);
    assert_eq!(cx.count(b"zzz").unwrap(), 0, "absent is zero, not an error");
}

#[test]
fn locate_gives_the_offsets_and_extract_gives_the_text_back() {
    let cx = codex::Codex::build(b"mississippi").unwrap();
    match cx.locate(b"ssi").unwrap() {
        Answer::Given(mut at) => {
            at.sort_unstable();
            assert_eq!(at, vec![2, 5]);
        },
        Answer::Declined => panic!("built with the locate layer, so it must locate"),
    }
    assert_eq!(cx.extract(0).unwrap(), b"mississippi");
    assert_eq!(cx.extract(7).unwrap(), b"ippi");
    assert_eq!(
        cx.extract(11).unwrap(),
        b"",
        "the end is a legal, empty answer"
    );
    assert!(
        cx.extract(12).is_err(),
        "past the end is arithmetic, not a question"
    );
}

#[test]
fn an_absent_pattern_is_an_empty_answer_not_a_declinature() {
    // The other side of the same coin: with a locate layer present, a pattern that
    // simply is not there is `Given([])`. Collapsing this into `Declined` would
    // send a caller off to a second tier to re-answer a question already answered.
    let cx = codex::Codex::build(b"mississippi").unwrap();
    match cx.locate(b"zzz").unwrap() {
        Answer::Given(at) => assert!(at.is_empty()),
        Answer::Declined => panic!("this index can locate; the pattern is merely absent"),
    }
}

#[test]
fn without_the_locate_layer_it_declines_rather_than_answering_empty() {
    // The distinction the `Answer` type exists for: this index CAN count and
    // cannot locate. An empty Vec here would read as "the pattern is absent".
    let options = codex::Options::new().without_locating();
    let cx = codex::Codex::build_with(b"mississippi", &options).unwrap();
    assert_eq!(cx.count(b"ssi").unwrap(), 2, "counting still works");
    assert!(matches!(cx.locate(b"ssi").unwrap(), Answer::Declined));
    assert!(!cx.measure().unwrap().locates());
}

#[test]
fn the_backward_search_step_narrows_to_the_same_count() {
    let cx = codex::Codex::build(b"mississippi").unwrap();
    let mut rows = cx.rows().unwrap();
    assert_eq!(rows.len(), 12, "the whole interval is len + 1 rows");
    // Right to left, as the backward step runs.
    for byte in b"ssi".iter().rev() {
        assert!(cx.narrow(&mut rows, *byte).unwrap());
    }
    assert_eq!(rows.len(), cx.count(b"ssi").unwrap());

    // An interval that has emptied stays empty, so the first false is final.
    let mut gone = cx.rows().unwrap();
    assert!(!cx.narrow(&mut gone, b'z').unwrap());
    assert!(gone.is_empty());
    assert!(!cx.narrow(&mut gone, b'i').unwrap());
}

#[test]
fn an_index_survives_a_round_trip_through_bytes() {
    let cx = codex::Codex::build(b"the quick brown fox").unwrap();
    let saved = cx.save().unwrap();
    assert!(!saved.is_empty());

    let back = codex::Codex::load(&saved).unwrap();
    assert_eq!(back.len(), cx.len());
    assert_eq!(back.count(b"quick").unwrap(), 1);
    assert_eq!(back.extract(0).unwrap(), b"the quick brown fox");
}

#[test]
fn a_corrupt_index_is_refused_rather_than_trusted() {
    let mut saved = codex::Codex::build(b"mississippi").unwrap().save().unwrap();
    saved[4] ^= 0xFF;
    assert!(
        codex::Codex::load(&saved).is_err(),
        "a mangled index must not load: every later answer would be silently wrong"
    );
    assert!(codex::Codex::load(b"").is_err());
}

#[test]
fn an_empty_text_indexes_and_answers_honestly() {
    let cx = codex::Codex::build(b"").unwrap();
    assert_eq!(cx.len(), 0);
    assert!(cx.is_empty());
    assert_eq!(cx.count(b"a").unwrap(), 0);
    assert_eq!(cx.extract(0).unwrap(), b"");
}

#[test]
fn the_measurement_struct_is_accepted_and_filled() {
    // A `struct_size` disagreement comes back as INVALID, which `measure` turns
    // into an Err — so this asserts the crate's declaration matches the library's.
    let cx = codex::Codex::build(b"mississippi").unwrap();
    let stats = cx.measure().unwrap();
    assert_eq!(stats.text_len(), 11);
    assert!(stats.sample_rate() > 0, "a filled struct, not a zeroed one");
    assert!(stats.index_bytes() > 0);
    assert!(stats.locates());
    assert!(codex::Codex::max_text_len() > 0);
}

// ── walk: which files a search may even read ─────────────────────────────────

/// A small tree with one of each genus, a dotfile, an ignore file and a nested
/// directory — enough for eligibility to be a real question.
fn plant() -> tempfile::TempDir {
    let dir = tempfile::tempdir().expect("a temp dir");
    let root = dir.path();
    fs::write(root.join("main.rs"), "fn main() {}\n").unwrap();
    fs::write(root.join("README.md"), "# docs\nprose here\n").unwrap();
    fs::write(root.join("config.toml"), "key = \"value\"\n").unwrap();
    fs::write(root.join(".hidden"), "not by default\n").unwrap();
    fs::write(root.join(".gitignore"), "ignored.rs\n").unwrap();
    fs::write(root.join("ignored.rs"), "fn skipped() {}\n").unwrap();
    fs::create_dir(root.join("nested")).unwrap();
    fs::write(root.join("nested/deep.rs"), "fn deep() {}\n").unwrap();
    dir
}

/// The paths a walk yielded, relative to `root`, sorted — so an assertion reads
/// as the eligible SET rather than as an iteration order.
fn eligible(walk: &mut Walk, root: &Path) -> Vec<String> {
    let mut found: Vec<String> = walk
        .entries()
        .map(|entry| {
            let entry = entry.expect("the planted tree is readable");
            let path = Path::new(entry.path_str().expect("utf-8 in a planted tree"));
            path.strip_prefix(root)
                .unwrap_or(path)
                .to_string_lossy()
                .replace('\\', "/")
        })
        .collect();
    found.sort();
    found
}

#[test]
fn a_walk_honours_gitignore_and_skips_hidden_by_default() {
    let dir = plant();
    let root = dir.path();
    let mut walk = Walk::open(&Spec::new().root(root)).unwrap();

    let found = eligible(&mut walk, root);
    assert!(found.contains(&"main.rs".to_owned()));
    assert!(found.contains(&"README.md".to_owned()));
    assert!(found.contains(&"nested/deep.rs".to_owned()));
    assert!(
        !found.contains(&"ignored.rs".to_owned()),
        ".gitignore is honoured with no policy set: {found:?}"
    );
    assert!(
        !found.iter().any(|p| p.starts_with('.')),
        "hidden entries stay out by default: {found:?}"
    );
    assert_eq!(
        walk.len(),
        found.len(),
        "the count must match what it yields"
    );
    assert_eq!(walk.gapped(), 0, "nothing was unreadable");
}

#[test]
fn a_policy_declines_a_default_and_the_set_grows() {
    let dir = plant();
    let root = dir.path();

    let mut plain = Walk::open(&Spec::new().root(root)).unwrap();
    let without = eligible(&mut plain, root);

    let mut lax = Walk::open(&Spec::new().root(root).with(Policy::NoIgnoreVcs)).unwrap();
    let with = eligible(&mut lax, root);

    assert!(
        with.contains(&"ignored.rs".to_owned()),
        "declining .gitignore must admit the file it hid: {with:?}"
    );
    assert!(with.len() > without.len());
}

#[test]
fn a_glob_narrows_and_its_negation_is_the_complement() {
    let dir = plant();
    let root = dir.path();

    let mut only = Walk::open(&Spec::new().root(root).glob("*.rs")).unwrap();
    let rs = eligible(&mut only, root);
    assert!(rs.iter().all(|p| p.ends_with(".rs")), "{rs:?}");
    assert!(rs.contains(&"main.rs".to_owned()));

    let mut without = Walk::open(&Spec::new().root(root).not_glob("*.rs")).unwrap();
    let others = eligible(&mut without, root);
    assert!(others.iter().all(|p| !p.ends_with(".rs")), "{others:?}");
    assert!(others.contains(&"README.md".to_owned()));
}

#[test]
fn max_depth_bounds_the_descent() {
    let dir = plant();
    let root = dir.path();
    let mut shallow = Walk::open(&Spec::new().root(root).max_depth(1)).unwrap();
    let found = eligible(&mut shallow, root);
    assert!(
        !found.contains(&"nested/deep.rs".to_owned()),
        "depth 1 must not descend: {found:?}"
    );
}

#[test]
fn membership_agrees_with_iteration() {
    let dir = plant();
    let root = dir.path();
    let mut walk = Walk::open(&Spec::new().root(root)).unwrap();
    let found = eligible(&mut walk, root);
    assert!(walk.holds(&root.join("main.rs")));
    assert!(
        !walk.holds(&root.join("ignored.rs")),
        "holds() must agree with what the walk yielded: {found:?}"
    );
    assert!(!walk.holds(&root.join("does-not-exist.rs")));
}

#[test]
fn rewind_replays_the_same_set() {
    let dir = plant();
    let root = dir.path();
    let mut walk = Walk::open(&Spec::new().root(root)).unwrap();
    let first = eligible(&mut walk, root);
    assert!(!first.is_empty());
    assert!(
        eligible(&mut walk, root).is_empty(),
        "a spent walk yields nothing until it is rewound"
    );
    walk.rewind();
    assert_eq!(eligible(&mut walk, root), first);
}

#[test]
fn one_at_a_time_and_batched_iteration_agree() {
    let dir = plant();
    let root = dir.path();
    let mut walk = Walk::open(&Spec::new().root(root)).unwrap();
    let batched = eligible(&mut walk, root);

    walk.rewind();
    let mut single = Vec::new();
    while let Some(entry) = walk.next_entry().unwrap() {
        single.push(entry.path().to_vec());
    }
    assert_eq!(single.len(), batched.len(), "the two pull verbs must agree");
}

#[test]
fn an_entry_carries_its_size_and_what_the_file_is_for() {
    let dir = plant();
    let root = dir.path();
    let mut walk = Walk::open(&Spec::new().root(root)).unwrap();
    let mut seen = Vec::new();
    for entry in walk.entries() {
        let entry = entry.unwrap();
        let path = entry.path_str().unwrap().to_owned();
        seen.push((path, entry.size(), entry.genus()));
    }
    let readme = seen
        .iter()
        .find(|(p, ..)| p.ends_with("README.md"))
        .unwrap();
    assert_eq!(readme.2, Genus::Docs, "markdown is the paper trail");
    let toml = seen
        .iter()
        .find(|(p, ..)| p.ends_with("config.toml"))
        .unwrap();
    assert_eq!(toml.2, Genus::Data);
    let code = seen.iter().find(|(p, ..)| p.ends_with("main.rs")).unwrap();
    assert_eq!(code.2, Genus::Code);

    assert!(
        seen.iter().all(|(_, size, _)| *size == 0),
        "this walk read no file, so every size is 0 rather than a guess"
    );
}

#[test]
fn a_size_arrives_only_when_the_walk_was_asked_to_read() {
    // The two modes of one field: 0 means "never asked", and under Members it
    // cannot be 0, because an empty file is not a member. So a host never needs a
    // second field to know whether the first is set.
    let dir = plant();
    let root = dir.path();
    let mut walk = Walk::open(&Spec::new().root(root).with(Policy::Members)).unwrap();
    let sizes: Vec<u64> = walk.entries().map(|e| e.unwrap().size()).collect();
    assert!(!sizes.is_empty());
    assert!(
        sizes.iter().all(|size| *size > 0),
        "under Members every entry is a real file with real bytes: {sizes:?}"
    );
}

#[test]
fn genus_is_a_total_partition_with_no_gap_to_fall_through() {
    assert_eq!(walk::genus(Path::new("a/b.md")).unwrap(), Genus::Docs);
    assert_eq!(walk::genus(Path::new("a/b.json")).unwrap(), Genus::Data);
    assert_eq!(walk::genus(Path::new("a/b.rs")).unwrap(), Genus::Code);
    assert_eq!(
        walk::genus(Path::new("a/b.wat-is-this")).unwrap(),
        Genus::Code,
        "an unfamiliar extension must land in Code, never in a gap"
    );
    assert_eq!(walk::genus(Path::new("LICENSE")).unwrap(), Genus::Docs);
}

#[test]
fn binary_detection_reads_the_bytes_not_the_name() {
    assert!(!walk::is_binary(b"plain text\nwith rows\n"));
    assert!(walk::is_binary(b"ELF\0\0\0\0binary"));
    assert!(!walk::is_binary(b""), "nothing is not binary");
    assert!(
        !walk::is_binary("caf\u{e9} na\u{ef}ve \u{4e2d}\u{6587}".as_bytes()),
        "valid UTF-8 is text no matter how high the codepoints go"
    );
}

#[test]
fn the_limits_struct_is_accepted_and_filled() {
    let limits = Walk::limits().unwrap();
    assert!(
        limits.binary_window() > 0,
        "a filled struct, not a zeroed one"
    );
    assert!(limits.file_cap() > 0);
    assert!(limits.type_rows() > 0);
    assert!(limits.type_names() >= limits.type_rows());
}

#[test]
fn a_spec_with_no_root_walks_the_working_directory() {
    // Not an empty question: an all-defaults spec is `rg pat` with no path, which
    // descends the CWD. A binding that documented this as "walks nothing" would
    // send a caller looking for the bug in their own root handling.
    let walk = Walk::open(&Spec::new()).unwrap();
    assert!(
        !walk.is_empty(),
        "the crate's own source tree is the CWD under `cargo test`"
    );
    assert!(
        walk.holds(Path::new("Cargo.toml")),
        "and paths carry no ./ prefix"
    );
}

#[test]
fn naming_a_root_explicitly_is_the_same_walk_with_prefixed_paths() {
    // The one visible difference the header calls out, held here so it cannot
    // drift into a surprise.
    let mut rootless = Walk::open(&Spec::new()).unwrap();
    let mut dotted = Walk::open(&Spec::new().root(Path::new("."))).unwrap();
    assert_eq!(rootless.len(), dotted.len(), "the same eligible set");

    let bare: Vec<String> = rootless
        .entries()
        .map(|e| e.unwrap().path_str().unwrap().to_owned())
        .collect();
    let prefixed: Vec<String> = dotted
        .entries()
        .map(|e| e.unwrap().path_str().unwrap().to_owned())
        .collect();
    assert!(bare.iter().all(|p| !p.starts_with("./")));
    assert!(
        prefixed.iter().all(|p| p.starts_with("./")),
        "as `rg pat .` prints them"
    );
}

// ── tree: searching a corpus rather than a buffer ────────────────────────────

#[test]
fn a_corpus_search_reports_the_file_the_row_and_the_span() {
    let dir = plant();
    let corpus = Corpus::open(&[dir.path()]).unwrap();
    let Answer::Given(mut search) = corpus.search(&Query::new(b"fn main")).unwrap() else {
        panic!("the pattern is in the planted tree");
    };
    let mut hits = 0;
    for record in search.records() {
        let record = record.unwrap();
        hits += 1;
        assert!(
            record.path_str().unwrap().ends_with("main.rs"),
            "only main.rs holds `fn main`: {:?}",
            record.path_str()
        );
        assert_eq!(record.line_number(), 1);
        assert_eq!(record.kind(), Kind::Line);
        let spans: Vec<_> = record.highlights().collect();
        assert_eq!(spans.len(), 1);
        assert_eq!(
            &record.line()[spans[0].clone()],
            b"fn main",
            "a highlight must index the row it came with"
        );
    }
    assert_eq!(hits, 1);
}

#[test]
fn a_pattern_absent_from_the_corpus_yields_no_records() {
    let dir = plant();
    let corpus = Corpus::open(&[dir.path()]).unwrap();
    match corpus.search(&Query::new(b"nothing_here_at_all")).unwrap() {
        Answer::Given(mut search) => assert_eq!(search.records().count(), 0),
        Answer::Declined => {},
    }
}

#[test]
fn context_rows_arrive_beside_the_matching_row_and_are_marked() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("f.txt"), "one\ntwo\nTARGET\nfour\nfive\n").unwrap();
    let corpus = Corpus::open(&[dir.path()]).unwrap();
    let query = Query::new(b"TARGET").context(1, 1);
    let Answer::Given(mut search) = corpus.search(&query).unwrap() else {
        panic!("the pattern is there");
    };
    let rows: Vec<(u64, Kind, Vec<u8>)> = search
        .records()
        .map(|r| r.unwrap())
        .map(|r| (r.line_number(), r.kind(), r.line().to_vec()))
        .collect();
    assert_eq!(rows.len(), 3, "before, match, after: {rows:?}");
    let matched: Vec<_> = rows.iter().filter(|(_, k, _)| *k == Kind::Line).collect();
    assert_eq!(matched.len(), 1, "exactly one row is the match itself");
    assert_eq!(matched[0].0, 3);
    assert!(
        rows.iter().filter(|(_, k, _)| *k == Kind::Context).count() == 2,
        "the other two are context, and must say so: {rows:?}"
    );
}

#[test]
fn a_fixed_query_takes_metacharacters_literally() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("f.txt"), "a.c\nabc\n").unwrap();
    let corpus = Corpus::open(&[dir.path()]).unwrap();

    let Answer::Given(mut regex) = corpus.search(&Query::new(b"a.c")).unwrap() else {
        panic!("`a.c` as a regex matches both rows");
    };
    assert_eq!(regex.records().count(), 2, "`.` is any byte");

    let Answer::Given(mut fixed) = corpus.search(&Query::new(b"a.c").fixed(true)).unwrap() else {
        panic!("`a.c` literally matches one row");
    };
    let found: Vec<_> = fixed
        .records()
        .map(|r| r.unwrap().line().to_vec())
        .collect();
    assert_eq!(found, vec![b"a.c".to_vec()]);
}

#[test]
fn max_results_bounds_the_stream() {
    let dir = tempfile::tempdir().unwrap();
    let body: String = (0..50).map(|i| format!("hit {i}\n")).collect();
    fs::write(dir.path().join("many.txt"), body).unwrap();
    let corpus = Corpus::open(&[dir.path()]).unwrap();
    let Answer::Given(mut search) = corpus.search(&Query::new(b"hit").max_results(5)).unwrap()
    else {
        panic!("the pattern is there");
    };
    assert_eq!(search.records().count(), 5);
}

#[test]
fn a_cancelled_search_stops_rather_than_finishing() {
    let dir = plant();
    let corpus = Corpus::open(&[dir.path()]).unwrap();
    let cancel = irgx::corpus::Cancel::new().unwrap();
    cancel.request();
    // Already cancelled before the search starts: the contract is that it does
    // not run to completion, whether it declines, errors, or yields nothing.
    let query = Query::new(b"fn").cancel(&cancel);
    match corpus.search(&query) {
        Ok(Answer::Given(mut search)) => {
            assert_eq!(
                search.records().count(),
                0,
                "a cancelled search produces nothing"
            );
        },
        Ok(Answer::Declined) | Err(_) => {},
    }
}

#[test]
fn the_one_at_a_time_record_verb_agrees_with_the_batched_one() {
    let dir = plant();
    let corpus = Corpus::open(&[dir.path()]).unwrap();

    let Answer::Given(mut batched) = corpus.search(&Query::new(b"fn")).unwrap() else {
        panic!("the pattern is there");
    };
    let by_batch: Vec<_> = batched
        .records()
        .map(|r| r.unwrap().line().to_vec())
        .collect();

    let Answer::Given(mut single) = corpus.search(&Query::new(b"fn")).unwrap() else {
        panic!("the pattern is there");
    };
    let mut by_one = Vec::new();
    while let Some(record) = single.next_record().unwrap() {
        by_one.push(record.line().to_vec());
    }
    assert_eq!(
        by_one, by_batch,
        "the two pull verbs must produce one sequence"
    );
}

// ── sieve: narrowing, and a plan derived from the pattern ────────────────────

#[test]
fn a_tree_with_no_index_declines_rather_than_narrowing_to_nothing() {
    // The most important assertion in this file. "No index built" must not read
    // as "no candidate documents" — one means read every file, the other means
    // read none, and they are the same empty Vec if a binding gets it wrong.
    let dir = tempfile::tempdir().unwrap();
    assert!(
        matches!(Sieve::at(dir.path()).unwrap(), Answer::Declined),
        "an empty directory holds no artifacts, and that is not a fault"
    );
}

#[test]
fn an_empty_artifact_location_is_refused_not_read_as_the_home() {
    // A caller that built a path and got an empty one has a bug; silently
    // resolving it to the artifact home would hide it.
    assert!(Sieve::at(Path::new("")).is_err());
}

#[test]
fn a_narrowing_plan_is_derived_from_the_pattern_and_describes_itself() {
    let re = Regex::new("WalletService").unwrap();
    let plan = Winnow::of(&re).unwrap();
    let facts = plan.facts().unwrap();
    assert!(
        !facts.is_idle(),
        "a long literal is exactly what a trigram tier can narrow on"
    );
    assert!(facts.clauses() > 0, "a filled struct, not a zeroed one");
    assert!(facts.atoms() > 0);
}

#[test]
fn a_pattern_that_cannot_be_narrowed_says_so_instead_of_pretending() {
    // `.+` matches everywhere, so no index can rule a document out. `idle` is the
    // honest answer; an empty candidate list would be a lie.
    let re = Regex::new(".+").unwrap();
    let plan = Winnow::of(&re).unwrap();
    assert!(plan.facts().unwrap().is_idle());
}

#[test]
fn a_plan_outlives_the_pattern_it_came_from() {
    // The ABI states the plan copies what it needs. If it borrowed instead, this
    // would be a use-after-free rather than a passing test.
    let plan = {
        let re = Regex::new("mississippi").unwrap();
        Winnow::of(&re).unwrap()
    };
    assert!(plan.facts().unwrap().clauses() > 0);
}
