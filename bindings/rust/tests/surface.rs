//! The `regex`-shaped surface: iteration, split, replace, and the plumbing.
//!
//! The point of mirroring the `regex` crate is that code written against it
//! keeps working, so these tests are written the way that code would be.

use std::borrow::Cow;

use irgx::{Captures, NoExpand, Regex, RegexBuilder};

#[test]
fn find_and_iterate() {
    let re = Regex::new(r"\d+").unwrap();
    let text = "a1 bb22 c333";

    let first = re.find(text).unwrap();
    assert_eq!(first.as_str(), "1");
    assert_eq!(first.start(), 1);
    assert_eq!(first.end(), 2);
    assert_eq!(first.range(), 1..2);
    assert_eq!(first.len(), 1);
    assert!(!first.is_empty());
    assert_eq!(first.as_bytes(), b"1");

    assert_eq!(
        re.find_iter(text).map(|m| m.as_str()).collect::<Vec<_>>(),
        ["1", "22", "333"]
    );
    assert!(re.find("none here").is_none());
    assert!(re.is_match(text));
    assert!(!re.is_match("none here"));
}

/// The sequence is one answer from the engine, so the iterator is eager. That
/// buys a length and a reverse walk, which the `regex` crate's lazy one cannot
/// offer, and it is the observable consequence of the `find_all` rule.
#[test]
fn iteration_knows_its_shape() {
    let re = Regex::new(r"\w+").unwrap();
    let found = re.find_iter("one two three");
    assert_eq!(found.len(), 3);
    assert_eq!(
        found.rev().map(|m| m.as_str()).collect::<Vec<_>>(),
        ["three", "two", "one"]
    );

    // Fused: exhausted stays exhausted.
    let mut once = Regex::new("a").unwrap().find_iter("a");
    assert!(once.next().is_some());
    assert!(once.next().is_none());
    assert!(once.next().is_none());
}

#[test]
fn split_and_splitn() {
    let re = Regex::new(r"\s*,\s*").unwrap();
    assert_eq!(
        re.split("a, b ,c,  d").collect::<Vec<_>>(),
        ["a", "b", "c", "d"]
    );
    // A leading or trailing separator produces an empty piece, as `str::split`
    // does.
    assert_eq!(re.split(",a,").collect::<Vec<_>>(), ["", "a", ""]);
    assert_eq!(
        re.split("no separators").collect::<Vec<_>>(),
        ["no separators"]
    );

    // splitn stops cutting and hands back the rest whole, separators included.
    assert_eq!(re.splitn("a,b,c,d", 2).collect::<Vec<_>>(), ["a", "b,c,d"]);
    assert_eq!(re.splitn("a,b,c,d", 1).collect::<Vec<_>>(), ["a,b,c,d"]);
    assert_eq!(re.splitn("a,b,c,d", 0).count(), 0);
    assert_eq!(re.splitn("a,b", 9).collect::<Vec<_>>(), ["a", "b"]);
}

#[test]
fn replace_family() {
    let re = Regex::new(r"\d+").unwrap();
    assert_eq!(re.replace("a1 b2 c3", "N"), "aN b2 c3");
    assert_eq!(re.replace_all("a1 b2 c3", "N"), "aN bN cN");
    assert_eq!(re.replacen("a1 b2 c3", 2, "N"), "aN bN c3");
    // A limit of zero means all of them, which is the `regex` crate's rule and
    // reads wrong every time; it is kept because code moving over relies on it.
    assert_eq!(re.replacen("a1 b2 c3", 0, "N"), "aN bN cN");
    // No match means the input comes back untouched, and un-copied.
    let untouched = re.replace_all("nothing", "N");
    assert!(matches!(untouched, Cow::Borrowed("nothing")));
}

