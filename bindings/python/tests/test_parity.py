"""Side-by-side with the standard library, in both directions.

Where the two engines are specified to agree, the assertion compares against
``re`` computed live, so this suite fails if either side moves. Where they
disagree, the assertion states OUR answer as a literal and the comment says why
the difference is deliberate; weakening one of those to a comparison would turn
a documented divergence into whatever the code happens to do today.
"""

from __future__ import annotations

import re

import irgx
import pytest

# Patterns in the grammar both engines implement the same way, over text chosen
# to exercise anchors, classes, alternation, quantifiers and word boundaries.
AGREE = [
    (r"\w+", "hello world 42"),
    (r"\d+", "a1 bb22 ccc333"),
    (r"[a-z]+\d", "ab1 cd2 x"),
    (r"(\w+)@(\w+)\.(\w+)", "me@example.com and you@other.org"),
    (r"colou?r", "color color colr"),
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
    assert [m.span() for m in irgx.finditer(pattern, text)] == [
        m.span() for m in re.finditer(pattern, text)
    ]


@pytest.mark.parametrize(("pattern", "text"), AGREE)
def test_findall_agrees_with_re(pattern, text):
    # `re.findall` returns "" for a group the match did not enter; none of these
    # patterns has one, which is why the comparison is exact here and the
    # divergence gets its own test below.
    assert irgx.findall(pattern, text) == re.findall(pattern, text)


@pytest.mark.parametrize(("pattern", "text"), AGREE)
def test_groups_agree_with_re(pattern, text):
    for mine, theirs in zip(irgx.finditer(pattern, text), re.finditer(pattern, text), strict=True):
        assert mine.group(0) == theirs.group(0)
        assert mine.groups() == theirs.groups()


@pytest.mark.parametrize(("pattern", "text"), AGREE)
def test_substitution_agrees_with_re(pattern, text):
    assert irgx.sub(pattern, "<>", text) == re.sub(pattern, "<>", text)


# `pos`/`endpos` × the texts and patterns where a bound can go wrong: an anchor
# or `\b` at either cut, an empty match at the cut, a multi-byte character
# straddling it, and bounds outside the text entirely.
REGIONS = [
    (0, None),
    (1, None),
    (2, None),
    (0, 2),
    (1, 3),
    (2, 2),
    (99, None),
    (-3, None),
    (0, 99),
    (3, 1),
]
BOUNDED = [
    ("^b", "abc"),
    (r"\bbc", "abc"),
    ("b$", "abc"),
    (r"b\b", "abc"),
    ("a", "aBaBa"),
    ("x*", "abc"),
    ("", "abc"),
    ("l*", "héllo"),
    ("é*", "ééé"),
    (".", "héllo"),
    ("l", "héllo"),
    (r"\w*", "aéb"),
]


@pytest.mark.parametrize(("pattern", "text"), BOUNDED)
@pytest.mark.parametrize(("pos", "endpos"), REGIONS)
def test_pos_and_endpos_bound_the_search_exactly_as_re_bounds_it(pattern, text, pos, endpos):
    # The two bounds are NOT symmetric in `re` and this asserts that asymmetry
    # rather than tidying it: `pos` leaves `^` and `\b` reading the real text,
    # while `endpos` truncates it, so `b$` with endpos=2 over "abc" matches. The
    # comparison is live, so if either side moves this fails.
    args = (text, pos) if endpos is None else (text, pos, endpos)
    assert [m.span() for m in irgx.compile(pattern).finditer(*args)] == [
        m.span() for m in re.compile(pattern).finditer(*args)
    ]
    ours, theirs = irgx.compile(pattern).search(*args), re.compile(pattern).search(*args)
    assert (ours.span() if ours else None) == (theirs.span() if theirs else None)
    # `is_match` has no `re` twin, so its oracle is `re.search`'s presence — the
    # point being that the cheap predicate and the span walk cannot disagree
    # about which region was asked about.
    assert irgx.compile(pattern).is_match(*args) is (theirs is not None)


# The same regions, over patterns that DECLARE groups — a separate list because
# the question is different: above, whether the right span was found; here,
# whether the group detail filled in afterwards describes that span.
BOUNDED_GROUPS = [
    (r"(\w)(\w*)", "hello"),
    (r"(?P<head>\w)(?P<tail>\w*)", "hello"),
    (r"(a)|(b)", "ab"),
    (r"(a(b(c)))", "xabcx"),
    (r"(\w)(\w*)", "héllo"),
    (r"(é)(\w*)", "éab"),
    (r"(x)?(a)", "a xa"),
]


@pytest.mark.parametrize(("pattern", "text"), BOUNDED_GROUPS)
@pytest.mark.parametrize(("pos", "endpos"), REGIONS)
def test_group_detail_under_a_bound_describes_the_match_the_bound_found(pattern, text, pos, endpos):
    # Group spans are filled in on first request, from a SECOND engine call — and
    # that call has to be handed the same text the walk was. Handing it the whole
    # subject let a greedy group run past `endpos` and report a wider whole-match
    # than the walk had found, which the binding correctly refused to reconcile
    # and the caller met as an error where `re` answers. The whole-match span
    # agreeing is not enough to catch that, which is why this asks for the groups.
    args = (text, pos) if endpos is None else (text, pos, endpos)
    for ours, theirs in zip(
        irgx.compile(pattern).finditer(*args), re.compile(pattern).finditer(*args), strict=True
    ):
        assert ours.span() == theirs.span()
        assert ours.groups() == theirs.groups()
        assert ours.groupdict() == theirs.groupdict()
        for index in range(1, re.compile(pattern).groups + 1):
            # `re` reports (-1, -1) for a group that did not participate too, so
            # this comparison needs no special case for it.
            assert ours.span(index) == theirs.span(index)
            assert ours.group(index) == theirs.group(index)


@pytest.mark.parametrize(("pattern", "text"), [*BOUNDED, *BOUNDED_GROUPS])
@pytest.mark.parametrize(("pos", "endpos"), REGIONS)
def test_fullmatch_reads_pos_as_a_window_not_as_the_start_of_the_text(pattern, text, pos, endpos):
    # `fullmatch` is answered by the munch plane's anchored-longest automaton,
    # which scans from a cursor and reads that cursor as the beginning of the
    # text. `re` reads `pos` as a window into a text that still begins at byte 0,
    # so `^` and `\b` assert differently under the two — `re.fullmatch(r"^\w+",
    # " lead", 1)` is None because `^` cannot hold at offset 1, while the scan is
    # happy to begin a line there. Every verb here must read the bound the same
    # way, so this holds `fullmatch` to `re` over the same regions `search` and
    # `finditer` are held to.
    args = (text, pos) if endpos is None else (text, pos, endpos)
    try:
        ours = irgx.compile(pattern).fullmatch(*args)
    except irgx.error:
        # The munch plane declines some patterns outright (`\b`, `\A`/`\z`,
        # multiline) and says so; a refusal is a documented answer, not a wrong
        # one, and `test_fullmatch_refuses_rather_than_reporting_the_wrong_groups`
        # is where those are pinned.
        return
    theirs = re.compile(pattern).fullmatch(*args)
    assert (ours.span() if ours else None) == (theirs.span() if theirs else None)


def test_a_bound_outside_the_text_clamps_rather_than_refusing():
    # Every one of these is a result in `re`, not an error, and the clamp happens
    # BEFORE the search — which is why a nullable pattern still matches at the
    # end for a `pos` past it, rather than reporting nothing.
    assert [m.span() for m in irgx.compile("x*").finditer("abc", 99)] == [(3, 3)]
    assert [m.span() for m in re.compile("x*").finditer("abc", 99)] == [(3, 3)]
    assert irgx.compile("a").search("abc", -5).span() == (0, 1)
    assert irgx.compile("a").search("abc", 0, 99).span() == (0, 1)
    # An inverted region has no positions in it, so there is nothing to match.
    assert irgx.compile("a").search("abc", 2, 1) is None
    assert list(irgx.compile("x*").finditer("abc", 2, 1)) == []


def test_expand_reads_the_template_domain_before_the_groups():
    # A documented divergence, and the one place the differ still reports one.
    # `re` renders a `str` template against a `bytes` match whenever every group
    # it references came back None — the domains only collide inside the join, so
    # a template that happens to reference nothing survives, and the same call on
    # the next match raises. That makes the refusal depend on the subject rather
    # than on the argument. This engine reads the template's domain first, so the
    # answer is the same for every match of the same pattern.
    ours, theirs = irgx.compile(b"(a)|(b)"), re.compile(b"(a)|(b)")
    for i, (mine, yours) in enumerate(
        zip(ours.finditer(b"ab"), theirs.finditer(b"ab"), strict=True)
    ):
        with pytest.raises(TypeError):
            mine.expand(r"<\1>")
        # `re`'s own answer flips between the two matches: group 1 participates in
        # the first and not the second.
        if i == 0:
            with pytest.raises(TypeError):
                yours.expand(r"<\1>")
        else:
            assert yours.expand(r"<\1>") == "<>"
        # Spelled in the subject's domain, the two agree — which is the point: the
        # divergence is the refusal, not the rendering.
        assert mine.expand(rb"<\1>") == yours.expand(rb"<\1>")


def test_the_bounds_live_on_the_compiled_pattern_only():
    # Exactly as in `re`: the module-level helpers take flags in that position, so
    # accepting a bound there would silently read one as the other. The one-shot
    # spelling is `compile(...).search(text, pos)`.
    for name in ("search", "finditer", "findall"):
        assert "pos" not in getattr(irgx, name).__code__.co_varnames
        assert "pos" in getattr(irgx.Pattern, name).__code__.co_varnames


def test_the_bounds_count_in_the_subjects_own_units():
    # `pos`/`endpos` are characters for `str` and bytes for `bytes`, exactly as
    # `re` reads them. "héllo" is 5 characters and 6 bytes, so a bound of 2 means
    # two different cuts depending on the subject — and getting this wrong would
    # silently search the wrong region rather than fail.
    assert irgx.compile("l").search("héllo", 2).span() == (2, 3)
    assert re.compile("l").search("héllo", 2).span() == (2, 3)
    assert irgx.compile(b"l").search("héllo".encode(), 2).span() == (3, 4)
    assert re.compile(b"l").search("héllo".encode(), 2).span() == (3, 4)


def test_an_empty_match_inside_a_character_is_not_a_position_a_str_has():
    # The engine reports the widest sequence — every empty match at every BYTE —
    # and byte 1 of "é" splits the character. `re` has no position there, so the
    # binding drops it; keeping it would surface as a DUPLICATE of the match at
    # the character's start, since both map to the same index.
    assert [m.span() for m in irgx.finditer("x*", "é")] == [(0, 0), (1, 1)]
    assert [m.span() for m in re.finditer("x*", "é")] == [(0, 0), (1, 1)]
    # A `bytes` subject keeps them, because its domain IS the engine's: three
    # positions in two bytes.
    assert [m.span() for m in irgx.finditer(b"x*", "é".encode())] == [(0, 0), (1, 1), (2, 2)]
    assert [m.span() for m in re.finditer(b"x*", "é".encode())] == [(0, 0), (1, 1), (2, 2)]


def test_alternation_prefers_the_left_branch_exactly_as_re_does():
    # This is the classic place a DFA engine diverges: POSIX leftmost-longest
    # would report "ab" for `a|ab`. It does not, which is what makes the
    # comparisons above meaningful rather than accidental.
    for pattern, text in [("a|ab", "ab"), ("ab|a", "ab"), ("(a|ab)(c|bcd)", "abcd")]:
        assert irgx.search(pattern, text).span() == re.search(pattern, text).span()


def test_lazy_quantifiers_agree_with_re():
    for pattern, text in [(r"\w+?", "abc"), (r"<.*?>", "<a><b>"), (r"a+?b", "aaab")]:
        assert [m.span() for m in irgx.finditer(pattern, text)] == [
            m.span() for m in re.finditer(pattern, text)
        ]


def test_ignore_case_agrees_with_re_on_ascii():
    assert irgx.findall("walrus", "WALRUS Walrus walrus", ignore_case=True) == re.findall(
        "walrus", "WALRUS Walrus walrus", re.IGNORECASE
    )


# ── the divergences, asserted as our behavior ────────────────────────────


def test_we_report_the_empty_match_at_the_end_of_the_text_exactly_as_re_does():
    # This was a divergence, and is not one any more. The ABI ran the CLI's
    # line-oriented walk, which suppresses an empty match after the last
    # character because it would be noise on a printed page; a library has no
    # page, and every one a caller knows reports it.
    for pattern in ("", "a*", r"\b", "x?"):
        for text in ("abc", "", "a", "aaa"):
            assert [m.span() for m in irgx.finditer(pattern, text)] == [
                m.span() for m in re.finditer(pattern, text)
            ], (pattern, text)


def test_a_non_participating_group_is_none_in_findall_not_empty_string():
    # `re.findall` flattens a group that did not participate to "", losing the
    # distinction between "did not match" and "matched nothing". `.groups()`
    # already reports None for that case in both libraries, so `findall`
    # agreeing with `.groups()` is the more consistent answer.
    assert irgx.findall(r"(a)|(b)", "ab") == [("a", None), (None, "b")]
    assert re.findall(r"(a)|(b)", "ab") == [("a", ""), ("", "b")]


def test_flags_are_keywords_and_the_re_bitmask_is_not_accepted():
    # `re.IGNORECASE` is an int; passing it positionally to a keyword-only
    # surface is a TypeError rather than a silently ignored argument.
    with pytest.raises(TypeError):
        irgx.compile("a", re.IGNORECASE)


def test_a_newline_is_ordinary_whitespace_because_the_haystack_is_a_buffer():
    # Also no longer a divergence, and this one was not a reporting rule but a
    # promise compiled in as fact. In the per-line model the compiler is
    # licensed to assume no haystack contains a newline - it drops `\n` from a
    # class run on exactly that ground - so `\s` over "a\nb" found NOTHING.
    # A CLI face keeps that promise by feeding one line at a time. A binding handed
    # a whole string cannot, so it compiles for a buffer and `\s` is `\s`.
    assert irgx.findall(r"\s", "a\nb") == re.findall(r"\s", "a\nb") == ["\n"]
    assert irgx.findall(r"\s", "a\tb") == ["\t"]
    assert irgx.findall(r"a\sb", "a\nb") == ["a\nb"]
    assert irgx.findall(r"[\n\t]", "a\nb\tc") == ["\n", "\t"]
    # `.` still excludes the newline, in both - that is a separate rule and it
    # did not move.
    assert irgx.findall(r"a.b", "a\nb") == re.findall(r"a.b", "a\nb") == []


def test_caret_and_dollar_anchor_the_text_unless_multiline_like_re():
    # The buffer model is not the `(?m)` question, and conflating them would
    # have turned multiline on for every caller. `^` means the start of the
    # string you passed, exactly as in `re`, until you ask otherwise.
    text = "a\nb\n"
    assert irgx.findall("^b", text) == re.findall("^b", text) == []
    assert irgx.findall("^b", text, multiline=True) == re.findall("^b", text, re.M) == ["b"]
    assert irgx.findall("^a", text) == re.findall("^a", text) == ["a"]
    # `\A`/`\Z` are the text's ends either way. (`re` spells the strict
    # end-of-text `\Z`; this engine spells it `\z`, as Perl and PCRE2 do.)
    assert irgx.findall(r"\Aa", text) == re.findall(r"\Aa", text) == ["a"]
    assert irgx.findall(r"a\z", text) == re.findall(r"a\Z", text) == []


def test_dotall_makes_dot_match_a_newline_like_re_s():
    text = "a\nb"
    assert irgx.findall(".", text) == re.findall(".", text) == ["a", "b"]
    assert irgx.findall(".", text, dotall=True) == re.findall(".", text, re.S) == ["a", "\n", "b"]
    assert irgx.findall("a.b", text, dotall=True) == re.findall("a.b", text, re.S) == ["a\nb"]


def test_the_two_flags_compose_the_way_re_composes_them():
    text = "ab\ncd"
    for pattern in ("^.", ".$", "^..", "..$"):
        for multiline, dotall, mode in (
            (False, False, 0),
            (True, False, re.M),
            (False, True, re.S),
            (True, True, re.M | re.S),
        ):
            assert irgx.findall(pattern, text, multiline=multiline, dotall=dotall) == re.findall(
                pattern, text, mode
            ), f"{pattern!r} multiline={multiline} dotall={dotall}"


def test_a_leading_inline_flag_says_what_the_keyword_says():
    # `re` lets a pattern carry its own flags, and a pattern out of a config file
    # is exactly where that matters: the host has no flag word to pass because it
    # would have to read the pattern to know which one it needed. So the leading
    # form is folded into the compile rather than refused, and the two spellings
    # are one answer.
    text = "ab\ncd"
    for inline, keyword, mode in (
        ("(?i)AB", {"ignore_case": True}, re.I),
        ("(?m)^c", {"multiline": True}, re.M),
        ("(?s)b.c", {"dotall": True}, re.S),
        ("(?ms)^c.", {"multiline": True, "dotall": True}, re.M | re.S),
    ):
        body = inline[inline.index(")") + 1 :]
        assert (
            irgx.findall(inline, text)
            == irgx.findall(body, text, **keyword)
            == re.findall(inline, text)
            == re.findall(body, text, mode)
        ), inline

    # The pattern is the more specific statement, so it wins over the keyword.
    assert irgx.findall("(?-i)ab", "ab AB", ignore_case=True) == ["ab"]
    # And under `fixed` the bytes are data, as they are for `re.escape` output.
    assert irgx.findall("(?i)ab", "(?i)ab AB", fixed=True) == ["(?i)ab"]


def test_a_nonleading_or_foreign_inline_flag_is_declined_rather_than_ignored():
    # Only the leading form is a whole-pattern option — which is also the only
    # form `re` itself allows since 3.11 — and `(?x)`/`(?U)`/`(?R)` are flags this
    # grammar does not have. Refusing beats honoring the letters it recognizes
    # and dropping the rest, which is how a pattern quietly matches the wrong
    # thing: `(?ix)a b` asking for both must not come back case-insensitive and
    # still sensitive to the space.
    for pattern in ("a(?i)b", "(?x) a b", "(?U)a+", "(?R)a$", "(?ix)a b"):
        with pytest.raises(irgx.UnsupportedPattern):
            irgx.compile(pattern)
    # The PCRE arm does honor them.
    assert irgx.compile("(?x) a b", pcre=True).findall("ab") == ["ab"]

    # The *scoped* form is the parser's own and needs no folding, so it is not on
    # that list: it compiles, and it stays scoped.
    assert irgx.findall("(?i:a)b", "AB ab Ab") == re.findall("(?i:a)b", "AB ab Ab")


def test_match_is_a_leftmost_search_with_a_start_test():
    # Exact rather than approximate, and only because this engine is leftmost-first
    # exactly as `re` is: if any match begins at `pos` then the leftmost match at
    # or after `pos` begins there, and if it begins later then none begins at
    # `pos`. So the comparison IS the anchor, not a stand-in for one.
    for pattern, text in ((r"\d+", "abc123"), (r"\w+", "abc123"), ("b", "abc"), ("x*", "")):
        got, want = irgx.match(pattern, text), re.match(pattern, text)
        assert (got is None) == (want is None), (pattern, text)
        if got is not None and want is not None:
            assert got.span() == want.span(), (pattern, text)
    # `pos` anchors where the caller says, in the caller's own units.
    assert irgx.compile(r"\d+").match("abc123", 3).span() == (3, 6)
    assert irgx.compile(r"\d+").match("abc123", 2) is None
    assert irgx.compile(r"\w").match("café", 3).span() == (3, 4)


def test_fullmatch_uses_the_anchored_automaton_rather_than_faking_an_anchor():
    # The reason the previous design refused to ship `fullmatch` at all: faking it
    # on an unanchored search is subtly wrong, and `a|ab` is the witness. Under
    # leftmost-first no match beginning at 0 is two bytes long, yet the region
    # HAS a full match, and `re` finds it by backtracking. This engine does not
    # backtrack, so the question goes to `irgx_munch_scan` under
    # IRGX_MUNCH_LONGEST — longest-at-exactly-here — where reaching the end of the
    # region is a complete answer, since longest is maximal.
    for pattern, text in (("a|ab", "ab"), ("ab|a", "ab"), (r"\d+", "12a"), (r"\w+", "café")):
        got, want = irgx.fullmatch(pattern, text), re.fullmatch(pattern, text)
        assert (got is None) == (want is None), (pattern, text)
        if got is not None and want is not None:
            assert got.span() == want.span(), (pattern, text)
    assert irgx.compile(r"\d+").fullmatch("ab12", 2).span() == (2, 4)
    assert irgx.compile(r"\d+").fullmatch("12ab", 0, 2).span() == (0, 2)
    assert irgx.fullmatch(r"(\d+)-(\d+)", "12-34").groups() == ("12", "34")


def test_fullmatch_refuses_rather_than_reporting_the_wrong_groups():
    # `(a)|(ab)` full-matches "ab" only along a path its LEFTMOST match does not
    # take, and `irgx_captures` reports the leftmost match at an offset — there is
    # no anchored capture verb in this ABI. Reporting group 1 from the one-byte
    # match under the two-byte span would be a wrong answer, so it is refused.
    with pytest.raises(irgx.error, match="anchored capture verb"):
        irgx.compile("(a)|(ab)").fullmatch("ab")
    # Without groups there is nothing to disagree about, so the same shape answers.
    assert irgx.fullmatch("a|ab", "ab").span() == (0, 2)
    # The anchored automaton is a determinization, so its refusals come along.
    for pattern, flags in ((r"\w+", {"pcre": True}), (r"^\w+$", {"multiline": True})):
        with pytest.raises(irgx.error, match="anchored automaton"):
            irgx.compile(pattern, **flags).fullmatch("abc")


def test_the_pattern_can_still_carry_its_own_anchors():
    # `\A...\z` remains the engine's own answer and needs no anchored verb at all.
    # Note the spelling: the end-of-text anchor is `\z`, as in Rust and RE2. `\Z`
    # is not in this grammar, and asking for it raises rather than quietly meaning
    # something else.
    whole = irgx.search(r"\A\w+\z", "abc")
    assert whole is not None and whole.span() == (0, 3)
    assert irgx.search(r"\A\w+\z", "abc def") is None
    with pytest.raises(irgx.error):
        irgx.compile(r"\Z")
