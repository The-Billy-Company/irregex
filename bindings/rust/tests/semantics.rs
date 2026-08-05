//! What the engine means, pinned case by case.
//!
//! The oracle test proves the Rust binding agrees with the Python one. This file
//! proves the answers are the ones we intend, spelled out, so a reader can see
//! the semantics without running a generator; and it covers the places where this
//! engine deliberately differs from the `regex` crate.

use irgx::{Error, Regex, RegexBuilder};

// ── nullable and zero-width patterns ─────────────────────────────────────

/// `a*` over `"abc"` is `[(0, 1), (2, 2), (3, 3)]`, which is what the `regex`
/// crate answers.
///
/// The empty match at 1 is missing because it abuts the `a` that ended there,
/// and that is the crate's convention rather than the engine's finding: the C
/// ABI reports it, Python's `re` shows it, and this crate skips it so that code
/// written against `regex` sees the sequence it expects. The trailing `(3, 3)`
/// IS reported - an empty match at the end of the text is a match.
///
/// `tests/sequence.rs` proves that agreement live against the crate rather than
/// against this table.
#[test]
fn nullable_star() {
    let re = Regex::new("a*").unwrap();
    assert_eq!(spans(&re, "abc"), [(0, 1), (2, 2), (3, 3)]);
    // The empty match at the end abuts the `aaa` that ended there, so it goes -
    // end of text is not a special case, adjacency is.
    assert_eq!(spans(&re, "aaa"), [(0, 3)]);
    assert_eq!(spans(&re, "aXaXa"), [(0, 1), (2, 3), (4, 5)]);
    // Every position is empty-matchable and none of them abuts a non-empty
    // match, so every one is reported, end of text included.
    assert_eq!(spans(&re, "bbb"), [(0, 0), (1, 1), (2, 2), (3, 3)]);
    // The end of the text is the only candidate position, and it counts.
    assert_eq!(spans(&re, ""), [(0, 0)]);
    assert!(re.is_match(""));
}

#[test]
fn empty_pattern() {
    let re = Regex::new("").unwrap();
    assert_eq!(spans(&re, "abc"), [(0, 0), (1, 1), (2, 2), (3, 3)]);
    assert_eq!(spans(&re, ""), [(0, 0)]);
    // A match is still a match: an empty one has an empty `as_str`, and is not
    // the same thing as no match.
    let found = re.find("abc").unwrap();
    assert_eq!(found.as_str(), "");
    assert!(found.is_empty());
    assert_eq!(found.len(), 0);
}

#[test]
fn word_boundary_is_zero_width() {
    let re = Regex::new(r"\b").unwrap();
    // Four boundaries in "ab cd": before `a`, after `b`, before `c`, and the one
    // at byte 5 after `d`, which is the end of the text and still a boundary.
    assert_eq!(spans(&re, "ab cd"), [(0, 0), (2, 2), (3, 3), (5, 5)]);
    assert_eq!(spans(&re, "a"), [(0, 0), (1, 1)]);
    // No word character, so no boundary anywhere - including at the end, which
    // is what separates this from the cases above.
    assert_eq!(spans(&re, " "), []);
    assert_eq!(spans(&re, ""), []);
}

/// A nullable group has to keep reporting an empty span rather than `None`,
/// because "matched nothing" and "was never entered" are different answers.
#[test]
fn nullable_groups_report_empty_not_absent() {
    let re = Regex::new("(a*)(b*)").unwrap();
    // At byte 0 the `a*` arm matches nothing and the `b*` arm matches "b", so
    // group one participated and is empty rather than absent.
    let caps = re.captures("ba").unwrap();
    assert_eq!(caps.get(0).map(|m| m.range()), Some(0..1));
    assert_eq!(caps.get(1).unwrap().as_str(), "");
    assert_eq!(caps.get(2).unwrap().as_str(), "b");
    assert!(caps.get(1).is_some(), "an empty match is still a match");

    // And where the whole match itself is empty, all three are.
    let caps = re.captures("xy").unwrap();
    assert!(caps.get(0).unwrap().is_empty());
    assert_eq!(caps.get(1).unwrap().as_str(), "");
    assert_eq!(caps.get(2).unwrap().as_str(), "");
}