#[test]
fn replacement_expands_group_references() {
    let re = Regex::new(r"(?P<first>\w+)\s+(?P<last>\w+)").unwrap();
    assert_eq!(re.replace("Ada Lovelace", "$last, $first"), "Lovelace, Ada");
    assert_eq!(re.replace("Ada Lovelace", "$2 $1"), "Lovelace Ada");
    assert_eq!(re.replace("Ada Lovelace", "${last}!"), "Lovelace!");
    // `$$` is a literal dollar, and a reference to a group that does not exist
    // expands to nothing rather than erroring.
    assert_eq!(re.replace("Ada Lovelace", "$$$first"), "$Ada");
    assert_eq!(re.replace("Ada Lovelace", "[$nope]"), "[]");
    // A bare `$` at the end is data.
    assert_eq!(re.replace("Ada Lovelace", "x$"), "x$");

    // NoExpand turns the whole thing off, which is what you want for text you
    // did not write.
    assert_eq!(
        re.replace("Ada Lovelace", NoExpand("$1 costs $5")),
        "$1 costs $5"
    );
}

#[test]
fn replacement_can_be_a_closure() {
    let re = Regex::new(r"\d+").unwrap();
    let doubled = re.replace_all("a1 b20 c300", |caps: &Captures<'_, '_>| {
        let n: u32 = caps[0].parse().unwrap();
        (n * 2).to_string()
    });
    assert_eq!(doubled, "a2 b40 c600");
}

/// Replacement has to work in bytes, because the offsets do; a multi-byte match
/// is where an off-by-one in the copy would show.
#[test]
fn replacement_is_byte_correct() {
    let re = RegexBuilder::new("café").ignore_case(true).build().unwrap();
    assert_eq!(re.replace_all("le café, le CAFÉ", "tea"), "le tea, le tea");

    let re = Regex::new("é").unwrap();
    assert_eq!(re.replace_all("café au naïf", "e"), "cafe au naïf");
}

/// A zero-width pattern in a replacement is where an advance loop would either
/// insert twice at one position or loop forever. The sequence comes from the
/// engine, so it does neither.
#[test]
fn replacement_handles_empty_matches() {
    let re = Regex::new("").unwrap();
    // The engine reports (0,0), (1,1), (2,2) for "abc" and suppresses the one at
    // the end of the buffer, so the final `-` the `regex` crate would add is not
    // there.
    assert_eq!(re.replace_all("abc", "-"), "-a-b-c");

    let star = Regex::new("a*").unwrap();
    assert_eq!(star.replace_all("abc", "[]"), "[]b[]c");
}

#[test]
fn accessors_and_traits() {
    let re: Regex = "a+b".parse().unwrap();
    assert_eq!(re.as_str(), "a+b");
    assert_eq!(re.to_string(), "a+b");
    assert_eq!(format!("{re:?}"), "\"a+b\"");
    assert_eq!(re.groups(), Some(0));

    // Clone recompiles, because a C handle cannot be duplicated. The clone has
    // to behave identically, including its flags.
    let cased = RegexBuilder::new("abc").ignore_case(true).build().unwrap();
    let copy = cased.clone();
    assert_eq!(copy.as_str(), "abc");
    assert!(copy.is_match("ABC"));
    assert_eq!(copy.find_iter("ABC abc").count(), 2);

    assert_eq!(irgx::ABI_VERSION, 2);
    assert!(!irgx::engine_version().is_empty());
    assert!(!irgx::pcre2_version().is_empty());
}

/// The checked verbs exist so a caller who does not want a panic never has to
/// take one, and they answer the same thing on the happy path.
#[test]
fn checked_verbs_mirror_the_panicking_ones() {
    let re = Regex::new(r"(\w)(\d)").unwrap();
    let text = "a1 b2";
    assert_eq!(re.try_is_match(text).unwrap(), re.is_match(text));
    assert_eq!(
        re.try_find(text).unwrap().map(|m| m.range()),
        re.find(text).map(|m| m.range())
    );
    assert_eq!(
        re.try_find_iter(text).unwrap().count(),
        re.find_iter(text).count()
    );
    assert_eq!(
        re.try_captures(text).unwrap().map(|c| c[1].to_owned()),
        re.captures(text).map(|c| c[1].to_owned())
    );
    assert_eq!(
        re.try_captures_iter(text).unwrap().count(),
        re.captures_iter(text).count()
    );
    assert_eq!(
        re.try_replacen(text, usize::MAX, "x").unwrap(),
        re.replace_all(text, "x")
    );
}

