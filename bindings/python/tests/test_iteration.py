"""What a match SEQUENCE is - the one thing this binding must not decide itself.

Zero-width and nullable patterns are where a regex binding goes wrong, because
there are two defensible answers. The engine can produce either: the CLI walk
suppresses an empty match that abuts the previous one and one at unterminated
end-of-text, which is right for printed line-oriented rows and is what ripgrep
does. The ABI this binding sits on runs the other one, the library walk, and so
``finditer`` here reports what ``re.finditer`` reports.

These tests hold it there by asking ``re`` live rather than writing the sequence
down. They used to assert the opposite - each of the first three is named after
a difference that no longer exists - because the ABI was assembled out of the
CLI's parts and inherited its page rules along with them.
"""

from __future__ import annotations

import ctypes
import re

import irgx
import pytest
from irgx import _abi
from irgx._pool import Compiled


def spans(pattern, text, **flags):
    return [m.span() for m in irgx.finditer(pattern, text, **flags)]


# ── the sequence is `re`'s ────────────────────────────────────────────────


def re_spans(pattern, text):
    return [m.span() for m in re.finditer(pattern, text)]


def test_an_empty_match_at_the_end_of_the_text_is_reported():
    # (3, 3) is a real position - it is where you would insert at the end - and
    # `re`, `rust-regex`, Go's `regexp` and JS `matchAll` all report it. Only a
    # line-oriented printer has cause to suppress it, and this is not one.
    assert spans("a*", "abc") == [(0, 1), (1, 1), (2, 2), (3, 3)] == re_spans("a*", "abc")
    assert spans(r"\b", "hi yo") == re_spans(r"\b", "hi yo")
    assert spans("x*", "") == [(0, 0)] == re_spans("x*", "")


def test_an_empty_match_touching_the_previous_match_is_reported():
    # After `a` at (0, 1) the next position is 1, where `a*` matches empty.
    # Reported, though it abuts the match just before it.
    for pattern, text in [("a*", "abcab"), ("(a)*", "baac"), ("a?", "bab"), ("a*", "bbb")]:
        assert spans(pattern, text) == re_spans(pattern, text), (pattern, text)
    assert spans("a*", "abcab") == [(0, 1), (1, 1), (2, 2), (3, 4), (4, 4), (5, 5)]


def test_the_empty_pattern_matches_between_every_character_and_past_the_end():
    assert spans("", "abc") == [(0, 0), (1, 1), (2, 2), (3, 3)] == re_spans("", "abc")
    assert spans("", "") == [(0, 0)] == re_spans("", "")
    assert irgx.findall("", "abc") == ["", "", "", ""]


def test_lookahead_under_pcre_is_zero_width_and_follows_the_same_rules():
    assert spans("(?=foo)", "foo foo", pcre=True) == [(0, 0), (4, 4)]
    assert spans("(?=x)", "foo", pcre=True) == []
    # A lookahead is not in the linear grammar at all, so without pcre=True it
    # is a refusal rather than a quiet non-match.
    with pytest.raises(irgx.error):
        irgx.compile("(?=foo)")


# ── the sequence is the engine's, not a loop's ────────────────────────────


def _naive_walk(pattern: str, text: str) -> list[tuple[int, int]]:
    """The wrong implementation: advance a cursor over ``irgx_captures``.

    Written out so the divergence below is demonstrated rather than asserted.
    This is the shape a binding falls into when it wants a `find(from)` cursor
    the C ABI deliberately does not offer.
    """
    compiled = Compiled(pattern.encode(), 0)
    data = text.encode()
    out = (_abi.Span * 1)()
    written = ctypes.c_size_t()
    found: list[tuple[int, int]] = []
    at = 0
    while at <= len(data):
        status = _abi.lib.irgx_captures(
            compiled.ptr, data, len(data), at, out, 1, ctypes.byref(written)
        )
        if status != _abi.MATCH:
            break
        start, end = out[0].start, out[0].end
        found.append((start, end))
        at = end + 1 if end == start else end
    return found


def test_a_hand_rolled_cursor_over_captures_now_agrees_with_find_all():
    # This test used to assert a DISAGREEMENT: the hand-rolled loop produced
    # `re`'s sequence while find_all produced the CLI's, so the two could be
    # told apart. Now that the ABI runs the library walk, both are `re`'s and
    # the loop is merely the slow way to get there - one FFI call per match
    # against one for the whole text, and a capture buffer allocated each time.
    #
    # Kept, and inverted, because the disagreement is what a future change to
    # either side would bring back. An engine that resumed differently, or a
    # binding that reimplemented finditer over `captures` and got the zero-width
    # step wrong, both show up right here.
    for pattern, text in [("a*", "abc"), (r"\b", "hi yo"), ("", "ab"), ("a?", "bab")]:
        assert _naive_walk(pattern, text) == spans(pattern, text) == re_spans(pattern, text), (
            pattern,
            text,
        )