// ── UTF-8 ────────────────────────────────────────────────────────────────

/// The engine reports byte offsets and Rust slices `str` by byte, so a returned
/// range indexes the caller's own string with no translation at all. This is the
/// assertion that would fail if the binding had copied the Python binding's
/// codepoint conversion.
#[test]
fn ranges_slice_the_callers_string() {
    let text = "le café noir, le CAFÉ clair";
    let re = RegexBuilder::new("café").ignore_case(true).build().unwrap();

    let found: Vec<&str> = re.find_iter(text).map(|m| &text[m.range()]).collect();
    assert_eq!(found, ["café", "CAFÉ"]);
    // And the range is the one the engine gave, in bytes, not in characters.
    let first = re.find(text).unwrap();
    assert_eq!(first.range(), 3..8, "'café' is five bytes from byte three");
    assert_eq!(first.as_str(), &text[3..8]);
    assert_eq!(text[..first.start()].chars().count(), 3);
}

#[test]
fn unicode_classes_are_codepoint_shaped() {
    let re = Regex::new(".").unwrap();
    // One match per codepoint, each as wide as that codepoint's encoding.
    assert_eq!(spans(&re, "aé日"), [(0, 1), (1, 3), (3, 6)]);

    let word = Regex::new(r"\w+").unwrap();
    assert_eq!(
        word.find_iter("naïve café")
            .map(|m| m.as_str())
            .collect::<Vec<_>>(),
        ["naïve", "café"]
    );
}

/// `unicode(false)` is byte semantics, and the caller asked for it. `.` then
/// matches one byte, which for `"é"` lands inside the codepoint. Slicing a `str`
/// there would panic in the caller's own code with no explanation, so the checked
/// verbs name it instead.
#[test]
fn byte_semantics_can_land_mid_codepoint() {
    let re = RegexBuilder::new(".").unicode(false).build().unwrap();
    let why = re.try_find("é").unwrap_err();
    assert_eq!(why, Error::NotCharBoundary { offset: 1 });
    assert!(why.to_string().contains("inside a UTF-8 codepoint"));
    assert!(why.to_string().contains("unicode(false)"));

    // ASCII text is unaffected, and a two-byte window over the same string is a
    // whole codepoint, so the failure is about the span and not the flag.
    assert_eq!(spans(&re, "ab"), [(0, 1), (1, 2)]);
    assert_eq!(
        RegexBuilder::new("..")
            .unicode(false)
            .build()
            .unwrap()
            .find("é")
            .unwrap()
            .as_str(),
        "é"
    );
}

#[test]
#[should_panic(expected = "inside a UTF-8 codepoint")]
fn byte_semantics_panic_is_explained() {
    // The infallible verbs panic, and the message has to say what happened
    // rather than surfacing as a slice-index panic from inside the crate.
    let _ = RegexBuilder::new(".")
        .unicode(false)
        .build()
        .unwrap()
        .find("é");
}

// ── groups ───────────────────────────────────────────────────────────────

#[test]
fn numbered_groups() {
    let re = Regex::new(r"(\w+)@(\w+)").unwrap();
    assert_eq!(re.groups(), Some(2));
    let caps = re.captures("mail bob@host now").unwrap();
    assert_eq!(caps.len(), 3);
    assert_eq!(&caps[0], "bob@host");
    assert_eq!(&caps[1], "bob");
    assert_eq!(&caps[2], "host");
    assert_eq!(caps.get(3), None, "there is no group three");
}

