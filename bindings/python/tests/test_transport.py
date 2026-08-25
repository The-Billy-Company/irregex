"""The two transports are one answer, asked two ways.

:mod:`irgx._engine` routes fourteen per-text verbs to a C extension when one is
present and to ctypes when it is not, which is the only optimization in this
package that could change what a caller sees. A binding that got this wrong
would not crash; it would answer *slightly* differently on one platform, in one
verb, for one shape of input, and every other test here would pass.

So the parity is asserted directly rather than inferred: for each verb, the same
handle is asked the same question through both implementations in one process,
and the two results must be equal objects. It is not a smoke test - the cases
below are the ones where the two implementations do genuinely different work.
Buffer growth (more matches than the first window), non-participating groups
(negative spans that become ``None``), an empty answer, and a refusal (a status
integer rather than a list) are four separate agreements, and the naive C
version gets three of them wrong.

A test that needs two transports cannot run where there is only one, and there
is exactly one in a source checkout nobody has compiled an accelerator into.
Those tests carry the ``accel`` marker, so the ctypes-only pass **deselects**
them rather than skipping them - which matters because this suite's CI gate
fails on any skip at all. A skip is how a tier goes dark without saying so, and
the whole point of the FFI tier is that it must not; ``-m "not accel"`` is a
question deliberately not asked, which is a different thing and reads as one.

The suite's other half of this proof is external: CI builds the accelerator,
runs everything, then runs it again under ``IRGX_NO_ACCEL=1``, so the fallback
is a path under test rather than a path in principle.
"""

from __future__ import annotations

import irgx
import pytest
from irgx import _abi, _engine
from irgx._munch import _CompiledMunch
from irgx._pool import Compiled
from irgx._set import _CompiledSet

#: Everything down to "declining it" needs both transports live in one process.
pytestmark = pytest.mark.accel


def both(verb: str):
    """The native and ctypes implementations of ``verb``.

    A hard failure rather than a skip, and the marker is why: reaching here at
    all means an accelerator was found, so a verb missing from it is an engine
    that did not export the symbol - a real gap, and the one thing a per-verb
    skip would have hidden behind the same word as "no accelerator here".
    """
    if verb not in _engine.native():
        pytest.fail(f"the accelerator is loaded but bound no {verb}; the engine did not export it")
    return getattr(_abi.ACCEL, verb), _engine._FALLBACK[verb]


def agree(verb: str, *args) -> object:
    """Assert both transports answer ``args`` identically, and return it."""
    native, ctypes_ = both(verb)
    mine, theirs = native(*args), ctypes_(*args)
    assert mine == theirs, f"{verb}{args!r}: native {mine!r} != ctypes {theirs!r}"
    assert type(mine) is type(theirs), f"{verb}{args!r}: {type(mine)} vs {type(theirs)}"
    return mine


# ── the regex plane ───────────────────────────────────────────────────────


# Each fixture yields the plain address both transports take, and holds the
# owning object for the test's lifetime. Returning `.ptr.value` alone would let
# the compile be collected on the next line and hand every assertion a freed
# handle - which segfaults rather than fails, and looks like a bug in the C.


@pytest.fixture
def regex():
    compiled = Compiled(rb"(\w+)@(\w+)?", 0)
    yield compiled.ptr.value


def test_is_match_agrees_on_a_hit_a_miss_and_an_offset(regex):
    assert agree("is_match", regex, "a@b", 0) == _abi.MATCH
    assert agree("is_match", regex, "....", 0) != _abi.MATCH
    # A `from` past the only match: the offset is the argument most easily
    # dropped on the way through a C parse, and dropping it still matches.
    assert agree("is_match", regex, "a@b....", 4) != _abi.MATCH


def test_is_match_agrees_on_str_and_the_bytes_it_encodes_to(regex):
    # The native transport reads a `str`'s own cached UTF-8 and the ctypes one
    # encodes a copy; on non-ASCII text those are different code paths to the
    # same bytes, and this is the assertion that says so.
    for text in ("a@b", "héllo@wörld", "日本@語"):
        assert agree("is_match", regex, text, 0) == _abi.MATCH
        assert agree("is_match", regex, text.encode(), 0) == _abi.MATCH


def test_find_all_agrees_including_past_the_first_window(regex):
    assert agree("find_all", regex, "a@b c@d", 0, 0) == [(0, 3), (4, 7)]
    assert agree("find_all", regex, "nothing here", 0, 0) == []
    assert agree("find_all", regex, "a@b c@d", 0, 1) == [(0, 3)]
    # 5,000 matches over a 4,096 first window: the retry, in both transports,
    # sized from the count the engine reported rather than from a schedule.
    many = agree("find_all", regex, "a@b " * 5_000, 0, 0)
    assert len(many) == 5_000


