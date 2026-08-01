"""str in, str out; bytes in, bytes out - and the offsets that go with each.

The engine searches UTF-8 bytes. A caller who passed a ``str`` must never see a
byte offset, because they cannot slice their own string with one. The invariant
that catches every mistake in that translation is a single line:

    text[m.start():m.end()] == m.group()

so it is asserted here on text where the two domains actually differ.
"""

from __future__ import annotations

import pytest

import irregex

# Every character past the first is multi-byte, so a binding that skipped the
# translation would be wrong from index 2 onwards.
MIXED = "naïve café CAFÉ ünïcödé"


def test_str_positions_index_the_callers_own_string():
    for match in irregex.finditer(r"\w+", MIXED):
        start, end = match.span()
        assert MIXED[start:end] == match.group()


def test_codepoint_indices_are_not_the_byte_offsets():
    found = [m.span() for m in irregex.finditer(r"\w+", MIXED)]
    assert found == [(0, 5), (6, 10), (11, 15), (16, 23)]
    # The same search over the same text as bytes reports byte offsets, and the
    # two disagree - which is exactly why the translation has to exist.
    raw = [m.span() for m in irregex.finditer(rb"\w+", MIXED.encode())]
    assert raw == [(0, 6), (7, 12), (13, 18), (19, 30)]
    assert raw != found


def test_ascii_text_takes_the_fast_path_and_gets_the_same_answer():
    plain = "naive cafe"
    assert plain.isascii()
    assert [m.span() for m in irregex.finditer(r"\w+", plain)] == [(0, 5), (6, 10)]
    for match in irregex.finditer(r"\w+", plain):
        assert plain[match.start() : match.end()] == match.group()


def test_case_folding_crosses_the_ascii_boundary():
    assert irregex.findall("café", "x CAFÉ y", ignore_case=True) == ["CAFÉ"]
    assert irregex.findall("CAFÉ", "x café y", ignore_case=True) == ["café"]
    assert irregex.findall("café", "x CAFÉ y") == []
    # Greek final sigma folds too, which ASCII-only folding would miss.
    assert irregex.findall("ΟΔΟΣ", "οδος", ignore_case=True) == ["οδος"]


def test_positions_are_right_when_a_match_starts_after_a_multibyte_character():
    text = "é" * 5 + "target"
    match = irregex.search("target", text)
    assert match is not None
    assert match.span() == (5, 11)
    assert text[match.start() : match.end()] == "target"


def test_group_positions_translate_too_not_just_the_whole_match():
    text = "ünïcödé=42"
    match = irregex.search(r"(\w+)=(\d+)", text)
    assert match is not None
    assert match.span(1) == (0, 7)
    assert match.span(2) == (8, 10)
    assert text[match.start(1) : match.end(1)] == match.group(1) == "ünïcödé"
    assert text[match.start(2) : match.end(2)] == match.group(2) == "42"


def test_out_of_order_position_requests_stay_correct():
    # The translation is built incrementally from checkpoints, so asking
    # backwards must give the same answers as asking forwards.
    matches = list(irregex.finditer(r"\w+", MIXED))
    backwards = [m.span() for m in reversed(matches)]
    forwards = [m.span() for m in matches]
    assert backwards == list(reversed(forwards))


def test_a_str_pattern_refuses_bytes_and_the_reverse():
    text_pattern = irregex.compile(r"\w+")
    byte_pattern = irregex.compile(rb"\w+")
    with pytest.raises(TypeError):
        text_pattern.findall(b"abc")
    with pytest.raises(TypeError):
        byte_pattern.findall("abc")
    with pytest.raises(TypeError):
        irregex.findall(r"\w+", b"abc")


def test_bytes_results_are_bytes():
    match = irregex.search(rb"(\w+)=(\d+)", b"answer=42")
    assert match is not None
    assert match.group(0) == b"answer=42"
    assert match.groups() == (b"answer", b"42")
    assert isinstance(match.string, bytes)


def test_unicode_can_be_turned_off_and_it_changes_what_a_word_is():
    # With Unicode on, `ï` is a word character; with it off, it is two bytes
    # that are not, so the run splits.
    assert irregex.findall(r"\w+", "naïve") == ["naïve"]
    assert irregex.findall(rb"\w+", "naïve".encode(), unicode=False) == [b"na", b"ve"]
