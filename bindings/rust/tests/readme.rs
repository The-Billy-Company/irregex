//! The README's code, compiled and run.
//!
//! `README.md` is not included as a doctest — its fourteen blocks are fragments
//! written for a reader, several of which have no `main` and no error context, so
//! `#![doc = include_str!("../README.md")]` would mean rewriting prose to satisfy
//! rustdoc. The cost of that is a README that reads worse; the cost of NOT having
//! it is a README that lies, which is not hypothetical: the section describing
//! `Munch` shipped `dotall(true)` and `patterns().collect()` past a human reading
//! it twice, when the real spellings are `dot_matches_new_line` and a `&[u32]`.
//! And the sentence claiming "the C ABI has no anchored verb" outlived the arrival
//! of one.
//!
//! So this is the seam between the two: every API SHAPE the README asserts,
//! written the way the README writes it. It cannot catch a wrong sentence, but it
//! catches every wrong call - which is the half that a reader cannot check and a
//! compiler can.

use irgx::{Munch, MunchBuilder, Pick, Regex, RegexSet, Why};

#[test]
fn the_tour_compiles_and_answers() {
    let re = Regex::new(r"(\w+)@(\w+)").unwrap();
    assert!(re.is_match("bob@host"));
    let m = re.find("write bob@host").unwrap();
    assert_eq!((m.start(), m.end(), m.as_str()), (6, 14, "bob@host"));
    // `find_at` starts late without moving the edges, and knows its own length.
    assert!(Regex::new("^b").unwrap().find_at("abc", 1).is_none());
    assert_eq!(re.find_iter("a@b c@d").len(), 2);
}

#[test]
fn the_set_section_compiles_and_answers() {
    let set = RegexSet::new([r"^\w+@\w+$", r"^\d{3}-\d{4}$", r"^https?://"]).unwrap();
    assert!(set.is_match("bob@host"));
    assert_eq!(set.matches("555-1234").iter().collect::<Vec<_>>(), [1]);
    assert_eq!(set.len(), 3);
}

#[test]
fn the_munch_section_compiles_and_answers() {
    let lex = Munch::new(["if", r"[a-z]+", r"[0-9]+", r"\s+"]).unwrap();

    let token = lex.token("if x", 0).unwrap();
    assert_eq!(token.len(), 2);
    assert_eq!(token.patterns(), [0, 1], "the keyword AND the identifier");
    assert_eq!(token.range(0), 0..2);

    // Restricting one call, and the other reading of the same offset.
    assert_eq!(lex.token_among("if x", 0, &[1]).map(|t| t.len()), Some(2));
    assert_eq!(lex.shortest_among("if x", 0, &[0, 1]).map(|t| t.len()), Some(1));

    // `admitted()` is the capacity at which the engine can never come up short.
    let mut winners = Vec::with_capacity(lex.admitted());
    let len = lex.scan_into("if x", 0, None, Pick::Longest, &mut winners).unwrap();
    assert_eq!((len, winners.as_slice()), (Some(2), [0, 1].as_slice()));
}

#[test]
fn the_munch_flags_are_spelled_as_regexbuilder_spells_them() {
    assert!(MunchBuilder::new(["if"]).ignore_case(true).build().unwrap().token("IF", 0).is_some());
    let dotall = MunchBuilder::new(["."]).dot_matches_new_line(true).build().unwrap();
    assert!(dotall.token("\n", 0).is_some());
    assert!(MunchBuilder::new(["."]).build().unwrap().token("\n", 0).is_none());
    // And there is no `multi_line` to call at all, which is the claim itself: it
    // is unrepresentable rather than accepted and ignored. A compiler cannot
    // assert the absence of a method, so the nearest thing it can hold is that
    // the builder's flags are exactly the three above; adding `multi_line` later
    // without revisiting the README would leave this test still passing and the
    // README's sentence false. Named here so the next person knows.
}

#[test]
fn a_partial_refusal_seats_the_rest_and_says_why() {
    let partial = Munch::new(["ok", r"(a)\1", r"\Ab"]).unwrap();
    assert_eq!((partial.len(), partial.admitted()), (3, 1));
    assert_eq!(partial.declined().iter().map(|r| r.why).collect::<Vec<_>>(), [
        Why::Syntax,
        Why::BufferAnchor,
    ]);
    assert!(partial.token("ok", 0).is_some(), "the seated terminal still lexes");
    // A wall and a budget are different advice, so they are different values.
    assert_ne!(Why::States, Why::BufferAnchor);
}

#[test]
fn the_windowed_section_compiles_and_answers() {
    let dollar = Regex::new("b$").unwrap();
    assert!(dollar.windows());
    // The ceiling confines the match; `$` still reads the real end. Slicing to the
    // same bound is the other question, and the README's contrast for it.
    assert!(!dollar.is_match_within("abc", 0, 2));
    assert!(dollar.is_match("ab"));
    // Fitting, not truncating the leftmost match.
    let word = Regex::new(r"\w+").unwrap();
    assert!(word.is_match_within("abcd", 0, 2));
    assert_eq!(word.find("abcd").map(|m| m.end()), Some(4));
    assert!(matches!(
        word.try_is_match_within("abc", 2, 1),
        Err(irgx::Error::BadWindow { start: 2, end: 1 })
    ));
}
