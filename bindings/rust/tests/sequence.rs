//! Which matches a nullable pattern yields, asked of the `regex` crate itself.
//!
//! Where the matches ARE is a fact about the pattern, and the engine settles it.
//! Which of them a library REPORTS is a convention, and every ecosystem picked a
//! different one: Python's `re` shows every empty match at every byte, Go's
//! `regexp` and Rust's `regex` skip an empty match abutting the previous one and
//! resume at the next character, and grep tools drop more still. The C ABI
//! reports the complete byte-granular sequence - the widest one - and each
//! binding thins it to its own ecosystem's convention on the way out.
//!
//! So this file does not assert a table of spans. A table is a claim about
//! `regex` frozen at the moment somebody typed it, and it would keep passing
//! long after it stopped being true. It runs both crates over the same inputs
//! and asserts they agree, which is the actual claim: drop this crate in where
//! `regex` was and the same code sees the same matches.

use irgx::{Regex, RegexBuilder};

/// Every span `irgx` reports for `pattern` over `text`.
fn ours(pattern: &str, text: &str) -> Vec<(usize, usize)> {
    Regex::new(pattern)
        .unwrap()
        .find_iter(text)
        .map(|found| (found.start(), found.end()))
        .collect()
}

/// Every span the `regex` crate reports for the same pattern and text.
fn theirs(pattern: &str, text: &str) -> Vec<(usize, usize)> {
    regex::Regex::new(pattern)
        .unwrap()
        .find_iter(text)
        .map(|found| (found.start(), found.end()))
        .collect()
}

fn agree(pattern: &str, text: &str) {
    assert_eq!(
        ours(pattern, text),
        theirs(pattern, text),
        "pattern {pattern:?} over text {text:?}"
    );
}

/// The patterns whose sequence is a convention rather than a fact - every one of
/// them can match empty - crossed with texts that put an empty match everywhere
/// it can be awkward: at the start, abutting a real match, between the bytes of
/// a multi-byte character, and at the very end.
const NULLABLE: &[&str] = &[
    "a*", "b*", "x*", "", "a?", "l*", "(a)*", "a*b*", "[^x]*", "(?:ab)*", "a{0,2}", "é*",
];

const TEXTS: &[&str] = &[
    "", "a", "b", "abc", "abcb", "aaa", "bbb", "aXaXa", "bab", "héllo", "ééé", "ab\ncd", "\n",
    "a\n", "\na",
];

#[test]
fn nullable_patterns_yield_the_same_sequence_as_the_regex_crate() {
    for pattern in NULLABLE {
        for text in TEXTS {
            agree(pattern, text);
        }
    }
}

/// The rule that removes a span: an empty match starting exactly where the
/// previous match ended is not reported. `a*` over `"abc"` matches `a` at 0..1,
/// and the empty match at 1 abuts it, so neither crate shows it.
#[test]
fn an_empty_match_abutting_the_previous_one_is_skipped_by_both() {
    agree("a*", "abc");
    assert_eq!(ours("a*", "abc"), [(0, 1), (2, 2), (3, 3)]);
}

/// The rule that skips a position: after an empty match the scan resumes at the
/// next CHARACTER, so no empty match is ever reported inside a multi-byte one.
/// `l*` over `"héllo"` has an empty match at byte 2 - the continuation byte of
/// the `é` - and neither crate reaches it.
#[test]
fn an_empty_match_inside_a_character_is_unreachable_for_both() {
    agree("l*", "héllo");
    let spans = ours("l*", "héllo");
    assert!(!spans.contains(&(2, 2)), "byte 2 splits the é: {spans:?}");
    assert_eq!(spans, [(0, 0), (1, 1), (3, 5), (6, 6)]);
}

/// An empty match at the end of the text is a real match and both crates report
/// it. This is the case the binding used to drop, because the ABI spoke grep
/// semantics where a trailing empty match is noise.
#[test]
fn the_empty_match_at_the_end_of_the_text_is_reported_by_both() {
    agree("x*", "abc");
    assert_eq!(ours("x*", "abc"), [(0, 0), (1, 1), (2, 2), (3, 3)]);
    agree("x*", "");
    assert_eq!(ours("x*", ""), [(0, 0)]);
}