/// The window `find_all` is asked for starts at a few thousand spans, and a text
/// with more matches than that is answered by a second pass at the count the
/// engine reported. A wrong implementation truncates silently here, keeping only
/// what the first window held.
#[test]
fn many_matches_are_not_truncated() {
    let text = "a ".repeat(20_000);
    let re = Regex::new("a").unwrap();
    assert_eq!(re.find_iter(&text).count(), 20_000);
    assert_eq!(
        re.find_iter(&text).next_back().unwrap().start(),
        text.len() - 2
    );

    // The empty pattern reports a match at every byte except the end of the
    // buffer, which is the densest sequence a text can produce and the case the
    // window sizing has to survive.
    let empty = Regex::new("").unwrap();
    assert_eq!(empty.find_iter(&text).count(), text.len());

    // And with groups, where each match also costs a `captures` call.
    let grouped = Regex::new("(a)").unwrap();
    assert_eq!(grouped.captures_iter(&text).count(), 20_000);
}

/// A window shorter than the answer comes back complete, and the seam that makes
/// that true is `find_all` reporting how many matches the TEXT has rather than
/// how many fit. The sizes walk the first window's own boundary, because the
/// exact fit is where a count read as a length is indistinguishable from a
/// truncation, and where an off-by-one in the retry either drops the last match
/// or reads a span nobody wrote.
#[test]
fn a_short_window_still_returns_every_match() {
    // The crate's private first-ask size. The assertions do not depend on it
    // being right - every count below has to come back whole either way - it
    // only puts the interesting cases where the seam actually changes.
    const FIRST_WINDOW: usize = 4096;

    let re = Regex::new("a").unwrap();
    for count in [1, FIRST_WINDOW - 1, FIRST_WINDOW, FIRST_WINDOW + 1, 9_999] {
        let text = "a.".repeat(count);
        let found: Vec<_> = re.find_iter(&text).map(|m| m.start()).collect();
        assert_eq!(found.len(), count, "{count} matches went in");
        // Every span, not just the count: a retry that re-read a stale buffer
        // would keep the length and lose the positions.
        assert!(
            found
                .iter()
                .enumerate()
                .all(|(nth, start)| *start == nth * 2),
            "the spans are not the ones the text has, at count {count}"
        );
    }

    // And the whole answer is reachable through the verbs built on top of it,
    // so nothing re-derives the sequence at a smaller size on the way out.
    let text = "a.".repeat(FIRST_WINDOW + 1);
    assert_eq!(re.split(&text).count(), FIRST_WINDOW + 2);
    assert_eq!(re.replace_all(&text, "").len(), FIRST_WINDOW + 1);
}

#[test]
fn expand_writes_into_a_caller_buffer() {
    let re = Regex::new(r"(?P<k>\w+)=(?P<v>\w+)").unwrap();
    let mut out = String::new();
    for caps in re.captures_iter("a=1 b=2") {
        caps.expand("$k:$v ", &mut out);
    }
    assert_eq!(out, "a:1 b:2 ");
}

#[test]
fn captures_iter_and_len() {
    let re = Regex::new(r"(a)(b)?").unwrap();
    let caps = re.captures("ab").unwrap();
    assert_eq!(caps.len(), 3);
    assert_eq!(
        caps.iter()
            .map(|g| g.map(|m| m.as_str()))
            .collect::<Vec<_>>(),
        [Some("ab"), Some("a"), Some("b")]
    );

    let caps = re.captures("ac").unwrap();
    assert_eq!(
        caps.iter()
            .map(|g| g.map(|m| m.as_str()))
            .collect::<Vec<_>>(),
        [Some("a"), Some("a"), None]
    );
}
