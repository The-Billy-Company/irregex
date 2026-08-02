"""``sub``, ``subn``, ``split``, and the template grammar behind them.

These verbs are built on top of ``finditer``, so they inherit the engine's
iteration rules rather than re-deriving a cursor of their own. The tests
therefore check the joins as well as the replacements: the text between two
matches has to come back untouched, in the caller's own domain, including where
that domain is codepoints and the engine's is bytes.
"""

from __future__ import annotations

import pytest

import irgx


def test_a_literal_replacement():
    assert irgx.sub(r"\d+", "N", "a1 b22 c333") == "aN bN cN"
    assert irgx.subn(r"\d+", "N", "a1 b22 c333") == ("aN bN cN", 3)


def test_count_caps_the_replacements_and_leaves_the_rest_alone():
    assert irgx.subn(r"\d", "N", "a1b2c3", count=2) == ("aNbNc3", 2)
    assert irgx.sub(r"\d", "N", "a1b2c3", count=0) == "aNbNcN"


def test_no_match_returns_the_original_text():
    assert irgx.sub(r"z+", "N", "abc") == "abc"
    assert irgx.subn(r"z+", "N", "abc") == ("abc", 0)


def test_numbered_backreferences_in_the_template():
    assert irgx.sub(r"(\w+)@(\w+)", r"\2 at \1", "me@here you@there") == ("here at me there at you")
    assert irgx.sub(r"(\w)(\w)", r"\2\1", "abcd") == "badc"
    # `\g<0>` is the whole match. `\0` is NOT: it is an octal escape for NUL,
    # which is `re`'s reading too, and changing it here would silently alter
    # the meaning of a template ported from `re`.
    assert irgx.sub(r"\d+", r"<\g<0>>", "a1 b22") == "a<1> b<22>"
    assert irgx.sub(r"\d+", r"<\0>", "a1 b22") == "a<\x00> b<\x00>"


def test_named_backreferences_in_the_template():
    assert irgx.sub(r"(?P<w>\w+)", r"[\g<w>]", "hi yo") == "[hi] [yo]"
    # \g<1> is the numbered spelling of the same thing.
    assert irgx.sub(r"(\w+)", r"[\g<1>]", "hi yo") == "[hi] [yo]"


def test_a_group_the_match_did_not_enter_contributes_nothing():
    # A template cannot render None, so a non-participating group renders as
    # empty. This is `re`'s behaviour too, and it is the only sensible one:
    # the alternative is refusing to substitute at all.
    assert irgx.sub(r"(a)|(b)", r"<\1\2>", "ab") == "<a><b>"


def test_an_escape_that_is_not_a_group_reference():
    assert irgx.sub(r"x", r"a\nb", "x") == "a\nb"
    assert irgx.sub(r"x", r"a\\b", "x") == "a\\b"
    assert irgx.sub(r"x", "100%", "x") == "100%"


def test_a_template_naming_a_group_that_does_not_exist_is_refused_up_front():
    # Resolved when the template is compiled, not when a match happens to
    # arrive, so a bad template on a pattern that matches nothing still fails.
    with pytest.raises(irgx.error):
        irgx.sub(r"(a)", r"\2", "zzz")
    with pytest.raises(irgx.error):
        irgx.sub(r"(a)", r"\g<nope>", "zzz")
    with pytest.raises(irgx.error):
        irgx.sub(r"(a)", "\\", "zzz")


def test_a_callable_replacement_receives_the_match():
    seen = []

    def upper(match):
        seen.append(match.span())
        return match.group().upper()

    assert irgx.sub(r"[a-z]+", upper, "ab 12 cd") == "AB 12 CD"
    assert seen == [(0, 2), (6, 8)]


def test_a_callable_can_use_groups():
    assert irgx.sub(r"(\d+)", lambda m: str(int(m.group(1)) * 2), "a1 b20") == "a2 b40"


def test_substitution_over_bytes_stays_bytes():
    assert irgx.sub(rb"\d+", b"N", b"a1 b22") == b"aN bN"
    assert irgx.sub(rb"(\w)(\w)", rb"\2\1", b"abcd") == b"badc"
    assert isinstance(irgx.sub(rb"x", b"y", b"x"), bytes)


def test_substitution_over_non_ascii_text_keeps_the_untouched_parts_intact():
    # The joins are cut in the caller's domain, so a binding slicing with byte
    # offsets would corrupt the text around every match here.
    text = "café=1 ünïcödé=22 naïve=333"
    assert irgx.sub(r"\d+", "N", text) == "café=N ünïcödé=N naïve=N"
    assert irgx.sub(r"(\w+)=(\d+)", r"\2:\1", text) == "1:café 22:ünïcödé 333:naïve"


def test_expand_renders_a_template_against_one_match():
    match = irgx.search(r"(?P<k>\w+)=(?P<v>\d+)", "answer=42")
    assert match.expand(r"\g<v> is \g<k>") == "42 is answer"
    assert match.expand(r"\2/\1") == "42/answer"


def test_split_on_a_separator():
    assert irgx.split(r"\s*,\s*", "a , b,c") == ["a", "b", "c"]
    assert irgx.split(r",", "a,b,c", maxsplit=1) == ["a", "b,c"]
    assert irgx.split(r"z", "abc") == ["abc"]


def test_split_keeps_declared_groups_the_way_re_does():
    assert irgx.split(r"(\s*)(,)(\s*)", "a , b") == ["a", " ", ",", " ", "b"]


def test_split_reports_empty_leading_and_trailing_fields():
    assert irgx.split(r",", ",a,") == ["", "a", ""]
    assert irgx.split(r",", "") == [""]


def test_split_over_non_ascii_text():
    assert irgx.split(r"·", "café·thé·eau") == ["café", "thé", "eau"]