/// A pattern that cannot match empty has no convention to follow - the thinning
/// rules only ever remove empty spans - so agreement here is the engine's alone.
#[test]
fn non_nullable_patterns_need_no_thinning_and_still_agree() {
    for (pattern, text) in [
        ("a", "banana"),
        ("a+", "aabaa"),
        ("[abc]", "xaybzc"),
        ("ab|ba", "abba"),
        ("(a)(b)", "abab"),
        ("é", "ééé"),
        (".", "héllo"),
        ("\\w+", "one two"),
    ] {
        agree(pattern, text);
    }
}

/// `find_at` and `is_match_at`, against the crate that defines what they mean.
///
/// The claim worth testing is not "a search can start late" - it is that starting
/// late does not move the haystack's edges, which is the one thing slicing gets
/// wrong and the reason both crates ship the verb at all. `^b` at offset 1 of
/// `"abc"` must NOT match, because `^` is still offset 0; slice to `"bc"` and it
/// would. Asked of `regex` rather than asserted as a table, so a divergence in
/// either direction fails.
#[test]
fn find_at_agrees_with_the_regex_crate_including_at_the_edges() {
    for pattern in [
        "^b", r"\bbc", r"\Bc", "b$", r"b\b", "a", "x*", "", "a?", "l*", "bc", r"\w+", "é", ".",
    ] {
        for text in [
            "", "a", "abc", "aBaBa", "héllo", "ééé", "ab\ncd", "\n", "a\n",
        ] {
            let (mine, crates) = (
                Regex::new(pattern).unwrap(),
                regex::Regex::new(pattern).unwrap(),
            );
            // Only character boundaries: an offset inside a character names no
            // position either crate reports a match from, and this crate refuses
            // it rather than searching from a byte the caller did not mean.
            for start in (0..=text.len()).filter(|at| text.is_char_boundary(*at)) {
                assert_eq!(
                    mine.find_at(text, start)
                        .map(|found| (found.start(), found.end())),
                    crates
                        .find_at(text, start)
                        .map(|found| (found.start(), found.end())),
                    "find_at({pattern:?}, {text:?}, {start})"
                );
                assert_eq!(
                    mine.is_match_at(text, start),
                    crates.is_match_at(text, start),
                    "is_match_at({pattern:?}, {text:?}, {start})"
                );
            }
        }
    }
}

/// The row the verb exists for, stated on its own so a reader does not have to
/// reconstruct it from the loop above: a late start is not a slice.
#[test]
fn a_late_start_does_not_move_the_haystacks_edges() {
    let caret = Regex::new("^b").unwrap();
    assert!(caret.find_at("abc", 1).is_none());
    // What slicing would have answered - the wrong answer, available for contrast.
    assert!(caret.find("bc").is_some());

    let boundary = Regex::new(r"\bbc").unwrap();
    assert!(boundary.find_at("abc", 1).is_none());
    assert!(boundary.find("bc").is_some());

    // And the right edge is untouched either way, since this verb bounds only the
    // start: `$` is still the end of the text.
    assert_eq!(
        Regex::new("c$")
            .unwrap()
            .find_at("abc", 1)
            .map(|m| m.start()),
        Some(2)
    );
}

/// Every window of every text, for the patterns where slicing is a sound oracle.
///
/// A window confines the match while leaving every assertion reading the whole
/// text — so for a pattern that asserts nothing, there is nothing left for the
/// two readings to disagree about, and `is_match(&text[start..end])` is exactly
/// the question. That makes the `regex` crate an oracle for a verb it does not
/// ship, over the entire grid, for precisely the patterns whose answer does not
/// depend on the distinction. The patterns whose answer DOES depend on it are
/// the next two tests, and they cannot use this oracle by construction.
#[test]
fn a_window_confines_the_match_and_slicing_oracles_the_assertion_free_half() {
    for pattern in ["a", "x*", "", "a?", "bc", r"\w+", "b|abc", "a+b", "[^x]"] {
        for text in ["", "a", "abc", "aBaBa", "héllo", "ab\ncd", "a\n"] {
            let (mine, crates) = (
                Regex::new(pattern).unwrap(),
                regex::Regex::new(pattern).unwrap(),
            );
            let bounds: Vec<usize> = (0..=text.len())
                .filter(|at| text.is_char_boundary(*at))
                .collect();
            for &start in &bounds {
                for &end in bounds.iter().filter(|end| **end >= start) {
                    assert_eq!(
                        mine.is_match_within(text, start, end),
                        crates.is_match(&text[start..end]),
                        "is_match_within({pattern:?}, {text:?}, {start}, {end})"
                    );
                }
            }
        }
    }
}

