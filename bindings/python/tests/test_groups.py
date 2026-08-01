"""Capture groups: numbered, named, and the ones the match never entered.

The distinction that matters most here is ``None`` versus ``""``. A group that
did not participate and a group that matched the empty string are different
facts, and ``(a)|(b)`` produces one of each on every match, so a binding that
flattens them is losing information the engine took care to keep.
"""

from __future__ import annotations

import ctypes

import pytest

import irregex
from irregex import _abi


def test_numbered_groups():
    match = irregex.search(r"(\w+)@(\w+)\.(\w+)", "write to me@example.com now")
    assert match is not None
    assert match.group(0) == "me@example.com"
    assert match.group(1) == "me"
    assert match.group(2, 3) == ("example", "com")
    assert match.groups() == ("me", "example", "com")
    assert match[2] == "example"
    assert match.span(1) == (9, 11)


def test_a_group_that_did_not_participate_is_none_not_empty():
    pattern = irregex.compile(r"(\w+)=(?:(\d+)|(true))")

    number = pattern.search("n=42")
    assert number is not None
    assert number.groups() == ("n", "42", None)
    assert number.group(3) is None
    assert number.span(3) == (-1, -1)
    assert number.start(3) == -1

    flag = pattern.search("n=true")
    assert flag is not None
    assert flag.groups() == ("n", None, "true")


def test_a_group_that_matched_empty_is_not_none():
    match = irregex.search(r"(a)(x*)(b)", "ab")
    assert match is not None
    assert match.groups() == ("a", "", "b")
    assert match.group(2) == ""
    assert match.group(2) is not None
    assert match.span(2) == (1, 1)


def test_named_groups():
    pattern = irregex.compile(r"(?P<user>\w+)@(?P<host>[\w.]+)")
    assert pattern.groups == 2
    assert pattern.groupindex == {"user": 1, "host": 2}

    match = pattern.search("mail me@example.com")
    assert match is not None
    assert match["user"] == "me"
    assert match.group("host") == "example.com"
    assert match.groupdict() == {"user": "me", "host": "example.com"}
    assert match.span("user") == (5, 7)


def test_the_other_named_group_spelling_works_too():
    pattern = irregex.compile(r"(?<key>\w+)")
    assert pattern.groupindex == {"key": 1}
    assert pattern.search("abc").group("key") == "abc"


def test_lookbehind_is_not_mistaken_for_a_group_name():
    pattern = irregex.compile(r"(?<=x)(?P<rest>\w+)", pcre=True)
    assert pattern.groupindex == {"rest": 1}
    assert pattern.search("xabc").group("rest") == "abc"


def test_groupdict_reports_absent_named_groups():
    pattern = irregex.compile(r"(?P<num>\d+)|(?P<word>[a-z]+)")
    assert pattern.groupindex == {"num": 1, "word": 2}
    match = pattern.search("42")
    assert match is not None
    assert match.groupdict() == {"num": "42", "word": None}
    assert match.groupdict(default="-") == {"num": "42", "word": "-"}


@pytest.mark.parametrize("pcre", [False, True])
def test_a_name_is_found_through_spellings_that_look_like_groups_and_are_not(pcre):
    # An escaped `\(` opens nothing and `(?:` opens a group that gets no number,
    # so reading the names off the pattern text has to get both right to arrive
    # at the same answer the parser already holds. Both grammars, because the
    # PCRE2 arm keeps its names in its own table and has to agree.
    pattern = irregex.compile(r"\((?:x|y)(?P<inner>\w+)\)", pcre=pcre)
    assert pattern.groups == 1
    assert pattern.groupindex == {"inner": 1}
    assert pattern.search("(xab)").group("inner") == "ab"


@pytest.mark.parametrize(
    "source,subject",
    [
        # A `[` inside a comment group, and one inside a quoted run: neither
        # opens a character class, and a scan that thinks either does swallows
        # the rest of the pattern - including the name declared after it.
        (r"(?#[)(?P<n>\w+)", "abc"),
        (r"\Q[\E(?P<n>\w+)", "[abc"),
    ],
)
def test_a_name_comes_from_the_parser_not_from_reading_the_pattern_text(source, subject):
    pattern = irregex.compile(source, pcre=True)
    assert pattern.groups == 1
    assert pattern.groupindex == {"n": 1}
    assert pattern.search(subject).group("n") == "abc"