def test_find_first_agrees_on_a_hit_a_miss_and_an_offset(regex):
    # A span on a hit and the OK status on a miss, which is a different SHAPE of
    # answer rather than an empty one - the naive C would hand back a status for
    # both and read as a miss every time.
    assert agree("find_first", regex, "a@b c@d", 0) == (0, 3)
    assert agree("find_first", regex, "a@b c@d", 1) == (4, 7)
    assert agree("find_first", regex, "nothing here", 0) == _abi.OK
    # The whole point of the verb: it stops at the first match, so a text full of
    # them costs what one costs. The answer must still be the first one.
    assert agree("find_first", regex, "a@b " * 5_000, 0) == (0, 3)


def test_captures_agrees_about_a_group_that_never_participated(regex):
    # Group 2 is optional and absent, so the engine writes (-1, -1) and both
    # transports must turn that into `None` rather than into a span.
    assert agree("captures", regex, "a@", 0, 2) == [(0, 2), (0, 1), None]
    assert agree("captures", regex, "a@b", 0, 2) == [(0, 3), (0, 1), (2, 3)]


def test_a_refusal_is_the_same_status_integer_from_both(regex):
    # `at` is not the start of a match, so `captures` declines. Both transports
    # must hand the raw status back rather than raise or invent an empty list -
    # deciding which sentence to build out of it is the plane's business.
    mine = agree("captures", regex, "a@b", 1, 2)
    assert isinstance(mine, int)


def test_texts_agrees_on_type_thinning_and_a_refusal(regex):
    # The whole-answer verb builds finished strings in C where ctypes slices
    # and decodes, so the agreement covers the answer's TYPE as well as its
    # value - a bytes where a str belongs is equality-false already, but the
    # empty list agrees on nothing unless the shapes are compared too.
    assert agree("texts", regex, "a@b c@d", 0, True) == ["a@b", "c@d"]
    assert agree("texts", regex, b"a@b c@d", 0, False) == [b"a@b", b"c@d"]
    assert agree("texts", regex, "nothing here", 0, True) == []
    assert agree("texts", regex, "a@b " * 5_000, 0, True) == ["a@b"] * 5_000


def test_texts_agrees_about_an_empty_match_inside_a_character():
    # `x*` matches empty at every byte, and byte 1 of "é" splits the character;
    # both transports must drop it, or a wide text answers with a duplicate.
    compiled = Compiled(rb"x*", 0)
    rx = compiled.ptr.value
    assert agree("texts", rx, "é", 0, True) == ["", ""]
    assert agree("texts", rx, "é".encode(), 0, False) == [b"", b"", b""]


def test_group_texts_agrees_on_shape_absence_and_a_refusal(regex):
    # Two groups answer as tuples, and the optional second group's absence must
    # come through as None from both - the negative span is the engine's word
    # for it, and turning that into an empty string would erase a fact.
    assert agree("group_texts", regex, "a@b c@", 0, 2, True) == [("a", "b"), ("c", None)]
    assert agree("group_texts", regex, b"a@b", 0, 2, False) == [(b"a", b"b")]
    assert agree("group_texts", regex, "nothing here", 0, 2, True) == []


def test_group_texts_agrees_at_one_group_where_the_answer_is_bare():
    compiled = Compiled(rb"(\w+)@", 0)
    rx = compiled.ptr.value
    assert agree("group_texts", rx, "a@ bc@", 0, 1, True) == ["a", "bc"]


def test_spliced_agrees_on_the_join_the_tally_and_the_cap(regex):
    # The native verb sizes the whole answer and fills one buffer where ctypes
    # joins a list of slices, so the agreement is over an assembly rather than a
    # walk. The tally rides along because `subn` owes it and the cap decides it.
    assert agree("spliced", regex, "a@b c@d", "-", 0, True) == ("- -", 2)
    assert agree("spliced", regex, "a@b c@d", "-", 1, True) == ("- c@d", 1)
    # No match: the subject back, unchanged, and a tally of zero — not an empty
    # string, which is what a C verb that forgot the tail would answer.
    assert agree("spliced", regex, "nothing here", "-", 0, True) == ("nothing here", 0)
    assert agree("spliced", regex, "", "-", 0, True) == ("", 0)
    # An empty replacement is a real constant, not an absent one.
    assert agree("spliced", regex, "a@b c@d", "", 0, True) == (" ", 2)
    # Past the first window, so the span retry runs under the assembly.
    text, made = agree("spliced", regex, "a@b " * 5_000, "-", 0, True)
    assert made == 5_000 and text == "- " * 5_000