#[test]
fn named_groups() {
    let re = Regex::new(r"(?P<user>\w+)@(?P<host>\w+)").unwrap();
    assert_eq!(re.group_index("user"), Some(1));
    assert_eq!(re.group_index("host"), Some(2));
    assert_eq!(re.group_index("nope"), None);
    assert_eq!(
        re.group_names().collect::<Vec<_>>(),
        [("user", 1), ("host", 2)]
    );

    let caps = re.captures("bob@host").unwrap();
    assert_eq!(caps.name("user").unwrap().as_str(), "bob");
    assert_eq!(caps.name("host").unwrap().as_str(), "host");
    assert_eq!(caps.name("nope"), None);
    assert_eq!(&caps["user"], "bob");

    // The other spelling of the same thing.
    let angle = Regex::new(r"(?<year>\d{4})-(?<month>\d{2})").unwrap();
    let caps = angle.captures("2026-07").unwrap();
    assert_eq!(caps.name("year").unwrap().as_str(), "2026");
    assert_eq!(caps.name("month").unwrap().as_str(), "07");
}

/// The names come from the engine, one group number at a time, and not from
/// reading the pattern back. Every row here is a place where a scan of the
/// pattern source and the parser that actually ran disagree: a `(` inside a
/// character class is data, `(?<=` is lookbehind rather than a name, `\(` is a
/// literal, `(?:` is a group that cannot be named, and `(?#` is a comment whose
/// contents mean nothing at all.
///
/// The last two rows are the ones the scan got wrong rather than merely could
/// have: PCRE2's third spelling of a name has no angle brackets to find, and the
/// `[` inside a comment left a class-tracking scan convinced the rest of the
/// pattern was character-class data, so the name after it disappeared.
#[test]
fn names_come_from_the_engine_not_the_pattern_source() {
    /// A pattern, the grammar to compile it under, and the `(name, group
    /// number)` pairs the engine declares for it.
    type Row = (&'static str, bool, &'static [(&'static str, usize)]);

    const GRID: &[Row] = &[
        (r"[(?<x>]+(?P<real>a)", false, &[("real", 1)]),
        (r"\((?<inner>x)\)", false, &[("inner", 1)]),
        (r"(?:ab)(?<tail>c)", false, &[("tail", 1)]),
        (r"(?P<a>x)(?<b>y)", false, &[("a", 1), ("b", 2)]),
        (r"(?<=\$)(?<amount>\d+)", true, &[("amount", 1)]),
        (r"(?'money'\d+)", true, &[("money", 1)]),
        (r"(?#[)(?<after>x)", true, &[("after", 1)]),
    ];

    for &(pattern, pcre, want) in GRID {
        let re = RegexBuilder::new(pattern).pcre(pcre).build().unwrap();
        assert_eq!(
            re.group_names().collect::<Vec<_>>(),
            want,
            "{pattern:?}: the engine is the authority on which groups have names"
        );
        for &(name, number) in want {
            assert_eq!(re.group_index(name), Some(number), "{pattern:?}");
        }
    }

    // A name resolves to a group a match can be read through, so the table is
    // wired to the same numbering `captures` reports in.
    let behind = RegexBuilder::new(r"(?<=\$)(?<amount>\d+)")
        .pcre(true)
        .build()
        .unwrap();
    assert_eq!(behind.group_index("=\\$)"), None);
    assert_eq!(
        behind
            .captures("cost $42")
            .unwrap()
            .name("amount")
            .unwrap()
            .as_str(),
        "42"
    );
}

/// A group with no name is absent from the table rather than present under a
/// made-up one, and the walk stops at the group count instead of asking for an
/// index past it - which the seam answers with a refusal, not an absence.
#[test]
fn unnamed_groups_are_absent_from_the_name_table() {
    let mixed = Regex::new(r"(a)(?P<middle>b)(c)").unwrap();
    assert_eq!(mixed.groups(), Some(3));
    assert_eq!(mixed.group_names().collect::<Vec<_>>(), [("middle", 2)]);
    assert_eq!(mixed.group_names().len(), 1);

    let anonymous = Regex::new(r"(a)(b)").unwrap();
    assert_eq!(anonymous.groups(), Some(2));
    assert_eq!(anonymous.group_names().count(), 0);

    // No groups at all is the other end of the same walk, and it asks the engine
    // nothing.
    let plain = Regex::new(r"\d+").unwrap();
    assert_eq!(plain.groups(), Some(0));
    assert_eq!(plain.group_names().count(), 0);
}

/// The distinction a binding is most likely to lose: a group the match never
/// entered is `None`, and a group that matched the empty string is `Some("")`.
#[test]
fn non_participating_group_is_none() {
    let re = Regex::new("(a)|(b)").unwrap();

    let caps = re.captures("a").unwrap();
    assert_eq!(caps.get(1).map(|m| m.as_str()), Some("a"));
    assert_eq!(caps.get(2), None, "the b arm was never entered");

    let caps = re.captures("b").unwrap();
    assert_eq!(caps.get(1), None, "the a arm was never entered");
    assert_eq!(caps.get(2).map(|m| m.as_str()), Some("b"));

    // Against a group that participated and matched nothing.
    let nullable = Regex::new("(a)(x?)").unwrap();
    let caps = nullable.captures("a").unwrap();
    assert_eq!(caps.get(2).map(|m| m.as_str()), Some(""));
    assert_ne!(caps.get(2), None);
}

#[test]
#[should_panic(expected = "did not participate")]
fn indexing_a_missing_group_panics() {
    // Same shape as the `regex` crate: `get` is the checked form, `Index` is not.
    let re = Regex::new("(a)|(b)").unwrap();
    let caps = re.captures("a").unwrap();
    let _ = &caps[2];
}

#[test]
fn captures_iter_walks_every_match() {
    let re = Regex::new(r"(\w)(\d)").unwrap();
    let pairs: Vec<(&str, &str)> = re
        .captures_iter("a1 b2 c3")
        .map(|caps| (caps.get(1).unwrap().as_str(), caps.get(2).unwrap().as_str()))
        .collect();
    assert_eq!(pairs, [("a", "1"), ("b", "2"), ("c", "3")]);
}

// ── flags ────────────────────────────────────────────────────────────────

/// Each flag has to change an answer, or the builder is wiring a bit the engine
/// ignores.
#[test]
fn fixed_makes_metacharacters_data() {
    let regex = Regex::new("a.c").unwrap();
    let fixed = RegexBuilder::new("a.c").fixed(true).build().unwrap();
    assert!(regex.is_match("abc"));
    assert!(!fixed.is_match("abc"));
    assert!(fixed.is_match("xa.cx"));

    // A pattern the grammar would reject outright is just a string here.
    let broken = RegexBuilder::new("a(b").fixed(true).build().unwrap();
    assert!(broken.is_match("xa(bx"));
    assert!(Regex::new("a(b").is_err());
}

#[test]
fn ignore_case_folds() {
    let re = RegexBuilder::new("abc").ignore_case(true).build().unwrap();
    assert_eq!(
        re.find_iter("ABC abc AbC")
            .map(|m| m.as_str())
            .collect::<Vec<_>>(),
        ["ABC", "abc", "AbC"]
    );
    assert_eq!(
        Regex::new("abc").unwrap().find_iter("ABC abc AbC").count(),
        1
    );
}

#[test]
fn word_filters_the_sequence() {
    let plain = Regex::new("cat").unwrap();
    let worded = RegexBuilder::new("cat").word(true).build().unwrap();
    let text = "cat concatenate the cat.";
    assert_eq!(plain.find_iter(text).count(), 3);
    // The hit inside "concatenate" has word characters on both sides, so it is
    // not a match; the scan resumes past it rather than stopping.
    assert_eq!(
        worded
            .find_iter(text)
            .map(|m| m.range())
            .collect::<Vec<_>>(),
        [0..3, 20..23]
    );
}

#[test]
fn smart_case_reads_the_pattern() {
    let lower = RegexBuilder::new("abc").smart_case(true).build().unwrap();
    let upper = RegexBuilder::new("Abc").smart_case(true).build().unwrap();
    // No uppercase in the pattern, so fold.
    assert_eq!(lower.find_iter("ABC abc").count(), 2);
    // An uppercase letter in the pattern turns folding off.
    assert_eq!(upper.find_iter("ABC abc Abc").count(), 1);
}

#[test]
fn unicode_off_is_byte_semantics() {
    let text = "naïve café";
    let unicode = Regex::new(r"\w+").unwrap();
    let bytes = RegexBuilder::new(r"\w+").unicode(false).build().unwrap();
    assert_eq!(
        unicode
            .find_iter(text)
            .map(|m| m.as_str())
            .collect::<Vec<_>>(),
        ["naïve", "café"]
    );
    // The multi-byte codepoints are not word bytes, so each word splits at them.
    assert_eq!(
        bytes
            .find_iter(text)
            .map(|m| m.as_str())
            .collect::<Vec<_>>(),
        ["na", "ve", "caf"]
    );
}

#[test]
fn pcre_adds_lookaround_and_backreferences() {
    // The linear engine has no lookaround at all, which is a refusal and not a
    // silent reinterpretation.
    assert!(Regex::new("foo(?=bar)").is_err());
    assert!(Regex::new(r"(\w)\1").is_err() || !Regex::new(r"(\w)\1").unwrap().is_match("aa"));

    let ahead = RegexBuilder::new("foo(?=bar)").pcre(true).build().unwrap();
    // The lookahead is not part of the match, so only the first "foo" and only
    // three bytes of it.
    assert_eq!(
        ahead
            .find_iter("foobar foobaz")
            .map(|m| m.range())
            .collect::<Vec<_>>(),
        vec![0..3]
    );

    let behind = RegexBuilder::new(r"(?<=\$)\d+").pcre(true).build().unwrap();
    assert_eq!(
        behind
            .find_iter("$42 and 43")
            .map(|m| m.as_str())
            .collect::<Vec<_>>(),
        ["42"]
    );

    let backref = RegexBuilder::new(r"(\w)\1").pcre(true).build().unwrap();
    assert_eq!(
        backref
            .find_iter("aa bb ab cc")
            .map(|m| m.as_str())
            .collect::<Vec<_>>(),
        ["aa", "bb", "cc"]
    );
}

/// `fixed` wins over `pcre`, as it does in the engine: a literal string needs no
/// grammar, so there is nothing for the other arm to parse.
#[test]
fn fixed_wins_over_pcre() {
    let re = RegexBuilder::new("(?=x)")
        .fixed(true)
        .pcre(true)
        .build()
        .unwrap();
    assert!(re.is_match("a(?=x)b"));
    assert!(!re.is_match("x"));
}

// ── grammar notes the README makes claims about ───────────────────────────

/// A newline is ordinary whitespace, because the text is one buffer rather than
/// a sequence of lines. `\s` matches it, a character class containing it matches
/// it, and `.` does not - which is the same split `regex` and `re` make.
///
/// This used to say the opposite. The engine has a line-oriented model for grep
/// work, where a newline is a terminator no pattern may cross, and the binding
/// was reaching the engine through it - so `\s` found nothing in `"a\nb"` and a
/// caller searching a file had no way to write a pattern that spanned a line.
/// The binding now compiles in the buffer model, which is the one a library
/// caller means.
#[test]
fn newline_is_ordinary_whitespace_in_a_buffer() {
    assert_eq!(spans(&Regex::new(r"\s").unwrap(), "a\nb"), [(1, 2)]);
    assert_eq!(spans(&Regex::new(r"\s").unwrap(), "a\tb"), [(1, 2)]);
    assert_eq!(spans(&Regex::new("[ \n]").unwrap(), "a\nb"), [(1, 2)]);
    assert_eq!(
        Regex::new(r"a\sb").unwrap().find("a\nb").unwrap().as_str(),
        "a\nb"
    );
    // `.` still stops at a newline unless asked otherwise, exactly as it does in
    // `regex` and `re`. Inline `(?s)` is PCRE2 grammar here, so the portable way
    // to ask is the builder.
    assert_eq!(spans(&Regex::new(".").unwrap(), "a\nb"), [(0, 1), (2, 3)]);
    let dotall = RegexBuilder::new(".")
        .dot_matches_new_line(true)
        .build()
        .unwrap();
    assert_eq!(spans(&dotall, "a\nb"), [(0, 1), (1, 2), (2, 3)]);
}

/// `^` and `$` are text anchors by default and line anchors under
/// `multi_line`, which is what `regex` and `re` both do. The buffer model is a
/// separate question - the text is one buffer either way.
#[test]
fn multi_line_moves_the_anchors_and_nothing_else() {
    let text = "ab\ncd";
    assert_eq!(spans(&Regex::new("^..").unwrap(), text), [(0, 2)]);
    let lines = RegexBuilder::new("^..").multi_line(true).build().unwrap();
    assert_eq!(spans(&lines, text), [(0, 2), (3, 5)]);

    assert_eq!(spans(&Regex::new("..$").unwrap(), text), [(3, 5)]);
    let ends = RegexBuilder::new("..$").multi_line(true).build().unwrap();
    assert_eq!(spans(&ends, text), [(0, 2), (3, 5)]);

    // Still one buffer under either setting: a match may cross the newline.
    for re in [Regex::new(r"b\nc").unwrap(), {
        RegexBuilder::new(r"b\nc").multi_line(true).build().unwrap()
    }] {
        assert_eq!(spans(&re, text), [(1, 4)]);
    }
}

/// The end-of-text anchor is `\z`, as in Rust's `regex` crate and RE2, and it
/// means the end of the text rather than "before a trailing newline". There is
/// no anchored search verb, so the anchor in the pattern is how you ask.
#[test]
fn text_anchors() {
    assert_eq!(
        Regex::new(r"\Aa").unwrap().find("ab").map(|m| m.range()),
        Some(0..1)
    );
    assert_eq!(Regex::new(r"\Aa").unwrap().find("ba"), None);
    assert_eq!(
        Regex::new(r"a\z").unwrap().find("ba").map(|m| m.range()),
        Some(1..2)
    );
    assert_eq!(Regex::new(r"a\z").unwrap().find("ba\n"), None);
    // `^` and `$` are not multiline by default, which is the `regex` crate's
    // default too.
    assert_eq!(Regex::new("^b").unwrap().find("a\nb"), None);
    assert_eq!(Regex::new("a$").unwrap().find("a\nb"), None);
}

/// The buffer is ONE unit, so `^` and `\A` match only at offset 0, `$` and `\z`
/// only at the end, and an interior newline is an ordinary byte. Both arms of the
/// engine say so: `find_iter`, which the C ABI makes the authority on the match
/// sequence, and `is_match`, which runs the same walk and stops at the first hit.
///
/// The grid below is built to tell three hypotheses apart, because "no match" on
/// its own is far too weak a claim. An engine with per-line anchors and an engine
/// whose anchors never match anything both produce no match for `\Aabc\z` over
/// `"x\nabc\ny"`, and only one of those is a bug this test should catch. So every
/// row carries what all three hypotheses predict, and the test asserts the engine
/// against the text-anchor column while proving the grid actually separates it
/// from the other two. `is_match` used to fail this by running a boolean document
/// kernel that split the buffer into lines; the rows where `line` differs from
/// `text` are the ones that caught it, and they are checked to still exist.
#[test]
fn anchors_are_text_anchors_and_find_all_is_the_authority() {
    /// `(pattern, text, text-anchor, per-line, anchors-never-match)`.
    const GRID: &[(&str, &str, bool, bool, bool)] = &[
        // No match under text anchors, but a match on an interior line: these
        // separate the real contract from the per-line reading.
        ("^a", "\nabc", false, true, false),
        (r"\Aa", "\nabc", false, true, false),
        ("b$", "ab\ncd", false, true, false),
        (r"b\z", "ab\ncd", false, true, false),
        ("^abc$", "x\nabc\ny", false, true, false),
        (r"\Aabc\z", "x\nabc\ny", false, true, false),
        ("c$", "abc\n", false, true, false),
        ("^c", "ab\ncd", false, true, false),
        // A match under text anchors, in a text that still holds a newline: these
        // separate the real contract from an engine whose anchors match nothing,
        // which the rows above cannot do.
        ("^a", "ab\ncd", true, true, false),
        (r"\Aa", "ab\ncd", true, true, false),
        ("d$", "ab\ncd", true, true, false),
        (r"d\z", "ab\ncd", true, true, false),
        (r"\Aab\ncd\z", "ab\ncd", true, true, false),
        // And with no newline at all, where every reading agrees. A failure here
        // is a broken anchor rather than a broken unit of matching.
        ("^a", "ab", true, true, false),
        ("^b", "ab", false, false, false),
        (r"a\z", "ab", false, false, false),
        (r"b\z", "ab", true, true, false),
    ];

    for &(pattern, text, want, _, _) in GRID {
        let re = Regex::new(pattern).unwrap();
        let found = !spans(&re, text).is_empty();
        assert_eq!(
            found,
            want,
            "{pattern:?} over {text:?}: the buffer is one unit, so find_iter should \
             {} match",
            if want { "" } else { "not" }
        );
        assert_eq!(
            re.is_match(text),
            want,
            "{pattern:?} over {text:?}: is_match runs the same walk as find_all, so it \
             should agree"
        );
        assert_eq!(re.find(text).is_some(), want, "{pattern:?} over {text:?}");
    }

    // The grid is only evidence if it discriminates, so check that it does rather
    // than trusting that whoever edits it next keeps that property.
    let separates_line = GRID.iter().filter(|&&(_, _, t, l, _)| t != l).count();
    let separates_dead = GRID.iter().filter(|&&(_, _, t, _, d)| t != d).count();
    assert!(
        separates_line >= 8,
        "only {separates_line} rows distinguish text anchors from per-line anchors; a grid \
         that cannot see the difference would pass against the document-kernel bug this \
         test exists for"
    );
    assert!(
        separates_dead >= 5,
        "only {separates_dead} rows would fail against an engine whose anchors never match, \
         so the grid is asserting absence and little else"
    );
}

/// The other half of "the buffer is one unit": per-line anchors are a *mode over*
/// that buffer, asked for once for the whole pattern, and never a claim about
/// what the text is. Both spellings ask - `multi_line(true)` and a leading
/// `(?m)` - and they are the same compile, so a pattern carried over from
/// another engine means here what it meant there.
///
/// What stays refused is the scoped `(?m:...)` form, which would make the anchors
/// mean one thing inside a subexpression and another outside it. Refusing beats
/// parsing it and applying it to everything, and the PCRE arm is the escape hatch
/// for a caller who needs the real scoping.
#[test]
fn per_line_anchors_are_one_mode_asked_for_two_ways() {
    for (inline, body) in [("(?m)^b", "^b"), (r"(?m)b$", r"b$")] {
        let folded = Regex::new(inline).unwrap();
        let built = RegexBuilder::new(body).multi_line(true).build().unwrap();
        for text in ["a\nb", "b\na", "b", "a\nb\n", ""] {
            assert_eq!(
                folded.find(text).map(|m| m.range()),
                built.find(text).map(|m| m.range()),
                "{inline:?} over {text:?}"
            );
        }
    }
    // Off is still off, and the default is still the text's own ends.
    assert_eq!(Regex::new("^b").unwrap().find("a\nb"), None);

    // The scoped form is a different question and is not answered here.
    assert!(
        Regex::new("(?m:^b)").is_err(),
        "a scoped (?m:...) compiled; applying it to the whole pattern is worse \
         than refusing it"
    );
    let scoped = RegexBuilder::new("(?m:^b)").pcre(true).build().unwrap();
    assert_eq!(scoped.find("a\nb").map(|m| m.range()), Some(2..3));
}

/// The reason to use this engine at all. A backtracking implementation takes
/// exponential time on this shape; a finite automaton does not notice.
#[test]
fn pathological_patterns_are_not_pathological() {
    let re = Regex::new("(a+)+b").unwrap();
    let text = "a".repeat(60);
    let started = std::time::Instant::now();
    assert!(!re.is_match(&text));
    assert!(
        started.elapsed() < std::time::Duration::from_secs(1),
        "the linear engine should not backtrack"
    );
}

fn spans(re: &Regex, text: &str) -> Vec<(usize, usize)> {
    re.find_iter(text).map(|m| (m.start(), m.end())).collect()
}