/// The distinction the previous test is built to exclude, stated on its own.
///
/// Each case is one where confining the match and cutting the text give opposite
/// answers, which is what makes the verb irreducible to either a late start or a
/// slice: the assertion is still reading bytes the window does not contain.
#[test]
fn an_assertion_reads_the_whole_text_no_matter_where_the_window_is() {
    for (pattern, text, start, end) in [
        // `$` and `\z` are still the real end, so a window that stops short of
        // it satisfies neither — where the slice "ab" would satisfy both.
        ("b$", "abc", 0, 2),
        (r"b\z", "abc", 0, 2),
        // `^` is still the real start, symmetrically.
        ("^b", "abc", 1, 3),
        // And `\b` still resolves against the byte outside the window: there is
        // no boundary inside "abc" at offset 1, though the slice "b" has two.
        (r"\bb\b", "abc", 1, 2),
    ] {
        let (mine, crates) = (
            Regex::new(pattern).unwrap(),
            regex::Regex::new(pattern).unwrap(),
        );
        assert!(
            !mine.is_match_within(text, start, end),
            "{pattern:?} should not match within {text:?}[{start}..{end}]"
        );
        assert!(
            crates.is_match(&text[start..end]),
            "the slice is the contrast, so {pattern:?} must match {:?}",
            &text[start..end]
        );
    }
}

/// Fitting is existence, not the leftmost match measured against the ceiling.
#[test]
fn a_window_admits_a_shorter_match_the_unwindowed_verb_would_never_report() {
    let word = Regex::new(r"\w+").unwrap();
    // The match this verb reports over the whole text overruns the window...
    assert_eq!(word.find("abcd").map(|at| at.range()), Some(0..4));
    // ...and the window still matches, on the strength of a match it never
    // reports, because a greedy pattern is asked to fit rather than to shrink.
    assert!(word.is_match_within("abcd", 0, 2));
    // Down to the smallest one that fits, and no further.
    assert!(word.is_match_within("abcd", 0, 1));
    assert!(!word.is_match_within("abcd", 0, 0));
}

/// Two invariants that hold for every pattern, including the ones no slice can
/// oracle: an inert ceiling is the unwindowed verb, and widening never loses.
#[test]
fn the_inert_ceiling_is_the_unwindowed_verb_and_widening_only_adds() {
    for pattern in [
        "^b", r"\bbc", r"\Bc", "b$", r"b\b", r"c\z", "a", "x*", "", r"\w+", ".",
    ] {
        for text in ["", "a", "abc", "aBaBa", "héllo", "ab\ncd", "a\n"] {
            let re = Regex::new(pattern).unwrap();
            let bounds: Vec<usize> = (0..=text.len())
                .filter(|at| text.is_char_boundary(*at))
                .collect();
            for &start in &bounds {
                assert_eq!(
                    re.is_match_within(text, start, text.len()),
                    re.is_match_at(text, start),
                    "an inert ceiling changed the answer: {pattern:?}, {text:?}, {start}"
                );
                for pair in bounds
                    .iter()
                    .filter(|end| **end >= start)
                    .collect::<Vec<_>>()
                    .windows(2)
                {
                    let (&narrow, &wide) = (pair[0], pair[1]);
                    assert!(
                        !re.is_match_within(text, start, narrow)
                            || re.is_match_within(text, start, wide),
                        "widening lost a match: {pattern:?}, {text:?}, \
                         [{start},{narrow}] matched but [{start},{wide}] did not"
                    );
                }
            }
        }
    }
}

