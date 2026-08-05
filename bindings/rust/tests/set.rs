//! `RegexSet`, asked of the `regex` crate itself.
//!
//! A set has two claims to make and they need different witnesses.
//!
//! The first is **agreement with `regex`**: drop this crate in where `regex` was
//! and `set.matches(text)` names the same patterns. That is a differential, and
//! it is run against the real `regex::RegexSet` rather than a frozen table,
//! because a table is a claim about `regex` at the moment somebody typed it.
//!
//! The second is **internal consistency**: a set names pattern `i` exactly when
//! `Regex::is_match` on pattern `i` alone would have said yes. The engine proves
//! this in its own suite, with the SIMD sieve on and off, which this crate cannot
//! reach from here — so what this file checks is that the crate did not lose it
//! in the plumbing. Both directions matter: a set that quietly dropped the
//! attribution and answered from a fused alternation would still pass a
//! `matched_any` test.

use irgx::{Regex, RegexSet, RegexSetBuilder};

/// The indices `irgx` reports, ascending.
fn ours(patterns: &[&str], text: &str) -> Vec<usize> {
    RegexSet::new(patterns)
        .unwrap()
        .matches(text)
        .iter()
        .collect()
}

/// The indices the `regex` crate reports for the same set and text.
fn theirs(patterns: &[&str], text: &str) -> Vec<usize> {
    regex::RegexSet::new(patterns)
        .unwrap()
        .matches(text)
        .iter()
        .collect()
}

/// Patterns chosen so a wrong UNIT would show: anchors that mean the text's ends
/// and not a line's, a class that has to cross a newline, and a nullable pattern
/// that matches everything including the empty text.
const PATTERNS: &[&str] = &[
    r"^b", r"c$", r"a\sb", r"x*", r"\bcat\b", r"\d+", r"héllo", r"q",
];

const TEXTS: &[&str] = &[
    "",
    "abc",
    "a\nb",
    "ab\ncd",
    "\n",
    "abc\n",
    "b",
    "a cat sat",
    "concatenate",
    "42",
    "héllo",
    "no match here",
];

#[test]
fn a_set_names_the_same_patterns_as_the_regex_crate() {
    for text in TEXTS {
        assert_eq!(
            ours(PATTERNS, text),
            theirs(PATTERNS, text),
            "over text {text:?}"
        );
    }
}

#[test]
fn every_subset_of_the_corpus_agrees_too() {
    // One set of eight is one shape. The interesting failures are in how a set is
    // ASSEMBLED - a sieve pooling literals across patterns, a fused gate built
    // only when every pattern shares one setting - so the differential runs over
    // every subset, which is where a set of one, a set of two literals, and a set
    // with no literal at all each get their turn.
    for mask in 0u32..(1 << PATTERNS.len()) {
        let chosen: Vec<&str> = PATTERNS
            .iter()
            .enumerate()
            .filter(|(at, _)| mask & (1 << at) != 0)
            .map(|(_, pattern)| *pattern)
            .collect();
        for text in TEXTS {
            assert_eq!(
                ours(&chosen, text),
                theirs(&chosen, text),
                "set {chosen:?} over text {text:?}"
            );
        }
    }
}

#[test]
fn a_set_agrees_with_the_same_patterns_compiled_one_at_a_time() {
    let set = RegexSet::new(PATTERNS).unwrap();
    let singles: Vec<Regex> = PATTERNS.iter().map(|p| Regex::new(p).unwrap()).collect();

    for text in TEXTS {
        let hits = set.matches(text);
        assert_eq!(hits.len(), PATTERNS.len(), "len is the SET's size");
        assert_eq!(
            hits.matched_any(),
            set.is_match(text),
            "the boolean verb and its own attribution disagree over {text:?}"
        );
        for (at, one) in singles.iter().enumerate() {
            assert_eq!(
                hits.matched(at),
                one.is_match(text),
                "pattern {:?} over text {text:?}",
                PATTERNS[at]
            );
        }
    }
}

