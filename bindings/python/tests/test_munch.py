"""What a lexer slate must answer: the longest reading at the cursor, and whose.

There is no ``re`` counterpart to a munch, but there is an ``re`` counterpart to
the *question*: ``Pattern.fullmatch(text, at, end)`` asks whether one terminal
spans exactly ``[at, end)``, so sweeping ``end`` gives the furthest that terminal
can reach from the cursor, and the maximum over the terminals is the maximal
munch by definition. Slow and obviously correct, which is what an oracle is for.

That oracle is exact only for terminals that assert nothing, because ``endpos``
moves ``$`` where a munch's ceiling does not - so the corpus here is
assertion-free on purpose and the anchor cases are their own tests below.
"""

from __future__ import annotations

import re

import irgx
import pytest

#: Assertion-free terminals, in the shapes a real lexer has: a keyword that is
#: also an identifier (the tie), two overlapping numeric readings (the longest),
#: a nullable terminal (the empty-token hazard), and a non-ASCII literal (the
#: offset domains).
TERMINALS = ("if", "[a-z]+", "[0-9]+", "[0-9]+[.][0-9]+", r"\s+", "x*", "héllo", "==", "=")

TEXTS = (
    "",
    "if",
    "iffy",
    "if x",
    "42",
    "3.14",
    "3.",
    "a==b",
    "a=b",
    "héllo wörld",
    "héllo",
    "\t\n ",
    "qqq",
)


def munch_at(terminals, text, at):
    """The maximal munch at ``at``, computed with ``re`` and no cleverness.

    Returns ``(length, winners)`` or ``None`` when nothing accepts here.
    """
    reach = {}
    for i, terminal in enumerate(terminals):
        rx = re.compile(terminal)
        ends = [end for end in range(at, len(text) + 1) if rx.fullmatch(text, at, end)]
        if ends:
            reach[i] = max(ends)
    if not reach:
        return None
    best = max(reach.values())
    return best - at, tuple(sorted(i for i, end in reach.items() if end == best))


@pytest.fixture(scope="module")
def slate():
    return irgx.compile_munch(TERMINALS)


class TestAgainstTheOracle:
    @pytest.mark.parametrize("text", TEXTS)
    def test_every_cursor_of_every_text_reads_as_re_reads_it(self, slate, text):
        # Every position including `len(text)`, which asks the only question
        # left at the end of the input: does anything accept the empty string.
        scan = slate.over(text)
        for at in range(len(text) + 1):
            token = scan.token(at)
            expected = munch_at(TERMINALS, text, at)
            if expected is None:
                assert token is None, f"{text!r} at {at}"
            else:
                assert token is not None, f"{text!r} at {at} should have matched"
                assert (token.length, token.patterns) == expected, f"{text!r} at {at}"

    def test_the_tie_is_reported_whole_rather_than_resolved(self, slate):
        # `if` is the keyword AND an identifier, and both reach length 2. Which
        # one a lexer wants is its own business - precedence by declaration
        # order, usually - so the engine names both instead of inventing a
        # winner. A single answer here would make keyword recognition impossible.
        token = slate.token("if")
        assert token.length == 2
        assert token.patterns == (0, 1)

    def test_a_terminal_that_reaches_further_wins_outright(self, slate):
        # The whole point of maximal munch: `==` beats `=`, and `3.14` beats the
        # `[0-9]+` that would otherwise stop at the dot.
        assert slate.token("==").patterns == (7,)
        assert slate.token("3.14") == (4, (3,))