def test_unnamed_groups_are_absent_from_groupindex_without_shifting_the_named_ones():
    # Every group is asked about by index, so an unnamed one answers "no name"
    # rather than being skipped in a way that could renumber its neighbours.
    pattern = irregex.compile(r"(\w)(?P<second>\w)(\w)(?P<fourth>\w)")
    assert pattern.groups == 4
    assert pattern.groupindex == {"second": 2, "fourth": 4}
    # Decoded at resolve time: the engine's bytes borrow a handle that a thread
    # can outlive, so what the mapping holds is a str and not a view of them.
    assert all(isinstance(name, str) for name in pattern.groupindex)
    assert pattern.search("abcd").groupdict() == {"second": "b", "fourth": "d"}


def test_the_three_answers_asking_a_group_for_its_name_can_give():
    # The binding walks 1..groups and reads OK as "this one is plain", so the
    # three answers are load-bearing: a name, no name, and a refusal past the
    # end. The last one is INVALID rather than an absence because the count is
    # knowable, which is what makes walking off the end a bug and not a result.
    compiled = _abi.Compiled(rb"(?P<named>a)(b)", 0)
    name = _abi.Text()

    assert _abi.lib.irregex_group_name(compiled.ptr, 1, ctypes.byref(name)) == _abi.MATCH
    assert name.decode() == "named"
    assert _abi.lib.irregex_group_name(compiled.ptr, 2, ctypes.byref(name)) == _abi.OK
    # Group 0 is the whole match, which is never named.
    assert _abi.lib.irregex_group_name(compiled.ptr, 0, ctypes.byref(name)) == _abi.OK
    assert _abi.lib.irregex_group_name(compiled.ptr, 3, ctypes.byref(name)) == _abi.INVALID


def test_a_pattern_with_no_groups_reports_zero():
    pattern = irregex.compile(r"\w+")
    assert pattern.groups == 0
    assert pattern.groupindex == {}
    match = pattern.search("abc")
    assert match.groups() == ()
    assert match.group(0) == "abc"


def test_asking_for_a_group_that_does_not_exist():
    match = irregex.search(r"(a)", "a")
    with pytest.raises(IndexError):
        match.group(2)
    with pytest.raises(IndexError):
        match.group("nope")
    with pytest.raises(IndexError):
        match[7]


def test_captures_reports_the_true_group_count_even_from_a_short_window():
    # This binding always sizes its window at group_count + 1, so the short-cap
    # path is exercised here directly against the C ABI: `written` must report
    # what the PATTERN has, not what was written, or a caller could never size
    # a retry. The whole-match span must still land in the truncated prefix.
    compiled = _abi.Compiled(rb"(a)(b)(c)", 0)
    out = (_abi.Span * 2)()
    written = ctypes.c_size_t()
    status = _abi.lib.irregex_captures(compiled.ptr, b"abc", 3, 0, out, 2, ctypes.byref(written))
    assert status == _abi.MATCH
    assert written.value == 4, "1 whole match + 3 declared groups"
    assert (out[0].start, out[0].end) == (0, 3)
    assert (out[1].start, out[1].end) == (0, 1)


def test_group_detail_is_filled_per_match_and_matches_find_all():
    # Every match's group 0 must equal the span find_all reported for it. The
    # binding checks this itself and raises on disagreement, so a silent
    # mismatch is impossible; this asserts the agreement holds across shapes.
    for pattern, text in [
        (r"(a+)(b*)", "aab aa b"),
        (r"\b(\w)(\w*)", "hi yo there"),
        (r"(x)?a", "a xa a"),
        (r"(?P<k>\w+)=(\d+)", "a=1 bb=22 ccc=333"),
    ]:
        compiled = irregex.compile(pattern)
        for match in compiled.finditer(text):
            assert match.span(0) == match.span()
            assert text[match.start() : match.end()] == match.group(0)
            for index in range(1, compiled.groups + 1):
                span = match.span(index)
                if span != (-1, -1):
                    assert text[span[0] : span[1]] == match.group(index)