#[test]
fn an_empty_set_matches_nothing_and_says_so() {
    for set in [
        RegexSet::empty(),
        RegexSet::new(Vec::<&str>::new()).unwrap(),
    ] {
        assert!(set.is_empty());
        assert_eq!(set.len(), 0);
        assert!(!set.is_match("anything at all"));
        let hits = set.matches("anything at all");
        assert!(!hits.matched_any());
        assert!(hits.is_empty());
        assert_eq!(hits.iter().count(), 0);
    }
}

#[test]
fn the_flags_reach_every_pattern() {
    let set = RegexSetBuilder::new(["café", "CIGAR"])
        .ignore_case(true)
        .build()
        .unwrap();
    assert_eq!(set.matches("le CAFÉ noir").iter().collect::<Vec<_>>(), [0]);
    assert_eq!(set.matches("a cigar").iter().collect::<Vec<_>>(), [1]);

    // `fixed` makes every metacharacter data, so the regex spelling stops
    // matching what it used to and starts matching itself.
    let fixed = RegexSetBuilder::new(["c.t"]).fixed(true).build().unwrap();
    assert!(!fixed.is_match("cat"));
    assert!(fixed.is_match("c.t"));

    // `word` is resolved per pattern by the engine, not by rewriting the pattern.
    let word = RegexSetBuilder::new(["cat"]).word(true).build().unwrap();
    assert!(word.is_match("a cat sat"));
    assert!(!word.is_match("concatenate"));

    // `smart_case` reads each pattern's own case, so one set holds both answers.
    let smart = RegexSetBuilder::new(["cat", "Cat"])
        .smart_case(true)
        .build()
        .unwrap();
    assert_eq!(smart.matches("CAT").iter().collect::<Vec<_>>(), [0]);
}

#[test]
fn a_refused_pattern_names_itself() {
    // Lookaround is outside the linear grammar and inside PCRE2's, so this is a
    // declinature that names the pattern to retry - not the first pattern, and
    // not a bare "one of them".
    let refusal = RegexSet::new(["a", "b", "c(?=at)"]).unwrap_err();
    let irgx::Error::NeedsPcre { pattern } = &refusal else {
        panic!("expected a declinature, got {refusal:?}");
    };
    assert_eq!(pattern, "c(?=at)");

    // And the retry the declinature described works.
    let set = RegexSetBuilder::new(["a", "b", "c(?=at)"])
        .pcre(true)
        .build()
        .unwrap();
    assert_eq!(set.matches("a cat").iter().collect::<Vec<_>>(), [0, 2]);

    // A malformed pattern is the other refusal, with the offset in the pattern
    // that caused it.
    let broken = RegexSet::new(["ok", "[z-a"]).unwrap_err();
    let (irgx::Error::Syntax { pattern, .. } | irgx::Error::Pattern { pattern, .. }) = &broken
    else {
        panic!("expected a syntax refusal, got {broken:?}");
    };
    assert_eq!(pattern, "[z-a");
}

#[test]
fn a_set_is_shareable_and_clonable() {
    let set = RegexSet::new([r"\d+", r"[a-z]+"]).unwrap();
    let clone = set.clone();
    assert_eq!(clone.patterns(), set.patterns());

    let total: usize = std::thread::scope(|scope| {
        let handles: Vec<_> = ["42", "abc", "42abc", "!!"]
            .map(|text| scope.spawn(|| set.matches(text).iter().count()))
            .into_iter()
            .collect();
        handles.into_iter().map(|h| h.join().unwrap()).sum()
    });
    assert_eq!(total, 4);
}

#[test]
fn matches_can_be_iterated_by_value_and_by_reference() {
    let hits = RegexSet::new(["a", "b", "c"]).unwrap().matches("ac");
    let by_ref: Vec<usize> = (&hits).into_iter().collect();
    let backwards: Vec<usize> = hits.iter().rev().collect();
    let by_value: Vec<usize> = hits.into_iter().collect();
    assert_eq!(by_ref, [0, 2]);
    assert_eq!(backwards, [2, 0]);
    assert_eq!(by_value, [0, 2]);
}