/// A window whose end precedes its start is the caller's bug, and is named as
/// that rather than folded into the ABI's one `INVALID` for every bad bound.
#[test]
fn a_backwards_window_is_refused_by_name() {
    let re = Regex::new("a").unwrap();
    assert!(matches!(
        re.try_is_match_within("abc", 2, 1),
        Err(irgx::Error::BadWindow { start: 2, end: 1 })
    ));
    // A bound inside a codepoint is still the boundary error, not this one.
    assert!(matches!(
        re.try_is_match_within("héllo", 0, 2),
        Err(irgx::Error::NotCharBoundary { offset: 2 })
    ));
    // It carries no status, because the engine never saw the call.
    let refused = re.try_is_match_within("abc", 2, 1).unwrap_err();
    assert!(refused.status().is_none());
}

/// Whether a pattern can be windowed is a property of the engine that compiled
/// it, and the linear engine — every pattern in this crate's default arm — can.
#[test]
fn the_linear_engine_windows() {
    for pattern in ["a", "^b", "b$", r"\w+", r"c\z", ""] {
        assert!(
            Regex::new(pattern).unwrap().windows(),
            "{pattern:?} should window"
        );
    }
}

/// An offset that names no position is refused rather than silently rounded.
#[test]
fn a_start_that_is_not_a_character_boundary_is_an_error() {
    let re = Regex::new("l*").unwrap();
    // Byte 1 is the continuation byte of the `é`.
    assert!(matches!(
        re.try_find_at("héllo", 2),
        Err(irgx::Error::NotCharBoundary { offset: 2 })
    ));
    assert!(matches!(
        re.try_is_match_at("héllo", 2),
        Err(irgx::Error::NotCharBoundary { offset: 2 })
    ));
    // Past the end is not a boundary either.
    assert!(re.try_find_at("abc", 99).is_err());
    // The end of the text IS one, and both crates answer there.
    assert_eq!(
        re.find_at("abc", 3).map(|m| (m.start(), m.end())),
        regex::Regex::new("l*")
            .unwrap()
            .find_at("abc", 3)
            .map(|m| (m.start(), m.end()))
    );
}

/// A pattern may carry its own flags in the leading `(?ims-u)` form, which is
/// where it matters most: a pattern out of a config file arrives with no builder
/// a caller could have configured, because configuring it would mean reading the
/// pattern first. `regex` folds that form, so both spellings and both crates have
/// to be one answer.
#[test]
fn a_leading_inline_flag_says_what_the_builder_says() {
    let texts = ["ab\ncd", "AB ab", "a\nb", "", "a\n"];
    // (inline spelling, the same pattern without it, then the three fields it
    // stands for: ignore_case, multi_line, dot_matches_new_line).
    for (inline, body, fold, lines, dot) in [
        ("(?i)AB", "AB", true, false, false),
        ("(?m)^c", "^c", false, true, false),
        ("(?s)b.c", "b.c", false, false, true),
        ("(?ms)^c.", "^c.", false, true, true),
    ] {
        let folded = Regex::new(inline).unwrap();
        let built = RegexBuilder::new(body)
            .ignore_case(fold)
            .multi_line(lines)
            .dot_matches_new_line(dot)
            .build()
            .unwrap();
        let theirs = regex::Regex::new(inline).unwrap();
        for text in texts {
            let spans = |m: irgx::Match| (m.start(), m.end());
            let ours: Vec<_> = folded.find_iter(text).map(spans).collect();
            let via_builder: Vec<_> = built.find_iter(text).map(spans).collect();
            let want: Vec<_> = theirs
                .find_iter(text)
                .map(|m| (m.start(), m.end()))
                .collect();
            assert_eq!(ours, via_builder, "{inline:?} over {text:?}");
            assert_eq!(ours, want, "{inline:?} over {text:?} vs regex");
        }
    }

    // The pattern is the more specific statement, so it beats the builder.
    let sensitive = RegexBuilder::new("(?-i)ab")
        .ignore_case(true)
        .build()
        .unwrap();
    assert_eq!(sensitive.find_iter("ab AB").count(), 1);
    // Under `fixed` the bytes are data, not a directive.
    let data = RegexBuilder::new("(?i)ab").fixed(true).build().unwrap();
    assert_eq!(
        data.find("(?i)ab AB").map(|m| (m.start(), m.end())),
        Some((0, 6))
    );
}