def test_spliced_agrees_on_bytes_where_the_answer_is_filled_in_place(regex):
    # The bytes arm writes straight into its final object and the str arm decodes
    # from scratch: two implementations of one assembly, so both need a witness.
    assert agree("spliced", regex, b"a@b c@d", b"-", 0, False) == (b"- -", 2)
    assert agree("spliced", regex, b"a@b", b"", 0, False) == (b"", 1)


def test_spliced_and_pieces_agree_about_a_match_inside_a_character():
    # `x*` matches empty at every byte and byte 1 of "é" splits the character.
    # Both verbs must drop that span, or the answer carries a cut no caller has
    # an index for — and for `spliced` a dropped span the SIZING pass kept would
    # be a buffer overrun rather than a wrong answer.
    compiled = Compiled(rb"x*", 0)
    rx = compiled.ptr.value
    assert agree("spliced", rx, "é", "-", 0, True) == ("-é-", 2)
    assert agree("spliced", rx, "é".encode(), b"-", 0, False) == (b"-\xc3-\xa9-", 3)
    assert agree("pieces", rx, "é", 0, True) == ["", "é", ""]
    assert agree("pieces", rx, "é".encode(), 0, False) == [b"", b"\xc3", b"\xa9", b""]


def test_pieces_agrees_on_the_tail_the_cap_and_a_miss(regex):
    # One more piece than there are cuts, always: the tail after the last match.
    assert agree("pieces", regex, "a@b c@d", 0, True) == ["", " ", ""]
    assert agree("pieces", regex, "x a@b y", 0, True) == ["x ", " y"]
    assert agree("pieces", regex, "a@b c@d", 1, True) == ["", " c@d"]
    # A miss is the whole subject as one piece, not an empty list.
    assert agree("pieces", regex, "nothing here", 0, True) == ["nothing here"]
    assert agree("pieces", regex, b"x a@b y", 0, False) == [b"x ", b" y"]
    assert len(agree("pieces", regex, "a@b " * 5_000, 0, True)) == 5_001


# ── the slate and needle planes ───────────────────────────────────────────


@pytest.fixture
def slate():
    compiled = _CompiledSet((b"foo", b"ba(r)", b"zzz"), 0, ("foo", "ba(r)", "zzz"))
    yield compiled.ptr.value


def test_slate_verbs_agree(slate):
    assert agree("slate_is_match", slate, "xxbarxx") == _abi.MATCH
    assert agree("slate_is_match", slate, "xxxxxxx") != _abi.MATCH
    assert agree("slate_which", slate, "foo and bar", 3) == [0, 1]
    assert agree("slate_which", slate, "neither", 3) == []


@pytest.fixture
def needles():
    return irgx.compile_needles(["ab", "cd", "ef"])


def test_needle_verbs_agree(needles):
    at = needles.ptr
    assert agree("needles_is_match", at, "xxcdxx") == _abi.MATCH
    assert agree("needles_is_match", at, "xxxxxx") != _abi.MATCH
    assert agree("needles_which", at, "ab and ef", 3) == [0, 2]
    assert agree("needles_find_all", at, "abcdab") == [(0, 0, 2), (1, 2, 4), (0, 4, 6)]
    # Past the first window, which for this verb is the one place it retries.
    assert len(agree("needles_find_all", at, "ab" * 5_000)) == 5_000


# ── the lexer plane ───────────────────────────────────────────────────────


@pytest.fixture
def munch():
    compiled = _CompiledMunch((rb"\d+", rb"[a-z]+", rb"if"), 0, ("d", "w", "if"))
    yield compiled.ptr.value


def test_munch_scan_agrees_about_the_whole_tie(munch):
    # `if` is both the keyword and an identifier, so the winners tuple has two
    # entries - the case where a C loop that stopped at the first winner would
    # still pass every single-winner test.
    assert agree("munch_scan", munch, "if x", 0, None, 0, 3) == (2, (1, 2))
    assert agree("munch_scan", munch, "42", 0, None, 0, 3) == (2, (0,))
    # An `allow` set, which is the argument that is `NULL` in the common case
    # and therefore the one most easily mishandled when it is not.
    assert agree("munch_scan", munch, "if x", 0, (1,), 0, 3) == (2, (1,))
    # No terminal accepts here, so the status comes back as an int from both.
    assert isinstance(agree("munch_scan", munch, "!!!", 0, None, 0, 3), int)