class TestTheCursor:
    def test_a_scan_encodes_once_and_answers_in_the_callers_units(self, slate):
        # The reason `over()` exists: a lexer asks one text a thousand
        # questions, and a `str` re-encoded per call is quadratic. It must also
        # answer in characters, not bytes - `héllo` is 5 characters and 6 bytes,
        # and a caller slicing their own str with a byte length gets nonsense.
        scan = slate.over("héllo wörld")
        assert scan.token(0) == (5, (6,))
        assert scan.text[0:5] == "héllo"
        # And a cursor stated in characters lands on the right byte, which this
        # text is built to catch: character 6 is `w` but byte 6 is the space
        # before it, so a scan that forgot to translate would report the
        # whitespace terminal here instead of the identifier one.
        assert scan.token(6) == (1, (1,))
        assert scan.text[6:7] == "w"
        assert scan.token(5) == (1, (4,))

    def test_the_one_shot_verb_agrees_with_the_scan_it_wraps(self, slate):
        for text in TEXTS:
            for at in range(len(text) + 1):
                assert slate.token(text, at) == slate.over(text).token(at)

    def test_a_cursor_past_the_end_is_an_error_rather_than_a_miss(self, slate):
        scan = slate.over("if")
        with pytest.raises(IndexError):
            scan.token(3)
        with pytest.raises(IndexError):
            scan.token(-1)
        # The end itself is legal, and answers about the empty string.
        assert scan.token(2) == (0, (5,))

    def test_a_scan_holds_the_text_it_was_given(self, slate):
        scan = slate.over("héllo")
        assert scan.text == "héllo"
        assert len(scan) == 5
        assert repr(scan) == "<irgx.Scan over 'héllo'>"


class TestPermission:
    def test_allow_restricts_one_call_and_not_the_slate(self, slate):
        # Context-sensitive lexing without a compile per context: the permission
        # set is what changes between "expecting an operand" and "expecting an
        # operator", and it must not leak into the next call.
        assert slate.token("if").patterns == (0, 1)
        assert slate.token("if", allow=[1]) == (2, (1,))
        assert slate.token("if").patterns == (0, 1)

    def test_permitting_nothing_matches_nothing(self, slate):
        assert slate.token("if", allow=[]) is None

    def test_a_restriction_changes_the_winner_and_not_just_the_report(self, slate):
        # Forbidding `==` does not leave a zero-length `=`-shaped hole: the
        # scan is re-run under the restriction, so `=` wins at length 1.
        assert slate.token("==") == (2, (7,))
        assert slate.token("==", allow=[8]) == (1, (8,))

    def test_an_allow_list_may_be_any_iterable(self, slate):
        assert slate.token("if", allow=iter([1])) == (2, (1,))
        assert slate.token("if", allow={1}) == (2, (1,))


class TestShortest:
    def test_shortest_is_the_other_reading_of_the_same_cursor(self, slate):
        # Not a different search: the same anchored scan, reported at its first
        # accepting length instead of its last. What a delimiter wants, so it
        # does not swallow its own terminator.
        assert slate.token("iffy") == (4, (1,))
        assert slate.token("iffy", shortest=True) == (1, (1,))

    def test_shortest_skips_the_empty_reading(self, slate):
        # `x*` accepts the empty string everywhere, so a shortest that counted
        # it would answer 0 at every cursor and no lexer could use the verb.
        assert slate.token("xy", shortest=True) == (1, (1, 5))

    def test_shortest_and_longest_agree_when_only_one_length_accepts(self, slate):
        # `\t` is reachable by exactly one terminal at exactly one length, so
        # the two readings of the cursor coincide - which is the case a lexer
        # spends most of its time in, and where the knob must cost nothing.
        assert slate.token("\t") == slate.token("\t", shortest=True) == (1, (4,))


class TestPartialRefusal:
    def test_a_slate_seats_what_it_can_and_says_what_it_could_not(self):
        # The policy that makes this a separate plane from `compile_set`: a
        # hundred and fifty terminals where one is outside the linear grammar is
        # a working lexer, and erroring would make the fallback the common path.
        slate = irgx.compile_munch(["ok", r"(a)\1", r"\Ab", r"x\z"])
        assert len(slate) == 1
        assert len(slate.patterns) == 4
        assert slate.declined == (
            irgx.Refusal(1, irgx.Why.SYNTAX),
            irgx.Refusal(2, irgx.Why.BUFFER_ANCHOR),
            irgx.Refusal(3, irgx.Why.BUFFER_ANCHOR),
        )
        # And the terminal that WAS seated still lexes, which is the point.
        assert slate.token("ok") == (2, (0,))

    def test_a_buffer_anchor_is_a_wall_and_a_state_bound_is_a_budget(self):
        # Two reasons a caller acts on differently: `STATES` says a bigger build
        # would take this terminal, `BUFFER_ANCHOR` that none ever will. They
        # were one value until a test asked why `\Ab` reported a size problem.
        slate = irgx.compile_munch(["a", r"\Ab"])
        assert slate.declined == (irgx.Refusal(1, irgx.Why.BUFFER_ANCHOR),)
        assert irgx.Why.BUFFER_ANCHOR != irgx.Why.STATES

    def test_a_word_boundary_has_no_left_context_at_a_cursor(self):
        # A scan begins where you point it, so there is no byte before the
        # cursor for `\b` to resolve against.
        slate = irgx.compile_munch(["a", r"\bword"])
        assert slate.declined == (irgx.Refusal(1, irgx.Why.WORD_CONTEXT),)

    def test_a_slate_that_could_seat_nothing_raises(self):
        # No handle exists to read reasons from, so this is the one case that
        # cannot be a partial success.
        with pytest.raises(irgx.UnsupportedPattern):
            irgx.compile_munch([r"(a)\1"])

    def test_declined_is_empty_in_the_ordinary_case(self, slate):
        assert slate.declined == ()
        assert len(slate) == len(slate.patterns)

    def test_an_unknown_reason_from_a_newer_engine_stays_an_int(self):
        # Forward compatibility as a decision: a reason this build has never
        # heard of is something to log, not something to crash on.
        from irgx._munch import _why

        assert _why(irgx.Why.STATES) is irgx.Why.STATES
        assert _why(99) == 99
        assert not isinstance(_why(99), irgx.Why)


