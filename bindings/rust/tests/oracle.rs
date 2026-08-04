//! Cross-check every answer against the Python binding.
//!
//! The Python binding was written against this same C ABI first, is
//! independently verified, and its own test suite pins the semantics. So it is
//! the oracle: `scripts/python_oracle.py` drives it over a corpus of pattern /
//! flag / text triples and records the spans and group spans it reports in
//! `testdata/python_oracle.json`, and this file asserts that the Rust binding
//! found the same matches.
//!
//! Found, not showed. The two bindings deliberately part company on which empty
//! matches they report - Python follows `re`, this crate follows `regex` - so
//! the assertion is that what this crate shows is the recorded sequence minus
//! some empty matches, never a different or reordered one. `tests/sequence.rs`
//! pins which ones, against the `regex` crate itself.
//!
//! The corpus is recorded in bytes. The Python binding reports codepoint indices
//! for a `str` pattern and byte offsets for a `bytes` one, and the generator asks
//! it in bytes, which is the like-for-like comparison: Rust `str` is indexed by
//! byte too. If the Rust binding needed an offset translation, this file is where
//! that would show up as an off-by-several on every non-ASCII case.

use std::collections::BTreeMap;

use irgx::{Regex, RegexBuilder};
use serde::Deserialize;

#[derive(Deserialize)]
struct Corpus {
    engine_version: String,
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    pattern: String,
    #[serde(default)]
    flags: BTreeMap<String, bool>,
    text: String,
    spans: Vec<[i64; 2]>,
    groups: Vec<Vec<[i64; 2]>>,
    is_match: bool,
}

impl Case {
    /// How the case names itself in a failure. Patterns and texts here contain
    /// newlines and non-ASCII, so both go through `Debug`.
    fn label(&self) -> String {
        format!(
            "case {} pattern {:?} flags {:?} text {:?}",
            self.name,
            self.pattern,
            self.flags.keys().collect::<Vec<_>>(),
            self.text
        )
    }

    fn compile(&self) -> Regex {
        let mut builder = RegexBuilder::new(&self.pattern);
        for (flag, &on) in &self.flags {
            match flag.as_str() {
                "fixed" => builder.fixed(on),
                "ignore_case" => builder.ignore_case(on),
                "word" => builder.word(on),
                "smart_case" => builder.smart_case(on),
                "unicode" => builder.unicode(on),
                "pcre" => builder.pcre(on),
                other => panic!("{}: unknown flag {other} in the corpus", self.label()),
            };
        }
        builder
            .build()
            .unwrap_or_else(|why| panic!("{}: {why}", self.label()))
    }
}

fn corpus() -> Corpus {
    let raw = include_str!("../testdata/python_oracle.json");
    serde_json::from_str(raw).expect("testdata/python_oracle.json should parse")
}

/// The corpus was generated against one engine build. A different one might be
/// right and the corpus stale, so say which is which rather than reporting a
/// hundred span mismatches.
#[test]
fn corpus_matches_the_linked_engine() {
    let found = irgx::engine_version();
    assert_eq!(
        corpus().engine_version,
        found,
        "testdata/python_oracle.json was generated against a different engine build than the \
         one linked here ({found}). Regenerate it with scripts/python_oracle.py."
    );
}

/// The recorded spans this crate is expected to show, and the reason any were
/// dropped - checked, not assumed.
///
/// The two bindings drive the same engine over the same bytes, so they find the
/// same matches. They do not SHOW the same ones: Python's `re` reports every
/// empty match and Rust's `regex` skips an empty match abutting the previous one
/// or sitting inside a character, and each binding follows its own ecosystem.
///
/// So the assertion here is the part that must hold regardless of convention -
/// what this crate shows is a subsequence of what the engine found, and every
/// span it dropped was empty. That is a real constraint (a non-nullable pattern
/// still gets exact equality, and no convention may ever drop a non-empty match
/// or reorder anything) and it deliberately does not re-derive WHICH empty spans
/// go. Re-deriving them here would just be the implementation restated as its
/// own oracle. `tests/sequence.rs` pins that exactly, against the `regex` crate
/// itself.
fn accounted(found: &[[i64; 2]], recorded: &[[i64; 2]], label: &str) {
    let mut showing = found.iter();
    for span in recorded {
        // Kept spans must appear in order; a skipped one must be empty.
        if showing.clone().next() == Some(span) {
            showing.next();
        } else {
            assert_eq!(
                span[0], span[1],
                "{label}: dropped {span:?}, which is not an empty match\n\
                 shown    {found:?}\n\
                 recorded {recorded:?}"
            );
        }
    }
    assert!(
        showing.next().is_none(),
        "{label}: shows a span the engine did not report\n\
         shown    {found:?}\n\
         recorded {recorded:?}"
    );
}

#[test]
fn spans_agree_with_the_python_binding() {
    let corpus = corpus();
    assert!(corpus.cases.len() > 50, "the corpus should be substantial");

    for case in &corpus.cases {
        let re = case.compile();
        let found: Vec<[i64; 2]> = re
            .try_find_iter(&case.text)
            .unwrap_or_else(|why| panic!("{}: {why}", case.label()))
            .map(|m| [m.start() as i64, m.end() as i64])
            .collect();
        accounted(&found, &case.spans, &case.label());
    }
}

