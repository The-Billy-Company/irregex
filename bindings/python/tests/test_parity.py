"""Side-by-side with the standard library, in both directions.

Where the two engines are specified to agree, the assertion compares against
``re`` computed live, so this suite fails if either side moves. Where they
disagree, the assertion states OUR answer as a literal and the comment says why
the difference is deliberate; weakening one of those to a comparison would turn
a documented divergence into whatever the code happens to do today.
"""

from __future__ import annotations

import re

import pytest

import irregex

# Patterns in the grammar both engines implement the same way, over text chosen
# to exercise anchors, classes, alternation, quantifiers and word boundaries.
AGREE = [
    (r"\w+", "hello world 42"),
    (r"\d+", "a1 bb22 ccc333"),
    (r"[a-z]+\d", "ab1 cd2 x"),
    (r"(\w+)@(\w+)\.(\w+)", "me@example.com and you@other.org"),
    (r"colou?r", "color colour colr"),
    (r"^\w+", "first second"),
    (r"\w+$", "first second"),
    (r"a|bb|ccc", "a bb ccc bbb"),
    (r"\s+", "a  b\tc d"),
    (r"[^ ]+", "a bb ccc"),
    (r"\bcat\b", "cat concatenate cats cat"),
    (r"(\d{4})-(\d{2})-(\d{2})", "on 2024-01-31 and 1999-12-25"),
    (r"[A-Z][a-z]+", "The Quick brown Fox"),
    (r"a{2,4}", "a aa aaa aaaa aaaaa"),
    (r"(ab)+", "ab abab ababab x"),
    (r"x[0-9a-f]*", "x x0 xff xdeadbeef xz"),
]


@pytest.mark.parametrize(("pattern", "text"), AGREE)
def test_spans_agree_with_re(pattern, text):
    assert [m.span() for m in irregex.finditer(pattern, text)] == [
        m.span() for m in re.finditer(pattern, text)
    ]


@pytest.mark.parametrize(("pattern", "text"), AGREE)
def test_findall_agrees_with_re(pattern, text):
    # `re.findall` returns "" for a group the match did not enter; none of these
    # patterns has one, which is why the comparison is exact here and the
    # divergence gets its own test below.
    assert irregex.findall(pattern, text) == re.findall(pattern, text)


@pytest.mark.parametrize(("pattern", "text"), AGREE)
def test_groups_agree_with_re(pattern, text):
    for mine, theirs in zip(
        irregex.finditer(pattern, text), re.finditer(pattern, text), strict=True
    ):
        assert mine.group(0) == theirs.group(0)
        assert mine.groups() == theirs.groups()


@pytest.mark.parametrize(("pattern", "text"), AGREE)
def test_substitution_agrees_with_re(pattern, text):
    assert irregex.sub(pattern, "<>", text) == re.sub(pattern, "<>", text)


def test_alternation_prefers_the_left_branch_exactly_as_re_does():
    # This is the classic place a DFA engine diverges: POSIX leftmost-longest
    # would report "ab" for `a|ab`. It does not, which is what makes the
    # comparisons above meaningful rather than accidental.
    for pattern, text in [("a|ab", "ab"), ("ab|a", "ab"), ("(a|ab)(c|bcd)", "abcd")]:
        assert irregex.search(pattern, text).span() == re.search(pattern, text).span()


def test_lazy_quantifiers_agree_with_re():
    for pattern, text in [(r"\w+?", "abc"), (r"<.*?>", "<a><b>"), (r"a+?b", "aaab")]:
        assert [m.span() for m in irregex.finditer(pattern, text)] == [
            m.span() for m in re.finditer(pattern, text)
        ]


def test_ignore_case_agrees_with_re_on_ascii():
    assert irregex.findall("walrus", "WALRUS Walrus walrus", ignore_case=True) == re.findall(
        "walrus", "WALRUS Walrus walrus", re.IGNORECASE
    )


# ── the divergences, asserted as our behaviour ────────────────────────────


def test_we_do_not_report_an_empty_match_at_the_end_of_the_text():
    # `re` reports an empty match after the last character; this engine does
    # not. The rule belongs to the engine, whose unit of work is a line of a
    # file and which reports what it found IN the text rather than after it.
    # `find_all` is the authority, so the binding reports what it reports.
    assert [m.span() for m in irregex.finditer("", "abc")] == [(0, 0), (1, 1), (2, 2)]
    assert [m.span() for m in re.finditer("", "abc")] == [(0, 0), (1, 1), (2, 2), (3, 3)]

    assert [m.span() for m in irregex.finditer("a*", "abc")] == [(0, 1), (2, 2)]
    assert [m.span() for m in re.finditer("a*", "abc")] == [(0, 1), (1, 1), (2, 2), (3, 3)]


def test_a_non_participating_group_is_none_in_findall_not_empty_string():
    # `re.findall` flattens a group that did not participate to "", losing the
    # distinction between "did not match" and "matched nothing". `.groups()`
    # already reports None for that case in both libraries, so `findall`
    # agreeing with `.groups()` is the more consistent answer.
    assert irregex.findall(r"(a)|(b)", "ab") == [("a", None), (None, "b")]
    assert re.findall(r"(a)|(b)", "ab") == [("a", ""), ("", "b")]


def test_flags_are_keywords_and_the_re_bitmask_is_not_accepted():
    # `re.IGNORECASE` is an int; passing it positionally to a keyword-only
    # surface is a TypeError rather than a silently ignored argument.
    with pytest.raises(TypeError):
        irregex.compile("a", re.IGNORECASE)


def test_a_newline_is_a_line_terminator_and_not_ordinary_whitespace():
    # The engine is line-oriented: a single character class will not match the
    # terminator, the same way a line-oriented searcher never presents one to
    # the pattern. `re` has no such notion and matches it like any other space.
    # A longer match may still span a newline, so this is about what a
    # one-character class admits, not about the buffer being cut up.
    assert irregex.findall(r"\s", "a\nb") == []
    assert re.findall(r"\s", "a\nb") == ["\n"]
    assert irregex.findall(r"\s", "a\tb") == ["\t"]  # every other space is ordinary
    assert irregex.findall(r"a\sb", "a\nb") == ["a\nb"]
    # `.` excludes the newline in both, which is the one place they already
    # agreed.
    assert irregex.findall(r"a.b", "a\nb") == re.findall(r"a.b", "a\nb") == []


def test_there_is_no_fullmatch_or_match_because_the_engine_has_no_anchored_verb():
    # Both would have to be faked on top of an unanchored search, which is how
    # they end up subtly wrong. `\A...\z` in the pattern says the same thing and
    # is the engine's own answer. Note the spelling: the end-of-text anchor is
    # `\z`, as in Rust and RE2. `\Z` is not in this grammar, and asking for it
    # raises rather than quietly meaning something else.
    assert not hasattr(irregex, "fullmatch")
    assert not hasattr(irregex, "match")
    whole = irregex.search(r"\A\w+\z", "abc")
    assert whole is not None and whole.span() == (0, 3)
    assert irregex.search(r"\A\w+\z", "abc def") is None
    with pytest.raises(irregex.error):
        irregex.compile(r"\Z")