def test_word_filtering_is_applied_by_the_engine_not_after_the_fact():
    # `concatenate` contains `cat`; a binding that filtered find_all's output
    # itself would have to re-derive where the search resumes after a rejected
    # span. The engine does it, and the resumption is visible here: the match
    # inside `concatenate` is skipped without swallowing the standalone one.
    assert spans("cat", "concatenate cat cats cat", word=True) == [(12, 15), (21, 24)]
    assert spans("cat", "concatenate cat cats cat") == [(3, 6), (12, 15), (16, 19), (21, 24)]


def test_a_text_with_more_matches_than_the_first_window_still_reports_all_of_them():
    # More matches than the first span window holds, so the retry path runs. A
    # binding that silently kept the first window would report 4096 here.
    text = "a" * 20_000
    assert len(spans("a", text)) == 20_000
    assert spans("a", text)[-1] == (19_999, 20_000)


def test_find_all_reports_the_count_the_text_has_not_the_count_that_fit():
    # The contract a short window is sized from. A saturating count made "did I
    # get everything?" undecidable - `written == cap` was equally a full window
    # and an exact fit - which is what cost this binding a grow-and-rescan loop.
    compiled = Compiled(b"a", 0)
    text = b"a" * 20
    out = (_abi.Span * 2)()
    written = ctypes.c_size_t()
    status = _abi.lib.irgx_find_all(compiled.ptr, text, len(text), out, 2, ctypes.byref(written))
    assert status == _abi.MATCH
    assert written.value == 20, "the text holds twenty, whatever the window holds"
    # At most `cap` spans are written, and they are the first ones.
    assert [(out[i].start, out[i].end) for i in range(2)] == [(0, 1), (1, 2)]


def test_asking_only_how_many_matches_there_are_costs_no_span_buffer():
    # cap 0 with a NULL out is the cheap counting question the true count makes
    # possible; before it, a count meant materializing every span.
    compiled = Compiled(rb"\w+", 0)
    text = b"one two three four"
    written = ctypes.c_size_t()
    _abi.lib.irgx_find_all(compiled.ptr, text, len(text), None, 0, ctypes.byref(written))
    assert written.value == 4


def test_a_short_window_is_resized_once_and_answers_completely(monkeypatch):
    # The count the engine reports IS the size of the retry, so a text with any
    # number of matches costs two searches at most. The doubling schedule this
    # replaced paid a whole rescan per rung: five passes over the text below.
    calls = 0
    # The walk goes through the WINDOWED verb, because `pos`/`endpos` need its
    # `from` and the whole-text case is that verb with an inert bound. Counting
    # `irgx_find_all` here would count zero and pass for the wrong reason.
    real = _abi.lib.irgx_find_all_in

    def counted(*args):
        nonlocal calls
        calls += 1
        return real(*args)

    monkeypatch.setattr(_abi.lib, "irgx_find_all_in", counted)
    monkeypatch.setattr("irgx._pattern._FIRST_WINDOW", 4)

    text = "a" * 5_000
    assert len(spans("a", text)) == 5_000
    assert calls == 2


# The same sequence is also checked against the exact face's `--json`, the
# authority the header names for it — in that face's own suite, since that is
# where the tool being compared against is built (`tests/test_span_parity.py`).


# ── the buffer is one unit, and every verb has to say so ──────────────────


ANCHOR_PATTERNS = ["^a", r"\Aa", "c$", r"c\z", "^abc$", r"\Aabc\z", "b$", "abc", "a*"]
ANCHOR_TEXTS = ["\nabc", "abc\n", "x\nabc\ny", "ab\ncd", "abc", ""]


@pytest.mark.parametrize("pattern", ANCHOR_PATTERNS)
@pytest.mark.parametrize("text", ANCHOR_TEXTS)
def test_is_match_and_the_span_sequence_answer_about_the_same_unit(pattern, text):
    # `is_match` is the cheap verb and it used to reach a different kernel - one
    # that splits a buffer into lines first, making `^` and `$` per-line - so it
    # and `search` disagreed on seven of these rows. There is no corpus behind
    # this plane, so the buffer IS the unit and both must read it that way.
    compiled = irgx.compile(pattern)
    assert compiled.is_match(text) == (compiled.search(text) is not None)


def test_an_interior_newline_is_an_ordinary_byte():
    # The discriminating half: an engine reading per-line would match all four.
    assert irgx.compile("^a").search("\nabc") is None
    assert irgx.compile("c$").search("abc\n") is None
    assert irgx.compile("^abc$").search("x\nabc\ny") is None
    assert irgx.compile("b$").search("ab\ncd") is None
    # And the anchors do still fire, so a dead-anchor engine fails here.
    assert irgx.compile("^a").search("ab\ncd").span() == (0, 1)
    assert irgx.compile("d$").search("ab\ncd").span() == (4, 5)