/// The corpus has to actually contain the disagreement, or the test above is
/// only ever checking exact equality and the subsequence rule is untested.
#[test]
fn the_corpus_contains_a_case_where_the_two_conventions_differ() {
    let differs = corpus().cases.iter().any(|case| {
        let shown = case.compile().try_find_iter(&case.text).unwrap().count();
        shown != case.spans.len()
    });
    assert!(
        differs,
        "no case exercises the empty-match convention gap; add a nullable pattern"
    );
}

#[test]
fn group_spans_agree_with_the_python_binding() {
    for case in &corpus().cases {
        let re = case.compile();
        // A pattern whose capture arm the engine refuses has no group detail in
        // either binding, and the generator would have failed on it.
        let Some(groups) = re.groups() else {
            panic!("{}: the capture arm refused this pattern", case.label());
        };
        let found: Vec<Vec<[i64; 2]>> = re
            .try_captures_iter(&case.text)
            .unwrap_or_else(|why| panic!("{}: {why}", case.label()))
            .map(|caps| {
                (0..=groups)
                    .map(|at| match caps.get(at) {
                        // A group the match did not enter is `None` here and
                        // (-1, -1) in the corpus, which is what the C ABI itself
                        // reports. Both bindings have to distinguish it from a
                        // group that matched empty, which is (n, n).
                        None => [-1, -1],
                        Some(m) => [m.start() as i64, m.end() as i64],
                    })
                    .collect()
            })
            .collect();
        // A capture row belongs to a whole match, so the rows this crate shows
        // are the rows of the spans it shows - same subsequence, same reason.
        // Comparing on row 0 (the whole match) keeps this honest: it checks the
        // group detail rides the right match rather than merely lining up by
        // count.
        let whole = |row: &Vec<[i64; 2]>| row[0];
        accounted(
            &found.iter().map(whole).collect::<Vec<_>>(),
            &case.groups.iter().map(whole).collect::<Vec<_>>(),
            &case.label(),
        );
        for row in &found {
            let same = case
                .groups
                .iter()
                .find(|recorded| recorded[0] == row[0])
                .unwrap_or_else(|| panic!("{}: no recorded row at {:?}", case.label(), row[0]));
            assert_eq!(row, same, "{}: group detail differs", case.label());
        }
    }
}

/// `find_all` is the header's declared authority on the match sequence, and
/// `is_match` is a separate arm that stops at the first hit. Across the whole
/// corpus they agree about whether a match exists at all, with no exceptions.
///
/// This test carried an allowlist while `is_match` ran a boolean document kernel
/// that split the buffer into lines, which turned `^`, `$`, `\A` and `\z` into
/// per-line anchors and made `\Aabc\z` over `"x\nabc\ny"` a match to `is_match`
/// and no match to `find_all`. `is_match` now runs the same walk `find_all` runs,
/// stopped at the first span, and the header states that the buffer is one unit.
/// So the allowlist is gone and the assertion is plain agreement; a future
/// divergence is a failure with nowhere to be recorded.
#[test]
fn is_match_agrees_with_find_all() {
    for case in &corpus().cases {
        let re = case.compile();
        let said = re
            .try_is_match(&case.text)
            .unwrap_or_else(|why| panic!("{}: {why}", case.label()));
        // Both bindings drive the same engine, so a difference from the recorded
        // answer would mean the Rust side is calling the wrong verb.
        assert_eq!(
            said,
            case.is_match,
            "{}: is_match disagrees with the Python binding",
            case.label()
        );
        assert_eq!(
            said,
            !case.spans.is_empty(),
            "{}: find_all reports {} match(es) and is_match says {said}. find_all is the \
             header's authority on the sequence, so the two arms have diverged.",
            case.label(),
            case.spans.len()
        );
    }
}

/// The corpus is only an oracle if it exercises the shapes that break bindings.
#[test]
fn corpus_covers_the_hard_shapes() {
    let corpus = corpus();
    let names: Vec<&str> = corpus.cases.iter().map(|case| case.name.as_str()).collect();
    for required in [
        "star_nullable",   // nullable, where an advance loop goes wrong
        "empty_pattern",   // the degenerate case
        "word_boundary",   // zero-width
        "unicode_literal", // multi-byte offsets
        "ascii_class",     // byte semantics under unicode(false)
        "groups_optional", // a group that cannot participate
        "pcre_backref",    // the other grammar
        "word",            // a flag that filters the sequence
    ] {
        assert!(
            names.contains(&required),
            "the corpus should cover {required}"
        );
    }
    // Every flag the builder exposes should appear on some case, or the corpus
    // is not checking that the Rust flag maps to the same bit the Python one does.
    for flag in [
        "fixed",
        "ignore_case",
        "word",
        "smart_case",
        "unicode",
        "pcre",
    ] {
        assert!(
            corpus
                .cases
                .iter()
                .any(|case| case.flags.contains_key(flag)),
            "the corpus should exercise the {flag} flag"
        );
    }
}
