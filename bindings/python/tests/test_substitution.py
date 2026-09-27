"""``sub``, ``subn``, ``split``, and the template grammar behind them.

These verbs are built on top of ``finditer``, so they inherit the engine's
iteration rules rather than re-deriving a cursor of their own. The tests
therefore check the joins as well as the replacements: the text between two
matches has to come back untouched, in the caller's own domain, including where
that domain is codepoints and the engine's is bytes.
"""

from __future__ import annotations

import re

import irgx
import pytest


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
    # empty. This is `re`'s behavior too, and it is the only sensible one:
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


def test_a_capped_sub_or_split_is_re_s_answer_for_every_cap():
    # The capped walk stops at the cap, and thinning then drops any empty match
    # inside a multi-byte character - so a nullable pattern over wide text is
    # where a prefix can come up short and the whole walk must be paid instead.
    cases = [(r"x*", "éé ab"), (r"(x*)", "é€😀"), (r"\d", "a1b2c3"), (r"(\w)(\d)?", "a1 b c3")]
    for pattern, text in cases:
        for n in range(6):
            assert irgx.subn(pattern, "-", text, count=n) == re.subn(pattern, "-", text, count=n)
            assert irgx.subn(pattern, r"<\g<0>>", text, count=n) == re.subn(
                pattern, r"<\g<0>>", text, count=n
            )
            assert irgx.split(pattern, text, maxsplit=n) == re.split(pattern, text, maxsplit=n)


def test_a_capped_walk_never_pays_for_the_whole_text(monkeypatch):
    # The point of `irgx_find_upto_in`: a capped verb over a pattern with no empty
    # matches must not reach `irgx_find_all_in`, whose count obliges it to walk
    # to the end. Driven through the ctypes verbs directly, so this holds under
    # either transport.
    from irgx import _abi, _engine
    from irgx._pool import Compiled

    compiled = Compiled(rb"(\w)=(\w)", 0)
    rx = compiled.ptr.value

    def refused(*_):
        raise AssertionError("a capped verb walked the whole text")

    monkeypatch.setattr(_abi.lib, "irgx_find_all_in", refused)
    text = "k=v; " * 1000
    assert _engine._spliced(rx, text, "-", 2, True) == ("-; -; " + "k=v; " * 998, 2)
    assert _engine._pieces(rx, text, 1, True)[0] == ""
    assert _engine._rendered(rx, text, (2, b"=", 1), 1, 2, True)[1] == 1
    assert _engine._group_pieces(rx, text, 1, 2, True)[:3] == ["", "k", "v"]


def test_octal_escapes_read_the_way_re_reads_them():
    # `\0` takes up to two more octal digits; three octal digits after the
    # backslash are a character, never a group; past 0o377 is refused. Each of
    # these used to render as NUL-then-digits or as a group plus a digit.
    groups = "(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)(k)(l)"
    subject = "abcdefghijkl"
    for template in (r"\07", r"\012", r"\0123", r"\101", r"\123", r"\377", r"\128"):
        assert irgx.sub(groups, template, subject) == re.sub(groups, template, subject)
    assert irgx.sub(rb"x", rb"\101\377", b"x") == b"A\xff"
    with pytest.raises(irgx.error):
        irgx.sub(r"x", r"\400", "x")


def test_an_unknown_non_letter_escape_keeps_its_backslash():
    assert irgx.sub(r"x", r"\ ", "x") == re.sub(r"x", r"\ ", "x") == "\\ "
    assert irgx.sub(r"x", "\\é", "x") == "\\é"


def test_a_group_number_is_ascii_decimal_only():
    # `isdigit` would read these as group 1; `re` refuses them.
    for template in (r"\g<١>", r"\g<²>"):
        with pytest.raises(irgx.error):
            irgx.sub(r"(a)", template, "a")


def test_parsed_templates_are_reused_and_bounded():
    from irgx import _pattern

    pattern = irgx.compile(r"(\w)")
    assert pattern.sub(r"<\1>", "ab") == pattern.sub(r"<\1>", "ab") == "<a><b>"
    assert list(pattern._templates) == [r"<\1>"]
    # A mutable template is parsed per call and never kept.
    bytes_pattern = irgx.compile(rb"(\w)")
    assert bytes_pattern.sub(bytearray(rb"<\1>"), b"ab") == b"<a><b>"
    assert not bytes_pattern._templates
    # A bad template raises every time, and is never stored.
    for _ in range(2):
        with pytest.raises(irgx.error):
            pattern.sub(r"\2", "ab")
    assert r"\2" not in pattern._templates
    for n in range(_pattern._TEMPLATES + 5):
        pattern.sub(f"{n}", "a")
    assert len(pattern._templates) <= _pattern._TEMPLATES


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


def test_group_templates_and_group_splits_agree_with_re_on_every_route():
    # The fast path serves an exact `str`/`bytes`; a subclass takes the Match walk.
    # Both must be `re`'s answer, including an absent group (empty in `sub`, None
    # in `split`), a cap, and wide text around every cut.
    class Text(str):
        pass

    cases = [
        (r"(\w+)=(\w+)", r"\2=\1", "clé=vâl; a=b; ñ=δ", 0),
        (r"(a)|(b)", r"<\1\2>", "abcab", 0),
        (r"(\w+)=(\w+)", r"[\g<0>|\2]", "k=v; x=y; p=q", 2),
    ]
    for pattern, template, text, count in cases:
        want = re.subn(pattern, template, text, count=count)
        assert irgx.subn(pattern, template, text, count=count) == want
        assert irgx.subn(pattern, template, Text(text), count=count) == want
        splits = re.split(pattern, text, maxsplit=count)
        assert irgx.split(pattern, text, maxsplit=count) == splits
        assert irgx.split(pattern, Text(text), maxsplit=count) == splits
    assert irgx.sub(rb"(\w)(\w)", rb"\2\1", b"abcd") == re.sub(rb"(\w)(\w)", rb"\2\1", b"abcd")
    assert irgx.split(rb"(,)|(;)", b"a,b;c") == re.split(rb"(,)|(;)", b"a,b;c")