class TestTheEmptySlate:
    def test_a_slate_of_no_terminals_is_a_working_lexer_that_matches_nothing(self):
        slate = irgx.compile_munch([])
        assert len(slate) == 0
        assert slate.declined == ()
        assert slate.token("anything") is None
        assert slate.over("anything").token(3) is None


class TestTheTextDomain:
    def test_a_bytes_slate_lexes_bytes_and_counts_bytes(self):
        slate = irgx.compile_munch([rb"\w+", rb"\s+"])
        assert slate.is_bytes
        scan = slate.over("héllo".encode())
        # Six bytes, and reported as six: a bytes caller's units ARE bytes.
        assert scan.token(0).length == 6
        assert scan.text[0:6] == "héllo".encode()

    def test_the_str_bytes_discipline_is_the_same_as_every_other_plane(self, slate):
        with pytest.raises(TypeError):
            slate.token(b"if")
        with pytest.raises(TypeError):
            irgx.compile_munch([rb"\w+"]).token("if")
        with pytest.raises(TypeError):
            irgx.compile_munch(["a", b"b"])
        with pytest.raises(TypeError):
            slate.token(42)
        with pytest.raises(TypeError):
            irgx.compile_munch([42])


class TestFlags:
    def test_flags_are_the_slates_and_not_a_terminals(self):
        # A munch determinizes every terminal together, so there is nowhere to
        # put "terminal 3 is case-insensitive" - the flag is the slate's.
        folded = irgx.compile_munch(["if", "[a-z]+"], ignore_case=True)
        assert folded.token("IF") == (2, (0, 1))
        assert irgx.compile_munch(["if"]).token("IF") is None

    def test_multiline_is_refused_rather_than_ignored(self):
        # It asks for the line-anchor reading, which an anchored scan cannot
        # observe either way. Answering as if it meant something would be worse.
        with pytest.raises(ValueError, match="multiline"):
            irgx.compile_munch(["a"], multiline=True)

    def test_dotall_is_carried_because_it_is_observable(self):
        assert irgx.compile_munch(["."]).token("\n") is None
        assert irgx.compile_munch(["."], dotall=True).token("\n") == (1, (0,))

    def test_an_unknown_flag_fails_loudly(self):
        with pytest.raises(TypeError):
            irgx.compile_munch(["a"], ignorecase=True)


class TestIdentity:
    def test_a_slate_reports_what_it_was_built_from(self, slate):
        assert slate.patterns == TERMINALS
        assert not slate.is_bytes
        assert isinstance(slate.flags, int)

    def test_len_is_the_seated_count_and_not_the_compile_list(self):
        # The number that matters, because a declined terminal can never win and
        # so can never be named by a token - it is also the exact cap at which
        # the winner buffer can never come up short.
        slate = irgx.compile_munch(["a", r"(a)\1", "b"])
        assert len(slate) == 2
        assert len(slate.patterns) == 3

    def test_repr_round_trips_through_the_verb_that_makes_one(self, slate):
        assert repr(irgx.compile_munch(["a"])) == "irgx.compile_munch(['a'])"
